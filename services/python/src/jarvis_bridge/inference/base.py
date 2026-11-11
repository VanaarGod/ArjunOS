"""Shared inference contracts (InferenceProvider / ModelDiscoveryProvider / HealthCheckProvider)."""
from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum
from typing import AsyncIterator, Protocol, runtime_checkable

CONTRACT_VERSION = "1"


class ErrorKind(str, Enum):
    UNREACHABLE = "unreachable"
    TIMEOUT = "timeout"
    AUTH = "auth"
    NOT_FOUND = "not_found"
    PROTOCOL = "protocol"
    HTTP = "http"
    REJECTED = "rejected"        # blocked by network policy
    UNSUPPORTED = "unsupported"


class ProviderError(Exception):
    def __init__(self, kind: ErrorKind, message: str, *, status: int | None = None):
        super().__init__(message)
        self.kind, self.status = kind, status

    def as_dict(self) -> dict:
        return {"kind": self.kind.value, "message": str(self), "status": self.status}


@dataclass(frozen=True)
class Capabilities:
    """None = unknown (never assume). True/False = verified or declared."""
    chat: bool | None = None
    streaming: bool | None = None
    tools: bool | None = None
    vision: bool | None = None
    embeddings: bool | None = None
    structured_output: bool | None = None


@dataclass(frozen=True)
class ModelInfo:
    id: str
    provider_id: str
    size_bytes: int | None = None
    family: str | None = None
    parameter_size: str | None = None
    quantization: str | None = None
    context_length: int | None = None
    capabilities: Capabilities = field(default_factory=Capabilities)
    local: bool = True


@dataclass(frozen=True)
class ChatMessage:
    role: str                         # system | user | assistant | tool
    content: str
    images_b64: tuple = ()
    attachments: tuple = ()             # app-level file attachments (dicts: name/kind/text/image_b64/note); turned into context by the chat layer


@dataclass
class ChatChunk:
    delta: str = ""
    done: bool = False
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    finish_reason: str | None = None
    thinking: bool = False          # the model is reasoning (no visible text yet); proves it is alive


@dataclass
class HealthStatus:
    ok: bool
    latency_ms: float | None = None
    version: str | None = None
    detail: str = ""
    error: dict | None = None


@runtime_checkable
class InferenceProvider(Protocol):
    id: str
    display_name: str
    version: str
    local: bool

    async def health(self) -> HealthStatus: ...
    async def list_models(self) -> list[ModelInfo]: ...
    def chat_stream(self, model: str, messages: list[ChatMessage], **opts) -> AsyncIterator[ChatChunk]: ...
    async def aclose(self) -> None: ...


async def collect(stream) -> tuple[str, ChatChunk]:
    """Drain a chat stream into (full_text, final_chunk)."""
    text, last = [], ChatChunk()
    async for c in stream:
        text.append(c.delta)
        if c.done:
            last = c
    return "".join(text), last
