"""A searchable index of the vault (SQLite, rebuilt incrementally from file modification times).

Notes are split into heading sections; each section is one searchable chunk (FTS5 + BM25, with a plain-Python fallback when the
local SQLite lacks FTS5). Title, alias and tag matches are boosted, because in a vault the note name is the strongest signal.
The index lives in the app's state folder, never inside the vault, and can always be rebuilt from the notes.
"""
from __future__ import annotations
import re, sqlite3, threading, time
from dataclasses import dataclass, field
from pathlib import Path
from ..memory.store import _STOP
from .vault import Vault, VaultError, chunk_note, link_key, parse_note

SCHEMA = """
CREATE TABLE IF NOT EXISTS notes(rel TEXT PRIMARY KEY, key TEXT, mtime REAL, size INTEGER, title TEXT, tags TEXT, aliases TEXT, links TEXT);
CREATE INDEX IF NOT EXISTS notes_key ON notes(key);
CREATE TABLE IF NOT EXISTS links(src TEXT, dst TEXT);
CREATE INDEX IF NOT EXISTS links_dst ON links(dst);
CREATE INDEX IF NOT EXISTS links_src ON links(src);
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
"""


@dataclass
class Hit:
    rel: str
    title: str
    heading: str
    text: str                      # the matching section
    score: float
    tags: list = field(default_factory=list)
    matched: int = 0               # how many distinct query words the section contains
    title_match: bool = False


def query_words(q: str) -> list:
    toks = [t.lower() for t in re.findall(r"\w+", q or "", re.UNICODE)]
    kept = [t for t in toks if t not in _STOP and len(t) > 1]
    return list(dict.fromkeys(kept or toks))[:16]


