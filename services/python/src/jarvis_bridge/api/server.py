"""JARVIS OS bridge: versioned local HTTP API (v1) consumed by the native Swift control plane."""
from __future__ import annotations
import argparse, asyncio, contextlib, functools, json, os, re, secrets, signal, threading, time
from pathlib import Path
from typing import AsyncIterator
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field
from .. import __version__, API_VERSION
from ..agents.registry import AgentRegistry, AgentDef, ModelAssignment, HierarchyError
from ..agents.runtime import AgentRuntime
from ..discovery.scanner import EndpointScanner
from ..inference.base import ChatMessage, ProviderError, collect as collect_stream
from ..inference.ollama import OllamaProvider
from ..inference.openai_compat import OpenAICompatProvider
from ..mcp.manager import MCPManager, ConfigError, normalize_name
from ..mcp.client import MCPError
from ..chat.orchestrator import ChatServices, run_chat
from ..profile import PROFILE_NAME_KEY, ProfileError, Profile, compile_block, estimate_tokens, MAX_BLOCK_CHARS, LIMITS as PROFILE_LIMITS, CHOICES as PROFILE_CHOICES, ProfileStore
from ..settings import SettingsStore
from ..files.extract import extract as extract_file, UnsupportedFile, ExtractionError, MAX_BYTES
from ..tools.websearch import DuckDuckGoSearch, SearchError
from ..tools.sandbox import ShellSandbox
from ..tools.shell import ShellRunner
from ..tools.files import FileCreator
from ..memory.store import MemoryStore
from ..obsidian.service import ObsidianService
from ..obsidian.vault import VaultError, discover_vaults, validate_root
from ..security.audit import AuditLog
from ..security.netguard import NetPolicy, EndpointRejected
from ..security.policy import PolicyEngine
from ..security.redact import redact, redact_text
from ..orchestration.crew import CrewConfig, CrewEngine, CrewInput, CrewSession
from ..orchestration.governor import ProviderRuntime
from ..tools.sandbox import ShellSandbox
from ..tools.shell import ShellRunner
from dataclasses import replace as dc_replace
from ..orchestration.resources import ModelRow, hardware_info, is_embedding, parse_params_b, read_system, warm_hardware, PREFERENCES

ALLOWED_HOSTS = {"127.0.0.1", "localhost", "[::1]"}
MAX_REQUEST_BYTES = 100 * 1024 * 1024


class AttachmentIn(BaseModel):
    name: str = Field(max_length=255); kind: str = Field(max_length=20)
    text: str | None = Field(default=None, max_length=700_000)
    image_b64: str | None = Field(default=None, max_length=8_000_000)
    note: str | None = Field(default=None, max_length=300)

class ChatMsg(BaseModel):
    role: str = Field(pattern="^(system|user|assistant|tool)$"); content: str = Field(max_length=200_000)
    attachments: list[AttachmentIn] = Field(default_factory=list, max_length=8)

class PageIn(BaseModel):
    """The active browser tab as the app read it. Every field is clamped again in chat/pagecontext.py; these limits just bound the request."""
    url: str = Field(default="", max_length=2048); title: str = Field(default="", max_length=300); tab_id: str | None = Field(default=None, max_length=64)
    status: str = "ready"; status_detail: str | None = Field(default=None, max_length=300)
    lang: str | None = Field(default=None, max_length=20); canonical: str | None = Field(default=None, max_length=2048)
    meta: dict[str, str] = Field(default_factory=dict); structured: list = Field(default_factory=list, max_length=12)
    prices: list[dict] = Field(default_factory=list, max_length=20); specs: list[dict] = Field(default_factory=list, max_length=80)
    headings: list[str] = Field(default_factory=list, max_length=60); tables: list = Field(default_factory=list, max_length=6)
    text: str = Field(default="", max_length=250_000); visible_text: str = Field(default="", max_length=8000)
    selection: str = Field(default="", max_length=8000); ocr_text: str = Field(default="", max_length=20_000)
    links: list[dict] = Field(default_factory=list, max_length=60); scroll: dict = Field(default_factory=dict)
    source: str = "dom"; notes: list[str] = Field(default_factory=list, max_length=10); captured_at: str | None = Field(default=None, max_length=40)

class ChatReq(BaseModel):
    endpoint: str; model: str; messages: list[ChatMsg] = Field(min_length=1, max_length=500)
    temperature: float | None = Field(default=None, ge=0, le=2)
    page: PageIn | None = None                    # the browser tab the user is looking at, when they want to ask about it

class EndpointReq(BaseModel):
    url: str; hint: str = "user-configured"

class MemReq(BaseModel):
    content: str; category: str; project: str | None = None; agent_id: str | None = None
    sensitivity: str = "personal"; subject_key: str | None = None; confirmed: bool = False

class ProfileReq(BaseModel):
    """Every field optional: only what is sent changes. Lengths and choices are validated by ProfileStore."""
    call_me: str | None = None; name: str | None = None; pronouns: str | None = None; language: str | None = None
    time_zone: str | None = None; role: str | None = None; about: str | None = None
    directness: str | None = None; formality: str | None = None; length: str | None = None
    humor: str | None = None; emoji: str | None = None; feedback: str | None = None
    instructions: str | None = None; include: bool | None = None; onboarded: bool | None = None

class ResolveReq(BaseModel):
    approve: bool

class AgentReq(BaseModel):
    id: str; name: str; role: str; instructions: str; parent_id: str | None = None
    allowed_tools: list[str] = []

class AssignReq(BaseModel):
    policy: str = "fixed"; models: list[str] = []; profile: str = "balanced"; escalate_to: list[str] = []

