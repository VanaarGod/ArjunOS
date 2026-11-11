"""MCP client: JSON-RPC 2.0 over stdio and Streamable HTTP.

Only advertised capabilities are used. Nothing here decides authorization: that is bridge.py + PolicyEngine.
"""
from __future__ import annotations
import asyncio
import json
import os
from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable
import httpx
from ..security.netguard import NetPolicy, validate_endpoint, EndpointRejected
from ..security.redact import redact_text
from ..security.shell import filtered_env

PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_VERSIONS = {"2025-06-18", "2025-03-26", "2024-11-05"}


class MCPError(Exception):
    def __init__(self, message: str, *, code: int | None = None, data: Any = None):
        super().__init__(message)
        self.code, self.data = code, data


class MCPTimeout(MCPError): ...
class MCPClosed(MCPError): ...


class State(str, Enum):
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    READY = "ready"
    FAILED = "failed"


@dataclass
class ServerSpec:
    name: str
    transport: str                       # "stdio" | "http"
    command: str | None = None
    args: list = field(default_factory=list)
    env: dict = field(default_factory=dict)       # declared env additions (values may be secrets)
    cwd: str | None = None
    url: str | None = None
    headers: dict = field(default_factory=dict)   # e.g. Authorization (kept out of logs)
    enabled: bool = True
    approved: bool = False                        # first launch needs explicit user approval


# ------------------------------------------------------------------ transports
class StdioTransport:
    def __init__(self, spec: ServerSpec, on_message: Callable[[dict], None], logs: deque):
        self.spec, self._on_message, self.logs = spec, on_message, logs
        self.proc: asyncio.subprocess.Process | None = None
        self._tasks: list = []

    async def start(self):
        env = filtered_env(self.spec.env)       # NOT the full parent environment
        try:
            self.proc = await asyncio.create_subprocess_exec(
                self.spec.command, *self.spec.args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, env=env, cwd=self.spec.cwd, limit=8 * 1024 * 1024)
        except (FileNotFoundError, PermissionError, OSError) as e:
            raise MCPError(f"cannot launch {self.spec.command!r}: {e.__class__.__name__}") from e
        self._tasks = [asyncio.create_task(self._read_stdout()), asyncio.create_task(self._read_stderr())]

    async def _read_stdout(self):
        assert self.proc and self.proc.stdout
        while True:
            line = await self.proc.stdout.readline()
            if not line:
                self._on_message({"__closed__": True}); return
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                self.logs.append(redact_text("non-JSON on stdout: " + line[:200].decode("utf-8", "replace"))); continue
            if isinstance(msg, dict):
                self._on_message(msg)

    async def _read_stderr(self):
        assert self.proc and self.proc.stderr
        while True:
            line = await self.proc.stderr.readline()
            if not line:
                return
            self.logs.append(redact_text(line.decode("utf-8", "replace").rstrip()))

    async def send(self, msg: dict):
        if not self.proc or self.proc.returncode is not None or not self.proc.stdin:
            raise MCPClosed("server process is not running")
        self.proc.stdin.write((json.dumps(msg, separators=(",", ":")) + "\n").encode())
        await self.proc.stdin.drain()

    async def close(self):
        p = self.proc
        if p and p.returncode is None:
            try:
                if p.stdin: p.stdin.close()
                await asyncio.wait_for(p.wait(), 2.0)
            except asyncio.TimeoutError:
                p.terminate()
                try: await asyncio.wait_for(p.wait(), 2.0)
                except asyncio.TimeoutError: p.kill(); await p.wait()
        for t in self._tasks: t.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)


