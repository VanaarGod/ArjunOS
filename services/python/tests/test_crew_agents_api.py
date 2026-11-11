import asyncio, json
import pytest
from test_api import Env
from test_crew import Machine, Team, rows, pdfs, BOSS, MINI
from test_crew_api import env_with_team, body, sse
from test_crew_agents import ONE, TWO
from jarvis_bridge.orchestration.crew import CrewEngine, CrewSession, CrewConfig, _Run
from mockservers import free_port


async def run_to_end(c, plan_body=None):
    r = await c.post("/v1/crew/run", json=plan_body or body(inputs=[{"name": "doc1.pdf", "kind": "pdf", "text": "fact " * 300}]))
    ev = sse(r.text); cid = ev[0]["crew_id"]; return cid, ev

def team_env(tmp_path, **kw):
    e, m, t = env_with_team(tmp_path, **kw); t.plan = ONE; return e, m, t


async def test_a_finished_crew_stays_available_for_follow_up_chats(tmp_path):
    e, m, t = team_env(tmp_path, workers={"w1": ["Report about facts. " * 15]})
    async with e.client() as c:
        cid, ev = await run_to_end(c)
        assert cid in e.svc.crews and not e.svc.crews[cid].running
        t.workers["w1"] = ["It is five words long."]
        r = await c.post(f"/v1/crew/{cid}/agents/w1/chat", json={"text": "How long is it?"})
        events = sse(r.text); assert r.status_code == 200
        assert "".join(x["ev"]["delta"] for x in events if "agent" in x and "delta" in x["ev"]) == "It is five words long." and events[-1] == {"done": True}
        r2 = await c.post(f"/v1/crew/{cid}/agents/boss/chat", json={"text": "Summarise for me"}); assert r2.status_code == 200 and sse(r2.text)[-1] == {"done": True}

async def test_a_new_run_replaces_the_old_finished_one_and_old_ones_expire(tmp_path):
    e, m, t = team_env(tmp_path, workers={"w1": ["Report. " * 30]})
    async with e.client() as c:
        first, _ = await run_to_end(c); second, _ = await run_to_end(c)
        assert first not in e.svc.crews and second in e.svc.crews
        e.svc.crews[second].finished_at -= 7300
        assert (await c.post(f"/v1/crew/{second}/agents/w1/chat", json={"text": "hi"})).status_code == 404

async def test_chat_endpoint_validates_agent_and_state(tmp_path):
    e, m, t = team_env(tmp_path, workers={"w1": ["Report. " * 30]})
    async with e.client() as c:
        cid, _ = await run_to_end(c)
        assert (await c.post(f"/v1/crew/{cid}/agents/..%2Fx/chat", json={"text": "hi"})).status_code in (404, 422)
        assert (await c.post(f"/v1/crew/{cid}/agents/evil/chat", json={"text": "hi"})).status_code == 422
        assert (await c.post(f"/v1/crew/{cid}/agents/w1/chat", json={"text": ""})).status_code == 422
        assert (await c.post("/v1/crew/crew_nope/agents/w1/chat", json={"text": "hi"})).status_code == 404
        e.svc.crews[cid]._chatting = {"w1"}
        assert (await c.post(f"/v1/crew/{cid}/agents/w1/chat", json={"text": "hi"})).status_code == 409           # one answer at a time
    async with e.client(token=None) as c:
        assert (await c.post(f"/v1/crew/{cid}/agents/w1/chat", json={"text": "hi"})).status_code == 401
        assert (await c.post(f"/v1/crew/{cid}/agents/w1/shell", json={"command": "pwd"})).status_code == 401

async def test_messages_queue_only_for_agents_that_are_working(tmp_path):
    e, m, t = team_env(tmp_path); loop = asyncio.get_running_loop()
    s = CrewSession(); s.task = loop.create_future(); e.svc.crews[s.id] = s
    run = type("R", (), {})(); sub = type("S", (), {"state": "working"})(); run.subs = {"w1": sub}; s.run = run
    async with e.client() as c:
        ok = await c.post(f"/v1/crew/{s.id}/agents/w1/message", json={"text": "focus on the numbers"}); assert ok.status_code == 200 and s.inbox["w1"] == ["focus on the numbers"]
        assert (await c.post(f"/v1/crew/{s.id}/agents/boss/message", json={"text": "be brief"})).status_code == 200 and s.inbox["boss"] == ["be brief"]
        assert (await c.post(f"/v1/crew/{s.id}/agents/w7/message", json={"text": "x"})).status_code == 404
        sub.state = "done"; assert (await c.post(f"/v1/crew/{s.id}/agents/w1/message", json={"text": "x"})).status_code == 409
        s.task.set_result(None)                                                                           # the crew ended
        assert (await c.post(f"/v1/crew/{s.id}/agents/boss/message", json={"text": "x"})).status_code == 409