class RunReq(BaseModel):
    prompt: str = Field(max_length=100_000)

class SettingsReq(BaseModel):
    web_search_mode: str | None = None
    web_search_consented: bool | None = None
    web_search_max_results: int | None = Field(default=None, ge=1, le=10)
    memory_auto_inject: bool | None = None
    attachment_context_chars: int | None = Field(default=None, ge=2000, le=100_000)
    page_context_chars: int | None = Field(default=None, ge=2000, le=100_000)
    browser_enabled: bool | None = None
    shell_enabled: bool | None = None
    files_enabled: bool | None = None
    read_paths: bool | None = None
    obsidian_enabled: bool | None = None
    obsidian_vault_path: str | None = Field(default=None, max_length=1000)
    obsidian_auto_context: bool | None = None
    obsidian_store_memories: bool | None = None
    obsidian_allow_write: bool | None = None
    obsidian_context_chars: int | None = Field(default=None, ge=1500, le=40_000)
    obsidian_agent_folder: str | None = Field(default=None, max_length=40)

class ObsConnectReq(BaseModel):
    path: str = Field(max_length=1000)

class ObsReindexReq(BaseModel):
    force: bool = False

class ObsNoteReq(BaseModel):
    title: str = Field(min_length=1, max_length=120); body: str = Field(min_length=1, max_length=200_000)
    tags: list[str] = Field(default_factory=list, max_length=10)

class CrewInputIn(BaseModel):
    name: str = Field(max_length=255); kind: str = Field(default="text", max_length=20)
    text: str = Field(default="", max_length=700_000)
    images_b64: list[str] = Field(default_factory=list, max_length=40)       # page renders for scanned PDFs / photos (app-side, PDFKit)
    worker_model: str | None = Field(default=None, max_length=300)           # force a model for this input; None = automatic
    note: str | None = Field(default=None, max_length=300)

class CrewReq(BaseModel):
    task: str = Field(max_length=20_000); boss: str = Field(max_length=300)
    worker_model: str | None = Field(default=None, max_length=300)
    inputs: list[CrewInputIn] = Field(default_factory=list, max_length=12)
    preference: str = Field(default="auto", pattern="^(auto|parallel|boss_and_one|one_at_a_time|boss_sleeps)$")
    max_workers: int = Field(default=4, ge=1, le=6)
    ui_browser: bool = False                                                  # the app can open pages in each agent's own browser panel
    review: bool = True                                                       # the boss reviews finished reports before the final answer

class CrewMessageReq(BaseModel):
    text: str = Field(min_length=1, max_length=8000)

class CrewShellReq(BaseModel):
    command: str = Field(min_length=1, max_length=2000)

class CrewAnswerReq(BaseModel):
    id: str = Field(max_length=40); text: str = Field(max_length=20_000)

class CrewPageReq(BaseModel):
    agent: str = Field(max_length=20); page: PageIn

class CrewBrowseResultReq(BaseModel):
    id: str = Field(max_length=40); ok: bool; page: PageIn | None = None; error: str | None = Field(default=None, max_length=300)

class SearchTestReq(BaseModel):
    query: str = Field(default="DuckDuckGo", max_length=200)

class McpImportReq(BaseModel):
    text: str = Field(max_length=200_000)
    name: str | None = None
    overwrite: bool = False

class McpSaveReq(BaseModel):
    config: dict | None = None
    text: str | None = Field(default=None, max_length=100_000)     # raw JSON text from the editor (preserves key names exactly)

class TrustReq(BaseModel):
    trusted: bool


