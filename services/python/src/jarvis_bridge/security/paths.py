"""Path-traversal-safe workspace resolution (symlinks resolved before the containment check)."""
from __future__ import annotations
from pathlib import Path


class PathEscape(PermissionError):
    pass


SENSITIVE_DIR_NAMES = {".ssh", ".gnupg", ".aws", ".kube", "Keychains", ".config/gcloud"}


def resolve_within(root: str | Path, candidate: str | Path, *, deny_sensitive: bool = True) -> Path:
    root_p = Path(root).resolve()
    cand = Path(candidate)
    full = (cand if cand.is_absolute() else root_p / cand).resolve()   # resolve() follows symlinks
    try:
        rel = full.relative_to(root_p)
    except ValueError:
        raise PathEscape(f"{candidate!s} escapes workspace {root_p}") from None
    if deny_sensitive and any(part in SENSITIVE_DIR_NAMES for part in rel.parts):
        raise PathEscape(f"{candidate!s} is inside a sensitive directory")
    return full
