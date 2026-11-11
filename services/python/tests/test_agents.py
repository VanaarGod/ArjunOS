import asyncio, pytest
from jarvis_bridge.agents.registry import AgentRegistry, AgentDef, ModelAssignment, HierarchyError
from jarvis_bridge.agents.runtime import AgentRuntime, TaskState
from jarvis_bridge.inference.base import ChatChunk, ProviderError, ErrorKind
from jarvis_bridge.security.policy import PolicyEngine
from jarvis_bridge.security.audit import AuditLog

def make(streamer=None, resolver=None, path=":memory:"):
    async def ok(ref, msgs):
        yield ChatChunk(delta=f"[{ref}]"); yield ChatChunk(delta="ok", done=True, prompt_tokens=3, completion_tokens=2)
    reg = AgentRegistry(path)
    res = resolver or (lambda a, asg: asg.models)
    return reg, AgentRuntime(reg, PolicyEngine(AuditLog()), res, streamer or ok)

def test_nine_default_roles_with_jarvis_at_top():
    reg = AgentRegistry()
    assert {a.id for a in reg.list()} == {"jarvis","research","coding","analysis","memory","voice","operator","security","scheduler"}
    tree = reg.tree(); assert tree[0]["id"] == "jarvis" and len(tree[0]["children"]) == 8
    assert set(reg.get("jarvis").allowed_delegates) == {a.id for a in reg.list()} - {"jarvis"}

def test_persistence_across_restart(tmp_path):
    db = tmp_path / "a.db"; r = AgentRegistry(db)
    r.create(AgentDef("legal", "Legal", "custom", "x", parent_id="research"))
    r.assign_models("legal", ModelAssignment("fixed", ["ollama/llama3"], escalate_to=["ollama/big"]))
    r2 = AgentRegistry(db)
    assert r2.get("legal").parent_id == "research" and r2.assignment("legal").models == ["ollama/llama3"]
    assert len(r2.list()) == 10                       # defaults not re-seeded

def test_model_assignment_independent_of_identity():
    reg = AgentRegistry(); before = reg.get("coding")
    reg.assign_models("coding", ModelAssignment("fixed", ["a/b"])); reg.assign_models("research", ModelAssignment("fixed", ["a/b"]))
    assert reg.get("coding") == before and reg.assignment("research").models == ["a/b"]    # one model, many agents

def test_hierarchy_rules():
    reg = AgentRegistry()
    with pytest.raises(HierarchyError): reg.update("jarvis", parent_id="coding")          # cycle
    with pytest.raises(HierarchyError): reg.create(AgentDef("x", "x", "r", "i", parent_id="nope"))
    with pytest.raises(HierarchyError): reg.delete("coding")                              # builtin
    reg.create(AgentDef("c1", "c1", "r", "i", parent_id="coding"))
    with pytest.raises(HierarchyError): reg.delete("coding")
    reg.update("c1", parent_id="research"); reg.delete("c1")
    with pytest.raises(HierarchyError): reg.update("jarvis", id="z")

async def test_task_runs_with_trace_usage_and_model():
    reg, rt = make(); reg.assign_models("research", ModelAssignment("fixed", ["ollama/m"]))
    t = await rt.run("research", "hello")
    assert t.state is TaskState.SUCCEEDED and t.output == "[ollama/m]ok" and t.model_used == "ollama/m"
    assert (t.prompt_tokens, t.completion_tokens) == (3, 2) and t.duration is not None
    assert [e.kind for e in t.trace] == ["requested", "model_attempt", "completed"]

async def test_fallback_model_used_and_degradation_reported():
    async def flaky(ref, msgs):
        if ref == "a/primary": raise ProviderError(ErrorKind.UNREACHABLE, "down")
        yield ChatChunk(delta="fb", done=True)
    reg, rt = make(flaky); reg.assign_models("coding", ModelAssignment("fixed", ["a/primary", "a/backup"]))
    t = await rt.run("coding", "x")
    assert t.state is TaskState.SUCCEEDED and t.model_used == "a/backup" and t.degraded
    assert "fallback_used" in [e.kind for e in t.trace]

async def test_all_models_failing_fails_loudly_without_inventing_one():
    async def dead(ref, msgs):
        raise ProviderError(ErrorKind.UNREACHABLE, "down"); yield
    reg, rt = make(dead); reg.assign_models("coding", ModelAssignment("fixed", ["a/x"]))
    t = await rt.run("coding", "x")
    assert t.state is TaskState.FAILED and "all assigned models failed" in t.error

async def test_no_model_assigned_is_an_honest_failure():
    reg, rt = make(); t = await rt.run("research", "x")
    assert t.state is TaskState.FAILED and "no model" in t.error

async def test_delegation_allowed_denied_and_depth_and_runaway():
    reg, rt = make(); [reg.assign_models(a.id, ModelAssignment("fixed", ["a/m"])) for a in reg.list()]
    root = await rt.run("jarvis", "plan")
    ok = await rt.run("research", "sub", parent=root); assert ok.state is TaskState.SUCCEEDED and ok.depth == 1
    deny = await rt.run("coding", "sub", parent=ok)                   # research may not delegate to coding
    assert deny.state is TaskState.FAILED and "may not delegate" in deny.error
    reg.update("jarvis", max_delegation_depth=0)
    deep = await rt.run("research", "deep", parent=root); assert "depth" in deep.error
    reg.update("jarvis", max_delegation_depth=3)
    rt.MAX_TOTAL_TASKS_PER_ROOT = 3
    outs = [await rt.run("research", f"n{i}", parent=root) for i in range(5)]
    assert any("runaway" in (o.error or "") for o in outs)

async def test_disabled_agent_refused():
    reg, rt = make(); reg.update("voice", enabled=False)
    assert (await rt.run("voice", "x")).state is TaskState.FAILED

async def test_timeout_and_cancel():
    async def slow(ref, msgs):
        await asyncio.sleep(30); yield ChatChunk(done=True)
    reg, rt = make(slow); reg.assign_models("research", ModelAssignment("fixed", ["a/m"])); reg.update("research", timeout_s=0.3)
    assert "timed out" in (await rt.run("research", "x")).error
    reg.update("research", timeout_s=30)
    job = asyncio.create_task(rt.run("research", "y")); await asyncio.sleep(0.2)
    tid = next(t.id for t in rt.tasks.values() if t.prompt == "y"); assert rt.cancel(tid)
    with pytest.raises(asyncio.CancelledError): await job
    assert rt.tasks[tid].state is TaskState.CANCELLED

async def test_parallel_execution_bounded():
    live = {"n": 0, "max": 0}
    async def s(ref, msgs):
        live["n"] += 1; live["max"] = max(live["max"], live["n"]); await asyncio.sleep(0.1); live["n"] -= 1
        yield ChatChunk(delta="x", done=True)
    reg, rt = make(s); reg.assign_models("research", ModelAssignment("fixed", ["a/m"]))
    rt._sem = asyncio.Semaphore(2)
    await asyncio.gather(*[rt.run("research", str(i)) for i in range(6)])
    assert live["max"] == 2

async def test_error_messages_are_redacted():
    async def leaky(ref, msgs):
        raise ProviderError(ErrorKind.HTTP, "bad key sk-abcdefghijklmnopqrstuvwx"); yield
    reg, rt = make(leaky); reg.assign_models("research", ModelAssignment("fixed", ["a/m"]))
    assert "sk-abcdef" not in (await rt.run("research", "x")).error
