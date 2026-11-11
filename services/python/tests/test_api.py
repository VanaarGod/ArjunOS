import json, httpx, pytest
from jarvis_bridge.api.server import create_app, Services
from jarvis_bridge.discovery.scanner import EndpointScanner
from jarvis_bridge.security.netguard import NetPolicy
import ipaddress
from jarvis_bridge.tools.websearch import DuckDuckGoSearch
from test_websearch import PAGE
from mockservers import serve, fake_ollama, free_port

TOKEN = "t" * 40

class Env:
    def __init__(self, tmp, ollama_port, offline=False, ddg=None):
        sc = EndpointScanner(candidates=[("Ollama", f"http://127.0.0.1:{ollama_port}")], policy=NetPolicy(offline_mode=offline))
        self.ddg_hits = []
        def handler(req):
            self.ddg_hits.append(str(req.url)); return httpx.Response(200, text=PAGE)
        search = DuckDuckGoSearch(offline=offline, transport=httpx.MockTransport(ddg or handler), resolver=lambda h: [ipaddress.ip_address("52.149.246.39")])
        self.svc = Services(tmp, offline=offline, scanner=sc, search=search)
        self.app = create_app(tmp, TOKEN, services=self.svc)
        self.key = f"127.0.0.1:{ollama_port}"
    def client(self, token=TOKEN, host="127.0.0.1:8765", **h):
        hdr = {"Host": host, **({"Authorization": f"Bearer {token}"} if token else {}), **h}
        return httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="http://127.0.0.1:8765", headers=hdr, timeout=20)

