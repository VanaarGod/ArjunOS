#!/usr/bin/env python3
"""Generate API contract fixtures from the REAL bridge app (mock Ollama backend) for the Swift tests.
   python scripts/gen_fixtures.py [--check]   (--check exits 1 if committed fixtures are stale)"""
import asyncio, json, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "services/python/src"), str(ROOT / "services/python/tests")]
import httpx
from jarvis_bridge.api.server import create_app, Services
from jarvis_bridge.discovery.scanner import EndpointScanner
from jarvis_bridge.security.policy import ActionRequest
from mockservers import serve, fake_ollama
from test_mcp import SERVER as FAKE_MCP
from test_websearch import PAGE
from jarvis_bridge.tools.websearch import DuckDuckGoSearch
from jarvis_bridge.tools.sandbox import ShellSandbox
from jarvis_bridge.tools.shell import ShellRunner
import ipaddress

OUT = ROOT / "apps/macos/Tests/JarvisCoreTests/Fixtures"
TOKEN = "f" * 40

def stable(o):
    """Replace volatile values (ids, timestamps, ports, latencies) so fixtures are deterministic."""
    if isinstance(o, dict):
        return {k: (0.0 if k in ("created", "last_seen", "ts", "latency_ms", "duration_s", "last_accessed", "score", "recency", "updated") and isinstance(v, (int, float)) and v is not None
                    else stable(v)) for k, v in o.items()}
    if isinstance(o, list): return [stable(x) for x in o]
    if isinstance(o, str):
        import re
        o = o.replace(sys.executable, "PYTHON").replace(FAKE_MCP, "FAKE_MCP.py")
        o = re.sub(r"127\.0\.0\.1:\d+", "127.0.0.1:PORT", o)
        o = re.sub(r"(mem|appr|task)_[0-9a-f]{8,}", r"\1_ID", o)
        return o
    return o

