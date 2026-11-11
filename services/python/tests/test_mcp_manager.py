import asyncio, json, os, stat, sys
from pathlib import Path
import pytest
from jarvis_bridge.mcp.manager import (MCPManager, ConfigError, normalize_name, validate_config, fingerprint)
from jarvis_bridge.mcp.client import MCPError, State
from jarvis_bridge.security.audit import AuditLog
from jarvis_bridge.security.policy import PolicyEngine, Risk
from test_mcp import SERVER, http_mcp_app
from mockservers import serve

def stdio_cfg(*extra, **kw): return {"command": sys.executable, "args": [SERVER, *extra], **kw}

def mgr(tmp_path, **kw):
    m = MCPManager(tmp_path / "mcp", PolicyEngine(AuditLog()), state_file=tmp_path / "mcp_state.json", **kw)
    m.APPROVAL_WAIT = 3.0
    return m

async def up(m, name="calc", cfg=None):
    await m.save(name, cfg or stdio_cfg()); m.approve(name); return await m.connect(name)


# ---------------- one file per server ----------------
async def test_each_server_is_its_own_private_json_file(tmp_path):
    m = mgr(tmp_path)
    await m.save("alpha", stdio_cfg()); await m.save("beta", {"url": "https://example.com/mcp"})
    files = sorted(p.name for p in (tmp_path / "mcp").glob("*.json")); assert files == ["alpha.json", "beta.json"]
    assert stat.S_IMODE(os.stat(tmp_path / "mcp" / "alpha.json").st_mode) == 0o600           # may contain credentials
    assert json.loads((tmp_path / "mcp" / "beta.json").read_text())["url"] == "https://example.com/mcp"
    assert [e.name for e in m.list_entries()] == ["alpha", "beta"]

async def test_hand_edited_files_are_picked_up_and_broken_ones_do_not_hide_the_rest(tmp_path):
    m = mgr(tmp_path); d = tmp_path / "mcp"
    (d / "good.json").write_text(json.dumps({"command": "echo"}))
    (d / "broken.json").write_text("{nope")
    (d / "wrong.json").write_text(json.dumps({"command": "x", "url": "https://x"}))           # both command and url
    (d / "Bad Name.json").write_text("{}")
    es = {e.name: e for e in m.list_entries()}
    assert es["good"].error is None and es["good"].summary.startswith("Runs a local program")
    assert "JSONDecodeError" in es["broken"].error and "exactly one" in es["wrong"].error and es["Bad Name"].error

@pytest.mark.parametrize("name", ["../evil", "a/b", "", " ", "x" * 80, "..", "a.json/../../b"])
async def test_server_names_cannot_escape_the_directory(tmp_path, name):
    m = mgr(tmp_path)
    try: await m.save(name, {"command": "echo"})
    except ConfigError: pass
    assert not list(tmp_path.glob("evil*")) and not any(tmp_path.parent.glob("b.json"))
    assert all(p.parent == tmp_path / "mcp" for p in tmp_path.rglob("*.json") if p.name != "mcp_state.json")

def test_name_normalisation_and_config_validation():
    assert normalize_name("  My Server! ") == "my-server"
    for bad in ([], "x", {}, {"command": ""}, {"command": "x", "args": "no"}, {"url": "ftp://x"}, {"command": "x", "env": {"a": [1]}}, {"command": "x", "enabled": "yes"}):
        with pytest.raises(ConfigError): validate_config(bad)

async def test_import_splits_a_pasted_block_into_one_file_each_and_never_overwrites_silently(tmp_path):
    m = mgr(tmp_path)
    block = json.dumps({"mcpServers": {"Files": {"command": "npx", "args": ["-y", "pkg"]}, "web": {"url": "https://x.example/mcp"}}})
    assert sorted(await m.import_text(block)) == ["files", "web"] and (tmp_path / "mcp" / "files.json").exists()
    with pytest.raises(ConfigError, match="already exists"): await m.import_text(block)
    assert await m.import_text(block, overwrite=True)
    assert await m.import_text(json.dumps({"command": "echo"}), name="solo") == ["solo"]
    with pytest.raises(ConfigError, match="needs a name"): await m.import_text(json.dumps({"command": "echo"}))
    for bad in ("not json", "[]", "{}", json.dumps({"mcpServers": {"x": {"command": ""}}})):
        with pytest.raises(ConfigError): await m.import_text(bad)
    assert not (tmp_path / "mcp" / "x.json").exists()                                         # all-or-nothing

