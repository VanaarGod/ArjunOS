"""MCP servers as one JSON file each:  <state>/mcp/<name>.json

  stdio:  {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents"], "env": {"K": "v"}}
  http :  {"url": "https://example.com/mcp", "headers": {"Authorization": "Bearer ..."}}
  both :  optional {"enabled": true, "description": "..."}

Safety: nothing launches until the user approves THAT file's exact contents (any edit revokes approval);
tool calls go through the policy gate (approval-required by default); env values are never logged.
"""
from __future__ import annotations
import asyncio, hashlib, json, os, re, tempfile, time
from dataclasses import dataclass, field
from pathlib import Path
from ..security.netguard import NetPolicy
from ..security.policy import ActionRequest, PolicyEngine, Risk, Verdict
from ..security.redact import redact, redact_text
from .bridge import MCPBridge, _RISKY_CMDS, _SENSITIVE_ENV, tool_id
from .client import MCPClient, MCPError, ServerSpec, State

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,39}$")
KNOWN_KEYS = {"command", "args", "env", "cwd", "url", "headers", "enabled", "description", "name", "transport"}


class ConfigError(ValueError): ...


def normalize_name(raw: str) -> str:
    n = re.sub(r"[^a-z0-9_-]+", "-", (raw or "").strip().lower()).strip("-_")
    if not NAME_RE.match(n): raise ConfigError(f"invalid server name {raw!r} (use letters, digits, - and _; max 40 chars)")
    return n


def validate_config(cfg: object) -> dict:
    if not isinstance(cfg, dict): raise ConfigError("a server config must be a JSON object")
    has_cmd, has_url = "command" in cfg, "url" in cfg
    if has_cmd == has_url: raise ConfigError("config needs exactly one of \"command\" (local server) or \"url\" (remote server)")
    if has_cmd:
        if not isinstance(cfg["command"], str) or not cfg["command"].strip(): raise ConfigError("\"command\" must be a non-empty string")
        if not isinstance(cfg.get("args", []), list) or not all(isinstance(a, (str, int, float)) for a in cfg.get("args", [])):
            raise ConfigError("\"args\" must be a list of strings")
    else:
        if not isinstance(cfg["url"], str) or not cfg["url"].startswith(("http://", "https://")): raise ConfigError("\"url\" must start with http:// or https://")
    for k in ("env", "headers"):
        v = cfg.get(k, {})
        if not isinstance(v, dict) or not all(isinstance(x, (str, int, float, bool)) for x in v.values()): raise ConfigError(f"\"{k}\" must be an object of simple values")
    if "enabled" in cfg and not isinstance(cfg["enabled"], bool): raise ConfigError("\"enabled\" must be true or false")
    return cfg


def fingerprint(cfg: dict) -> str:
    run = {k: cfg.get(k) for k in ("command", "args", "env", "cwd", "url", "headers")}
    return hashlib.sha256(json.dumps(run, sort_keys=True, default=str).encode()).hexdigest()


def to_spec(name: str, cfg: dict, *, approved: bool) -> ServerSpec:
    if "command" in cfg:
        return ServerSpec(name=name, transport="stdio", command=cfg["command"], args=[str(a) for a in cfg.get("args", [])],
                          env={k: str(v) for k, v in (cfg.get("env") or {}).items()}, cwd=cfg.get("cwd"),
                          enabled=cfg.get("enabled", True), approved=approved)
    return ServerSpec(name=name, transport="http", url=cfg["url"], headers={k: str(v) for k, v in (cfg.get("headers") or {}).items()},
                      enabled=cfg.get("enabled", True), approved=approved)


def describe(cfg: dict) -> tuple[str, list]:
    warnings: list = []
    if "command" in cfg:
        args = [str(a) for a in cfg.get("args", [])]
        summary = "Runs a local program: " + " ".join([cfg["command"], *args])
        base = cfg["command"].rsplit("/", 1)[-1]
        if base in _RISKY_CMDS: warnings.append(f"launches {base!r}, which can run arbitrary commands")
        if any(a in ("-c", "/c", "-Command") for a in args): warnings.append("passes an inline command string")
        if base in ("npx", "uvx", "pipx", "bunx"): warnings.append(f"downloads and runs a package when it starts (via {base})")
    else:
        summary = f"Connects to a remote server: {cfg['url']}"
        if cfg["url"].startswith("http://"): warnings.append("unencrypted http")
    for n in [*(cfg.get("env") or {}), *(f"header {h}" for h in (cfg.get("headers") or {}))]:
        if any(s in n.lower() for s in _SENSITIVE_ENV): warnings.append(f"{n} looks like a credential stored in this file (keep the file private)")
    return summary, warnings


@dataclass
class Entry:
    name: str
    config: dict | None = None
    error: str | None = None             # file could not be read/validated
    summary: str = ""
    warnings: list = field(default_factory=list)
    env_names: list = field(default_factory=list)
    approved: bool = False
    enabled: bool = True


