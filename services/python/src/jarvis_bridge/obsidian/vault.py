"""An Obsidian vault is just a folder of Markdown files, so this works with or without Obsidian running.

Safety rules (all enforced here, not left to callers):
  * only `.md` files, only inside the vault; hidden folders (.obsidian, .git, .trash ...) are never read or written;
    symlinks are resolved before the containment check, so a link cannot lead outside the vault;
  * the assistant NEVER edits your own notes. It can create NEW notes inside its own folder (default `ArjunOS/`), never
    overwriting (a taken name gets a number), and append only to notes it created itself;
  * text that looks like a secret is refused instead of being written into a vault that may sync to the cloud.
"""
from __future__ import annotations
import os, re, time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterator
from ..security.paths import PathEscape, resolve_within
from ..security.redact import redact_text

MAX_NOTE_BYTES = 2_000_000
MAX_NOTES = 50_000
MAX_WRITE_CHARS = 200_000
IGNORED_DIRS = {"node_modules", "__pycache__"}


class VaultError(ValueError):
    """Why a vault operation was refused, written for the user."""


# ------------------------------------------------------------------ parsing
@dataclass
class Note:
    rel: str
    title: str
    tags: list = field(default_factory=list)
    aliases: list = field(default_factory=list)
    links: list = field(default_factory=list)          # wikilink targets, as written (without alias / heading)
    frontmatter: dict = field(default_factory=dict)
    body: str = ""
    mtime: float = 0.0
    size: int = 0


_FM = re.compile(r"\A\ufeff?---[ \t]*\r?\n(.*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|\Z)", re.S)
_CODE = re.compile(r"```.*?```|~~~.*?~~~|`[^`\n]*`", re.S)
_TAG = re.compile(r"(?<![\w/#&\[(])#([A-Za-z\u00C0-\uFFFF][\w/\-\u00C0-\uFFFF]*)")
_WIKI = re.compile(r"!?\[\[([^\]\|#^\n]+)(?:#[^\]\|\n]*)?(?:\|[^\]\n]*)?\]\]")
_HEAD = re.compile(r"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$", re.M)


def _unquote(s: str) -> str:
    s = s.strip()
    return s[1:-1] if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'" else s


def _as_list(v) -> list:
    if v is None: return []
    if isinstance(v, list): return [x for x in (str(i).strip().lstrip("#") for i in v) if x]
    return [x for x in re.split(r"[,\s]+" if "," not in str(v) and "[" not in str(v) else r"\s*,\s*", str(v).strip("[] ")) if x.strip().lstrip("#")]


def parse_frontmatter(text: str) -> tuple:
    """(dict, body). A small YAML subset: `key: value`, `key: [a, b]`, and `key:` followed by `- item` lines."""
    m = _FM.match(text or "")
    if not m: return {}, text or ""
    fm, key = {}, None
    for raw in m.group(1).splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"): continue
        item = re.match(r"^\s+-\s*(.*)$", raw)
        if item and key is not None:
            fm.setdefault(key, [])
            if isinstance(fm[key], list): fm[key].append(_unquote(item.group(1)))
            continue
        kv = re.match(r"^([A-Za-z0-9_\- ]+?)\s*:\s*(.*)$", raw)
        if not kv: continue
        key = kv.group(1).strip().lower(); val = kv.group(2).strip()
        if val == "": fm[key] = []
        elif val.startswith("[") and val.endswith("]"): fm[key] = [_unquote(x) for x in val[1:-1].split(",") if x.strip()]
        else: fm[key] = _unquote(val)
    return fm, text[m.end():]


def parse_note(rel: str, text: str, mtime: float = 0.0, size: int = 0) -> Note:
    fm, body = parse_frontmatter(text)
    stripped = _CODE.sub(" ", body)
    tags = {t.strip("/").lower() for t in _as_list(fm.get("tags", fm.get("tag")))}
    tags |= {t.lower() for t in _TAG.findall(stripped) if not re.fullmatch(r"[0-9a-fA-F]{3,8}", t)}
    links = []
    for l in _WIKI.findall(stripped):
        l = l.strip()
        if l and l not in links: links.append(l)
    return Note(rel, Path(rel).stem, sorted(tags), _as_list(fm.get("aliases", fm.get("alias"))), links, fm, body, mtime, size)


