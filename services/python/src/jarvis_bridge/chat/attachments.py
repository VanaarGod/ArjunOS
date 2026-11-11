"""Turn attached files into model context within a character budget.

Local models have small context windows, so: (1) the budget is split fairly across files, (2) an oversized file is
reduced to the excerpts most relevant to the user's question (SQLite FTS5/BM25), and (3) the caller is told exactly how
much of each file was used so the UI can say so. File text is UNTRUSTED data: fenced, never parsed for tool tags.
"""
from __future__ import annotations
import re, sqlite3
from dataclasses import dataclass
from ..inference.base import ChatMessage
from ..memory.store import _fts_query
from ..security.untrusted import wrap_untrusted

CHUNK_CHARS = 1200
MAX_IMAGES = 4
GAP = "\n[… skipped …]\n"


@dataclass
class FileUse:
    name: str
    used_chars: int
    total_chars: int
    excerpted: bool

    def as_event(self) -> dict:
        return {"name": self.name, "used_chars": self.used_chars, "total_chars": self.total_chars, "excerpted": self.excerpted}


@dataclass
class AttachmentContext:
    blocks: list            # fenced text blocks, one per file (newest first)
    uses: list              # FileUse per text file
    images_by_message: dict # message index -> tuple of base64 images kept
    dropped_images: int


def _clean_name(name: str) -> str:
    return re.sub(r"[\x00-\x1f\x7f]", " ", name or "file").strip()[:120] or "file"


def chunk_text(text: str, size: int = CHUNK_CHARS) -> list:
    """Paragraph-aware chunks of roughly `size` characters (long paragraphs are hard-split)."""
    chunks, cur = [], ""
    for para in re.split(r"\n{2,}", text):
        while len(para) > size:
            cut = para.rfind("\n", 0, size); cut = cut if cut > size // 2 else para.rfind(" ", 0, size)
            cut = cut if cut > size // 2 else size
            if cur: chunks.append(cur); cur = ""
            chunks.append(para[:cut]); para = para[cut:].lstrip()
        if len(cur) + len(para) + 2 > size and cur: chunks.append(cur); cur = para
        else: cur = (cur + "\n\n" + para) if cur else para
    if cur.strip(): chunks.append(cur)
    return [c for c in chunks if c.strip()]


def select_excerpts(text: str, alloc: int, query: str) -> tuple:
    """Return (text_within_alloc, excerpted). Relevance-ranked chunks, in document order; always tries to keep the opening."""
    if len(text) <= alloc: return text, False
    chunks = chunk_text(text)
    chosen: set = set()
    used = 0
    def take(i: int) -> bool:
        nonlocal used
        cost = len(chunks[i]) + len(GAP)
        if i in chosen or used + cost > alloc: return False
        chosen.add(i); used += cost; return True
    q = _fts_query(query or "")
    ranked: list = []
    if q:
        db = sqlite3.connect(":memory:")
        try:
            db.execute("CREATE VIRTUAL TABLE c USING fts5(t, tokenize='porter unicode61')")
            db.executemany("INSERT INTO c(rowid, t) VALUES (?, ?)", [(i + 1, ch) for i, ch in enumerate(chunks)])
            ranked = [r[0] - 1 for r in db.execute("SELECT rowid FROM c WHERE c MATCH ? ORDER BY bm25(c) LIMIT 60", (q,))]
        except sqlite3.Error:
            ranked = []
        finally: db.close()
    take(0)                                              # the beginning usually says what the document is
    for i in ranked: take(i)
    if not ranked:                                       # nothing to match on (e.g. "summarize this"): read from the top
        for i in range(1, len(chunks)):
            if not take(i): break
    if not chosen and chunks: chosen.add(0); chunks[0] = chunks[0][:max(alloc, 200)]
    out, prev = [], None
    for i in sorted(chosen):
        if prev is not None and i != prev + 1: out.append(GAP)
        out.append(chunks[i]); out.append("\n\n"); prev = i
    return "".join(out).strip(), True


def build_attachment_context(messages: list, query: str, budget: int) -> AttachmentContext:
    texts: list = []          # (order, name, kind, text, warning)
    images_by_message: dict = {}
    img_seen = dropped = 0
    for mi in range(len(messages) - 1, -1, -1):          # newest message first
        for a in messages[mi].attachments or ():
            if a.get("kind") == "image" and a.get("image_b64"):
                if img_seen < MAX_IMAGES: images_by_message.setdefault(mi, []).append(a["image_b64"]); img_seen += 1
                else: dropped += 1
            elif a.get("text"):
                texts.append((len(texts), _clean_name(a.get("name", "")), a.get("kind", "text"), a["text"], a.get("note")))
    # fair allocation ("water-filling"): small files keep everything, leftover goes to the big ones
    alloc: dict = {}
    remaining, order = budget, sorted(texts, key=lambda t: len(t[3]))
    for k, t in enumerate(order):
        share = remaining // (len(order) - k)
        alloc[t[0]] = min(len(t[3]), share); remaining -= alloc[t[0]]
    blocks, uses = [], []
    for order_i, name, kind, text, note in texts:
        body, excerpted = select_excerpts(text, alloc[order_i], query)
        uses.append(FileUse(name, len(body), len(text), excerpted))
        head = f'Attached file "{name}" ({kind})'
        if excerpted: head += f" — EXCERPTS ONLY: about {len(body):,} of {len(text):,} characters shown, chosen for relevance to the question"
        if note: head += f" — {note}"
        blocks.append(wrap_untrusted(f"file:{name}", head + "\n" + body))
    return AttachmentContext(blocks, uses, {k: tuple(v) for k, v in images_by_message.items()}, dropped)
