"""OpenAI-compatible adapter (LM Studio, vLLM, llama.cpp server, LiteLLM, OpenRouter, ...)."""
from __future__ import annotations
import json
from typing import AsyncIterator
from ..security.netguard import NetPolicy
from .base import (Capabilities, ChatChunk, ChatMessage, ErrorKind, HealthStatus, ModelInfo, ProviderError)
from .http import make_client, map_error, Timer


class OpenAICompatProvider:
    version = "1"
    display_name = "OpenAI-compatible"

    def __init__(self, base_url: str, *, provider_id: str, display_name: str | None = None, api_key: str | None = None,
                 policy: NetPolicy = NetPolicy(), local: bool = True, timeout: float = 120.0, transport=None):
        """base_url must include the /v1 prefix, e.g. http://localhost:1234/v1"""
        self.id, self.local = provider_id, local
        if display_name:
            self.display_name = display_name
        self._c, self.base_url = make_client(base_url, policy, api_key=api_key, timeout=timeout, transport=transport)

    async def aclose(self):
        await self._c.aclose()

    async def health(self) -> HealthStatus:
        try:
            with Timer() as t:
                r = await self._c.get("/models", timeout=3.0)
                r.raise_for_status()
                self._parse_models(r.json())          # a 200 that is not a model list is NOT healthy
            return HealthStatus(True, t.ms)
        except Exception as e:
            pe = map_error(e)
            return HealthStatus(False, error=pe.as_dict(), detail=str(pe))

    def _parse_models(self, j) -> list[ModelInfo]:
        if not isinstance(j, dict) or not isinstance(j.get("data"), list):
            raise ProviderError(ErrorKind.PROTOCOL, "response is not an OpenAI model list")
        out = []
        for m in j["data"]:
            if isinstance(m, dict) and isinstance(m.get("id"), str):
                ctx = m.get("context_length") or m.get("max_model_len") or m.get("context_window")
                out.append(ModelInfo(id=m["id"], provider_id=self.id, local=self.local,
                                     context_length=ctx if isinstance(ctx, int) else None,
                                     capabilities=Capabilities()))     # /v1/models declares no capabilities
        if j["data"] and not out:
            raise ProviderError(ErrorKind.PROTOCOL, "model list contains no valid model objects")
        return out

    async def list_models(self) -> list[ModelInfo]:
        try:
            r = await self._c.get("/models", timeout=5.0)
            r.raise_for_status()
            return self._parse_models(r.json())
        except Exception as e:
            raise map_error(e) from e

    async def chat_stream(self, model: str, messages: list[ChatMessage], **opts) -> AsyncIterator[ChatChunk]:
        body = {"model": model, "stream": True, "stream_options": {"include_usage": True},
                "messages": [self._msg(m) for m in messages]}
        for k in ("temperature", "top_p", "max_tokens", "seed"):
            if k in opts:
                body[k] = opts[k]
        try:
            async with self._c.stream("POST", "/chat/completions", json=body) as r:
                if r.status_code >= 400:
                    await r.aread()
                    kind = ErrorKind.AUTH if r.status_code in (401, 403) else ErrorKind.NOT_FOUND if r.status_code == 404 else ErrorKind.HTTP
                    raise ProviderError(kind, f"HTTP {r.status_code}", status=r.status_code)
                usage = (None, None)
                async for line in r.aiter_lines():
                    line = line.strip()
                    if not line or line.startswith(":") or not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        yield ChatChunk(done=True, prompt_tokens=usage[0], completion_tokens=usage[1])
                        return
                    try:
                        j = json.loads(data)
                    except json.JSONDecodeError as e:
                        raise ProviderError(ErrorKind.PROTOCOL, "malformed SSE event") from e
                    if j.get("usage"):
                        usage = (j["usage"].get("prompt_tokens"), j["usage"].get("completion_tokens"))
                    for ch in j.get("choices") or []:
                        d = ch.get("delta") or {}
                        delta = d.get("content") or ""
                        if not delta and (d.get("reasoning_content") or d.get("reasoning")):
                            yield ChatChunk(thinking=True)
                        fr = ch.get("finish_reason")
                        if delta or fr:
                            yield ChatChunk(delta=delta, finish_reason=fr)
                raise ProviderError(ErrorKind.PROTOCOL, "stream ended without [DONE]")
        except ProviderError:
            raise
        except Exception as e:
            raise map_error(e) from e

    @staticmethod
    def _msg(m: ChatMessage) -> dict:
        if not m.images_b64: return {"role": m.role, "content": m.content}
        parts = [{"type": "text", "text": m.content}]
        parts += [{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b}} for b in m.images_b64]
        return {"role": m.role, "content": parts}

    async def probe_chat(self, model: str) -> HealthStatus:
        """Explicit, user-triggered test: sends one tiny fixed non-sensitive prompt. Never used by discovery."""
        try:
            with Timer() as t:
                text = ""
                async for c in self.chat_stream(model, [ChatMessage("user", "Reply with the single word: ok")], max_tokens=8):
                    text += c.delta
            return HealthStatus(True, t.ms, detail=f"received {len(text)} chars")
        except Exception as e:
            pe = map_error(e)
            return HealthStatus(False, error=pe.as_dict(), detail=str(pe))
