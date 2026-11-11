"""Authorization layer. EVERY tool invocation (built-in, MCP, plugin, agent) goes through PolicyEngine.authorize().

Trust model
  * Tool descriptions, annotations (e.g. MCP readOnlyHint) and tool output are UNTRUSTED. A tool can never
    lower its own risk; only the user-controlled registry can.
  * Unknown tools default to APPROVAL_REQUIRED.
  * Approvals are bound to a hash of the exact action, single-use, and expire.
  * Standing grants only ever cover MONITORED actions, never APPROVAL_REQUIRED ones.
"""
from __future__ import annotations
import hashlib
import json
import secrets
import time
from dataclasses import dataclass, field
from enum import Enum, IntEnum
from .audit import AuditLog


class Risk(IntEnum):
    SAFE = 0
    MONITORED = 1
    APPROVAL_REQUIRED = 2
    BLOCKED = 3


class Verdict(str, Enum):
    ALLOW = "allow"
    DENY = "deny"
    NEEDS_APPROVAL = "needs_approval"


# Flags that force approval regardless of registered risk.
HIGH_IMPACT_FLAGS = frozenset({
    "destructive", "external_communication", "purchase", "credential_access",
    "sensitive_data_transmission", "privileged", "security_setting", "publish", "production_infra",
})


@dataclass(frozen=True)
class ActionRequest:
    actor: str                       # "user" | "agent" | "scheduler" | "plugin:<id>"
    tool_id: str                     # stable id, e.g. "mcp:filesystem/read_file"
    target: str = ""                 # resource acted on (path, URL, recipient)
    args: dict = field(default_factory=dict)
    agent_id: str | None = None
    flags: frozenset = frozenset()   # claimed by caller; can only RAISE risk
    task_id: str | None = None
    depth: int = 0                   # delegation / tool-chain depth

    def fingerprint(self) -> str:
        blob = json.dumps({"t": self.tool_id, "target": self.target, "a": self.args}, sort_keys=True, default=str)
        return hashlib.sha256(blob.encode()).hexdigest()


@dataclass
class Decision:
    verdict: Verdict
    risk: Risk
    reason: str
    approval_id: str | None = None

    @property
    def allowed(self) -> bool:
        return self.verdict is Verdict.ALLOW


@dataclass
class ExecutionBudget:
    max_tool_calls: int = 50
    max_depth: int = 4
    max_identical_calls: int = 3     # loop breaker
    calls: int = 0
    seen: dict = field(default_factory=dict)


@dataclass
class _Pending:
    approval_id: str
    fingerprint: str
    request: ActionRequest
    created: float
    status: str = "pending"         # pending | approved | denied | consumed | expired