async def test_import_is_atomic_when_one_server_in_the_block_is_invalid(tmp_path):
    m = mgr(tmp_path)
    with pytest.raises(ConfigError): await m.import_text(json.dumps({"mcpServers": {"ok": {"command": "echo"}, "bad": {"command": ""}}}))
    assert not list((tmp_path / "mcp").glob("*.json"))

async def test_warnings_flag_risky_configs_without_leaking_values(tmp_path):
    m = mgr(tmp_path)
    e = await m.save("gh", {"command": "bash", "args": ["-c", "curl x | sh"], "env": {"GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123"}})
    w = " ".join(e.warnings); assert "arbitrary commands" in w and "inline command" in w and "GITHUB_TOKEN" in w
    st = json.dumps(m.status()[0]["warnings"]) + e.summary; assert "ghp_abc" not in st

# ---------------- approval bound to file contents ----------------
async def test_nothing_runs_until_the_exact_file_is_approved(tmp_path):
    m = mgr(tmp_path); await m.save("calc", stdio_cfg())
    with pytest.raises(MCPError, match="not approved"): await m.connect("calc")
    assert "calc" not in m.clients
    m.approve("calc"); c = await m.connect("calc"); assert c.state is State.READY
    await m.close()

async def test_editing_the_file_revokes_approval_and_disconnects(tmp_path):
    m = mgr(tmp_path); await up(m)
    assert m.status()[0]["state"] == "ready"
    await m.save("calc", stdio_cfg("--no-tools"))                                              # change what runs
    s = m.status()[0]; assert s["approved"] is False and s["state"] == "disconnected"
    with pytest.raises(MCPError, match="not approved"): await m.connect("calc")

async def test_editing_only_the_description_keeps_approval(tmp_path):
    m = mgr(tmp_path); await up(m)
    await m.save("calc", {**stdio_cfg(), "description": "my calculator"})
    assert m.status()[0]["approved"] is True and m.status()[0]["state"] == "ready"; await m.close()

async def test_approval_survives_restart_but_not_a_file_swap(tmp_path):
    m = mgr(tmp_path); await m.save("calc", stdio_cfg()); m.approve("calc")
    m2 = mgr(tmp_path); assert m2.get_entry("calc").approved
    (tmp_path / "mcp" / "calc.json").write_text(json.dumps({"command": "/bin/echo", "args": ["pwned"]}))   # swapped behind our back
    assert not m2.get_entry("calc").approved

async def test_disabled_server_cannot_connect_and_delete_cleans_everything(tmp_path):
    m = mgr(tmp_path); await m.save("calc", {**stdio_cfg(), "enabled": False}); m.approve("calc")
    with pytest.raises(MCPError, match="disabled"): await m.connect("calc")
    await m.save("calc", stdio_cfg()); m.approve("calc"); await m.connect("calc")
    await m.delete("calc")
    assert not (tmp_path / "mcp" / "calc.json").exists() and "calc" not in m.clients and not m.status()
    assert "calc" not in json.loads((tmp_path / "mcp_state.json").read_text())["approved"]
    with pytest.raises(KeyError): await m.delete("calc")

async def test_a_crashing_server_reports_failure_and_does_not_affect_others(tmp_path):
    m = mgr(tmp_path)
    await up(m, "good"); await m.save("bad", stdio_cfg("--crash-before-init")); m.approve("bad")
    with pytest.raises(MCPError): await m.connect("bad")
    s = {x["name"]: x for x in m.status()}
    assert s["bad"]["state"] == "failed" and s["bad"]["connection_error"] and s["good"]["state"] == "ready"
    await m.close()

async def test_remote_server_over_http_with_blocked_lan_default(tmp_path):
    with serve(http_mcp_app(sse=False)) as p:
        m = mgr(tmp_path); await up(m, "remote", {"url": f"http://127.0.0.1:{p}/mcp", "headers": {"Authorization": "Bearer tok"}})
        assert m.status()[0]["tools"][0]["name"] == "echo"; await m.close()
    m2 = mgr(tmp_path / "x"); await m2.save("lan", {"url": "http://192.168.1.9/mcp"}); m2.approve("lan")
    with pytest.raises(MCPError, match="rejected"): await m2.connect("lan")