class HttpTransport:
    """Streamable HTTP: each message is a POST; the reply is JSON or an SSE stream."""
    def __init__(self, spec: ServerSpec, on_message, logs: deque, policy: NetPolicy, transport=None):
        try:
            self.url = validate_endpoint(spec.url or "", policy)
        except EndpointRejected as e:
            raise MCPError(f"endpoint rejected: {e}") from e
        self.spec, self._on_message, self.logs = spec, on_message, logs
        self.session_id: str | None = None
        self.protocol_version: str | None = None
        self._c = httpx.AsyncClient(follow_redirects=False, timeout=httpx.Timeout(60.0, connect=5.0), transport=transport)
        self._bg: set = set()

    async def start(self): ...

    async def send(self, msg: dict):
        t = asyncio.create_task(self._post(msg)); self._bg.add(t); t.add_done_callback(self._bg.discard)

    async def _post(self, msg: dict):
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", **self.spec.headers}
        if self.session_id: h["Mcp-Session-Id"] = self.session_id
        if self.protocol_version: h["MCP-Protocol-Version"] = self.protocol_version
        try:
            async with self._c.stream("POST", self.url, json=msg, headers=h) as r:
                if r.status_code == 202:
                    return
                sid = r.headers.get("mcp-session-id")
                if sid: self.session_id = sid
                if r.status_code >= 400:
                    await r.aread()
                    self._fail(msg, MCPError(f"HTTP {r.status_code}", code=r.status_code)); return
                ct = r.headers.get("content-type", "")
                if ct.startswith("text/event-stream"):
                    data: list = []
                    async for line in r.aiter_lines():
                        if line.startswith("data:"): data.append(line[5:].lstrip())
                        elif line == "" and data:
                            self._emit("\n".join(data)); data = []
                    if data: self._emit("\n".join(data))
                else:
                    self._emit((await r.aread()).decode("utf-8", "replace"))
        except Exception as e:
            self._fail(msg, MCPError(redact_text(f"transport error: {type(e).__name__}")))

    def _emit(self, text: str):
        try:
            m = json.loads(text)
        except json.JSONDecodeError:
            self.logs.append("non-JSON HTTP body"); return
        for item in (m if isinstance(m, list) else [m]):
            if isinstance(item, dict): self._on_message(item)

    def _fail(self, req: dict, err: MCPError):
        if "id" in req:
            self._on_message({"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32000, "message": str(err)}})

    async def close(self):
        if self.session_id:
            try:
                await self._c.delete(self.url, headers={"Mcp-Session-Id": self.session_id, **self.spec.headers})
            except Exception: pass
        await self._c.aclose()


# ------------------------------------------------------------------ client
class MCPClient:
    def __init__(self, spec: ServerSpec, *, net_policy: NetPolicy = NetPolicy(), request_timeout: float = 30.0,
                 http_transport=None, on_notification: Callable[[str, dict], None] | None = None):
        self.spec, self.net_policy, self.request_timeout = spec, net_policy, request_timeout
        self.state = State.DISCONNECTED
        self.logs: deque = deque(maxlen=500)
        self.server_info: dict = {}
        self.capabilities: dict = {}
        self.protocol_version: str | None = None
        self.last_error: str | None = None
        self._http_transport, self._on_notification = http_transport, on_notification
        self._next_id, self._pending, self._t = 1, {}, None

    # ---- lifecycle ----
    async def connect(self) -> None:
        if not self.spec.approved:
            raise MCPError("server has not been approved by the user for first launch")
        if not self.spec.enabled:
            raise MCPError("server is disabled")
        self.state = State.CONNECTING
        try:
            if self.spec.transport == "stdio":
                self._t = StdioTransport(self.spec, self._dispatch, self.logs)
            elif self.spec.transport == "http":
                self._t = HttpTransport(self.spec, self._dispatch, self.logs, self.net_policy, self._http_transport)
            else:
                raise MCPError(f"unsupported transport {self.spec.transport!r}")
            await self._t.start()
            res = await self.request("initialize", {
                "protocolVersion": PROTOCOL_VERSION, "capabilities": {},
                "clientInfo": {"name": "jarvis-os", "version": "0.1.0"}}, timeout=15.0)
            ver = res.get("protocolVersion")
            if ver not in SUPPORTED_VERSIONS:
                raise MCPError(f"server negotiated unsupported protocol version {ver!r}")
            self.protocol_version, self.capabilities = ver, res.get("capabilities") or {}
            self.server_info = res.get("serverInfo") or {}
            if isinstance(self._t, HttpTransport): self._t.protocol_version = ver
            await self.notify("notifications/initialized")
            self.state = State.READY
        except Exception as e:
            self.state, self.last_error = State.FAILED, redact_text(str(e))
            await self.close(); self.state = State.FAILED
            raise

    async def close(self) -> None:
        if self._t:
            await self._t.close(); self._t = None
        for f in self._pending.values():
            if not f.done(): f.set_exception(MCPClosed("connection closed"))
        self._pending.clear()
        if self.state is not State.FAILED: self.state = State.DISCONNECTED

    async def reconnect(self) -> None:
        await self.close(); self.state = State.DISCONNECTED; await self.connect()

    # ---- JSON-RPC ----
    def _dispatch(self, msg: dict) -> None:
        if msg.get("__closed__"):
            if self.state is State.READY: self.state, self.last_error = State.FAILED, "server process exited"
            for f in self._pending.values():
                if not f.done(): f.set_exception(MCPClosed("server process exited"))
            return
        if "id" in msg and ("result" in msg or "error" in msg):
            f = self._pending.pop(msg["id"], None)
            if f and not f.done():
                if "error" in msg:
                    e = msg["error"] or {}
                    f.set_exception(MCPError(redact_text(str(e.get("message", "error"))), code=e.get("code"), data=e.get("data")))
                else:
                    f.set_result(msg.get("result") or {})
            return
        if "method" in msg and "id" in msg:                      # server->client request: we advertise no capabilities
            asyncio.create_task(self._t.send({"jsonrpc": "2.0", "id": msg["id"],
                                              "error": {"code": -32601, "message": "client does not support this method"}}))
            return
        if "method" in msg and self._on_notification:
            self._on_notification(msg["method"], msg.get("params") or {})

    async def request(self, method: str, params: dict | None = None, *, timeout: float | None = None) -> dict:
        if not self._t: raise MCPClosed("not connected")
        rid = self._next_id; self._next_id += 1
        fut = asyncio.get_running_loop().create_future(); self._pending[rid] = fut
        await self._t.send({"jsonrpc": "2.0", "id": rid, "method": method, **({"params": params} if params is not None else {})})
        try:
            return await asyncio.wait_for(asyncio.shield(fut), timeout or self.request_timeout)
        except asyncio.TimeoutError:
            self._pending.pop(rid, None)
            await self._cancel(rid, "timeout")
            raise MCPTimeout(f"{method} timed out") from None
        except asyncio.CancelledError:
            self._pending.pop(rid, None)
            await self._cancel(rid, "cancelled by client")
            raise

    async def _cancel(self, rid: int, reason: str):
        try: await self.notify("notifications/cancelled", {"requestId": rid, "reason": reason})
        except Exception: pass

    async def notify(self, method: str, params: dict | None = None):
        if self._t: await self._t.send({"jsonrpc": "2.0", "method": method, **({"params": params} if params else {})})

    # ---- capability-gated API ----
    def _require(self, cap: str):
        if cap not in self.capabilities:
            raise MCPError(f"server did not advertise the {cap!r} capability")

    async def _paged(self, method: str, key: str, cap: str) -> list:
        self._require(cap)
        out, cursor = [], None
        for _ in range(100):                                    # hard page cap
            res = await self.request(method, {"cursor": cursor} if cursor else {})
            out += res.get(key, [])
            cursor = res.get("nextCursor")
            if not cursor: return out
        raise MCPError("pagination did not terminate")

    async def list_tools(self) -> list: return await self._paged("tools/list", "tools", "tools")
    async def list_resources(self) -> list: return await self._paged("resources/list", "resources", "resources")
    async def list_resource_templates(self) -> list: return await self._paged("resources/templates/list", "resourceTemplates", "resources")
    async def list_prompts(self) -> list: return await self._paged("prompts/list", "prompts", "prompts")

    async def read_resource(self, uri: str) -> dict:
        self._require("resources"); return await self.request("resources/read", {"uri": uri})

    async def get_prompt(self, name: str, arguments: dict | None = None) -> dict:
        self._require("prompts"); return await self.request("prompts/get", {"name": name, "arguments": arguments or {}})

    async def call_tool(self, name: str, arguments: dict | None = None, *, timeout: float | None = None) -> dict:
        self._require("tools"); return await self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=timeout)

    async def ping(self) -> bool:
        try: await self.request("ping", timeout=5.0); return True
        except MCPError: return False

    def status(self) -> dict:
        return {"name": self.spec.name, "state": self.state.value, "transport": self.spec.transport,
                "server": self.server_info, "protocol": self.protocol_version,
                "advertised_capabilities": sorted(self.capabilities), "error": self.last_error,
                "log_tail": list(self.logs)[-20:]}