class Services:
    def __init__(self, state_dir: Path, *, offline: bool = False, scanner: EndpointScanner | None = None,
                 search: DuckDuckGoSearch | None = None, mcp_http_transport=None, workspace: Path | None = None,
                 sandbox: ShellSandbox | None = None):
        state_dir.mkdir(parents=True, exist_ok=True)
        self.state_dir, self.offline = state_dir, offline
        self.net = NetPolicy(offline_mode=offline)
        self.audit = AuditLog(state_dir / "audit.db")
        self.policy = PolicyEngine(self.audit)
        self.memory = MemoryStore(state_dir / "memory.db")
        self.registry = AgentRegistry(state_dir / "agents.db")
        self.settings = SettingsStore(state_dir / "settings.json")
        self.profile = ProfileStore(state_dir / "profile.json")
        self.scanner = scanner or EndpointScanner(policy=self.net)
        self.search = search or DuckDuckGoSearch(offline=offline)
        self.mcp = MCPManager(state_dir / "mcp", self.policy, state_file=state_dir / "mcp_state.json",
                              net_policy=self.net, http_transport=mcp_http_transport)
        self.providers: dict = {}
        self.runtime = AgentRuntime(self.registry, self.policy, self._resolve, self._stream)
        self.sandbox = sandbox or ShellSandbox(workspace or state_dir / "workspace")
        self.shell = ShellRunner(self.sandbox, self.policy, self.audit)
        self.files = FileCreator(self.sandbox.workspace, self.policy)
        self.obsidian = ObsidianService(self.settings, state_dir, self.memory, audit=lambda **kw: self.audit.record(**kw))
        self.chat = ChatServices(self.memory, self.settings, self.search, self.mcp, self.shell, self.files, obsidian=self.obsidian, profile=self.profile)
        self.crews: dict = {}                       # crew id -> CrewSession (one running at a time: crews share the machine's memory; the last finished one is kept for follow-up chats)
        self._agent_shells: dict = {}               # (crew id, agent id) -> ShellRunner with that agent's own private workspace
        warm_hardware()                             # read CPU/GPU facts in the background so the first memory reading is not slow

    async def startup(self):
        """Reconnect servers the user already approved (best effort; failures are visible in their status)."""
        for e in self.mcp.list_entries():
            if e.config is not None and e.approved and e.enabled:
                try: await self.mcp.connect(e.name)
                except Exception: pass

    def provider_for(self, key: str):
        ep = next((e for e in self.scanner.endpoints() if e.key == key), None)
        if ep is None or not ep.usable:
            raise HTTPException(404, f"endpoint {key!r} is unknown or not validated")
        p = self.providers.get(key)
        if p is None:
            p = OllamaProvider(ep.base_url, provider_id=key, policy=self.net) if ep.kind == "ollama" else \
                OpenAICompatProvider(ep.base_url, provider_id=key, policy=self.net)
            self.providers[key] = p
        return p

    def _resolve(self, agent, assignment):
        return list(assignment.models)            # "endpointkey|model" refs, validated at run time

    async def _stream(self, ref: str, msgs: list):
        key, _, model = ref.partition("|")
        async for c in self.provider_for(key).chat_stream(model, msgs):
            yield c

    # ---- crew (boss + workers) ----
    async def model_rows(self) -> dict:
        """Every local chat model as a ModelRow keyed by 'endpoint|model' (remote providers are never used by a crew)."""
        rows: dict = {}
        for e in self.scanner.endpoints():
            if not e.usable: continue
            try:
                prov = self.provider_for(e.key)
                if not prov.local: continue
                models = await prov.list_models()
            except Exception: continue
            for m in models:
                ref = f"{e.key}|{m.id}"
                rows[ref] = ModelRow(ref, m.id, m.size_bytes, parse_params_b(m.parameter_size, m.id, m.size_bytes), m.capabilities.vision,
                                     m.capabilities.chat is not False and not is_embedding(m.id), bool(getattr(prov, "can_manage_memory", False)), m.context_length)
        return rows

    def agent_shell(self, crew: str, agent: str) -> ShellRunner:
        """Each agent gets its OWN terminal: the same allow-list, approval rules and OS sandbox, but a private workspace folder
        (workspace/agents/<crew>/<agent>), so one agent's files never mix with another's."""
        key = (crew, agent)
        runner = self._agent_shells.get(key)
        if runner is None:
            main = self.shell.sandbox
            box = ShellSandbox(main.workspace / "agents" / crew / agent, backend=main.backend, node=main.node, timeout=main.timeout)
            runner = ShellRunner(box, self.policy, self.audit)
            if len(self._agent_shells) > 60: self._agent_shells.pop(next(iter(self._agent_shells)))
            self._agent_shells[key] = runner
        return runner

    def model_runtime(self) -> ProviderRuntime:
        return ProviderRuntime(lambda: [(e.key, self.providers[e.key]) for e in self.scanner.endpoints() if e.usable and e.key in self.providers])

    async def crew_engine(self) -> CrewEngine:
        rows = await self.model_rows()
        async def llm(ref: str, msgs: list) -> str:
            key, _, model = ref.partition("|")
            text, _last = await asyncio.wait_for(collect_stream(self.provider_for(key).chat_stream(model, msgs)), 900)
            return text
        async def agent_chat(ref: str, msgs: list, page: dict | None = None, agent: str | None = None, crew: str | None = None):
            key, _, model = ref.partition("|"); prov = self.provider_for(key)
            def stream(m, messages): return prov.chat_stream(m, messages)
            chat = dc_replace(self.chat, shell=self.agent_shell(crew, agent)) if (agent and crew and self.chat.shell is not None) else self.chat
            async for ev in run_chat(stream, model, list(msgs), chat, supports_vision=rows[ref].vision if ref in rows else None, page=page):
                yield redact(ev)
        return CrewEngine(llm=llm, agent_chat=agent_chat, models=rows, runtime=self.model_runtime(), sysmem=read_system)

    async def close(self):
        for p in self.providers.values(): await p.aclose()
        await self.mcp.close()