# ---------- guards ----------
async def test_auth_host_and_origin_guards(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client(token=None) as c: assert (await c.get("/v1/health")).status_code == 401
    async with e.client(token="wrong" * 8) as c: assert (await c.get("/v1/health")).status_code == 401
    async with e.client(host="evil.example.com") as c: assert (await c.get("/v1/health")).status_code == 421      # DNS rebinding
    async with e.client(Origin="http://evil.example.com") as c: assert (await c.get("/v1/health")).status_code == 403
    async with e.client() as c:
        r = await c.get("/v1/health"); assert r.status_code == 200 and r.json()["api_version"] == "v1"
    async with e.client(host="localhost:9") as c: assert (await c.get("/v1/health")).status_code == 200

# ---------- the vertical slice ----------
async def test_discover_list_chat_stream_and_agent_run(tmp_path):
    with serve(fake_ollama()) as p:
        e = Env(tmp_path, p)
        async with e.client() as c:
            assert (await c.get("/v1/providers")).json()[0]["status"] == "unreachable"      # honest before any scan
            ev = (await c.post("/v1/providers/scan")).json()["events"]
            assert ev[0]["type"] == "endpoint_up"
            prov = (await c.get("/v1/providers")).json()[0]
            assert prov["kind"] == "ollama" and prov["models"] == ["llama3.2:3b", "qwen2.5-coder:7b"]
            ms = (await c.get("/v1/models")).json()
            assert {m["id"] for m in ms} == {"llama3.2:3b", "qwen2.5-coder:7b"}
            assert next(m for m in ms if m["id"] == "llama3.2:3b")["capabilities"]["tools"] is True
            # streaming chat over SSE
            body = {"endpoint": e.key, "model": "llama3.2:3b", "messages": [{"role": "user", "content": "hi"}]}
            async with c.stream("POST", "/v1/chat", json=body) as r:
                events = [json.loads(l[6:]) async for l in r.aiter_lines() if l.startswith("data: ")]
            assert "".join(x.get("delta", "") for x in events) == "Hello from mock Ollama" and events[-1]["done"] and events[-1]["completion_tokens"] == 4
            # unknown model => typed error event, not a crash
            body["model"] = "ghost"
            async with c.stream("POST", "/v1/chat", json=body) as r:
                events = [json.loads(l[6:]) async for l in r.aiter_lines() if l.startswith("data: ")]
            assert events[0]["error"]["kind"] == "not_found"
            # agent run through assigned model, with trace
            assert (await c.put("/v1/agents/research/models", json={"policy": "fixed", "models": [f"{e.key}|llama3.2:3b"]})).status_code == 200
            run = (await c.post("/v1/agents/research/run", json={"prompt": "summarise"})).json()
            assert run["state"] == "succeeded" and run["output"] == "Hello from mock Ollama" and run["model"].endswith("llama3.2:3b")
            assert [t["kind"] for t in run["trace"]] == ["requested", "model_attempt", "completed"]
        await e.svc.close()

async def test_unknown_or_unvalidated_endpoint_cannot_be_used(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        body = {"endpoint": e.key, "model": "m", "messages": [{"role": "user", "content": "x"}]}
        assert (await c.post("/v1/chat", json=body)).status_code == 404                  # never scanned/validated
        body["endpoint"] = "8.8.8.8:80"; assert (await c.post("/v1/chat", json=body)).status_code == 404

async def test_user_endpoint_policy_via_api(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        for bad in ("http://169.254.169.254/v1", "http://192.168.1.4:8000/v1", "file:///etc/passwd"):
            assert (await c.post("/v1/providers/endpoints", json={"url": bad})).status_code == 422
        assert (await c.delete("/v1/providers/endpoints/nope")).status_code == 404

async def test_request_validation(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        assert (await c.post("/v1/chat", json={"endpoint": "x", "model": "m", "messages": []})).status_code == 422
        assert (await c.post("/v1/chat", json={"endpoint": "x", "model": "m", "messages": [{"role": "hacker", "content": "x"}]})).status_code == 422

# ---------- memory / approvals / agents / mcp ----------
async def test_memory_lifecycle_and_persistence(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        m = (await c.post("/v1/memory", json={"content": "prefers metric units", "category": "preference"})).json()
        assert m["status"] == "proposed"                                                  # not auto-confirmed
        assert (await c.get("/v1/memory/search", params={"q": "metric"})).json() == []
        assert (await c.post(f"/v1/memory/{m['id']}/confirm")).json()["status"] == "confirmed"
        hit = (await c.get("/v1/memory/search", params={"q": "metric"})).json()[0]
        assert hit["memory"]["content"] == "prefers metric units" and "lexical" in hit["why"]
        assert (await c.post("/v1/memory", json={"content": "x", "category": "bogus"})).status_code == 422
    e2 = Env(tmp_path, free_port())                                                       # "restart"
    async with e2.client() as c:
        assert (await c.get("/v1/memory/search", params={"q": "metric"})).json()
        mid = (await c.get("/v1/memory/search", params={"q": "metric"})).json()[0]["memory"]["id"]
        assert (await c.delete(f"/v1/memory/{mid}")).status_code == 200 and (await c.delete(f"/v1/memory/{mid}")).status_code == 404

async def test_approvals_listing_and_resolution_redacts_secrets(tmp_path):
    from jarvis_bridge.security.policy import ActionRequest
    e = Env(tmp_path, free_port())
    d = e.svc.policy.authorize(ActionRequest(actor="agent", tool_id="mcp:x/send", target="x", args={"api_key": "sk-abcdefghijklmnopqrstuvwx", "to": "a@b.c"}))
    async with e.client() as c:
        lst = (await c.get("/v1/approvals")).json()
        assert lst[0]["id"] == d.approval_id and "sk-abcdef" not in json.dumps(lst) and lst[0]["args"]["to"] == "a@b.c"
        assert (await c.post(f"/v1/approvals/{d.approval_id}/resolve", json={"approve": False})).status_code == 200
        assert (await c.post(f"/v1/approvals/{d.approval_id}/resolve", json={"approve": True})).status_code == 404   # can't flip later
        assert (await c.get("/v1/approvals")).json() == []
        assert any(a["decision"] == "approval_denied" for a in (await c.get("/v1/audit")).json())

async def test_agent_tree_create_assign_and_errors(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        assert (await c.get("/v1/agents/tree")).json()[0]["id"] == "jarvis"
        assert (await c.post("/v1/agents", json={"id": "legal", "name": "Legal", "role": "custom", "instructions": "x", "parent_id": "research"})).status_code == 200
        assert (await c.post("/v1/agents", json={"id": "bad", "name": "b", "role": "r", "instructions": "x", "parent_id": "ghost"})).status_code == 422
        assert (await c.put("/v1/agents/ghost/models", json={"models": []})).status_code == 404
        run = (await c.post("/v1/agents/research/run", json={"prompt": "x"})).json()
        assert run["state"] == "failed" and "no model" in run["error"]                    # honest, no fake output

async def test_offline_mode_reported_and_blocks_remote_scan_targets(tmp_path):
    e = Env(tmp_path, free_port(), offline=True)
    async with e.client() as c:
        assert (await c.get("/v1/health")).json()["offline_mode"] is True
        assert (await c.post("/v1/providers/endpoints", json={"url": "https://api.openai.com/v1"})).status_code == 422


# ---------- parent watchdog ----------
def test_watchdog_fires_when_parent_is_gone_and_not_before():
    import subprocess, sys, threading
    from jarvis_bridge.api.server import watch_parent, _pid_alive
    alive = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    try:
        fired = threading.Event(); watch_parent(alive.pid, interval=0.05, on_gone=fired.set)
        assert not fired.wait(0.3)                       # parent still alive => must not fire
    finally:
        alive.kill(); alive.wait()
    assert not _pid_alive(alive.pid)                     # reaped => really gone
    fired2 = threading.Event(); watch_parent(alive.pid, interval=0.05, on_gone=fired2.set)
    assert fired2.wait(2.0)

def test_watchdog_treats_permission_error_as_alive(monkeypatch):
    import os
    from jarvis_bridge.api import server
    def deny(pid, sig): raise PermissionError
    monkeypatch.setattr(os, "kill", deny)
    assert server._pid_alive(1) is True


# ---------- settings, search, remember, MCP over the API ----------
async def sse_events(c, body):
    async with c.stream("POST", "/v1/chat", json=body) as r:
        return [json.loads(l[6:]) async for l in r.aiter_lines() if l.startswith("data: ")]

async def test_settings_default_to_no_search_until_consent_and_validate(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        s = (await c.get("/v1/settings")).json()
        assert s["web_search_consented"] is False and s["web_search_active"] is False and s["web_search_mode"] == "auto"
        assert (await c.post("/v1/tools/web_search/test", json={"query": "x"})).status_code == 409        # no consent, no network
        assert (await c.put("/v1/settings", json={"web_search_mode": "always"})).status_code == 422
        assert (await c.put("/v1/settings", json={"web_search_max_results": 99})).status_code == 422
        s = (await c.put("/v1/settings", json={"web_search_consented": True})).json(); assert s["web_search_active"] is True
        assert any(a["decision"] == "settings_changed" for a in (await c.get("/v1/audit")).json())
        r = (await c.post("/v1/tools/web_search/test", json={"query": "example"})).json()
        assert r["results"][0]["url"] == "https://example.com/a?x=1"
    assert len(e.ddg_hits) == 1
    e2 = Env(tmp_path, free_port())                                                                          # persisted
    async with e2.client() as c: assert (await c.get("/v1/settings")).json()["web_search_consented"] is True

async def test_web_search_test_endpoint_reports_failures_as_502(tmp_path):
    e = Env(tmp_path, free_port(), ddg=lambda r: httpx.Response(429, text="slow"))
    e.svc.settings.update(web_search_consented=True)
    async with e.client() as c:
        r = await c.post("/v1/tools/web_search/test", json={"query": "x"}); assert r.status_code == 502 and "429" in r.json()["detail"]

async def test_chat_with_search_keyword_end_to_end(tmp_path):
    with serve(fake_ollama()) as p:
        e = Env(tmp_path, p); e.svc.settings.update(web_search_consented=True)
        async with e.client() as c:
            await c.post("/v1/providers/scan")
            body = {"endpoint": e.key, "model": "llama3.2:3b", "messages": [{"role": "user", "content": "search for example domain"}]}
            ev = await sse_events(c, body)
        tools = [x["tool"] for x in ev if "tool" in x]
        assert [t["status"] for t in tools] == ["running", "done"] and tools[1]["results"][0]["title"] == "Example Domain & more"
        assert "".join(x.get("delta", "") for x in ev) == "Hello from mock Ollama" and ev[-1]["done"] is True
        assert len(e.ddg_hits) == 1
        await e.svc.close()

async def test_chat_without_consent_never_touches_the_network_and_says_so(tmp_path):
    with serve(fake_ollama()) as p:
        e = Env(tmp_path, p)
        async with e.client() as c:
            await c.post("/v1/providers/scan")
            ev = await sse_events(c, {"endpoint": e.key, "model": "llama3.2:3b", "messages": [{"role": "user", "content": "search for cats"}]})
        assert not e.ddg_hits and any("permission" in x.get("notice", "") for x in ev)
        await e.svc.close()

async def test_remember_through_chat_writes_a_memory_that_is_then_used(tmp_path):
    with serve(fake_ollama()) as p:
        e = Env(tmp_path, p)
        async with e.client() as c:
            await c.post("/v1/providers/scan")
            ev = await sse_events(c, {"endpoint": e.key, "model": "llama3.2:3b", "messages": [{"role": "user", "content": "remember that my cat is called Biscuit"}]})
            saved = next(x for x in ev if "memory_saved" in x)["memory_saved"]
            assert "Biscuit" in saved["content"] or "cat" in saved["content"]
            hit = (await c.get("/v1/memory/search", params={"q": "cat Biscuit"})).json()
            assert hit and hit[0]["memory"]["status"] == "confirmed" and hit[0]["memory"]["source"] == "user"
            ev2 = await sse_events(c, {"endpoint": e.key, "model": "llama3.2:3b", "messages": [{"role": "user", "content": "what is my cat called?"}]})
            assert any("memory_used" in x for x in ev2)
        await e.svc.close()

async def test_mcp_servers_are_managed_one_file_at_a_time_over_the_api(tmp_path):
    import sys
    from test_mcp import SERVER
    e = Env(tmp_path, free_port())
    cfg = {"command": sys.executable, "args": [SERVER]}
    async with e.client() as c:
        assert (await c.get("/v1/mcp/servers")).json() == []
        assert (await c.get("/v1/mcp/directory")).json()["path"].endswith("mcp")
        r = await c.put("/v1/mcp/servers/Calc", json={"config": cfg}); assert r.status_code == 200 and r.json()["name"] == "calc"
        assert (tmp_path / "mcp" / "calc.json").exists() and r.json()["approved"] is False and r.json()["state"] == "disconnected"
        assert (await c.post("/v1/mcp/servers/calc/connect")).status_code == 422                       # needs approval first
        assert (await c.post("/v1/mcp/servers/calc/approve")).status_code == 200
        s = (await c.post("/v1/mcp/servers/calc/connect")).json()
        assert s["state"] == "ready" and {t["name"] for t in s["tools"]} >= {"echo", "add"}
        assert (await c.post("/v1/mcp/servers/calc/tools/add/trust", json={"trusted": True})).json()["trusted"] is True
        assert next(t for t in (await c.get("/v1/mcp/servers")).json()[0]["tools"] if t["name"] == "add")["trusted"]
        # editing what runs revokes approval and disconnects
        r = await c.put("/v1/mcp/servers/calc", json={"config": {**cfg, "args": [SERVER, "--no-tools"]}}); assert r.json()["approved"] is False and r.json()["state"] == "disconnected"
        assert (await c.put("/v1/mcp/servers/bad", json={"config": {"command": ""}})).status_code == 422
        assert (await c.put("/v1/mcp/servers/bad", json={"text": "{not json"})).status_code == 422
        assert (await c.put("/v1/mcp/servers/bad", json={})).status_code == 422
        txt = '{"command": "echo", "env": {"MY_VAR": "1", "snake_case_var": "2"}}'
        saved = (await c.put("/v1/mcp/servers/texty", json={"text": txt})).json()
        assert json.loads(saved["config_text"])["env"] == {"MY_VAR": "1", "snake_case_var": "2"}              # key names preserved exactly
        await c.delete("/v1/mcp/servers/texty")
        assert (await c.put("/v1/mcp/servers/..%2Fevil", json={"config": cfg})).status_code in (404, 422)
        imp = await c.post("/v1/mcp/servers/import", json={"text": json.dumps({"mcpServers": {"a": {"command": "echo"}, "b": {"url": "https://x.example/mcp"}}})})
        assert sorted(imp.json()["created"]) == ["a", "b"] and (tmp_path / "mcp" / "a.json").exists() and (tmp_path / "mcp" / "b.json").exists()
        assert (await c.post("/v1/mcp/servers/import", json={"text": "nope"})).status_code == 422
        assert (await c.delete("/v1/mcp/servers/a")).status_code == 200 and not (tmp_path / "mcp" / "a.json").exists()
        assert (await c.delete("/v1/mcp/servers/a")).status_code == 404
    await e.svc.close()

async def test_approved_servers_reconnect_on_startup(tmp_path):
    import sys
    from test_mcp import SERVER
    e = Env(tmp_path, free_port()); await e.svc.mcp.save("calc", {"command": sys.executable, "args": [SERVER]}); e.svc.mcp.approve("calc"); await e.svc.close()
    e2 = Env(tmp_path, free_port()); await e2.svc.startup()
    assert e2.svc.mcp.status()[0]["state"] == "ready"; await e2.svc.close()


# ---------- file attachments over the API ----------
from officegen import make_pdf, make_docx, make_xlsx
from urllib.parse import quote

async def upload(c, name, data, **kw):
    return await c.post("/v1/files/extract", content=data, headers={"X-Filename": quote(name), "Content-Type": "application/octet-stream"}, **kw)

async def test_upload_extracts_text_pdf_docx_xlsx_and_decodes_the_filename(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        r = (await upload(c, "résumé notes.md", "# Hello\nwörld".encode())).json(); assert r["name"] == "résumé notes.md" and r["kind"] == "text" and "wörld" in r["text"] and r["truncated"] is False
        r = (await upload(c, "r.pdf", make_pdf([["Quarterly revenue grew 12 percent"]]))).json(); assert r["kind"] == "pdf" and "revenue grew 12 percent" in r["text"]
        r = (await upload(c, "m.docx", make_docx(["Agenda", "Item one"], headings={0: 1}))).json(); assert r["kind"] == "docx" and "# Agenda" in r["text"]
        r = (await upload(c, "b.xlsx", make_xlsx({"Sheet": [["Item", "Cost"], ["GPU", 1200]]}))).json(); assert r["kind"] == "xlsx" and "GPU | 1200" in r["text"]

async def test_upload_errors_are_specific_and_never_500(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        r = await upload(c, "a.doc", b"x"); assert r.status_code == 200 and r.json()["kind"] == "legacy" and "old binary format" in r.json()["warning"]
        assert (await upload(c, "pic.png", b"\x89PNG")).status_code == 415                                 # images go to vision models instead
        r = await upload(c, "bin.dat", bytes(range(256)) * 50); assert r.status_code == 200 and r.json()["kind"] == "binary"
        assert (await upload(c, "broken.pdf", b"%PDF-1.4 nope")).status_code == 422
        assert (await upload(c, "x.docx", b"PK\x03\x04junk")).status_code == 422
        big = await c.post("/v1/files/extract", content=b"a" * (26 * 1024 * 1024), headers={"X-Filename": "big.txt"}); assert big.status_code == 413

async def test_upload_requires_the_bridge_token_and_audit_log_holds_no_file_content(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client(token=None) as c: assert (await upload(c, "a.txt", b"hi")).status_code == 401
    async with e.client() as c:
        await upload(c, "diary.txt", b"my very private diary entry about sk-abcdefghijklmnopqrstuvwx")
        log = json.dumps((await c.get("/v1/audit")).json())
        assert "file_attached" in log and "diary.txt" in log and "private diary" not in log and "sk-abcdef" not in log

async def test_attachment_settings_roundtrip_and_validation(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        assert (await c.get("/v1/settings")).json()["attachment_context_chars"] == 12000
        assert (await c.put("/v1/settings", json={"attachment_context_chars": 24000})).json()["attachment_context_chars"] == 24000
        for bad in (100, 10**7): assert (await c.put("/v1/settings", json={"attachment_context_chars": bad})).status_code == 422

async def test_chat_with_a_file_streams_a_files_used_event(tmp_path):
    with serve(fake_ollama()) as p:
        e = Env(tmp_path, p)
        async with e.client() as c:
            await c.post("/v1/providers/scan")
            body = {"endpoint": e.key, "model": "llama3.2:3b", "messages": [{"role": "user", "content": "how long is the warranty?",
                    "attachments": [{"name": "manual.pdf", "kind": "pdf", "text": "Warranty: the compressor is covered for 36 months."}]}]}
            ev = await sse_events(c, body)
        used = next(x for x in ev if "files_used" in x)["files_used"][0]
        assert used["name"] == "manual.pdf" and used["excerpted"] is False and used["total_chars"] == len("Warranty: the compressor is covered for 36 months.")
        await e.svc.close()

async def test_images_reach_vision_models_and_are_withheld_from_text_only_models(tmp_path):
    app = fake_ollama(("llama3.2:3b", "llava:7b"))
    with serve(app) as p:
        e = Env(tmp_path, p)
        async with e.client() as c:
            await c.post("/v1/providers/scan")
            def body(model): return {"endpoint": e.key, "model": model, "messages": [{"role": "user", "content": "what is this?", "attachments": [{"name": "cat.jpg", "kind": "image", "image_b64": "QUJDRA=="}]}]}
            ev_v = await sse_events(c, body("llava:7b")); ev_t = await sse_events(c, body("llama3.2:3b"))
        chats = app.state.s["chats"]
        vision_call = next(x for x in chats if x["model"] == "llava:7b"); text_call = next(x for x in chats if x["model"] == "llama3.2:3b")
        assert any(m.get("images") == ["QUJDRA=="] for m in vision_call["messages"] if m["role"] == "user") and not any("notice" in x for x in ev_v)
        assert not any(m.get("images") for m in text_call["messages"]) and any("can't view images" in x.get("notice", "") for x in ev_t)
        await e.svc.close()

async def test_what_the_model_actually_received_contains_the_fenced_file_text(tmp_path):
    app = fake_ollama()
    with serve(app) as p:
        e = Env(tmp_path, p)
        async with e.client() as c:
            await c.post("/v1/providers/scan")
            await sse_events(c, {"endpoint": e.key, "model": "llama3.2:3b", "messages": [{"role": "user", "content": "how long is the warranty?",
                "attachments": [{"name": "manual.pdf", "kind": "pdf", "text": "The compressor warranty lasts 36 months."}]}]})
        system = next(m["content"] for m in app.state.s["chats"][-1]["messages"] if m["role"] == "system")
        assert "36 months" in system and "<<<UNTRUSTED" in system and 'Attached file "manual.pdf"' in system
        await e.svc.close()

async def test_attachment_limits_are_enforced_by_the_schema(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        many = [{"name": f"f{i}.txt", "kind": "text", "text": "x"} for i in range(9)]
        r = await c.post("/v1/chat", json={"endpoint": "x", "model": "m", "messages": [{"role": "user", "content": "hi", "attachments": many}]}); assert r.status_code == 422
        huge = [{"name": "h.txt", "kind": "text", "text": "x" * 700_001}]
        r = await c.post("/v1/chat", json={"endpoint": "x", "model": "m", "messages": [{"role": "user", "content": "hi", "attachments": huge}]}); assert r.status_code == 422


async def test_oversized_requests_are_rejected_before_being_read(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        r = await c.post("/v1/memory", content=b"{}", headers={"Content-Length": str(101 * 1024 * 1024), "Content-Type": "application/json"})
        assert r.status_code == 413


async def test_health_reports_python_and_pdf_support(tmp_path):
    import sys
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        h = (await c.get("/v1/health")).json()
        assert h["python"] == sys.executable and h["pdf_support"] is True
