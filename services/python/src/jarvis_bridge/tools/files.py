"""Create files for the user, inside the sandbox workspace only.

Deliberately boring and safe, so it can run WITHOUT an approval prompt when the user says "create a markdown file":
  - only inside the workspace folder (symlinks followed, sensitive names refused)
  - only a short list of plain-text file types; nothing executable is ever created
  - NEVER overwrites: an existing name becomes name-2.ext, name-3.ext, ...
  - size capped; the content is written exactly as given
"""
from __future__ import annotations
import os, re
from dataclasses import dataclass
from pathlib import Path
from ..security.paths import PathEscape, resolve_within
from ..security.policy import ActionRequest, PolicyEngine, Risk

TOOL_ID = "file:create"
ALLOWED_EXT = ("md", "txt", "js", "mjs", "cjs", "ts", "json", "html", "css", "csv", "yml", "yaml", "py", "xml", "toml", "svg")
MAX_CHARS = 200_000
PREVIEW_CHARS = 1200


class FileError(ValueError):
    """Why the file was not created, written for the user."""


@dataclass(frozen=True)
class CreatedFile:
    rel: str                  # path relative to the workspace, as finally used
    path: str                 # absolute path
    size: int                 # bytes
    renamed: bool             # True when the name was taken and a number was added
    preview: str
    truncated: bool = False   # the model's reply was cut off before it finished the file


def _clean_part(part: str) -> str:
    part = re.sub(r"[^A-Za-z0-9._\- ]", "-", part).strip().strip(".")
    return re.sub(r"[ ]+", "-", part)


def clean_name(name: str, ext_hint: str | None = None) -> str:
    """'  "My Notes"  ' -> 'My-Notes.md'. Raises FileError for anything not allowed."""
    n = (name or "").strip().strip("\"'`").replace("\\", "/")
    if not n: raise FileError("the file needs a name")
    if n.startswith("/") or n.startswith("~") or re.match(r"^[A-Za-z]:", n): raise FileError("file names must be relative (the file goes in the workspace)")
    parts = [p for p in n.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts): raise FileError("file names can't go up a folder")
    parts = [_clean_part(p) for p in parts]
    if not parts or not all(parts): raise FileError("that file name isn't usable")
    if len(parts) > 4 or len(n) > 120: raise FileError("that file name is too long")
    leaf = parts[-1]
    stem, dot, ext = leaf.rpartition(".")
    if not dot or not stem:
        stem, ext = leaf, (ext_hint or "txt") if not dot else (ext_hint or "txt")
        if dot and not stem: stem = ext                                  # ".md" -> handled above; keep something sensible
    ext = ext.lower()
    if ext not in ALLOWED_EXT:
        raise FileError(f"'.{ext}' files can't be created here (allowed: {', '.join(ALLOWED_EXT)})")
    parts[-1] = f"{stem}.{ext}"
    return "/".join(parts)


class FileCreator:
    def __init__(self, workspace: str | Path, policy: PolicyEngine | None = None):
        self.workspace = Path(workspace).expanduser().resolve()
        self.policy = policy
        if policy: policy.register_tool(TOOL_ID, Risk.SAFE)

    def create(self, name: str, content: str, *, ext_hint: str | None = None, truncated: bool = False) -> CreatedFile:
        rel = clean_name(name, ext_hint)
        text = (content or "").replace("\r\n", "\n").lstrip("\ufeff")
        if "\x00" in text: raise FileError("the content isn't plain text")
        if not text.strip(): raise FileError("there was nothing to write")
        if len(text) > MAX_CHARS: raise FileError(f"the file would be longer than {MAX_CHARS:,} characters")
        if not text.endswith("\n"): text += "\n"
        if self.policy:
            d = self.policy.authorize(ActionRequest(actor="agent", agent_id="jarvis", tool_id=TOOL_ID, target=rel, args={"chars": len(text)}))
            if not d.allowed: raise FileError(d.reason or "blocked by policy")
        final = rel
        for i in range(1, 100):
            if i > 1:
                stem, _, ext = rel.rpartition(".")
                final = f"{stem}-{i}.{ext}"
            try:
                target = resolve_within(self.workspace, final)
            except PathEscape:
                raise FileError("that location isn't allowed") from None
            target.parent.mkdir(parents=True, exist_ok=True)
            try:
                with open(target, "x", encoding="utf-8") as f: f.write(text)         # "x" = fail if it exists: never overwrite
            except FileExistsError:
                continue
            return CreatedFile(rel=final, path=str(target), size=len(text.encode("utf-8")), renamed=final != rel,
                               preview=text[:PREVIEW_CHARS] + ("…" if len(text) > PREVIEW_CHARS else ""), truncated=truncated)
        raise FileError("too many files with that name already exist")