class VaultIndex:
    def __init__(self, path: str | Path = ":memory:"):
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        with self._lock:
            self._db.executescript(SCHEMA)
            try:
                self._db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(rel UNINDEXED, heading, body, title, tokenize='porter unicode61')")
                self.fts = True
            except sqlite3.OperationalError:
                self._db.execute("CREATE TABLE IF NOT EXISTS chunks(rel TEXT, heading TEXT, body TEXT, title TEXT)")
                self.fts = False
            self._db.commit()
        self.root: str | None = None

    def close(self):
        with self._lock: self._db.close()

    # ---------------------------------------------------------------- building
    def bind(self, vault: Vault):
        """Tie the index to one vault; switching vaults starts from a clean index."""
        with self._lock:
            row = self._db.execute("SELECT v FROM meta WHERE k='root'").fetchone()
            if row and row["v"] != str(vault.root): self._clear()
            self._db.execute("INSERT OR REPLACE INTO meta(k,v) VALUES('root',?)", (str(vault.root),)); self._db.commit()
        self.root = str(vault.root)

    def _clear(self):
        for t in ("notes", "links", "chunks"): self._db.execute(f"DELETE FROM {t}")

    def _drop(self, rel: str):
        self._db.execute("DELETE FROM notes WHERE rel=?", (rel,)); self._db.execute("DELETE FROM links WHERE src=?", (rel,))
        self._db.execute("DELETE FROM chunks WHERE rel=?", (rel,))

    def refresh(self, vault: Vault, *, max_seconds: float = 20.0, force: bool = False) -> dict:
        """Bring the index up to date with the files. Time-boxed: a huge vault is indexed over a few calls (`pending`)."""
        t0 = time.monotonic()
        self.bind(vault)
        current = {rel: (mt, sz) for rel, mt, sz in vault.iter_notes()}
        with self._lock:
            known = {r["rel"]: (r["mtime"], r["size"]) for r in self._db.execute("SELECT rel,mtime,size FROM notes")}
            if force: known = {}
            removed = [r for r in known if r not in current]
            changed = [r for r, v in current.items() if known.get(r) != v]
            for r in removed: self._drop(r)
            self._db.commit()
        done = 0
        for rel in changed:
            if time.monotonic() - t0 > max_seconds: break
            try: text, mt, sz = vault.read_text(rel)
            except VaultError: continue
            note = parse_note(rel, text, mt, sz)
            chunks = chunk_note(note)
            with self._lock:
                self._drop(rel)
                self._db.execute("INSERT INTO notes(rel,key,mtime,size,title,tags,aliases,links) VALUES(?,?,?,?,?,?,?,?)",
                                 (rel, link_key(rel), mt, sz, note.title, " ".join(note.tags), "\n".join(note.aliases), "\n".join(note.links)))
                self._db.executemany("INSERT INTO links(src,dst) VALUES(?,?)", [(rel, link_key(l)) for l in note.links])
                alias_title = " ".join([note.title, *note.aliases, *[t.replace("/", " ") for t in note.tags]])      # name, aliases and tags are all searchable
                rows = chunks or [("", note.title)]                                  # an empty note is still findable by name
                self._db.executemany("INSERT INTO chunks(rel,heading,body,title) VALUES(?,?,?,?)", [(rel, h, t, alias_title) for h, t in rows])
                self._db.commit()
            done += 1
        pending = max(0, len(changed) - done)
        return {**self.stats(), "changed": done, "removed": len(removed), "pending": pending, "seconds": round(time.monotonic() - t0, 2)}

    def stats(self) -> dict:
        with self._lock:
            n = self._db.execute("SELECT COUNT(*) FROM notes").fetchone()[0]
            c = self._db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        return {"notes": n, "chunks": c, "fts": self.fts}

    # ---------------------------------------------------------------- searching
    def _meta(self, rels: list) -> dict:
        if not rels: return {}
        with self._lock:
            q = ",".join("?" * len(rels))
            return {r["rel"]: r for r in self._db.execute(f"SELECT rel,title,tags,aliases FROM notes WHERE rel IN ({q})", rels)}

    def search(self, query: str, *, limit: int = 6, folder: str | None = None, tag: str | None = None) -> list:
        words = query_words(query)
        if not words: return []
        raw = self._fts(words, limit * 6) if self.fts else self._plain(words, limit * 6)
        meta = self._meta(list({r[0] for r in raw}))
        best: dict = {}
        for rel, heading, body, score in raw:
            m = meta.get(rel)
            if m is None: continue
            if folder and not rel.startswith(folder.rstrip("/") + "/"): continue
            tags = m["tags"].split() if m["tags"] else []
            if tag and tag.lower().lstrip("#") not in tags: continue
            low = (heading + " " + body).lower()
            matched = sum(1 for w in words if w in low)
            name = (m["title"] + " " + m["aliases"]).lower()
            tmatch = any(w in name for w in words if len(w) > 2) or any(w in tags for w in words)
            total = score + (3.0 if tmatch else 0) + 0.4 * matched
            h = Hit(rel, m["title"], heading, body, total, tags, matched, tmatch)
            if rel not in best or total > best[rel].score: best[rel] = h
        return sorted(best.values(), key=lambda h: -h.score)[:limit]

    def _fts(self, words: list, n: int) -> list:
        q = " OR ".join(f'"{w}"' for w in words)
        with self._lock:
            try:
                rows = self._db.execute("SELECT rel, heading, body, bm25(chunks, 0.0, 2.0, 1.0, 3.0) AS s FROM chunks WHERE chunks MATCH ? ORDER BY s LIMIT ?", (q, n)).fetchall()
            except sqlite3.OperationalError: return []
        return [(r["rel"], r["heading"], r["body"], -float(r["s"])) for r in rows]

    def _plain(self, words: list, n: int) -> list:
        out = []
        with self._lock:
            for r in self._db.execute("SELECT rel,heading,body,title FROM chunks"):
                low, name = (r["heading"] + " " + r["body"]).lower(), r["title"].lower()
                s = sum(low.count(w) for w in words) + 3 * sum(1 for w in words if w in name)
                if s: out.append((r["rel"], r["heading"], r["body"], float(s)))
        return sorted(out, key=lambda t: -t[3])[:n]

    # ---------------------------------------------------------------- the link graph
    def resolve(self, ref: str) -> str | None:
        """A note path, title, alias or [[wikilink]] -> its path, or None."""
        key = link_key(ref)
        if not key: return None
        with self._lock:
            exact = self._db.execute("SELECT rel FROM notes WHERE key=?", (key,)).fetchone()
            if exact: return exact["rel"]
            stem = key.rsplit("/", 1)[-1]
            rows = self._db.execute("SELECT rel,key,aliases FROM notes WHERE LOWER(title)=? OR key LIKE ? OR LOWER(aliases) LIKE ? ORDER BY LENGTH(rel), mtime DESC",
                                    (stem, "%/" + stem, "%" + stem + "%")).fetchall()
        for r in rows:                                                          # the vault's own rule: the shortest unambiguous path wins
            if r["key"] == key or r["key"].endswith("/" + key) or r["key"].rsplit("/", 1)[-1] == stem: return r["rel"]
        for r in rows:
            if key in [a.strip().lower() for a in r["aliases"].split("\n")]: return r["rel"]
        return None

    def outgoing(self, rel: str) -> list:
        """Notes this note links to: [(link text, resolved path or None)]."""
        with self._lock:
            row = self._db.execute("SELECT links FROM notes WHERE rel=?", (rel,)).fetchone()
        return [(l, self.resolve(l)) for l in (row["links"].split("\n") if row and row["links"] else [])]

    def backlinks(self, rel: str) -> list:
        with self._lock:
            row = self._db.execute("SELECT key,title,aliases FROM notes WHERE rel=?", (rel,)).fetchone()
            if not row: return []
            names = {row["key"], row["key"].rsplit("/", 1)[-1], *[a.strip().lower() for a in row["aliases"].split("\n") if a.strip()]}
            q = ",".join("?" * len(names))
            return [r["src"] for r in self._db.execute(f"SELECT DISTINCT src FROM links WHERE dst IN ({q}) AND src != ? LIMIT 50", [*names, rel])]

    def recent(self, limit: int = 20) -> list:
        with self._lock:
            return [{"rel": r["rel"], "title": r["title"], "mtime": r["mtime"], "tags": r["tags"].split() if r["tags"] else []}
                    for r in self._db.execute("SELECT rel,title,mtime,tags FROM notes ORDER BY mtime DESC LIMIT ?", (limit,))]

    def tags(self, limit: int = 50) -> list:
        counts: dict = {}
        with self._lock:
            for r in self._db.execute("SELECT tags FROM notes WHERE tags != ''"):
                for t in r["tags"].split(): counts[t] = counts.get(t, 0) + 1
        return sorted(({"tag": t, "count": c} for t, c in counts.items()), key=lambda x: (-x["count"], x["tag"]))[:limit]