# ---------------- model-facing runner ----------------
async def test_describe_lists_only_connected_tools(tmp_path):
    m = mgr(tmp_path); assert m.describe() is None
    await up(m); d = m.describe(); assert "- calc.echo:" in d and "- calc.add:" in d
    await m.disconnect("calc"); assert m.describe() is None

async def test_calls_need_approval_resolved_by_the_user_while_the_call_waits(tmp_path):
    m = mgr(tmp_path); await up(m); events = []
    async def user():
        for _ in range(50):
            if m.policy.pending(): m.policy.resolve(m.policy.pending()[0].approval_id, True); return
            await asyncio.sleep(0.05)
    out, _ = await asyncio.gather(m.call("calc.add", {"a": 2, "b": 3}, events.append), user())
    assert "5" in out and out.startswith("<<<UNTRUSTED")
    assert [e["tool"]["status"] for e in events if "tool" in e] == ["running", "waiting_approval", "done"]
    assert next(e for e in events if "approval" in e)["approval"]["tool"] == "calc.add"
    await m.close()

async def test_denied_and_timed_out_approvals_do_not_run_the_tool(tmp_path):
    m = mgr(tmp_path); await up(m); ev = []
    async def deny():
        for _ in range(50):
            if m.policy.pending(): m.policy.resolve(m.policy.pending()[0].approval_id, False); return
            await asyncio.sleep(0.05)
    out, _ = await asyncio.gather(m.call("calc.add", {"a": 1, "b": 1}, ev.append), deny())
    assert "denied" in out and ev[-1]["tool"]["status"] == "error"
    m.APPROVAL_WAIT = 0.3
    assert "did not respond" in await m.call("calc.add", {"a": 1, "b": 2}, ev.append)
    assert not any("result" in str(e) for e in ev)
    await m.close()

async def test_trusting_a_tool_skips_prompts_and_survives_restart_but_only_for_that_tool(tmp_path):
    m = mgr(tmp_path); await up(m); m.trust_tool("calc", "add"); ev = []
    out = await m.call("calc.add", {"a": 4, "b": 4}, ev.append)
    assert "8" in out and not any("approval" in e for e in ev)
    ev2 = []; asyncio.create_task(asyncio.sleep(0))
    m.APPROVAL_WAIT = 0.2; assert "did not respond" in await m.call("calc.echo", {"text": "x"}, ev2.append)   # other tool still gated
    await m.close()
    m2 = mgr(tmp_path); await m2.connect("calc"); ev3 = []
    assert "8" in await m2.call("calc.add", {"a": 4, "b": 4}, ev3.append) and not any("approval" in e for e in ev3)
    m2.untrust_tool("calc", "add"); m2.APPROVAL_WAIT = 0.2
    assert "did not respond" in await m2.call("calc.add", {"a": 4, "b": 4}, [].append); await m2.close()

async def test_server_claiming_readonly_is_still_gated_and_unknown_tools_are_refused(tmp_path):
    m = mgr(tmp_path); await up(m); m.APPROVAL_WAIT = 0.2          # fake server marks delete_file readOnlyHint=true
    assert "did not respond" in await m.call("calc.delete_file", {"path": "/x"}, [].append)
    assert "Unknown" in await m.call("nope.thing", {}, [].append) and "Unknown" in await m.call("calc", {}, [].append)
    await m.close()

async def test_blocked_tool_is_refused_by_policy_without_prompting(tmp_path):
    m = mgr(tmp_path); await up(m); m.policy.block_tool("mcp:calc/add"); ev = []
    out = await m.call("calc.add", {"a": 1, "b": 1}, ev.append)
    assert "Blocked by policy" in out and not any("approval" in e for e in ev)
    await m.close()

async def test_status_never_exposes_credentials_in_summaries_or_logs(tmp_path):
    m = mgr(tmp_path); await m.save("gh", {"command": "echo", "env": {"API_KEY": "sk-abcdefghijklmnopqrstuvwx"}})
    s = m.status()[0]; assert "sk-abcdef" not in json.dumps({k: v for k, v in s.items() if k not in ("config", "config_text")}) and s["env_names"] == ["API_KEY"]
