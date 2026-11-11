"""Ollama adapter (official REST API: /api/version, /api/tags, /api/show, /api/chat NDJSON)."""
from __future__ import annotations
import json
from typing import AsyncIterator
import httpx
from ..security.netguard import NetPolicy
from .base import (Capabilities, ChatChunk, ChatMessage, ErrorKind, HealthStatus, ModelInfo, ProviderError)
from .http import make_client, map_error, Timer

DEFAULT_URL = "http://localhost:11434"


class OllamaProvider:
    version = "1"
    display_name = "Ollama"
    local = True

    def __init__(self, base_url: str = DEFAULT_URL, *, provider_id: str = "ollama", policy: NetPolicy = NetPolicy(),
                 timeout: float = 120.0, transport=None):
        self.id = provider_id
        self._c, self.base_url = make_client(base_url, policy, timeout=timeout, transport=transport)

    async def aclose(self):
        await self._c.aclose()

    can_manage_memory = True          # Ollama can load and unload models on request (other servers cannot)

    async def loaded_models(self) -> dict:
        """Models currently in memory: {name: resident bytes} (GET /api/ps)."""
        try:
            r = await self._c.get("/api/ps", timeout=5.0); r.raise_for_status()
            return {(m.get("model") or m.get("name")): int(m.get("size") or 0) for m in r.json().get("models", [])}
        except Exception as e:
            raise map_error(e) from e

    async def load_model(self, model: str, keep_alive: str = "30m") -> None:
        """Load a model into memory without generating anything."""
        try:
            r = await self._c.post("/api/generate", json={"model": model, "keep_alive": keep_alive}, timeout=300.0); r.raise_for_status()
        except Exception as e:
            raise map_error(e) from e

    async def unload_model(self, model: str) -> None:
        """Free a model's memory right now (keep_alive 0)."""
        try:
            r = await self._c.post("/api/generate", json={"model": model, "keep_alive": 0}, timeout=30.0); r.raise_for_status()
        except Exception as e:
            raise map_error(e) from e

    async def health(self) -> HealthStatus:
        try:
            with Timer() as t:
                r = await self._c.get("/api/version", timeout=3.0)
                r.raise_for_status()
            return HealthStatus(True, t.ms, version=r.json().get("version"))
        except Exception as e:
            pe = map_error(e)
            return HealthStatus(False, error=pe.as_dict(), detail=str(pe))

    @staticmethod
    def _caps_from_show(show: dict) -> Capabilities:
        raw = show.get("capabilities")      # newer Ollama versions; absent on old ones => unknown, not False
        if not isinstance(raw, list):
            return Capabilities()
        s = set(raw)
        return Capabilities(chat="completion" in s, streaming=True if "completion" in s else None,
                            tools="tools" in s, vision="vision" in s, embeddings="embedding" in s)

    async def list_models(self, *, with_details: bool = True) -> list[ModelInfo]:
        try:
            r = await self._c.get("/api/tags", timeout=5.0)
            r.raise_for_status()
            tags = r.json().get("models", [])
        except Exception as e:
            raise map_error(e) from e
        out = []
        for m in tags:
            name = m.get("model") or m.get("name")
            d = m.get("details") or {}
            caps, ctx = Capabilities(), None
            if with_details:
                try:
                    sr = await self._c.post("/api/show", json={"model": name}, timeout=5.0)
                    if sr.status_code == 200:
                        show = sr.json()
                        caps = self._caps_from_show(show)
                        for k, v in (show.get("model_info") or {}).items():
                            if k.endswith(".context_length") and isinstance(v, int):
                                ctx = v
                except Exception:
                    pass                      # details are best-effort; listing must not fail
            out.append(ModelInfo(id=name, provider_id=self.id, size_bytes=m.get("size"), family=d.get("family"),
                                 parameter_size=d.get("parameter_size"), quantization=d.get("quantization_level"),
                                 context_length=ctx, capabilities=caps))
        return out

    async def chat_stream(self, model: str, messages: list[ChatMessage], **opts) -> AsyncIterator[ChatChunk]:
        body = {"model": model, "stream": True,
                "messages": [self._msg(m) for m in messages]}
        options = {k: v for k, v in opts.items() if k in ("temperature", "top_p", "num_ctx", "num_predict", "seed")}
        if options:
            body["options"] = options
        try:
            async with self._c.stream("POST", "/api/chat", json=body) as r:
                if r.status_code >= 400:
                    await r.aread()
                    detail = ""
                    try:
                        detail = r.json().get("error", "")
                    except Exception:
                        pass
                    kind = ErrorKind.NOT_FOUND if r.status_code == 404 else ErrorKind.HTTP
                    raise ProviderError(kind, detail or f"HTTP {r.status_code}", status=r.status_code)
                async for line in r.aiter_lines():
                    if not line.strip():
                        continue
                    try:
                        j = json.loads(line)
                    except json.JSONDecodeError as e:
                        raise ProviderError(ErrorKind.PROTOCOL, "malformed stream line") from e
                    if "error" in j:
                        raise ProviderError(ErrorKind.HTTP, str(j["error"]))
                    msg = j.get("message") or {}
                    yield ChatChunk(delta=msg.get("content", "") or "", done=bool(j.get("done")),
                                    prompt_tokens=j.get("prompt_eval_count"), completion_tokens=j.get("eval_count"),
                                    finish_reason=j.get("done_reason"), thinking=bool(msg.get("thinking")))
        except ProviderError:
            raise
        except Exception as e:
            raise map_error(e) from e

    @staticmethod
    def _msg(m: ChatMessage) -> dict:
        d = {"role": m.role, "content": m.content}
        if m.images_b64:
            d["images"] = list(m.images_b64)
        return d