def chunk_note(note: Note, max_chars: int = 1400) -> list:
    """[(heading path, text)]: one chunk per heading section, long sections split at paragraph boundaries."""
    body = note.body.strip()
    if not body: return []
    marks = [(m.start(), len(m.group(1)), m.group(2).strip()) for m in _HEAD.finditer(body)]
    sections, stack = [], []
    pos = 0
    def add(text, path):
        text = text.strip()
        if text: sections.append((" › ".join(path), text))
    first = marks[0][0] if marks else len(body)
    add(body[:first], [])
    for i, (start, level, title) in enumerate(marks):
        stack = [(l, t) for l, t in stack if l < level] + [(level, title)]
        end = marks[i + 1][0] if i + 1 < len(marks) else len(body)
        sec = body[start:end]
        add(_HEAD.sub("", sec, count=1) if sec.startswith("#") else sec, [t for _, t in stack])
    out = []
    for heading, text in sections:
        if len(text) <= max_chars: out.append((heading, text)); continue
        cur = ""
        for para in re.split(r"\n\s*\n", text):
            while len(para) > max_chars: out.append((heading, para[:max_chars])); para = para[max_chars:]
            if len(cur) + len(para) + 2 > max_chars and cur.strip(): out.append((heading, cur.strip())); cur = ""
            cur += para + "\n\n"
        if cur.strip(): out.append((heading, cur.strip()))
    return out


def link_key(name: str) -> str:
    """How a wikilink / title / path is compared: lowercase, no `.md`, no `[[ ]]`, no heading or alias part."""
    n = (name or "").strip()
    n = re.sub(r"^!?\[\[|\]\]$", "", n)
    n = re.split(r"[|#^]", n, 1)[0].strip().replace("\\", "/")
    return re.sub(r"\.md$", "", n, flags=re.I).strip("/").lower()


# ------------------------------------------------------------------ the vault
_BAD_NAME = re.compile(r'[\\/:*?"<>|#^\[\]\x00-\x1f]')


def clean_title(title: str) -> str:
    t = _BAD_NAME.sub(" ", title or "")
    t = re.sub(r"\s+", " ", t).strip().strip(".")
    return t[:80].strip() or "Untitled"


def validate_root(path: str) -> Path:
    if not path or not str(path).strip(): raise VaultError("Choose a vault folder first.")
    p = Path(os.path.expanduser(str(path).strip()))
    if not p.is_absolute(): raise VaultError("The vault path must be a full path, like /Users/you/Documents/MyVault.")
    try: p = p.resolve(strict=True)
    except (FileNotFoundError, OSError): raise VaultError("That folder doesn't exist (or isn't reachable right now).") from None
    if not p.is_dir(): raise VaultError("That path is a file, not a folder.")
    if p == Path("/") or p == Path.home().resolve() or p.parent == Path("/"):
        raise VaultError("That folder is too broad to be a vault. Choose the folder that holds your Obsidian notes.")
    if not os.access(p, os.R_OK | os.X_OK): raise VaultError("ArjunOS isn't allowed to read that folder. Check its permissions.")
    return p