class MCPManager:
    APPROVAL_WAIT = 120.0

    def __init__(self, directory: str | Path, policy: PolicyEngine, *, state_file: str | Path, net_policy: NetPolicy = NetPolicy(),
                 http_transport=None):
        self.dir = Path(directory); self.dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.policy, self.net_policy, self.http_transport = policy, net_policy, http_transport
        self.bridge = MCPBridge(policy)
        self._state_file = Path(state_file)
        self._state = self._load_state()
        self.clients: dict[str, MCPClient] = {}
        self._tools: dict[str, list] = {}

    # ---------------- persistence ----------------
    def _load_state(self) -> dict:
        try: s = json.loads(self._state_file.read_text()); return {"approved": dict(s.get("approved", {})), "trusted": list(s.get("trusted", []))}
        except Exception: return {"approved": {}, "trusted": []}

    def _save_state(self):
        self._atomic(self._state_file, json.dumps(self._state, indent=2))

    @staticmethod
    def _atomic(path: Path, text: str):
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
        with os.fdopen(fd, "w") as f: f.write(text)
        os.chmod(tmp, 0o600); os.replace(tmp, path)       # may hold credentials: owner-only

    def _path(self, name: str) -> Path:
        return self.dir / f"{normalize_name(name)}.json"

    # ---------------- files ----------------
    def list_entries(self) -> list:
        out = []
        for p in sorted(self.dir.glob("*.json")):
            name = p.stem
            if not NAME_RE.match(name): out.append(Entry(name, error="file name must be lowercase letters, digits, - or _")); continue
            try:
                cfg = validate_config(json.loads(p.read_text()))
                summary, warns = describe(cfg)
                out.append(Entry(name, cfg, None, summary, warns, [*(cfg.get("env") or {}), *(f"header:{h}" for h in (cfg.get("headers") or {}))],
                                 self._state["approved"].get(name) == fingerprint(cfg), cfg.get("enabled", True)))
            except (ConfigError, json.JSONDecodeError, OSError) as e:
                out.append(Entry(name, error=f"{type(e).__name__}: {e}"))
        return out

    def get_entry(self, name: str) -> Entry:
        e = next((x for x in self.list_entries() if x.name == normalize_name(name)), None)
        if e is None: raise KeyError(name)
        return e

    async def save(self, name: str, cfg: dict) -> Entry:
        name = normalize_name(name); validate_config(cfg)
        if isinstance(cfg.get("name"), str) and normalize_name(cfg["name"]) != name: raise ConfigError("\"name\" inside the file must match the file name")
        old = self._read_raw(name)
        self._atomic(self._path(name), json.dumps(cfg, indent=2) + "\n")
        if old is not None and fingerprint(old) != fingerprint(cfg):          # edited what runs => approval revoked
            self._state["approved"].pop(name, None); self._save_state()
            await self.disconnect(name)
        return self.get_entry(name)

    def _read_raw(self, name: str) -> dict | None:
        try: return json.loads(self._path(name).read_text())
        except Exception: return None

    async def import_text(self, text: str, *, name: str | None = None, overwrite: bool = False) -> list:
        """Accepts one server object (needs `name`), a {"mcpServers": {...}} block (many), or {"name": {...}} maps."""
        try: data = json.loads(text)
        except json.JSONDecodeError as e: raise ConfigError(f"not valid JSON: {e}")
        if not isinstance(data, dict): raise ConfigError("expected a JSON object")
        if isinstance(data.get("mcpServers"), dict): items = data["mcpServers"]
        elif "command" in data or "url" in data:
            if not name: raise ConfigError("a single server config needs a name")
            items = {name: data}
        elif data and all(isinstance(v, dict) and ("command" in v or "url" in v) for v in data.values()): items = data
        else: raise ConfigError("no MCP server found: expected {\"command\": ...}, {\"url\": ...} or {\"mcpServers\": {...}}")
        created = []
        for raw, cfg in items.items():
            n = normalize_name(raw); validate_config(cfg)
            if self._path(n).exists() and not overwrite: raise ConfigError(f"a server named {n!r} already exists")
            created.append((n, cfg))
        for n, cfg in created: await self.save(n, cfg)
        return [n for n, _ in created]

    async def delete(self, name: str):
        n = normalize_name(name); await self.disconnect(n)
        try: self._path(n).unlink()
        except FileNotFoundError: raise KeyError(n)
        self._state["approved"].pop(n, None)
        self._state["trusted"] = [t for t in self._state["trusted"] if not t.startswith(n + "/")]; self._save_state()

    # ---------------- approval & connection ----------------
    def approve(self, name: str) -> Entry:
        e = self.get_entry(name)
        if e.error or e.config is None: raise ConfigError(f"fix the file first: {e.error}")
        self._state["approved"][e.name] = fingerprint(e.config); self._save_state()
        return self.get_entry(name)

    async def connect(self, name: str) -> MCPClient:
        e = self.get_entry(name)
        if e.error or e.config is None: raise ConfigError(f"fix the file first: {e.error}")
        if not e.enabled: raise MCPError("server is disabled (\"enabled\": false)")
        if not e.approved: raise MCPError("not approved: review what this server runs, then approve it")
        await self.disconnect(e.name)
        c = MCPClient(to_spec(e.name, e.config, approved=True), net_policy=self.net_policy, http_transport=self.http_transport)
        self.clients[e.name] = c
        try:
            await c.connect()
            self._tools[e.name] = await self.bridge.attach(c)
        except Exception:
            self._tools.pop(e.name, None); raise                       # client stays registered so its error is visible
        for t in self._tools[e.name]:
            if f"{e.name}/{t['name']}" in self._state["trusted"]: self._apply_trust(e.name, t["name"])
        return c

    async def disconnect(self, name: str):
        n = normalize_name(name); c = self.clients.pop(n, None); self._tools.pop(n, None); self.bridge.clients.pop(n, None)
        if c: await c.close()

    async def close(self):
        for n in list(self.clients): await self.disconnect(n)

    def _apply_trust(self, server: str, tool: str):
        tid = tool_id(server, tool); self.policy.register_tool(tid, Risk.MONITORED); self.policy.grant_standing(tid, "jarvis")

    def trust_tool(self, server: str, tool: str):
        self._apply_trust(server, tool); key = f"{server}/{tool}"
        if key not in self._state["trusted"]: self._state["trusted"].append(key); self._save_state()

    def untrust_tool(self, server: str, tool: str):
        tid = tool_id(server, tool); self.policy.revoke_grant(tid, "jarvis"); self.policy.register_tool(tid, Risk.APPROVAL_REQUIRED)
        self._state["trusted"] = [t for t in self._state["trusted"] if t != f"{server}/{tool}"]; self._save_state()

    def status(self) -> list:
        out = []
        for e in self.list_entries():
            c = self.clients.get(e.name)
            raw = None
            try: raw = self._path(e.name).read_text()
            except OSError: pass
            out.append({"name": e.name, "error": e.error, "config": e.config, "config_text": raw, "summary": e.summary, "warnings": e.warnings,
                        "env_names": e.env_names, "approved": e.approved, "enabled": e.enabled,
                        "state": c.state.value if c else "disconnected", "connection_error": c.last_error if c else None,
                        "server": c.server_info if c else {}, "advertised": sorted(c.capabilities) if c else [],
                        "tools": [{"name": t["name"], "description": redact_text(str(t.get("description", "")))[:300],
                                   "trusted": f"{e.name}/{t['name']}" in self._state["trusted"]} for t in self._tools.get(e.name, [])],
                        "log_tail": list(c.logs)[-10:] if c else []})
        return out

    # ---------------- model-facing runner (McpRunner protocol) ----------------
    def describe(self) -> str | None:
        lines = []
        for n, tools in sorted(self._tools.items()):
            if n in self.clients and self.clients[n].state is State.READY:
                for t in tools: lines.append(f"- {n}.{t['name']}: {redact_text(str(t.get('description', '')))[:160]}")
        return "\n".join(lines) or None

    async def call(self, qualified: str, args: dict, emit) -> str:
        server, _, tool = qualified.partition(".")
        base = {"name": qualified, "args": redact(args)}
        if not tool or server not in self.clients or self.clients[server].state is not State.READY:
            emit({"tool": {**base, "status": "error", "error": "no such connected tool"}}); return f"Unknown or disconnected tool {qualified!r}."
        emit({"tool": {**base, "status": "running"}})
        r = await self.bridge.invoke(server, tool, args, actor="agent", agent_id="jarvis")
        if r.decision.verdict is Verdict.NEEDS_APPROVAL:
            aid = r.decision.approval_id
            emit({"approval": {"id": aid, "tool": qualified, "args": redact(args)}})
            emit({"tool": {**base, "status": "waiting_approval"}})
            deadline = time.monotonic() + self.APPROVAL_WAIT
            while time.monotonic() < deadline:
                st = self.policy._pending[aid].status
                if st != "pending": break
                await asyncio.sleep(0.1)
            st = self.policy._pending[aid].status
            if st == "approved":
                r = await self.bridge.invoke(server, tool, args, actor="agent", agent_id="jarvis", approval_id=aid)
            else:
                msg = "The user denied this tool call." if st == "denied" else "The user did not respond to the approval request in time."
                emit({"tool": {**base, "status": "error", "error": msg}}); return msg + " Do not retry; explain this to the user."
        if not r.decision.allowed:
            emit({"tool": {**base, "status": "error", "error": r.decision.reason}}); return f"Blocked by policy: {r.decision.reason}."
        emit({"tool": {**base, "status": "error" if r.is_error else "done"}})
        return r.text or ""
