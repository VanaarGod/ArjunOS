"""Policy-enforcing bridge between agents and MCP servers + config import.

Every tools/call passes PolicyEngine.authorize(). Server-supplied descriptions and annotations are
UNTRUSTED display text; they never affect risk. Results are fenced as untrusted data.
"""
from __future__ import annotations
import json
from dataclasses import dataclass
from ..security.policy import PolicyEngine, ActionRequest, Decision, Verdict, Risk
from ..security.untrusted import wrap_untrusted, screen
from .client import MCPClient, ServerSpec, MCPError


@dataclass
class ToolResult:
    decision: Decision
    text: str | None = None            # fenced, untrusted
    is_error: bool = False
    flagged: bool = False
    raw: dict | None = None


def tool_id(server: str, tool: str) -> str:
    return f"mcp:{server}/{tool}"


class MCPBridge:
    def __init__(self, policy: PolicyEngine):
        self.policy = policy
        self.clients: dict[str, MCPClient] = {}

    async def attach(self, client: MCPClient) -> list:
        """Register a connected server's tools. Registered risk is ALWAYS approval-required; user can lower it later."""
        self.clients[client.spec.name] = client
        tools = await client.list_tools() if "tools" in client.capabilities else []
        for t in tools:
            tid = tool_id(client.spec.name, t["name"])
            if tid not in self.policy._registry:                # never overwrite a user-chosen risk level
                self.policy.register_tool(tid, Risk.APPROVAL_REQUIRED)
        return tools

    async def invoke(self, server: str, tool: str, arguments: dict | None = None, *, actor: str = "agent",
                     agent_id: str | None = None, task_id: str | None = None, depth: int = 0,
                     flags: frozenset = frozenset(), approval_id: str | None = None) -> ToolResult:
        client = self.clients.get(server)
        req = ActionRequest(actor=actor, agent_id=agent_id, tool_id=tool_id(server, tool),
                            target=f"{server}/{tool}", args=arguments or {}, flags=flags, task_id=task_id, depth=depth)
        d = self.policy.authorize(req, approval_id=approval_id)      # <-- the only gate
        if not d.allowed:
            return ToolResult(d)
        if client is None:
            return ToolResult(d, text=f"server {server!r} is not connected", is_error=True)
        try:
            res = await client.call_tool(tool, arguments or {})
        except MCPError as e:
            self.policy.audit.record(actor=actor, agent_id=agent_id, tool_id=req.tool_id, decision="allow",
                                     outcome="error", detail={"error": str(e)})
            return ToolResult(d, text=f"tool error: {e}", is_error=True)
        text = "\n".join(c.get("text", "") for c in res.get("content", []) if isinstance(c, dict) and c.get("type") == "text")
        flagged = screen(text).suspicious
        self.policy.audit.record(actor=actor, agent_id=agent_id, tool_id=req.tool_id, decision="allow",
                                 outcome="error" if res.get("isError") else "ok",
                                 detail={"flagged_injection": flagged, "result_chars": len(text)})
        return ToolResult(d, text=wrap_untrusted(req.tool_id, text), is_error=bool(res.get("isError")), flagged=flagged, raw=res)


# ------------------------------------------------------------------ config import
@dataclass
class ImportedServer:
    spec: ServerSpec
    summary: str
    env_vars: list                     # NAMES only; values are never shown
    warnings: list


_SENSITIVE_ENV = ("key", "token", "secret", "password", "credential")
_RISKY_CMDS = {"sh", "bash", "zsh", "cmd", "powershell", "pwsh", "sudo", "curl", "wget"}


def parse_mcp_config(text: str) -> list:
    """Parse Claude Desktop / Claude Code style {"mcpServers": {...}}. Pure parsing: NOTHING is executed or approved."""
    data = json.loads(text)
    servers = data.get("mcpServers") if isinstance(data, dict) else None
    if not isinstance(servers, dict):
        raise ValueError("not an MCP config: missing 'mcpServers' object")
    out = []
    for name, cfg in servers.items():
        if not isinstance(cfg, dict):
            continue
        warnings, env = [], cfg.get("env") if isinstance(cfg.get("env"), dict) else {}
        if "command" in cfg:
            cmd, args = str(cfg["command"]), [str(a) for a in cfg.get("args", [])]
            spec = ServerSpec(name=name, transport="stdio", command=cmd, args=args, env={k: str(v) for k, v in env.items()})
            summary = "Runs a local process: " + " ".join([cmd, *args])
            base = cmd.rsplit("/", 1)[-1]
            if base in _RISKY_CMDS: warnings.append(f"launches {base!r}, which can execute arbitrary commands")
            if any(a in ("-c", "/c", "-Command") for a in args): warnings.append("passes an inline command string")
            if base in ("npx", "uvx", "pipx", "bunx") : warnings.append(f"downloads and runs a package at launch via {base}")
        elif "url" in cfg:
            hdrs = cfg.get("headers") if isinstance(cfg.get("headers"), dict) else {}
            spec = ServerSpec(name=name, transport="http", url=str(cfg["url"]), headers={k: str(v) for k, v in hdrs.items()})
            summary = f"Connects to remote server {cfg['url']}"
            if str(cfg["url"]).startswith("http://"): warnings.append("unencrypted http")
        else:
            continue
        spec.approved = False                                   # imports are NEVER pre-approved
        names = list(env) + [f"header:{h}" for h in spec.headers]
        for n in names:
            if any(s in n.lower() for s in _SENSITIVE_ENV): warnings.append(f"{n} looks like a credential; will be moved to the Keychain")
        out.append(ImportedServer(spec, summary, names, warnings))
    return out