async def build() -> dict:
    out = {}
    with serve(fake_ollama()) as port, tempfile.TemporaryDirectory() as td:
        sc = EndpointScanner(candidates=[("Ollama", f"http://127.0.0.1:{port}")])
        ddg = DuckDuckGoSearch(transport=httpx.MockTransport(lambda r: httpx.Response(200, text=PAGE)),
                               resolver=lambda h: [ipaddress.ip_address("52.149.246.39")])
        svc = Services(Path(td), scanner=sc, search=ddg); app = create_app(td, TOKEN, services=svc)
        key = f"127.0.0.1:{port}"
        c = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1:1",
                              headers={"Host": "127.0.0.1:1", "Authorization": f"Bearer {TOKEN}"}, timeout=20)
        async with c:
            out["health"] = (await c.get("/v1/health")).json(); out["health"]["pdf_support"] = True   # machine-independent
            await c.post("/v1/providers/scan")
            out["providers"] = (await c.get("/v1/providers")).json()
            out["models"] = (await c.get("/v1/models")).json()
            m = (await c.post("/v1/memory", json={"content": "prefers metric units", "category": "preference"})).json()
            await c.post(f"/v1/memory/{m['id']}/confirm")
            out["memory_search"] = (await c.get("/v1/memory/search", params={"q": "metric"})).json()
            out["memory_list"] = (await c.get("/v1/memory")).json()
            out["profile"] = (await c.put("/v1/profile", json={"call_me": "Arjun", "directness": "direct", "length": "brief", "onboarded": True,
                                                              "instructions": "Show code before explanations."})).json()
            svc.policy.authorize(ActionRequest(actor="agent", agent_id="research", tool_id="mcp:x/send", target="x", args={"to": "a@b.c", "n": 3, "ok": True}))
            out["approvals"] = (await c.get("/v1/approvals")).json()
            out["agent_tree"] = (await c.get("/v1/agents/tree")).json()
            await c.put("/v1/agents/research/models", json={"policy": "fixed", "models": [f"{key}|llama3.2:3b"]})
            out["agent_run"] = (await c.post("/v1/agents/research/run", json={"prompt": "hi"})).json()
            out["settings"] = (await c.put("/v1/settings", json={"web_search_consented": True})).json()
            async def events(text):
                async with c.stream("POST", "/v1/chat", json={"endpoint": key, "model": "llama3.2:3b", "messages": [{"role": "user", "content": text}]}) as r:
                    return [json.loads(l[6:]) async for l in r.aiter_lines() if l.startswith("data: ")]
            out["chat_events_search"] = await events("search for example domain")
            out["chat_events_memory"] = await events("remember that my cat is called Biscuit")
            out["file_extract"] = (await c.post("/v1/files/extract", content=b"Warranty: 36 months.\n", headers={"X-Filename": "manual.txt"})).json()
            async with c.stream("POST", "/v1/chat", json={"endpoint": key, "model": "llama3.2:3b", "messages": [{"role": "user", "content": "how long is the warranty?",
                    "attachments": [{"name": "manual.txt", "kind": "text", "text": "Warranty: 36 months."}]}]}) as r:
                out["chat_events_files"] = [json.loads(l[6:]) async for l in r.aiter_lines() if l.startswith("data: ")]
            await c.put("/v1/mcp/servers/files", json={"config": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"], "env": {"API_TOKEN": "x"}}})
            await c.put("/v1/mcp/servers/calc", json={"config": {"command": sys.executable, "args": [FAKE_MCP]}})
            await c.post("/v1/mcp/servers/calc/approve"); await c.post("/v1/mcp/servers/calc/connect")
            await c.post("/v1/mcp/servers/calc/tools/add/trust", json={"trusted": True})
            out["mcp_servers"] = (await c.get("/v1/mcp/servers")).json()
            # terminal tool events (echo needs no Node, so this is identical on every machine)
            runner = ShellRunner(ShellSandbox(Path(td) / "fixture-workspace", backend=None, node=None), svc.policy)
            shell_events = []
            runner.APPROVAL_WAIT = 10                                # safety net: never hang the generator
            async def approve_when_asked():
                while True:                                          # (an unrelated MCP approval is already pending above)
                    mine = [p for p in svc.policy.pending() if p.request.tool_id == "shell:run"]
                    if mine: svc.policy.resolve(mine[0].approval_id, True); return
                    await asyncio.sleep(0.01)
            approver = asyncio.create_task(approve_when_asked())
            await runner.run("echo hello", shell_events.append, 1); await approver
            out["chat_events_shell"] = shell_events
            st = (await c.get("/v1/shell/status")).json()          # machine-independent: this Mac's real paths are not fixtures
            st.update({"workspace": "WORKSPACE", "node": "/usr/local/bin/node", "sandbox": "seatbelt", "javascript_ready": True})
            out["shell_status"] = st
            # the page the user has open: what the app sends (field names) and what the bridge reports back
            from jarvis_bridge.api.server import PageIn
            from jarvis_bridge.chat.pagecontext import build_page_block
            sample = {"url": "https://shop.example.com/p/1", "title": "Example product", "status": "ready", "text": "Example product. $19.99. Ships free.",
                      "prices": [{"text": "$19.99", "label": "Price"}], "structured": [{"@type": "Product", "name": "Example product"}]}
            out["page_in_fields"] = sorted(PageIn.model_fields)
            out["chat_events_page"] = [{"page_used": build_page_block(sample, "price?", 16000).use.as_event()}, {"thinking": True}, {"ping": True},
                                       {"delta": "On the page: $19.99."}, {"done": True, "prompt_tokens": None, "completion_tokens": None}]
        await svc.close()
    return {k: stable(v) for k, v in out.items()}

def main():
    data = asyncio.run(build()); check = "--check" in sys.argv; stale = []
    OUT.mkdir(parents=True, exist_ok=True)
    for name, val in data.items():
        text = json.dumps(val, indent=2, sort_keys=True) + "\n"; p = OUT / f"{name}.json"
        if check:
            if not p.exists() or p.read_text() != text: stale.append(name)
        else: p.write_text(text)
    if check and stale: print("STALE fixtures:", ", ".join(stale)); sys.exit(1)
    print("fixtures ok" if check else f"wrote {len(data)} fixtures to {OUT}")

if __name__ == "__main__": main()
