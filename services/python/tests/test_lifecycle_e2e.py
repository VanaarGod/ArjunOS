"""Real processes, no mocks: a bridge subprocess, a real stdio MCP server child, and a stand-in 'app' parent."""
import hashlib, json, os, shutil, subprocess, sys, time
import httpx, pytest
from mockservers import free_port
from test_mcp import SERVER

pytestmark = pytest.mark.skipif(not (shutil.which("pgrep") and shutil.which("ps")), reason="needs pgrep/ps")
SRC = os.path.join(os.path.dirname(__file__), "..", "src")

def alive(pid: str) -> bool:
    out = subprocess.run(["ps", "-p", pid, "-o", "stat="], capture_output=True, text=True).stdout.strip()
    return bool(out) and not out.startswith("Z")

def test_bridge_reconnects_approved_servers_and_cleans_up_when_the_app_dies(tmp_path):
    state = tmp_path / "state"; (state / "mcp").mkdir(parents=True)
    cfg = {"command": sys.executable, "args": [SERVER]}
    (state / "mcp" / "calc.json").write_text(json.dumps(cfg))
    fp = hashlib.sha256(json.dumps({k: cfg.get(k) for k in ("command", "args", "env", "cwd", "url", "headers")}, sort_keys=True, default=str).encode()).hexdigest()
    (state / "mcp_state.json").write_text(json.dumps({"approved": {"calc": fp}, "trusted": []}))
    app = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])        # stands in for the Swift app
    port, token = free_port(), "t" * 40
    bridge = subprocess.Popen([sys.executable, "-m", "jarvis_bridge.api.server", "--state-dir", str(state), "--port", str(port), "--parent-pid", str(app.pid)],
                              env={**os.environ, "JARVIS_BRIDGE_TOKEN": token, "PYTHONPATH": os.path.abspath(SRC)})
    try:
        status = None
        for _ in range(80):
            try:
                r = httpx.get(f"http://127.0.0.1:{port}/v1/mcp/servers", headers={"Authorization": f"Bearer {token}"}, timeout=1)
                if r.status_code == 200 and r.json() and r.json()[0]["state"] == "ready": status = r.json()[0]; break
            except httpx.HTTPError: pass
            time.sleep(0.25)
        assert status and {t["name"] for t in status["tools"]} >= {"echo", "add"}, "approved server was not reconnected on startup"
        kids = subprocess.run(["pgrep", "-P", str(bridge.pid)], capture_output=True, text=True).stdout.split()
        assert kids and all(alive(k) for k in kids), "expected a live MCP child process"
        app.kill(); app.wait()
        deadline = time.time() + 15
        while bridge.poll() is None and time.time() < deadline: time.sleep(0.2)
        assert bridge.poll() is not None, "bridge outlived its parent"
        time.sleep(0.6)
        assert not any(alive(k) for k in kids), "MCP child was orphaned"
    finally:
        for p in (bridge, app):
            if p.poll() is None: p.kill()