class Vault:
    def __init__(self, root: str | Path, agent_folder: str = "ArjunOS"):
        self.root = validate_root(str(root))
        self.agent_folder = agent_folder.strip("/ ") or "ArjunOS"
        self.name = self.root.name

    # ---- paths
    def reachable(self) -> bool:
        return self.root.is_dir() and os.access(self.root, os.R_OK)

    def safe_path(self, rel: str) -> Path:
        r = (rel or "").replace("\\", "/").strip().lstrip("/")
        if not r or "\x00" in r: raise VaultError("That note path isn't valid.")
        parts = [p for p in r.split("/") if p not in ("", ".")]
        if any(p == ".." for p in parts): raise VaultError("Note paths can't go up a folder.")
        if any(p.startswith(".") for p in parts): raise VaultError("Hidden folders (like .obsidian) are off limits.")
        if not parts[-1].lower().endswith(".md"): raise VaultError("Only Markdown (.md) notes can be used.")
        try: return resolve_within(self.root, "/".join(parts), deny_sensitive=False)
        except PathEscape: raise VaultError("That note is outside the vault.") from None

    def rel_of(self, path: Path) -> str:
        return path.resolve().relative_to(self.root).as_posix()

    def iter_notes(self) -> Iterator[tuple]:
        """(rel, mtime, size) for every readable note. Hidden folders and symlinks that leave the vault are skipped."""
        n = 0
        for dirpath, dirs, files in os.walk(self.root, followlinks=False):
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in IGNORED_DIRS)
            for f in sorted(files):
                if f.startswith(".") or not f.lower().endswith(".md"): continue
                full = Path(dirpath) / f
                try:
                    if full.is_symlink():
                        full.resolve().relative_to(self.root)                  # a link must stay inside the vault
                    st = full.stat()
                except (ValueError, OSError): continue
                if st.st_size > MAX_NOTE_BYTES: continue
                n += 1
                if n > MAX_NOTES: return
                yield full.relative_to(self.root).as_posix(), st.st_mtime, st.st_size

    # ---- reading
    def read_text(self, rel: str) -> tuple:
        p = self.safe_path(rel)
        try: st = p.stat()
        except OSError: raise VaultError("That note doesn't exist.") from None
        if st.st_size > MAX_NOTE_BYTES: raise VaultError("That note is too large to read.")
        with open(p, "rb") as fh: data = fh.read(MAX_NOTE_BYTES)
        return data.decode("utf-8", errors="replace"), st.st_mtime, st.st_size

    def read_note(self, rel: str) -> Note:
        text, mt, size = self.read_text(rel)
        return parse_note(self.rel_of(self.safe_path(rel)), text, mt, size)

    # ---- the assistant's own area
    def agent_dir(self, sub: str = "") -> Path:
        p = self.root / self.agent_folder / sub if sub else self.root / self.agent_folder
        return p

    def in_agent_area(self, rel: str) -> bool:
        return rel.replace("\\", "/").lstrip("/").startswith(self.agent_folder + "/")

    def _write_new(self, folder_rel: str, title: str, content: str) -> tuple:
        """Create folder/title.md without ever overwriting. Returns (rel, renamed)."""
        folder = self.root / folder_rel
        try: resolve_within(self.root, folder_rel, deny_sensitive=False)
        except PathEscape: raise VaultError("That folder is outside the vault.") from None
        folder.mkdir(parents=True, exist_ok=True)
        base = clean_title(title)
        for n in range(1, 500):
            name = f"{base}.md" if n == 1 else f"{base} {n}.md"
            target = folder / name
            try:
                with open(target, "x", encoding="utf-8") as fh: fh.write(content)
                return target.relative_to(self.root).as_posix(), n > 1
            except FileExistsError: continue
        raise VaultError("Couldn't find a free name for that note.")

    def create_note(self, title: str, body: str, tags: list | None = None, *, sub: str = "Notes") -> tuple:
        """A NEW note in the assistant's folder. Returns (rel, renamed)."""
        body = (body or "").strip("\n")
        if not body.strip(): raise VaultError("The note is empty.")
        if len(body) > MAX_WRITE_CHARS: raise VaultError("That note is too long to save.")
        if redact_text(body) != body or redact_text(title or "") != (title or ""):
            raise VaultError("That looks like it contains a secret or credential, so I didn't write it into your vault.")
        sub = "/".join(clean_title(p) for p in (sub or "Notes").split("/") if p and p != "..")
        tag_list = [re.sub(r"[^\w/\-]", "-", t.strip().lstrip("#")).strip("-") for t in (tags or []) if t and t.strip()]
        fm = ["---", f"created: {datetime.now().replace(microsecond=0).isoformat()}", "source: arjunos"]
        if tag_list: fm.append("tags: [" + ", ".join(dict.fromkeys(tag_list)) + "]")
        fm.append("---")
        return self._write_new(f"{self.agent_folder}/{sub}", title, "\n".join(fm) + "\n\n" + body + "\n")

    def append_note(self, rel: str, text: str) -> str:
        """Append to a note the assistant created. Your own notes are never edited."""
        p = self.safe_path(rel)
        r = self.rel_of(p)
        if not self.in_agent_area(r): raise VaultError("I only add to notes I created myself (in the ArjunOS folder), never to your own notes.")
        if not p.exists(): raise VaultError("That note doesn't exist.")
        if redact_text(text) != text: raise VaultError("That looks like it contains a secret or credential, so I didn't write it.")
        if p.stat().st_size + len(text) > 500_000: raise VaultError("That note is already very large.")
        with open(p, "a", encoding="utf-8") as fh: fh.write("\n\n" + text.strip("\n") + "\n")
        return r

    def write_agent_file(self, rel: str, content: str) -> None:
        """Create or replace a file inside the assistant's own folder (used for mirrored memories only)."""
        p = self.safe_path(rel)
        if not self.in_agent_area(self.rel_of(p) if p.exists() else rel.lstrip("/")): raise VaultError("Not in the assistant's folder.")
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(f".{p.name}.tmp")
        tmp.write_text(content, encoding="utf-8"); os.replace(tmp, p)

    def delete_agent_file(self, rel: str) -> bool:
        p = self.safe_path(rel)
        if not self.in_agent_area(rel.lstrip("/")): raise VaultError("Not in the assistant's folder.")
        try: p.unlink(); return True
        except FileNotFoundError: return False


# ------------------------------------------------------------------ finding the user's vaults
def discover_vaults(config_dirs: list | None = None) -> list:
    """Vaults Obsidian knows about (its own obsidian.json). [{path, name, open}], most recently used first."""
    import json
    dirs = config_dirs if config_dirs is not None else [Path.home() / "Library/Application Support/obsidian", Path.home() / ".config/obsidian"]
    seen, out = set(), []
    for d in dirs:
        try: data = json.loads((Path(d) / "obsidian.json").read_text(encoding="utf-8"))
        except (OSError, ValueError): continue
        for v in sorted((data.get("vaults") or {}).values(), key=lambda v: -(v.get("ts") or 0)):
            path = v.get("path")
            if isinstance(path, str) and path not in seen and Path(path).is_dir():
                seen.add(path); out.append({"path": path, "name": Path(path).name, "open": bool(v.get("open"))})
    return out