async def test_each_agent_has_its_own_terminal_workspace(tmp_path):
    e, m, t = team_env(tmp_path, workers={"w1": ["Report. " * 30]})
    async with e.client() as c:
        cid, _ = await run_to_end(c)
        info = (await c.get(f"/v1/crew/{cid}/agents/w1/terminal")).json()
        assert info["enabled"] and info["workspace"].endswith(f"agents/{cid}/w1") and "ls" in info["allowed"] and "rm" not in info["allowed"]
        a = (await c.post(f"/v1/crew/{cid}/agents/w1/shell", json={"command": "mkdir only_in_w1"})).json(); assert a["ok"], a
        ls1 = (await c.post(f"/v1/crew/{cid}/agents/w1/shell", json={"command": "ls"})).json(); ls2 = (await c.post(f"/v1/crew/{cid}/agents/boss/shell", json={"command": "ls"})).json()
        assert "only_in_w1" in ls1["output"] and "only_in_w1" not in ls2["output"]
        pwd = (await c.post(f"/v1/crew/{cid}/agents/w1/shell", json={"command": "pwd"})).json(); assert pwd["output"].strip().endswith(f"{cid}/w1") or "w1" in pwd["output"]

async def test_the_user_terminal_keeps_every_safety_rule(tmp_path):
    e, m, t = team_env(tmp_path, workers={"w1": ["Report. " * 30]})
    async with e.client() as c:
        cid, _ = await run_to_end(c)
        for cmd in ["rm -rf /", "sudo ls", "ls | cat", "cat /etc/passwd", "cat ../../../etc/hosts", "echo hi > f.txt", "curl http://x.com", "node -e 'x'; ls"]:
            r = (await c.post(f"/v1/crew/{cid}/agents/w1/shell", json={"command": cmd})).json()
            assert r["blocked"] and not r["ok"], cmd
        tilde = (await c.post(f"/v1/crew/{cid}/agents/w1/shell", json={"command": "ls ~"})).json()           # there is no shell, so ~ is just a name inside the sandbox
        assert "Library" not in tilde["output"] and "Documents" not in tilde["output"]
        e.svc.settings.update(shell_enabled=False)
        assert (await c.post(f"/v1/crew/{cid}/agents/w1/shell", json={"command": "pwd"})).status_code == 409
        assert (await c.get(f"/v1/crew/{cid}/agents/w1/terminal")).json() == {"enabled": False}

async def test_agent_chat_runs_with_the_agents_own_terminal_not_a_shared_one(tmp_path):
    """Workers' tool calls (and approvals) use their own sandbox, so their files never mix."""
    e, m, t = team_env(tmp_path)
    a, b = e.svc.agent_shell("crew_x", "w1"), e.svc.agent_shell("crew_x", "w2")
    assert a is not b and a.sandbox.workspace != b.sandbox.workspace and a is e.svc.agent_shell("crew_x", "w1")
    assert a.sandbox.workspace.is_relative_to(e.svc.shell.sandbox.workspace) and a.sandbox.workspace.parts[-3:] == ("agents", "crew_x", "w1")

async def test_resources_report_cpu_and_gpu(tmp_path):
    e, m, t = team_env(tmp_path)
    async with e.client() as c:
        j = (await c.get("/v1/system/resources")).json()
    assert {"cpu_percent", "cpu_name", "gpu_name", "gpu_limit", "unified"} <= set(j)


async def test_the_review_switch_reaches_the_engine(tmp_path):
    e, m, t = team_env(tmp_path, workers={"w1": ["Report. " * 30]}, review={"verdicts": [{"id": "w1", "ok": True}]})
    async with e.client() as c:
        _, on = await run_to_end(c); assert any("review" in x for x in on)
        payload = body(inputs=[{"name": "doc1.pdf", "kind": "pdf", "text": "fact " * 300}]); payload["review"] = False
        _, off = await run_to_end(c, payload); assert not any("review" in x for x in off)
