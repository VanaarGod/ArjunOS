"""The model-facing terminal tool: one command per call, validated first, approved by the user, then run in the sandbox.

Order matters: a command that validation would refuse is refused WITHOUT bothering the user with an approval card.
Every approval is bound to the exact command text (PolicyEngine fingerprint), is single-use and expires.
"""
from __future__ import annotations
import asyncio, time
from typing import Callable
from ..security.audit import AuditLog
from ..security.policy import ActionRequest, PolicyEngine, Risk, Verdict
from ..security.redact import redact_text
from ..security.untrusted import wrap_untrusted
from .sandbox import ALLOWED_COMMANDS, CommandRejected, ShellResult, ShellSandbox

TOOL_ID = "shell:run"
UI_OUTPUT_CHARS = 6000
MODEL_OUTPUT_CHARS = 12000


def _trim(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit] + f"\n… [{len(text) - limit} more characters not shown]"


def format_result(r: ShellResult) -> str:
    parts = []
    if r.timed_out: parts.append("The command ran too long and was stopped.")
    if r.flooded: parts.append("The command printed too much output and was stopped.")
    parts.append(f"exit code: {r.exit_code if r.exit_code is not None else 'none (stopped)'}")
    if r.stdout.strip(): parts.append("stdout:\n" + r.stdout.rstrip())
    if r.stderr.strip(): parts.append("stderr:\n" + r.stderr.rstrip())
    if not r.stdout.strip() and not r.stderr.strip(): parts.append("(no output)")
    return "\n".join(parts)


class ShellRunner:
    APPROVAL_WAIT = 300.0

    def __init__(self, sandbox: ShellSandbox, policy: PolicyEngine, audit: AuditLog | None = None):
        self.sandbox, self.policy = sandbox, policy
        self.audit = audit or policy.audit
        policy.register_tool(TOOL_ID, Risk.APPROVAL_REQUIRED)          # always ask; standing grants are impossible for this level

    # ---- prompt text for the model ----
    def describe(self) -> str:
        st = self.sandbox.status()
        names = [c for c in ALLOWED_COMMANDS if c != "node" or st["javascript_ready"]]
        js = ('Run JavaScript with node: node -e "console.log(1+1)" or node script.js. To create a file, have node write it: '
              'node -e "require(\'fs\').writeFileSync(\'hello.js\', \'console.log(1)\')". ') if st["javascript_ready"] else \
             "JavaScript (node) is not available right now, so do not offer to run code. "
        return (f"Allowed programs: {', '.join(names)}. {js}"
                "Run ONE command per call: no pipes, redirects, &&, ;, $VARIABLES or backticks. Files live in a private workspace folder and "
                "paths must stay inside it. There is no network, no sudo, and files can never be deleted. The user must approve every command, "
                "so only run what you need.")

    # ---- a command the user typed themselves (an agent's terminal panel) ----
    async def run_user(self, command: str, label: str = "terminal") -> dict:
        """Same allow-list, path checks and OS sandbox as an agent's command, but no approval step: the person typing it is the approver."""
        command = (command or "").strip()
        try:
            v = self.sandbox.check(command)
        except CommandRejected as e:
            return {"ok": False, "blocked": True, "exit_code": None, "output": f"Blocked: {e}."}
        try:
            r = await self.sandbox.execute(v)
        except Exception as e:
            err = redact_text(f"{type(e).__name__}: {e}")
            self.audit.record(actor="user", agent_id=label, tool_id=TOOL_ID, decision="allow", outcome="error", detail={"program": v.argv[0], "error": err})
            return {"ok": False, "blocked": False, "exit_code": None, "output": f"The command could not be run: {err}"}
        self.audit.record(actor="user", agent_id=label, tool_id=TOOL_ID, decision="allow", outcome="ok" if r.ok else "error",
                          detail={"program": v.argv[0], "exit_code": r.exit_code, "seconds": round(r.duration, 2), "timed_out": r.timed_out, "flooded": r.flooded})
        return {"ok": r.ok, "blocked": False, "exit_code": r.exit_code, "timed_out": r.timed_out, "output": _trim(format_result(r), UI_OUTPUT_CHARS)}

    # ---- one call ----
    async def run(self, command: str, emit: Callable[[dict], None], tid: int = 0) -> str:
        command = (command or "").strip()
        shown = {"command": command}
        base = {"id": tid, "name": "shell", "args": shown}
        try:
            v = self.sandbox.check(command)
        except CommandRejected as e:
            msg = f"Blocked: {e}."
            emit({"tool": {**base, "status": "error", "error": str(e)}})
            return msg + " Do not retry this command; tell the user what you can do instead."

        req = ActionRequest(actor="agent", agent_id="jarvis", tool_id=TOOL_ID, target=redact_text(v.display)[:200], args=shown)
        d = self.policy.authorize(req)
        if d.verdict is Verdict.NEEDS_APPROVAL:
            aid = d.approval_id
            emit({"approval": {"id": aid, "tool": "shell", "args": shown}})
            emit({"tool": {**base, "status": "waiting_approval"}})
            deadline = time.monotonic() + self.APPROVAL_WAIT
            while time.monotonic() < deadline and self.policy.approval_status(aid) == "pending":
                await asyncio.sleep(0.1)
            st = self.policy.approval_status(aid)
            if st != "approved":
                msg = "The user denied this command." if st == "denied" else "The user did not respond to the approval request in time."
                emit({"tool": {**base, "status": "error", "error": msg}})
                return msg + " Do not retry; explain this to the user."
            d = self.policy.authorize(req, approval_id=aid)
        if not d.allowed:
            emit({"tool": {**base, "status": "error", "error": d.reason}})
            return f"Blocked by policy: {d.reason}."

        emit({"tool": {**base, "status": "running"}})
        try:
            r = await self.sandbox.execute(v)
        except Exception as e:                                          # never crash the chat on a tool failure
            err = redact_text(f"{type(e).__name__}: {e}")
            self.audit.record(actor="agent", agent_id="jarvis", tool_id=TOOL_ID, decision="allow", outcome="error", detail={"program": v.argv[0], "error": err})
            emit({"tool": {**base, "status": "error", "error": err}})
            return f"The command could not be run: {err}"
        self.audit.record(actor="agent", agent_id="jarvis", tool_id=TOOL_ID, decision="allow", outcome="ok" if r.ok else "error",
                          detail={"program": v.argv[0], "exit_code": r.exit_code, "seconds": round(r.duration, 2),
                                  "timed_out": r.timed_out, "flooded": r.flooded})
        text = format_result(r)
        emit({"tool": {**base, "status": "done" if r.ok else "error", "exit_code": r.exit_code, "output": _trim(text, UI_OUTPUT_CHARS),
                       **({"error": "stopped: " + ("timed out" if r.timed_out else "too much output")} if (r.timed_out or r.flooded) else {})}})
        return wrap_untrusted("shell", _trim(text, MODEL_OUTPUT_CHARS))
