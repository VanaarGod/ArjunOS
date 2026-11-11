"""Network guard: SSRF / DNS-rebinding / redirect hygiene for every outbound URL.

Policy:
  * loopback is allowed by default (local engines)
  * private LAN requires allow_lan (separately permissioned feature)
  * link-local / cloud metadata ranges are ALWAYS blocked
  * public hosts require allow_remote AND that offline mode is off
  * URLs may never embed credentials
"""
from __future__ import annotations
import ipaddress
import socket
from dataclasses import dataclass
from urllib.parse import urlsplit


class EndpointRejected(ValueError):
    """Raised with a user-presentable reason when a URL violates network policy."""


@dataclass(frozen=True)
class NetPolicy:
    allow_lan: bool = False
    allow_remote: bool = False
    offline_mode: bool = False
    blocklist: frozenset = frozenset()     # hostnames or "host:port"
    allowlist: frozenset = frozenset()     # if non-empty, only these hosts


_ALWAYS_BLOCKED = [
    ipaddress.ip_network("169.254.0.0/16"),     # link-local incl. cloud metadata
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("224.0.0.0/4"),        # multicast
]


def classify_ip(ip) -> str:
    if any(ip.version == n.version and ip in n for n in _ALWAYS_BLOCKED):
        return "blocked"
    if ip.is_loopback:
        return "loopback"
    if ip.is_private or ip.is_unspecified:
        return "lan"
    return "public"


def _resolve(host: str):
    try:
        return [ipaddress.ip_address(host)]
    except ValueError:
        pass
    if host.lower() == "localhost":
        return [ipaddress.ip_address("127.0.0.1")]
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        raise EndpointRejected(f"cannot resolve host {host!r}: {e}") from e
    return [ipaddress.ip_address(i[4][0]) for i in infos]


def validate_endpoint(url: str, policy: NetPolicy = NetPolicy(), *, resolver=_resolve) -> str:
    """Return the normalised URL (no trailing slash) or raise EndpointRejected."""
    try:
        parts = urlsplit(url.strip())
        host = parts.hostname
        port = parts.port
    except ValueError as e:
        raise EndpointRejected(f"malformed URL: {e}") from e
    if parts.scheme not in ("http", "https"):
        raise EndpointRejected(f"scheme {parts.scheme!r} not allowed (http/https only)")
    if parts.username or parts.password:
        raise EndpointRejected("credentials in URL are not allowed; use the credential store")
    if not host:
        raise EndpointRejected("URL has no host")
    hostport = f"{host}:{port}" if port else host
    if host in policy.blocklist or hostport in policy.blocklist:
        raise EndpointRejected(f"{hostport} is on the blocklist")
    if policy.allowlist and host not in policy.allowlist and hostport not in policy.allowlist:
        raise EndpointRejected(f"{hostport} is not on the allowlist")
    classes = {classify_ip(ip) for ip in resolver(host)}   # every resolved address must pass
    if "blocked" in classes:
        raise EndpointRejected(f"{host} resolves to a blocked address range (link-local/metadata)")
    if "public" in classes:
        if policy.offline_mode:
            raise EndpointRejected("offline mode is on: remote endpoints are disabled")
        if not policy.allow_remote:
            raise EndpointRejected("remote endpoints are disabled; enable a remote provider explicitly")
        if parts.scheme != "https":
            raise EndpointRejected("remote endpoints must use https")
    elif "lan" in classes and not policy.allow_lan:
        raise EndpointRejected("LAN endpoints require the optional LAN permission")
    return url.strip().rstrip("/")


def is_loopback_url(url: str) -> bool:
    try:
        return all(classify_ip(ip) == "loopback" for ip in _resolve(urlsplit(url).hostname or ""))
    except (EndpointRejected, ValueError):
        return False