def create_app(state_dir: str | Path, token: str, *, offline: bool = False, services: Services | None = None) -> FastAPI:
    svc = services or Services(Path(state_dir), offline=offline)

    @contextlib.asynccontextmanager
    async def lifespan(_app):
        asyncio.create_task(svc.startup())
        yield
        await svc.close()

    app = FastAPI(title="JARVIS OS bridge", version=__version__, docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.svc = svc

    @app.middleware("http")
    async def guard(request: Request, call_next):
        host = (request.headers.get("host") or "").rsplit(":", 1)[0] if not (request.headers.get("host") or "").startswith("[") \
            else (request.headers.get("host") or "").split("]")[0] + "]"
        if host not in ALLOWED_HOSTS:                                          # DNS-rebinding defence
            return JSONResponse({"error": "bad host"}, 421)
        if "origin" in request.headers:                                        # we are not a browser API
            return JSONResponse({"error": "browser origins are not permitted"}, 403)
        if not secrets.compare_digest((request.headers.get("authorization") or "").encode(), f"Bearer {token}".encode()):
            return JSONResponse({"error": "unauthorized"}, 401)
        try: declared = int(request.headers.get("content-length", "0"))
        except ValueError: declared = 0
        if declared > MAX_REQUEST_BYTES:                                       # bounded memory: one oversized body cannot exhaust the bridge
            return JSONResponse({"error": "request too large"}, 413)
        return await call_next(request)

    @app.exception_handler(Exception)
    async def boom(request: Request, exc: Exception):                          # never leak secrets in errors
        return JSONResponse({"error": "internal_error", "detail": redact_text(f"{type(exc).__name__}: {exc}")}, 500)

    v = f"/{API_VERSION}"

    def _pdf_ready() -> bool:
        try:
            import importlib; importlib.invalidate_caches(); importlib.import_module("pypdf"); return True
        except Exception: return False

    @app.get(v + "/health")
    async def health():
        import sys
        return {"ok": True, "bridge_version": __version__, "api_version": API_VERSION, "offline_mode": svc.offline,
                "memory_schema": svc.memory.schema_version, "python": sys.executable, "pdf_support": _pdf_ready()}

    # ---- providers & models ----
    @app.get(v + "/providers")
    async def providers():
        return [{"key": e.key, "base_url": e.base_url, "kind": e.kind, "status": e.status, "owner": e.owner, "hint": e.hint,
                 "version": e.version, "models": e.models, "latency_ms": e.latency_ms, "last_seen": e.last_seen,
                 "last_error": e.last_error, "failures": e.failures} for e in svc.scanner.endpoints()]

    @app.post(v + "/providers/scan")
    async def scan():
        ev = await svc.scanner.scan_once(manual=True)
        return {"events": [e.__dict__ for e in ev], "log_tail": svc.scanner.log[-20:]}

    @app.post(v + "/providers/endpoints")
    async def add_endpoint(r: EndpointReq):
        try: ep = svc.scanner.add_user_endpoint(r.url, r.hint)
        except EndpointRejected as e: raise HTTPException(422, str(e))
        await svc.scanner.scan_once(manual=True); return {"key": ep.key, "status": ep.status}

    @app.delete(v + "/providers/endpoints/{key}")
    async def rm_endpoint(key: str):
        if not svc.scanner.remove(key): raise HTTPException(404, "unknown endpoint")
        p = svc.providers.pop(key, None)
        if p: await p.aclose()
        return {"removed": key}

    @app.get(v + "/models")
    async def models():
        out = []
        for e in svc.scanner.endpoints():
            if not e.usable: continue
            try: ms = await svc.provider_for(e.key).list_models()
            except ProviderError as ex: out.append({"endpoint": e.key, "error": ex.as_dict()}); continue
            out += [{"endpoint": e.key, "id": m.id, "size_bytes": m.size_bytes, "family": m.family, "quantization": m.quantization,
                     "context_length": m.context_length, "capabilities": m.capabilities.__dict__, "local": m.local} for m in ms]
        return out

    @app.post(v + "/chat")
    async def chat(r: ChatReq):
        prov = svc.provider_for(r.endpoint)
        if not prov.local and svc.offline: raise HTTPException(409, "offline mode is on; remote providers are disabled")
        if not prov.local: raise HTTPException(409, "remote provider requires explicit per-request approval")
        msgs = [ChatMessage(m.role, m.content, attachments=tuple(a.model_dump() for a in m.attachments)) for m in r.messages]
        supports_vision = None
        if any(a.image_b64 for m in r.messages for a in m.attachments):
            try:
                info = next((x for x in await prov.list_models() if x.id == r.model), None)
                supports_vision = info.capabilities.vision if info else None
            except ProviderError: supports_vision = None
        opts = {"temperature": r.temperature} if r.temperature is not None else {}
        def stream(model, messages): return prov.chat_stream(model, messages, **opts)
        async def sse() -> AsyncIterator[str]:
            try:
                async for ev in run_chat(stream, r.model, msgs, svc.chat, supports_vision=supports_vision, page=r.page.model_dump() if r.page else None):
                    yield "data: " + json.dumps(redact(ev)) + "\n\n"
            except Exception as e:                                            # never leave the client hanging
                yield "data: " + json.dumps({"error": {"kind": "internal", "message": redact_text(f"{type(e).__name__}: {e}")}}) + "\n\n"
        return StreamingResponse(sse(), media_type="text/event-stream")

    # ---- files ----
    @app.post(v + "/files/extract")
    async def files_extract(request: Request):
        """Raw file bytes in the body, original name in X-Filename (percent-encoded). Returns extracted text."""
        from urllib.parse import unquote
        try: declared = int(request.headers.get("content-length", "0"))
        except ValueError: declared = 0
        if declared > MAX_BYTES + 1024: raise HTTPException(413, f"File is larger than the {MAX_BYTES // 2**20} MB limit.")
        data = await request.body()
        name = unquote(request.headers.get("x-filename", "file"))
        try:
            ex = await asyncio.wait_for(asyncio.to_thread(extract_file, name, data), 45)
        except UnsupportedFile as e: raise HTTPException(415, str(e))
        except ExtractionError as e: raise HTTPException(422, str(e))
        except asyncio.TimeoutError: raise HTTPException(422, "Reading this file took too long and was stopped.")
        svc.audit.record(actor="user", decision="file_attached", target=redact_text(ex.name)[:120], detail={"kind": ex.kind, "chars": ex.chars, "bytes": len(data)})
        return {"name": ex.name, "kind": ex.kind, "text": ex.text, "chars": ex.chars, "truncated": ex.truncated, "warning": ex.warning}

    # ---- settings & web search ----
    @app.get(v + "/settings")
    async def get_settings():
        from dataclasses import asdict
        return {**asdict(svc.settings.value), "web_search_active": svc.settings.value.web_search_active, "offline_mode": svc.offline}

    @app.put(v + "/settings")
    async def put_settings(r: SettingsReq):
        from dataclasses import asdict
        try: new = svc.settings.update(**{k: x for k, x in r.model_dump().items() if x is not None})
        except ValueError as e: raise HTTPException(422, str(e))
        svc.audit.record(actor="user", decision="settings_changed", detail=asdict(new))
        return {**asdict(new), "web_search_active": new.web_search_active, "offline_mode": svc.offline}

    @app.post(v + "/tools/web_search/test")
    async def web_search_test(r: SearchTestReq):
        if not svc.settings.value.web_search_consented: raise HTTPException(409, "web search needs your one-time permission first")
        try: res = await svc.search.search(r.query, max_results=svc.settings.value.web_search_max_results)
        except SearchError as e: raise HTTPException(502, str(e))
        return {"query": r.query, "results": [x.__dict__ for x in res]}

    # ---- profile: who the user is, how they like answers, their standing instructions ----
    def _profile_out() -> dict:
        d = svc.profile.describe()
        d["choices"] = {k: [c for c in t if c] for k, t in PROFILE_CHOICES.items()}
        return d

    def _sync_name_memory() -> None:
        """What to call the user is also their first memory (visible and editable in the Memory screen). Kept in step with the profile."""
        who = svc.profile.value.call_me or svc.profile.value.name
        if not who: return
        text = f"The user goes by {who}. Address them as {who}."
        existing = svc.memory.find_by_subject(PROFILE_NAME_KEY)
        if existing is None:
            svc.memory.add(text, category="preference", source="user", subject_key=PROFILE_NAME_KEY, confirmed=True, provenance={"via": "profile"})
        elif existing.content != text:
            svc.memory.edit(existing.id, text)

    @app.get(v + "/profile")
    async def get_profile(): return _profile_out()

    @app.put(v + "/profile")
    async def put_profile(r: ProfileReq):
        changes = {k: x for k, x in r.model_dump().items() if x is not None}
        try: svc.profile.update(**changes)
        except ProfileError as e: raise HTTPException(422, str(e))
        if "call_me" in changes or "name" in changes: _sync_name_memory()
        svc.audit.record(actor="user", decision="profile_changed", detail={"fields": sorted(changes)})        # which fields, never their text
        return _profile_out()

    @app.post(v + "/profile/preview")
    async def preview_profile(r: ProfileReq):
        """What the model would receive for these (unsaved) values, and what it costs. Powers the live token meter."""
        from dataclasses import asdict
        try: p = Profile(**{**asdict(svc.profile.value), **{k: x for k, x in r.model_dump().items() if x is not None}}).validate()
        except ProfileError as e:
            return {"ok": False, "error": str(e), "compiled": "", "chars": 0, "tokens": 0, "max_chars": MAX_BLOCK_CHARS}
        block = compile_block(p)
        return {"ok": True, "error": None, "compiled": block, "chars": len(block), "tokens": estimate_tokens(block), "max_chars": MAX_BLOCK_CHARS}

    # ---- sandboxed terminal ----
    @app.get(v + "/shell/status")
    async def shell_status():
        return {"enabled": svc.settings.value.shell_enabled, **svc.sandbox.status()}

    @app.post(v + "/shell/selftest")
    async def shell_selftest():
        """User-initiated: runs fixed probes that try to delete/write/spawn/connect/read from inside the sandbox."""
        checks = await svc.sandbox.selftest(svc.state_dir)
        svc.audit.record(actor="user", decision="shell_selftest", detail={"ok": all(c.ok for c in checks)})
        return {"ok": all(c.ok for c in checks), "checks": [c.__dict__ for c in checks]}

    # ---- memory ----
    @app.post(v + "/memory")
    async def mem_add(r: MemReq):
        try: m = svc.memory.add(r.content, category=r.category, source="user", project=r.project, agent_id=r.agent_id,
                                sensitivity=r.sensitivity, subject_key=r.subject_key, confirmed=r.confirmed)
        except ValueError as e: raise HTTPException(422, str(e))
        return m.__dict__

    @app.get(v + "/memory")
    async def mem_list(category: str | None = None, status: str | None = None, project: str | None = None, limit: int = 200):
        """Everything saved, newest first (the Memory screen shows this when it opens, so nothing hides behind a search)."""
        return [m.__dict__ for m in svc.memory.list(category=category, status=status, project=project, limit=max(1, min(limit, 1000)))]

    @app.get(v + "/memory/search")
    async def mem_search(q: str, project: str | None = None, agent_id: str | None = None, limit: int = 8):
        return [{"memory": h.memory.__dict__, "score": h.score, "why": h.why} for h in svc.memory.search(q, project=project, agent_id=agent_id, limit=min(limit, 50))]

    @app.post(v + "/memory/{mid}/confirm")
    async def mem_confirm(mid: str):
        if not svc.memory.get(mid, touch=False): raise HTTPException(404, "unknown memory")
        return svc.memory.confirm(mid).__dict__

    @app.delete(v + "/memory/{mid}")
    async def mem_del(mid: str):
        if not svc.memory.delete(mid): raise HTTPException(404, "unknown memory")
        return {"deleted": mid}

    @app.get(v + "/memory/stats")
    async def mem_stats(): return svc.memory.storage_stats()

    # ---- approvals & audit ----
    @app.get(v + "/approvals")
    async def approvals():
        return [{"id": p.approval_id, "tool": p.request.tool_id, "target": p.request.target, "agent": p.request.agent_id,
                 "args": redact(p.request.args), "flags": sorted(p.request.flags)} for p in svc.policy.pending()]

    @app.post(v + "/approvals/{aid}/resolve")
    async def resolve(aid: str, r: ResolveReq):
        try: svc.policy.resolve(aid, r.approve)
        except KeyError: raise HTTPException(404, "no such pending approval")
        return {"id": aid, "approved": r.approve}

    @app.get(v + "/audit")
    async def audit(limit: int = 100): return svc.audit.query(limit=min(limit, 1000))

    # ---- agents ----
    @app.get(v + "/agents/tree")
    async def tree(): return svc.registry.tree()

    @app.post(v + "/agents")
    async def create_agent(r: AgentReq):
        try: a = svc.registry.create(AgentDef(**r.model_dump()))
        except HierarchyError as e: raise HTTPException(422, str(e))
        return a.__dict__

    @app.put(v + "/agents/{aid}/models")
    async def assign(aid: str, r: AssignReq):
        try: svc.registry.assign_models(aid, ModelAssignment(**r.model_dump()))
        except KeyError: raise HTTPException(404, "unknown agent")
        return {"agent": aid, **r.model_dump()}

    @app.post(v + "/agents/{aid}/run")
    async def run_agent(aid: str, r: RunReq):
        t = await svc.runtime.run(aid, r.prompt)
        return {"id": t.id, "state": t.state.value, "output": t.output, "error": t.error, "model": t.model_used, "degraded": t.degraded,
                "tokens": {"prompt": t.prompt_tokens, "completion": t.completion_tokens}, "duration_s": t.duration,
                "trace": [{"ts": e.ts, "kind": e.kind, "detail": redact(e.detail)} for e in t.trace]}

    # ---- Obsidian vault (knowledge base + memory storage) ----
    obs = svc.obsidian

    def _obs_active():
        if not obs.active: raise HTTPException(409, obs.issue or "No Obsidian vault is connected. Choose one in Settings → Obsidian.")

    def _background(fn, *a, **kw):
        asyncio.get_running_loop().create_task(asyncio.to_thread(fn, *a, **kw))

    @app.get(v + "/obsidian/status")
    async def obsidian_status():
        st = obs.status()
        if st["active"] and not st["last_index"]:                                  # first look since the bridge started: index and sync in the background
            def warm():
                try: obs.refresh(max_seconds=300); obs.sync_memories()
                except Exception: pass
            _background(warm)
        return st

    @app.get(v + "/obsidian/discover")
    async def obsidian_discover(): return {"vaults": discover_vaults()}

    @app.post(v + "/obsidian/connect")
    async def obsidian_connect(r: ObsConnectReq):
        try: root = validate_root(r.path)
        except VaultError as e: raise HTTPException(422, str(e))
        svc.settings.update(obsidian_enabled=True, obsidian_vault_path=str(root))
        svc.audit.record(actor="user", decision="obsidian_connected", detail={"vault": root.name})
        if not obs.active: raise HTTPException(422, obs.issue or "That folder can't be used as a vault.")
        rep = await asyncio.to_thread(obs.refresh, max_seconds=8)
        if rep.get("pending"): _background(obs.refresh, max_seconds=600)
        _background(obs.sync_memories)
        return obs.status()

    @app.post(v + "/obsidian/reindex")
    async def obsidian_reindex(r: ObsReindexReq):
        _obs_active()
        rep = await asyncio.to_thread(obs.refresh, force=r.force, max_seconds=15)
        if rep.get("pending"): _background(obs.refresh, max_seconds=600)
        return {**obs.status(), "report": rep}

    @app.post(v + "/obsidian/memories/sync")
    async def obsidian_sync():
        _obs_active()
        if not svc.settings.value.obsidian_store_memories: raise HTTPException(409, "Storing memories in the vault is turned off in Settings.")
        return await asyncio.to_thread(obs.sync_memories)

    @app.get(v + "/obsidian/search")
    async def obsidian_search(q: str, limit: int = 8, folder: str | None = None, tag: str | None = None):
        _obs_active()
        hits = await asyncio.to_thread(obs.search, q[:500], min(max(limit, 1), 30), folder=folder, tag=tag)
        return [{"path": h.rel, "title": h.title, "heading": h.heading or None, "excerpt": redact_text(h.text.strip())[:500], "score": round(h.score, 3), "tags": h.tags} for h in hits]

    @app.get(v + "/obsidian/note")
    async def obsidian_note(path: str):
        _obs_active()
        n = await asyncio.to_thread(obs.read, path, 60_000)
        if n is None: raise HTTPException(404, "no such note")
        n["body"] = redact_text(n["body"]); n.pop("frontmatter", None)
        return n

    @app.post(v + "/obsidian/note")
    async def obsidian_new_note(r: ObsNoteReq):
        """The user saves something to the vault (for example 'Save to Obsidian'). New notes only, in the ArjunOS folder."""
        _obs_active()
        try: return await asyncio.to_thread(obs.create_note_as_user, r.title, r.body, r.tags)
        except VaultError as e: raise HTTPException(422, str(e))

    @app.get(v + "/obsidian/recent")
    async def obsidian_recent(limit: int = 20):
        _obs_active(); await asyncio.to_thread(obs.ensure_fresh)
        return {"notes": obs.index.recent(min(max(limit, 1), 100)), "tags": obs.index.tags(40)}

    # ---- system resources & crews ----
    @app.get(v + "/system/resources")
    async def system_resources():
        eng = await svc.crew_engine()
        try: loaded = await eng.runtime.loaded()
        except Exception: loaded = {}
        await asyncio.to_thread(hardware_info)                                  # cached after the first call
        return {**read_system().as_dict(), "loaded": [{"ref": r, "bytes": b} for r, b in sorted(loaded.items())],
                "models": [{"ref": m.ref, "id": m.id, "size_bytes": m.size_bytes, "params_b": m.params_b, "vision": m.vision,
                            "manageable": m.manageable, "context_length": m.context_length}
                           for m in eng.models.values() if m.chat]}

    def _crew_inputs(r: CrewReq) -> list:
        return [CrewInput(i.name, i.kind, i.text, list(i.images_b64), i.worker_model, i.note) for i in r.inputs]

    def _crew_cfg(r: CrewReq) -> CrewConfig:
        return CrewConfig(boss=r.boss, worker_model=r.worker_model, preference=r.preference, max_workers=r.max_workers, review=r.review,
                          attachment_chars=min(svc.settings.value.attachment_context_chars, 60_000))

    async def _crew_checked(r: CrewReq):
        eng = await svc.crew_engine()
        for ref in [r.boss, r.worker_model, *[i.worker_model for i in r.inputs]]:
            if ref and ref not in eng.models: raise HTTPException(422, f"{ref.partition('|')[2] or ref} isn't an installed local model")
        return eng

    @app.post(v + "/crew/preview")
    async def crew_preview(r: CrewReq):
        """What would run and how: the memory mode, which small model each file gets. Loads nothing."""
        eng = await _crew_checked(r); cfg = _crew_cfg(r)
        plan, rows = await eng.make_plan(cfg, _crew_inputs(r))
        return {"plan": plan.as_dict(), "system": read_system().as_dict(), "boss": r.boss,
                "workers": [{"ref": w.ref, "id": w.id, "vision": w.vision, "params_b": w.params_b, "size_bytes": w.size_bytes} for w in rows]}

    @app.post(v + "/crew/run")
    async def crew_run(r: CrewReq):
        if any(s_.running for s_ in svc.crews.values()):
            raise HTTPException(409, "A crew is already running. Stop it first: crews share your Mac's memory.")
        eng = await _crew_checked(r)
        for old in [k for k, s_ in svc.crews.items() if not s_.running]: svc.crews.pop(old, None)        # only the latest finished crew is kept
        session = CrewSession(); session.has_ui_browser = r.ui_browser; svc.crews[session.id] = session
        svc.audit.record(actor="user", decision="crew_started", detail={"boss": r.boss, "inputs": len(r.inputs), "preference": r.preference})
        eng.start(session, r.task, _crew_inputs(r), _crew_cfg(r))
        async def sse() -> AsyncIterator[str]:
            try:
                yield "data: " + json.dumps({"crew_id": session.id}) + "\n\n"
                async for ev in eng.stream(session, heartbeat=5.0):
                    yield "data: " + json.dumps(redact(ev)) + "\n\n"
            except Exception as e:
                yield "data: " + json.dumps({"error": {"kind": "internal", "message": redact_text(f"{type(e).__name__}: {e}")}}) + "\n\n"
            finally:
                session.cancel(); session.finished_at = time.time()           # the app went away or the run ended; the session stays so you can keep talking to its agents
        return StreamingResponse(sse(), media_type="text/event-stream")

    def _crew(cid: str) -> CrewSession:
        s_ = svc.crews.get(cid)
        if s_ is not None and not s_.running and s_.finished_at and time.time() - s_.finished_at > 7200:
            svc.crews.pop(cid, None); s_ = None                                  # a finished crew is forgotten after two hours
        if s_ is None: raise HTTPException(404, "no such crew")
        return s_

    def _agent_id(aid: str) -> str:
        if not re.fullmatch(r"boss|w[0-9]{1,3}", aid): raise HTTPException(422, "not a valid agent id")
        return aid

    @app.post(v + "/crew/{cid}/answer")
    async def crew_answer(cid: str, r: CrewAnswerReq):
        if not _crew(cid).answer(r.id, r.text): raise HTTPException(404, "that question is no longer waiting")
        return {"ok": True}

    @app.post(v + "/crew/{cid}/page")
    async def crew_page(cid: str, r: CrewPageReq):
        """The app pushes what an agent's own browser panel is showing; that agent sees it as its page context from its next step."""
        s_ = _crew(cid); s_.pages[r.agent] = r.page.model_dump(); s_.has_ui_browser = True
        return {"ok": True}

    @app.post(v + "/crew/{cid}/browse_result")
    async def crew_browse_result(cid: str, r: CrewBrowseResultReq):
        res = {"ok": r.ok, "page": r.page.model_dump() if r.page else None, "error": r.error}
        if not _crew(cid).browse_result(r.id, res): raise HTTPException(404, "that page request is no longer waiting")
        return {"ok": True}

    @app.post(v + "/crew/{cid}/agents/{aid}/message")
    async def crew_agent_message(cid: str, aid: str, r: CrewMessageReq):
        """Say something to an agent that is working right now; it sees it at its next step."""
        s_ = _crew(cid); _agent_id(aid)
        if not s_.running: raise HTTPException(409, "The crew isn't running. Use chat to talk to this agent.")
        if aid != "boss":
            sub = s_.run.subs.get(aid) if s_.run else None
            if sub is None: raise HTTPException(404, "no such agent")
            if sub.state not in ("queued", "working", "waiting_user"): raise HTTPException(409, "That agent has finished. Use chat to talk to it.")
        s_.send_to_agent(aid, r.text)
        return {"queued": True}

    @app.post(v + "/crew/{cid}/agents/{aid}/chat")
    async def crew_agent_chat(cid: str, aid: str, r: CrewMessageReq):
        """A follow-up chat with one agent (streams events). Wakes its model if it is asleep, within what memory allows."""
        s_ = _crew(cid); _agent_id(aid)
        if s_.run is None: raise HTTPException(409, "This crew never got started.")
        if aid == "boss" and s_.running: raise HTTPException(409, "The boss is busy running the crew. Send it a message instead.")
        busy = getattr(s_, "_chatting", None)
        if busy is None: busy = s_._chatting = set()
        if aid in busy: raise HTTPException(409, "This agent is already answering. Wait for it to finish.")
        busy.add(aid)
        async def sse() -> AsyncIterator[str]:
            try:
                async for ev in s_.run.e.chat(s_, aid, r.text):
                    yield "data: " + json.dumps(redact(ev)) + "\n\n"
            except Exception as e:
                yield "data: " + json.dumps({"error": {"kind": "internal", "message": redact_text(f"{type(e).__name__}: {e}")}}) + "\n\n"
            finally: busy.discard(aid)
        return StreamingResponse(sse(), media_type="text/event-stream")

    @app.get(v + "/crew/{cid}/agents/{aid}/terminal")
    async def crew_agent_terminal(cid: str, aid: str):
        _crew(cid); _agent_id(aid)
        if svc.shell is None or not svc.settings.value.shell_enabled: return {"enabled": False}
        st = svc.agent_shell(cid, aid).sandbox.status()
        return {"enabled": True, "workspace": st["workspace"], "allowed": st["allowed"], "javascript_ready": st["javascript_ready"], "sandbox": st["sandbox"]}

    @app.post(v + "/crew/{cid}/agents/{aid}/shell")
    async def crew_agent_shell(cid: str, aid: str, r: CrewShellReq):
        """A command YOU type in an agent's terminal: same allow-list and sandbox as the agent's own, in that agent's private workspace."""
        _crew(cid); _agent_id(aid)
        if svc.shell is None or not svc.settings.value.shell_enabled: raise HTTPException(409, "The terminal is turned off in Settings.")
        return await svc.agent_shell(cid, aid).run_user(r.command, label=f"{cid}/{aid}")

    @app.post(v + "/crew/{cid}/cancel")
    async def crew_cancel(cid: str):
        _crew(cid).cancel(); return {"ok": True}

    # ---- MCP (one JSON file per server) ----
    def mcp_call(fn):
        @functools.wraps(fn)
        async def wrapper(*a, **k):
            try: return await fn(*a, **k)
            except KeyError: raise HTTPException(404, "unknown MCP server")
            except (ConfigError, MCPError) as e: raise HTTPException(422, redact_text(str(e)))
        return wrapper

    @app.get(v + "/mcp/servers")
    async def mcp_list(): return svc.mcp.status()

    @app.get(v + "/mcp/directory")
    async def mcp_dir(): return {"path": str(svc.mcp.dir)}

    @app.post(v + "/mcp/servers/import")
    @mcp_call
    async def mcp_import(r: McpImportReq): return {"created": await svc.mcp.import_text(r.text, name=r.name, overwrite=r.overwrite)}

    @app.put(v + "/mcp/servers/{name}")
    @mcp_call
    async def mcp_save(name: str, r: McpSaveReq):
        if r.text is not None:
            try: cfg = json.loads(r.text)
            except json.JSONDecodeError as e: raise ConfigError(f"not valid JSON: {e}")
        elif r.config is not None: cfg = r.config
        else: raise ConfigError("send the server JSON as \"text\"")
        await svc.mcp.save(name, cfg); return next(x for x in svc.mcp.status() if x["name"] == normalize_name(name))

    @app.delete(v + "/mcp/servers/{name}")
    @mcp_call
    async def mcp_delete(name: str): await svc.mcp.delete(name); return {"deleted": normalize_name(name)}

    @app.post(v + "/mcp/servers/{name}/approve")
    @mcp_call
    async def mcp_approve(name: str):
        svc.mcp.approve(name); svc.audit.record(actor="user", decision="mcp_server_approved", tool_id=f"mcp:{normalize_name(name)}")
        return {"approved": normalize_name(name)}

    @app.post(v + "/mcp/servers/{name}/connect")
    @mcp_call
    async def mcp_connect(name: str):
        await svc.mcp.connect(name); return next(x for x in svc.mcp.status() if x["name"] == normalize_name(name))

    @app.post(v + "/mcp/servers/{name}/disconnect")
    @mcp_call
    async def mcp_disconnect(name: str): await svc.mcp.disconnect(name); return {"disconnected": normalize_name(name)}

    @app.post(v + "/mcp/servers/{name}/tools/{tool}/trust")
    @mcp_call
    async def mcp_trust(name: str, tool: str, r: TrustReq):
        (svc.mcp.trust_tool if r.trusted else svc.mcp.untrust_tool)(normalize_name(name), tool); return {"tool": tool, "trusted": r.trusted}

    return app


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _terminate_self() -> None:
    """Graceful: SIGTERM lets uvicorn run shutdown (which stops MCP server child processes). Hard exit only as a fallback."""
    t = threading.Timer(8.0, lambda: os._exit(0)); t.daemon = True; t.start()
    os.kill(os.getpid(), signal.SIGTERM)


def watch_parent(pid: int, *, interval: float = 2.0, on_gone=_terminate_self, alive=_pid_alive) -> threading.Thread:
    """Exit when the host app dies, so a crashed/force-quit app never leaves an orphaned bridge behind."""
    def loop():
        while True:
            time.sleep(interval)
            if not alive(pid):
                on_gone(); return
    t = threading.Thread(target=loop, daemon=True, name="parent-watchdog"); t.start(); return t


def main():
    ap = argparse.ArgumentParser(prog="jarvis-bridge")
    ap.add_argument("--state-dir", required=True); ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--parent-pid", type=int, default=0, help="exit when this process disappears")
    a = ap.parse_args()
    if a.parent_pid > 0: watch_parent(a.parent_pid)
    token = os.environ.pop("JARVIS_BRIDGE_TOKEN", "")
    if len(token) < 32: raise SystemExit("JARVIS_BRIDGE_TOKEN (>=32 chars) must be supplied by the host app")
    import uvicorn
    uvicorn.run(create_app(a.state_dir, token, offline=a.offline), host="127.0.0.1", port=a.port, log_level="warning")

if __name__ == "__main__":
    main()
