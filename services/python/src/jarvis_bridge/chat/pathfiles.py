"""Read files the user names by path.

If you write a path in your message ("summarise ~/Documents/budget.xlsx", "what is in /Users/me/Desktop/deck.pptx", a quoted
path with spaces, a file:// link, or a folder), the file is read and given to the model like an attachment. Any type works:
text and code, PDF, Word, Excel, PowerPoint, OpenDocument, RTF, EPUB, SQLite, archives, images (for vision models), and anything
else (what it is, how big, plus a sample of readable text).

Safety, because this reads from disk:
  * Only paths in messages the USER typed are read. Web pages, files, tool output and memories can never name a file to read.
  * Content is fenced as untrusted data like any attachment: the model is told never to follow instructions inside it.
  * Credential stores are refused (SSH and cloud keys, keychains, browser logins, PEM private keys, ...), because if a document or
    page tricked the assistant, secrets from those files are what could leak. See DENIED_* below.
  * Only regular files are opened (never devices or pipes), at most MAX_FILES per message, with size and time limits.
  * The user is told exactly which files were read, and which could not be.
"""
from __future__ import annotations
import base64, os, re, stat
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote

from ..files.extract import IMAGE_EXT, MAX_BYTES, UnsupportedFile, ExtractionError, _finish, _looks_binary, extract
from ..security.untrusted import wrap_untrusted  # noqa: F401  (documented: content is fenced by the attachment layer)

MAX_FILES = 6
SCAN_USER_MESSAGES = 3                 # the newest few messages, so a follow-up question keeps its file in context
SCAN_CHARS = 12_000                    # a pasted wall of text is not scanned for paths
MAX_DIR_ENTRIES = 200
HEAD_BYTES, TAIL_BYTES = 420_000, 150_000          # together under the 600,000-character text limit, so the end and the marker survive
MAX_IMAGE_BYTES = 10 * 1024 * 1024
VISION_IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
HOME_FOLDERS = ("Desktop", "Documents", "Downloads")

# ---- credential stores that are never read (relative to the home folder unless it starts with "/")
DENIED_PREFIXES = (".gnupg/", ".aws/credentials", ".aws/sso/", ".azure/", ".config/gcloud/", ".config/gh/", ".kube/config", ".docker/config.json",
                   ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".password-store/", ".config/op/", ".1password/",
                   "Library/Keychains/", "Library/Cookies/", "Library/Safari/", "Library/Application Support/com.apple.TCC/",
                   "Library/Application Support/Google/Chrome/", "Library/Application Support/BraveSoftware/", "Library/Application Support/Firefox/",
                   "Library/Application Support/Microsoft Edge/", "Library/Application Support/1Password", "Library/Group Containers/")
DENIED_ABSOLUTE = ("/etc/shadow", "/etc/master.passwd", "/etc/sudoers", "/private/etc/master.passwd", "/private/etc/sudoers", "/private/var/db/dslocal/")
DENIED_NAMES = re.compile(r"^(id_(rsa|dsa|ecdsa|ed25519)(_sk)?|.*\.(kdbx|keychain|keychain-db|p12|pfx|jks|keystore|ovpn)|login data|cookies|logins\.json|key[34]\.db)$", re.I)
PEM_PRIVATE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")
CRED_REASON = ("it looks like a credential store (keys, keychains, cloud or browser logins). I never read those, so a document or web page "
               "can't trick me into leaking a secret from them")


def _home() -> Path: return Path(os.path.expanduser("~"))


def denied_reason(real: Path) -> str | None:
    """Why this (fully resolved) path must not be read, or None."""
    s = str(real)
    if any(s == a.rstrip("/") or s.startswith(a if a.endswith("/") else a + "/") or s == a for a in DENIED_ABSOLUTE): return CRED_REASON
    home = str(_home().resolve())
    if s.startswith(home + "/"):
        rel = s[len(home) + 1:]
        if rel.startswith(".ssh/") and not (rel.endswith(".pub") or rel in (".ssh/config", ".ssh/known_hosts")): return CRED_REASON
        if any(rel == p.rstrip("/") or rel.startswith(p) for p in DENIED_PREFIXES): return CRED_REASON
    if DENIED_NAMES.match(real.name): return CRED_REASON
    return None


