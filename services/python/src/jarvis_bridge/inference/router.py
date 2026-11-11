"""Capability-aware model router.

Hard rules:
  * privacy=private_local can NEVER select a remote provider, even as fallback.
  * a required capability must be VERIFIED (True); unknown (None) does not satisfy it.
  * if nothing qualifies, raise NoRouteError with a per-candidate explanation. No silent downgrade.
"""
from __future__ import annotations
import re
from dataclasses import dataclass, field
from .base import ModelInfo

_EMBED_ONLY = re.compile(r"(embed|bge-|nomic|e5-|minilm)", re.I)
_CODER = re.compile(r"(coder|code|codestral|deepseek-coder|starcoder)", re.I)


@dataclass(frozen=True)
class Profile:
    name: str
    privacy: str = "any"                         # "private_local" | "any"
    allow_remote: bool = False
    preferred_providers: tuple = ()
    preferred_models: tuple = ()                 # regex patterns, earlier = better
    required_caps: frozenset = frozenset()       # subset of {"tools","vision","embeddings","structured_output"}
    min_context: int | None = None
    max_latency_ms: float | None = None
    prefer_small: bool = False                   # fast / low-resource profiles
    prefer_coder: bool = False
    max_cost_per_mtok: float | None = None       # applies to remote only


BUILTIN_PROFILES = {
    "fast": Profile("fast", prefer_small=True),
    "balanced": Profile("balanced"),
    "high_quality": Profile("high_quality"),
    "coding": Profile("coding", prefer_coder=True),
    "vision": Profile("vision", required_caps=frozenset({"vision"})),
    "private_local": Profile("private_local", privacy="private_local", allow_remote=False),
    "low_resource": Profile("low_resource", prefer_small=True, privacy="private_local"),
}


@dataclass(frozen=True)
class TaskNeeds:
    complexity: str = "normal"                   # trivial | normal | hard
    needs_vision: bool = False
    needs_tools: bool = False
    est_context_tokens: int = 0
    kind: str = "chat"                           # chat | code | embed


@dataclass
class Candidate:
    model: ModelInfo
    remote: bool = False
    latency_ms: float | None = None
    healthy: bool = True
    cost_per_mtok: float | None = None


@dataclass
class RouteDecision:
    chosen: Candidate
    fallbacks: list = field(default_factory=list)
    rejected: dict = field(default_factory=dict)         # "provider/model" -> reason
    notes: list = field(default_factory=list)

    def ordered(self) -> list:
        return [self.chosen, *self.fallbacks]


class NoRouteError(Exception):
    def __init__(self, message: str, rejected: dict):
        super().__init__(message)
        self.rejected = rejected

    def explain(self) -> str:
        return str(self) + "\n" + "\n".join(f"  - {k}: {v}" for k, v in self.rejected.items())


def _name(c: Candidate) -> str:
    return f"{c.model.provider_id}/{c.model.id}"


def route(profile: Profile, needs: TaskNeeds, candidates: list) -> RouteDecision:
    rejected: dict = {}
    required = set(profile.required_caps)
    if needs.needs_vision: required.add("vision")
    if needs.needs_tools: required.add("tools")
    if needs.kind == "embed": required.add("embeddings")
    ok: list = []
    for c in candidates:
        n, m = _name(c), c.model
        if not c.healthy:
            rejected[n] = "provider unhealthy"; continue
        if c.remote and (profile.privacy == "private_local" or not profile.allow_remote):
            rejected[n] = "remote provider not permitted by this profile's privacy constraints"; continue
        if needs.kind != "embed" and _EMBED_ONLY.search(m.id) and m.capabilities.embeddings is not False:
            rejected[n] = "embedding model, not a chat model"; continue
        missing = [k for k in sorted(required) if getattr(m.capabilities, k, None) is not True]
        if missing:
            unknown = [k for k in missing if getattr(m.capabilities, k, None) is None]
            rejected[n] = ("capability not verified: " if unknown else "lacks capability: ") + ", ".join(missing)
            continue
        need_ctx = max(profile.min_context or 0, needs.est_context_tokens)
        if need_ctx and (m.context_length is not None and m.context_length < need_ctx):
            rejected[n] = f"context {m.context_length} < required {need_ctx}"; continue
        if profile.max_latency_ms and c.latency_ms and c.latency_ms > profile.max_latency_ms:
            rejected[n] = f"latency {c.latency_ms:.0f}ms > limit {profile.max_latency_ms:.0f}ms"; continue
        if c.remote and profile.max_cost_per_mtok is not None and (c.cost_per_mtok is None or c.cost_per_mtok > profile.max_cost_per_mtok):
            rejected[n] = "cost unknown or above limit"; continue
        ok.append(c)
    if not ok:
        raise NoRouteError(f"No provider satisfies profile {profile.name!r} for this task "
                           f"(privacy={profile.privacy}, required={sorted(required) or 'none'})", rejected)

    def score(c: Candidate) -> tuple:
        s = []
        s.append(0 if c.model.provider_id in profile.preferred_providers else 1)
        pm = next((i for i, p in enumerate(profile.preferred_models) if re.search(p, c.model.id, re.I)), 99)
        s.append(pm)
        s.append(1 if c.remote else 0)                                   # local before remote
        want_code = profile.prefer_coder or needs.kind == "code"
        s.append(0 if (want_code and _CODER.search(c.model.id)) else 1)
        size = c.model.size_bytes or 0
        small = profile.prefer_small or needs.complexity == "trivial"
        s.append(size if small else -size)                               # trivial => smallest; else largest
        s.append(c.latency_ms or 1e9)
        return tuple(s)

    ok.sort(key=score)
    notes = []
    if any(c.remote for c in ok[:1]):
        notes.append("selected a REMOTE provider; data leaves this machine")
    return RouteDecision(ok[0], ok[1:], rejected, notes)