class PolicyEngine:
    APPROVAL_TTL = 300.0

    def __init__(self, audit: AuditLog | None = None, *, clock=time.time):
        self.audit = audit or AuditLog()
        self._clock = clock
        self._registry: dict[str, Risk] = {}         # tool_id -> user-assigned risk
        self._blocked: set[str] = set()
        self._agent_tools: dict[str, set[str]] = {}  # agent_id -> allowed tool ids (absent => no restriction set)
        self._grants: set[tuple[str, str | None]] = set()  # (tool_id, agent_id|None) standing grants (MONITORED only)
        self._pending: dict[str, _Pending] = {}
        self._budgets: dict[str, ExecutionBudget] = {}
        self._disabled_plugins: set[str] = set()

    # ---- configuration (all user-controlled) ----
    def register_tool(self, tool_id: str, risk: Risk) -> None:
        self._registry[tool_id] = risk

    def block_tool(self, tool_id: str) -> None:
        self._blocked.add(tool_id)

    def set_agent_tools(self, agent_id: str, tools: set[str]) -> None:
        self._agent_tools[agent_id] = set(tools)

    def grant_standing(self, tool_id: str, agent_id: str | None = None) -> None:
        if self._registry.get(tool_id, Risk.APPROVAL_REQUIRED) >= Risk.APPROVAL_REQUIRED:
            raise ValueError("standing grants may not cover APPROVAL_REQUIRED tools; approve each action")
        self._grants.add((tool_id, agent_id))

    def revoke_grant(self, tool_id: str, agent_id: str | None = None) -> None:
        self._grants.discard((tool_id, agent_id))

    def disable_plugin(self, plugin_id: str) -> None:
        """Isolate one plugin without touching the rest of the app."""
        self._disabled_plugins.add(plugin_id)

    def begin_task(self, task_id: str, budget: ExecutionBudget | None = None) -> ExecutionBudget:
        self._budgets[task_id] = budget or ExecutionBudget()
        return self._budgets[task_id]

    # ---- classification ----
    def classify(self, req: ActionRequest) -> Risk:
        if req.tool_id in self._blocked:
            return Risk.BLOCKED
        base = self._registry.get(req.tool_id, Risk.APPROVAL_REQUIRED)   # unknown => approval
        if req.flags & HIGH_IMPACT_FLAGS:
            base = max(base, Risk.APPROVAL_REQUIRED)
        return base

    # ---- the single gate ----
    def authorize(self, req: ActionRequest, *, approval_id: str | None = None) -> Decision:
        risk = self.classify(req)

        def done(v: Verdict, reason: str, appr: str | None = None, outcome: str | None = None) -> Decision:
            self.audit.record(actor=req.actor, agent_id=req.agent_id, tool_id=req.tool_id, target=req.target,
                              decision=v.value, approval_id=appr or approval_id, outcome=outcome,
                              detail={"risk": risk.name, "reason": reason, "flags": sorted(req.flags)})
            return Decision(v, risk, reason, appr)

        plugin = self._plugin_of(req.tool_id)
        if plugin and plugin in self._disabled_plugins:
            return done(Verdict.DENY, f"plugin {plugin!r} is disabled")
        if risk is Risk.BLOCKED:
            return done(Verdict.DENY, "blocked by policy")
        if req.agent_id and req.agent_id in self._agent_tools and req.tool_id not in self._agent_tools[req.agent_id]:
            return done(Verdict.DENY, f"agent {req.agent_id!r} is not permitted to use this tool")

        # loop / budget limits
        if req.task_id:
            b = self._budgets.setdefault(req.task_id, ExecutionBudget())
            if req.depth > b.max_depth:
                return done(Verdict.DENY, f"delegation depth {req.depth} exceeds limit {b.max_depth}")
            if b.calls >= b.max_tool_calls:
                return done(Verdict.DENY, f"tool-call budget of {b.max_tool_calls} exhausted")
            fp = req.fingerprint()
            if b.seen.get(fp, 0) >= b.max_identical_calls:
                return done(Verdict.DENY, "identical call repeated too many times (loop suspected)")
        else:
            b = None

        if risk >= Risk.APPROVAL_REQUIRED:
            if approval_id:
                p = self._pending.get(approval_id)
                if p is None:
                    return done(Verdict.DENY, "unknown approval reference")
                if self._clock() - p.created > self.APPROVAL_TTL:
                    p.status = "expired"
                    return done(Verdict.DENY, "approval expired")
                if p.fingerprint != req.fingerprint():
                    return done(Verdict.DENY, "approval does not match this action (bound to a different action)")
                if p.status != "approved":
                    return done(Verdict.DENY if p.status != "pending" else Verdict.NEEDS_APPROVAL,
                                f"approval is {p.status}", approval_id)
                p.status = "consumed"                                   # single use
                return self._commit(b, req, done(Verdict.ALLOW, "approved by user", approval_id, "authorized"))
            pid = "appr_" + secrets.token_hex(8)
            self._pending[pid] = _Pending(pid, req.fingerprint(), req, self._clock())
            return done(Verdict.NEEDS_APPROVAL, "user approval required for this action", pid)

        if risk is Risk.MONITORED and req.actor != "user":
            if (req.tool_id, req.agent_id) not in self._grants and (req.tool_id, None) not in self._grants:
                pid = "appr_" + secrets.token_hex(8)
                self._pending[pid] = _Pending(pid, req.fingerprint(), req, self._clock())
                return done(Verdict.NEEDS_APPROVAL, "no standing grant for this monitored tool", pid)
        return self._commit(b, req, done(Verdict.ALLOW, f"{risk.name.lower()} action permitted", outcome="authorized"))

    def _commit(self, b: ExecutionBudget | None, req: ActionRequest, d: Decision) -> Decision:
        if b is not None and d.allowed:
            b.calls += 1
            fp = req.fingerprint()
            b.seen[fp] = b.seen.get(fp, 0) + 1
        return d

    @staticmethod
    def _plugin_of(tool_id: str) -> str | None:
        return tool_id.split(":", 1)[1].split("/", 1)[0] if tool_id.startswith(("mcp:", "plugin:")) else None

    # ---- approvals (resolved by the UI / user only) ----
    def pending(self) -> list[_Pending]:
        return [p for p in self._pending.values() if p.status == "pending"]

    def approval_status(self, approval_id: str) -> str | None:
        p = self._pending.get(approval_id)
        return p.status if p else None

    def resolve(self, approval_id: str, approve: bool, *, resolver: str = "user") -> None:
        p = self._pending.get(approval_id)
        if p is None or p.status != "pending":
            raise KeyError(f"no pending approval {approval_id!r}")
        p.status = "approved" if approve else "denied"
        self.audit.record(actor=resolver, tool_id=p.request.tool_id, target=p.request.target,
                          decision="approval_" + p.status, approval_id=approval_id)