# ---------------------------------------------------------------- finding paths in text
_TOKEN = re.compile(r"""(?<![\w:/.\\~-])(?:file://)?(?:~|/)(?:\\.|[^\s"'`<>|])*""")
_HOME_REL = re.compile(r"""(?<![\w/.~\\-])(?:%s)/(?:\\.|[^\s"'`<>|])+""" % "|".join(HOME_FOLDERS))
_QUOTED = re.compile(r"""(["'`])((?:file://|~|/|(?:%s)/)[^\n"'`]{1,500}?)\1""" % "|".join(HOME_FOLDERS))
_TRAIL = ".,;:!?)]}>\"'"


def _clean(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("file://"): raw = unquote(raw[7:])
    return re.sub(r"\\(.)", r"\1", raw)                                  # "My\ File.pdf" -> "My File.pdf"


def _expand(p: str) -> Path | None:
    if p.startswith(HOME_FOLDERS) and "/" in p.split(" ")[0]: p = "~/" + p
    try: return Path(os.path.expanduser(p))
    except Exception: return None


def _exists(p: str) -> bool:
    e = _expand(p)
    try: return bool(e and e.exists())
    except OSError: return False


def _best(token: str, rest: str) -> str:
    """The token, trimmed of trailing punctuation or a :line number, and extended over the following words while that names a real
    file (so an unquoted path with spaces, like ~/Documents/My Report final.pdf, still resolves). The longest real match wins."""
    base = _clean(token)
    stripped = re.sub(r":\d+(?::\d+)?$", "", base)                       # file.py:42 from a stack trace
    words = rest.split(" ") if rest else []
    for v in dict.fromkeys([base, stripped]):
        for k in range(min(len(words), 8), -1, -1):
            t = v if k == 0 else v + " " + " ".join(words[:k])
            while t and not _exists(t) and t[-1] in _TRAIL: t = t[:-1]
            if t and _exists(t): return t
    return stripped.rstrip(_TRAIL) or base


def find_paths(text: str) -> list[str]:
    """Candidate paths in one message, in order, de-duplicated. Looks real or is dropped silently (like "/help" or "and/or")."""
    text = text[:SCAN_CHARS]; found: list[str] = []
    def add(p: str) -> None:
        if p and p not in found: found.append(p)
    for m in _QUOTED.finditer(text):
        add(_clean(m.group(2)).rstrip(_TRAIL) if not _exists(_clean(m.group(2))) else _clean(m.group(2)))
    quoted_spans = [m.span(2) for m in _QUOTED.finditer(text)]
    for rx in (_TOKEN, _HOME_REL):
        for m in rx.finditer(text):
            if any(a <= m.start() < b for a, b in quoted_spans): continue
            rest = text[m.end():m.end() + 160].split("\n")[0].lstrip(" ")
            p = _best(m.group(), rest if text[m.end():m.end() + 1] == " " else "")
            segs = [s for s in p.replace("\\", "/").split("/") if s]
            if _exists(p) or len(segs) >= 2 or p.startswith("~/"): add(p)
    return found


# ---------------------------------------------------------------- reading
@dataclass
class PathReads:
    attachments: dict = field(default_factory=dict)    # message index -> [attachment dicts]
    notices: list = field(default_factory=list)
    read: list = field(default_factory=list)           # display names that were read


def _display(p: Path) -> str:
    s = str(p); h = str(_home())
    s = "~" + s[len(h):] if s.startswith(h + "/") else s
    return s if len(s) <= 110 else "…" + s[-109:]


def _read_bytes(p: Path, size: int) -> tuple[bytes, str | None]:
    """The file's bytes. A huge plain-text file (a log) is read as its start plus its end instead of being refused."""
    with open(p, "rb") as f:
        if size <= MAX_BYTES: return f.read(), None
        head = f.read(HEAD_BYTES)
        if _looks_binary(head) or head[:4] in (b"PK\x03\x04", b"%PDF"): raise UnsupportedFile(f"it is {size / 2**20:.0f} MB, over the {MAX_BYTES // 2**20} MB limit for this kind of file")
        f.seek(max(HEAD_BYTES, size - TAIL_BYTES)); tail = f.read(TAIL_BYTES)
        return head + f"\n[… {size - len(head) - len(tail):,} bytes skipped …]\n".encode() + tail, f"large file ({size / 2**20:.0f} MB): only the start and the end were read"


def _folder(p: Path) -> dict:
    rows = []
    try: entries = sorted(os.scandir(p), key=lambda e: (not e.is_dir(follow_symlinks=False), e.name.lower()))
    except OSError as e: raise ExtractionError(f"the folder can't be listed ({e.strerror or 'permission denied'})") from e
    for e in entries[:MAX_DIR_ENTRIES]:
        if e.name.startswith("."): continue
        try: st = e.stat(follow_symlinks=False); rows.append(f"{'dir ' if stat.S_ISDIR(st.st_mode) else 'file'}  {st.st_size:>12,}  {e.name}")
        except OSError: rows.append(f"?     {e.name}")
    extra = len(entries) - MAX_DIR_ENTRIES
    text = f"Folder {_display(p)} ({len(rows)} visible entries; hidden files omitted):\n" + "\n".join(rows) + (f"\n[… {extra} more entries not listed]" if extra > 0 else "")
    return {"name": _display(p), "kind": "folder", "text": text, "note": f"folder listing of {p}"}


def read_one(p: Path) -> dict:
    """-> an attachment dict, or raises ExtractionError / UnsupportedFile with a short reason (no leading capital)."""
    real = p.resolve()
    why = denied_reason(real)
    if why: raise PermissionError(why)
    st = os.stat(real)
    if stat.S_ISDIR(st.st_mode): return _folder(real)
    if not stat.S_ISREG(st.st_mode): raise UnsupportedFile("it isn't a regular file (devices and pipes are never opened)")
    ext = real.suffix.lower(); name = _display(real)
    if ext in IMAGE_EXT:
        if ext not in VISION_IMAGE_EXT: raise UnsupportedFile(f"{ext} images can't be sent to the model directly. Convert it to PNG or JPEG, or drag it into the chat")
        if st.st_size > MAX_IMAGE_BYTES: raise UnsupportedFile(f"the image is {st.st_size / 2**20:.0f} MB; drag it into the chat so it can be resized")
        return {"name": name, "kind": "image", "image_b64": base64.b64encode(real.read_bytes()).decode(), "note": f"image read from {real}"}
    data, note = _read_bytes(real, st.st_size)
    ex = extract(real.name, data)
    if PEM_PRIVATE.search(ex.text): raise PermissionError(CRED_REASON)
    bits = [f"read from {real}"] + ([note] if note else []) + ([ex.warning] if ex.warning else [])
    return {"name": name, "kind": ex.kind, "text": ex.text, "note": "; ".join(bits)}


def read_mentioned(messages: list) -> PathReads:
    """Look in the newest user messages for paths and read them. Never raises: problems become notices."""
    out = PathReads(); seen: set = set(); budget = MAX_FILES; skipped = 0
    user_idx = [i for i in range(len(messages) - 1, -1, -1) if messages[i].role == "user"][:SCAN_USER_MESSAGES]
    for i in user_idx:
        for raw in find_paths(messages[i].content):
            e = _expand(raw)
            if e is None: continue
            try: real = e.resolve()
            except (OSError, RuntimeError): continue
            if str(real) in seen: continue
            seen.add(str(real))
            if budget <= 0: skipped += 1; continue
            shown = _display(real)
            if not os.path.lexists(real):
                if i == user_idx[0]: out.notices.append(f"I couldn't find {shown}. Check the spelling, or drag the file into the chat.")
                continue
            budget -= 1
            try: att = read_one(real)
            except PermissionError as ex:
                out.notices.append(f"I didn't read {shown}: {ex}." if "credential" in str(ex) else f"I couldn't read {shown}: {ex.strerror or ex}. If it's in Documents, Desktop or Downloads, macOS may be asking for permission.")
                continue
            except (UnsupportedFile, ExtractionError) as ex: out.notices.append(f"I couldn't read {shown}: {ex}."); continue
            except OSError as ex: out.notices.append(f"I couldn't read {shown}: {ex.strerror or ex}."); continue
            except Exception as ex: out.notices.append(f"I couldn't read {shown}: {type(ex).__name__}."); continue
            out.attachments.setdefault(i, []).append(att); out.read.append(shown)
    if skipped: out.notices.append(f"I read the first {MAX_FILES} paths you mentioned and skipped {skipped} more. Tell me which ones you want next.")
    return out
