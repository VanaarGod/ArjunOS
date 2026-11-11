"""Local inference endpoint discovery.

Rules (from the project brief):
  * loopback + explicitly configured endpoints only; never sweeps the LAN
  * anonymous GET probes only: no prompts, no API keys
  * a service is classified ONLY if it returns a validated, protocol-shaped response
  * an open TCP port is never enough; unrecognised services are reported, not registered
  * nothing is installed or executed because something was discovered
"""
from __future__ import annotations
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit
import httpx
from ..security.netguard import NetPolicy, validate_endpoint, EndpointRejected

# Candidates, not guarantees. (display hint, base url)
DEFAULT_CANDIDATES = [
    ("Ollama", "http://127.0.0.1:11434"),
    ("LM Studio", "http://127.0.0.1:1234/v1"),
    ("vLLM", "http://127.0.0.1:8000/v1"),
    ("llama.cpp server", "http://127.0.0.1:8080/v1"),
    ("OpenAI-compatible", "http://127.0.0.1:5000/v1"),
]

PROBE_TIMEOUT = 1.5


@dataclass
class Endpoint:
    key: str                          # canonical host:port (duplicate detection / ownership)
    base_url: str
    hint: str = ""
    owner: str = "discovered"         # discovered | user
    kind: str = "unknown"             # ollama | openai_compat | unknown
    status: str = "unreachable"       # validated | auth_required | unreachable | unrecognized | rejected
    version: str | None = None
    models: list = field(default_factory=list)
    latency_ms: float | None = None
    first_seen: float | None = None
    last_seen: float | None = None
    last_error: str | None = None
    failures: int = 0
    next_probe_at: float = 0.0

    @property
    def usable(self) -> bool:
        return self.status == "validated"


@dataclass
class ScanEvent:
    type: str                         # endpoint_up | endpoint_down | model_added | model_removed | endpoint_removed
    endpoint: str
    detail: str = ""


def canonical_key(url: str) -> str:
    p = urlsplit(url)
    host = "127.0.0.1" if p.hostname in ("localhost", "::1") else p.hostname
    return f"{host}:{p.port or (443 if p.scheme == 'https' else 80)}"


