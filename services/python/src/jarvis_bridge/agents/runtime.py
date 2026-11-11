"""Common agent execution lifecycle with delegation limits, fallback models and operational traces.

One loop for all agent roles: roles differ by definition (instructions/tools/model), not by code.
Traces record operational steps, never model chain-of-thought.
"""
from __future__ import annotations
import asyncio, time, uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Awaitable, Callable
from ..inference.base import ChatMessage, ProviderError
from ..security.policy import PolicyEngine, ExecutionBudget
from ..security.redact import redact_text
from .registry import AgentRegistry, AgentDef


class TaskState(str, Enum):
    QUEUED = "queued"; RUNNING = "running"; SUCCEEDED = "succeeded"; FAILED = "failed"; CANCELLED = "cancelled"


@dataclass
class TraceEvent:
    ts: float; kind: str; detail: dict

@dataclass
class Task:
    id: str; agent_id: str; prompt: str; parent_task_id: str | None = None; depth: int = 0
    state: TaskState = TaskState.QUEUED; output: str = ""; error: str | None = None
    model_used: str | None = None; degraded: bool = False
    prompt_tokens: int = 0; completion_tokens: int = 0
    started: float | None = None; finished: float | None = None
    trace: list = field(default_factory=list); children: list = field(default_factory=list)

    def log(self, kind: str, **detail): self.trace.append(TraceEvent(time.time(), kind, detail))
    @property
    def duration(self) -> float | None: return (self.finished - self.started) if self.started and self.finished else None

# resolver(agent_def, assignment) -> ordered list of (model_ref, provider_stream_fn)
Streamer = Callable[[str, list], "AsyncIterator"]   # (model_ref, messages) -> async iterator of ChatChunk
Resolver = Callable[[AgentDef, object], list]


class AgentRuntime:
    MAX_TOTAL_TASKS_PER_ROOT = 25

    def __init__(self, registry: AgentRegistry, policy: PolicyEngine, resolver: Resolver, streamer: Streamer, *,
                 max_parallel: int = 4):
        self.registry, self.policy, self.resolver, self.streamer = registry, policy, resolver, streamer
        self.tasks: dict[str, Task] = {}
        self._running: dict[str, asyncio.Task] = {}
        self._sem = asyncio.Semaphore(max_parallel)
        self._root_counts: dict[str, int] = {}

    def _root_of(self, t: Task) -> str:
        while t.parent_task_id: t = self.tasks[t.parent_task_id]
        return t.id

    async def run(self, agent_id: str, prompt: str, *, parent: Task | None = None) -> Task:
        agent = self.registry.get(agent_id)
        t = Task("task_" + uuid.uuid4().hex[:12], agent_id, prompt, parent.id if parent else None, (parent.depth + 1) if parent else 0)
        self.tasks[t.id] = t
        if parent: parent.children.append(t.id)
        root = self._root_of(t); self._root_counts[root] = self._root_counts.get(root, 0) + 1
        t.log("requested", agent=agent_id, depth=t.depth)
        if agent is None or not agent.enabled:
            return self._fail(t, f"agent {agent_id!r} is unknown or disabled")
        if parent:
            pa = self.registry.get(parent.agent_id)
            if pa is None or agent_id not in pa.allowed_delegates:
                t.log("permission_check", result="deny", reason="not an authorised delegate")
                return self._fail(t, f"agent {parent.agent_id!r} may not delegate to {agent_id!r}")
            if t.depth > pa.max_delegation_depth:
                return self._fail(t, f"delegation depth {t.depth} exceeds limit {pa.max_delegation_depth}")
            if self._root_counts[root] > self.MAX_TOTAL_TASKS_PER_ROOT:
                return self._fail(t, "runaway task creation: per-request task limit reached")
        self.policy.begin_task(t.id, ExecutionBudget(max_tool_calls=agent.max_tool_calls, max_depth=agent.max_delegation_depth))
        async with self._sem:
            if t.state is TaskState.CANCELLED: return t
            t.state, t.started = TaskState.RUNNING, time.time()
            runner = asyncio.create_task(self._execute(t, agent)); self._running[t.id] = runner
            try:
                await asyncio.wait_for(asyncio.shield(runner), agent.timeout_s)
            except asyncio.TimeoutError:
                runner.cancel(); self._fail(t, f"timed out after {agent.timeout_s}s")
            except asyncio.CancelledError:
                runner.cancel(); t.state, t.finished = TaskState.CANCELLED, time.time(); t.log("cancelled"); raise
            finally: self._running.pop(t.id, None)
        return t

    async def _execute(self, t: Task, agent: AgentDef):
        assignment = self.registry.assignment(agent.id)
        try: candidates = self.resolver(agent, assignment)
        except Exception as e: return self._fail(t, f"model resolution failed: {redact_text(str(e))}")
        if not candidates: return self._fail(t, "no model is assigned or available for this agent")
        msgs = [ChatMessage("system", agent.instructions), ChatMessage("user", t.prompt)]
        last_err = None
        for i, ref in enumerate(candidates):
            t.log("model_attempt", model=ref, attempt=i)
            out = []
            try:
                async for c in self.streamer(ref, msgs):
                    out.append(c.delta)
                    if c.done: t.prompt_tokens += c.prompt_tokens or 0; t.completion_tokens += c.completion_tokens or 0
                t.output, t.model_used, t.degraded = "".join(out), ref, i > 0
                if i > 0: t.log("fallback_used", model=ref, note="primary model unavailable; capability may be degraded")
                t.state, t.finished = TaskState.SUCCEEDED, time.time(); t.log("completed", chars=len(t.output)); return
            except asyncio.CancelledError: raise
            except ProviderError as e:
                last_err = f"{ref}: {e.kind.value}: {redact_text(str(e))}"; t.log("model_failed", model=ref, error=last_err)
            except Exception as e:
                last_err = f"{ref}: {type(e).__name__}"; t.log("model_failed", model=ref, error=last_err)
        self._fail(t, f"all assigned models failed (no silent change of privacy/capability). Last: {last_err}")

    def _fail(self, t: Task, msg: str) -> Task:
        t.state, t.error, t.finished = TaskState.FAILED, msg, time.time(); t.log("failed", error=msg); return t

    def cancel(self, task_id: str) -> bool:
        r = self._running.get(task_id)
        if r: r.cancel(); t = self.tasks[task_id]; t.state, t.finished = TaskState.CANCELLED, time.time(); t.log("cancelled"); return True
        return False

    def history(self, agent_id: str | None = None) -> list:
        return [t for t in self.tasks.values() if agent_id in (None, t.agent_id)]
