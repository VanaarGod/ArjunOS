"""One hardened httpx client factory: no redirects, bounded timeouts, policy-checked URLs."""
from __future__ import annotations
import time
import httpx
from ..security.netguard import validate_endpoint, NetPolicy, EndpointRejected
from ..security.redact import redact_text
from .base import ProviderError, ErrorKind


def make_client(base_url: str, policy: NetPolicy, *, api_key: str | None = None, timeout: float = 30.0,
                transport: httpx.AsyncBaseTransport | None = None) -> tuple[httpx.AsyncClient, str]:
    try:
        url = validate_endpoint(base_url, policy)
    except EndpointRejected as e:
        raise ProviderError(ErrorKind.REJECTED, str(e)) from e
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    client = httpx.AsyncClient(base_url=url, headers=headers, follow_redirects=False,   # redirects can leak keys/SSRF
                               timeout=httpx.Timeout(timeout, connect=min(timeout, 3.0)), transport=transport)
    return client, url


def map_error(e: Exception) -> ProviderError:
    if isinstance(e, ProviderError):
        return e
    if isinstance(e, httpx.ConnectError):
        return ProviderError(ErrorKind.UNREACHABLE, "connection refused or host unreachable")
    if isinstance(e, httpx.TimeoutException):
        return ProviderError(ErrorKind.TIMEOUT, "request timed out")
    if isinstance(e, httpx.HTTPStatusError):
        s = e.response.status_code
        kind = ErrorKind.AUTH if s in (401, 403) else ErrorKind.NOT_FOUND if s == 404 else ErrorKind.HTTP
        return ProviderError(kind, f"HTTP {s}", status=s)
    return ProviderError(ErrorKind.PROTOCOL, redact_text(f"{type(e).__name__}: {e}"))


class Timer:
    def __enter__(self):
        self.t0 = time.perf_counter(); return self
    def __exit__(self, *a):
        self.ms = (time.perf_counter() - self.t0) * 1000