class EndpointScanner:
    def __init__(self, *, policy: NetPolicy = NetPolicy(), candidates=None, transport=None, clock=time.time,
                 backoff_base: float = 2.0, backoff_max: float = 300.0):
        self.policy, self.transport, self._clock = policy, transport, clock
        self.backoff_base, self.backoff_max = backoff_base, backoff_max
        self._eps: dict[str, Endpoint] = {}
        self.log: list[str] = []                       # diagnostic log (bounded)
        for hint, url in (candidates if candidates is not None else DEFAULT_CANDIDATES):
            self._add(url, hint, "discovered")

    # ---- registry management ----
    def _add(self, url: str, hint: str, owner: str) -> Endpoint | None:
        try:
            url = validate_endpoint(url, self.policy)
        except EndpointRejected as e:
            self._log(f"rejected {url}: {e}")
            return None
        key = canonical_key(url)
        if key in self._eps:                           # duplicate detection by host:port
            if owner == "user":
                self._eps[key].owner = "user"
            return self._eps[key]
        ep = Endpoint(key=key, base_url=url, hint=hint, owner=owner)
        self._eps[key] = ep
        return ep

    def add_user_endpoint(self, url: str, hint: str = "user-configured") -> Endpoint:
        ep = self._add(url, hint, "user")
        if ep is None:
            raise EndpointRejected(f"{url} violates network policy")
        return ep

    def remove(self, key: str) -> bool:
        return self._eps.pop(key, None) is not None

    def endpoints(self) -> list[Endpoint]:
        return list(self._eps.values())

    def _log(self, msg: str) -> None:
        self.log.append(f"{time.strftime('%H:%M:%S', time.localtime(self._clock()))} {msg}")
        del self.log[:-500]

    # ---- probing ----
    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(follow_redirects=False, transport=self.transport,
                                 timeout=httpx.Timeout(PROBE_TIMEOUT, connect=PROBE_TIMEOUT))

    async def _probe(self, c: httpx.AsyncClient, ep: Endpoint) -> None:
        origin = f"{urlsplit(ep.base_url).scheme}://{urlsplit(ep.base_url).netloc}"
        v1 = ep.base_url if ep.base_url.rstrip("/").endswith("/v1") else origin + "/v1"
        t0 = time.perf_counter()
        # 1) Ollama native fingerprint
        r = await c.get(origin + "/api/version")
        if r.status_code == 200 and _json(r).get("version") and isinstance(_json(r)["version"], str):
            tags = await c.get(origin + "/api/tags")
            if tags.status_code == 200 and isinstance(_json(tags).get("models"), list):
                ep.kind, ep.status, ep.version = "ollama", "validated", _json(r)["version"]
                ep.models = sorted((m.get("model") or m.get("name")) for m in _json(tags)["models"]
                                   if isinstance(m, dict) and (m.get("model") or m.get("name")))
                ep.latency_ms = (time.perf_counter() - t0) * 1000
                ep.base_url = origin                    # Ollama is addressed natively, not via /v1
                return
        # 2) OpenAI-compatible fingerprint
        m = await c.get(v1 + "/models")
        if m.status_code in (401, 403):
            ep.kind, ep.status, ep.models = "openai_compat", "auth_required", []
            ep.last_error = "endpoint requires an API key; configure it to validate"
            return
        j = _json(m)
        if m.status_code == 200 and isinstance(j.get("data"), list):
            data = [d for d in j["data"] if isinstance(d, dict) and isinstance(d.get("id"), str)]
            if j["data"] and not data:             # non-empty list with no valid model objects => malformed
                ep.kind, ep.status = "unknown", "unrecognized"
                ep.last_error = "/v1/models returned entries that are not model objects"
                return
            ep.kind = "openai_compat"
            ep.status, ep.base_url = "validated", v1
            ep.models = sorted(d["id"] for d in data)
            ep.latency_ms = (time.perf_counter() - t0) * 1000
            return
        ep.kind, ep.status = "unknown", "unrecognized"
        ep.last_error = f"port answers HTTP {m.status_code} but is not a recognised inference API"

    async def scan_once(self, *, manual: bool = False) -> list[ScanEvent]:
        """Probe due endpoints. manual=True ignores backoff (the 'Rescan' button)."""
        events: list[ScanEvent] = []
        now = self._clock()
        async with self._client() as c:
            for ep in list(self._eps.values()):
                if not manual and now < ep.next_probe_at:
                    continue
                before_status, before_models = ep.status, set(ep.models)
                try:
                    await self._probe(c, ep)
                    ep.failures, ep.next_probe_at = 0, 0.0
                    if ep.status != "unreachable":
                        ep.last_seen = now
                        ep.first_seen = ep.first_seen or now
                except (httpx.ConnectError, httpx.TimeoutException) as e:
                    ep.status, ep.models, ep.latency_ms = "unreachable", [], None
                    ep.last_error = "connection refused" if isinstance(e, httpx.ConnectError) else "timed out"
                    ep.failures += 1
                    ep.next_probe_at = now + min(self.backoff_base * 2 ** (ep.failures - 1), self.backoff_max)
                except Exception as e:                 # malformed responses etc. must never crash the scan
                    ep.status, ep.last_error = "unrecognized", f"{type(e).__name__}"
                    ep.failures += 1
                    ep.next_probe_at = now + min(self.backoff_base * 2 ** (ep.failures - 1), self.backoff_max)
                self._log(f"{ep.key} -> {ep.status} ({ep.kind})")
                if ep.status == "validated" and before_status != "validated":
                    events.append(ScanEvent("endpoint_up", ep.key, f"{ep.kind} {ep.version or ''}".strip()))
                elif before_status == "validated" and ep.status != "validated":
                    events.append(ScanEvent("endpoint_down", ep.key, ep.last_error or ""))
                if before_status == "validated" and ep.status == "validated" or ep.status == "validated":
                    for mid in sorted(set(ep.models) - before_models) if before_status == "validated" else []:
                        events.append(ScanEvent("model_added", ep.key, mid))
                    for mid in sorted(before_models - set(ep.models)) if before_status == "validated" else []:
                        events.append(ScanEvent("model_removed", ep.key, mid))
        return events


def _json(r: httpx.Response) -> dict:
    try:
        j = r.json()
        return j if isinstance(j, dict) else {}
    except Exception:
        return {}
