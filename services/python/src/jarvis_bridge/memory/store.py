"""Unified persistent memory: one SQLite database, FTS5 retrieval, provenance, project/agent isolation.

Design rules from the brief:
  * not every statement becomes memory: long-term preferences are PROPOSED and need user confirmation
  * conflicting memories keep provenance and are linked, never silently replaced
  * retrieval is explainable (why each record matched)
  * deletion/export/import are first-class
"""
from __future__ import annotations
import hashlib
import json
import re
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Callable

CATEGORIES = ("conversation", "preference", "project", "agent", "task", "document", "procedural", "episodic",
              "tool_history", "knowledge")
# categories that are never auto-confirmed
NEEDS_CONFIRMATION = {"preference", "procedural"}
SOURCE_TRUST = {"user": 1.0, "user_confirmed": 1.0, "agent": 0.6, "tool": 0.4, "document": 0.5, "web": 0.3, "import": 0.5}
SENSITIVITY = ("public", "personal", "sensitive")

SCHEMA_VERSION = 1
_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS memories(
  id TEXT PRIMARY KEY, category TEXT NOT NULL, content TEXT NOT NULL, content_hash TEXT NOT NULL,
  subject_key TEXT, status TEXT NOT NULL DEFAULT 'confirmed',          -- confirmed|proposed|unverified|inferred
  created REAL NOT NULL, last_accessed REAL, source TEXT NOT NULL, source_ref TEXT, provenance TEXT,
  project TEXT, agent_id TEXT, visibility TEXT NOT NULL DEFAULT 'private', -- private|shared
  confidence REAL NOT NULL DEFAULT 1.0, sensitivity TEXT NOT NULL DEFAULT 'personal',
  expires REAL, embedding_status TEXT NOT NULL DEFAULT 'none', embedding TEXT,
  conflicts_with TEXT
);
CREATE INDEX IF NOT EXISTS idx_mem_project ON memories(project);
CREATE INDEX IF NOT EXISTS idx_mem_hash ON memories(content_hash);
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(content, content='memories', content_rowid='rowid', tokenize='porter unicode61');
CREATE TRIGGER IF NOT EXISTS mem_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(rowid, content) VALUES (new.rowid, new.content); END;
CREATE TRIGGER IF NOT EXISTS mem_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, content) VALUES('delete', old.rowid, old.content); END;
CREATE TRIGGER IF NOT EXISTS mem_au AFTER UPDATE OF content ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, content) VALUES('delete', old.rowid, old.content);
  INSERT INTO memories_fts(rowid, content) VALUES (new.rowid, new.content); END;
"""


@dataclass
class Memory:
    id: str; category: str; content: str; status: str; source: str; created: float
    project: str | None = None; agent_id: str | None = None; visibility: str = "private"
    confidence: float = 1.0; sensitivity: str = "personal"; subject_key: str | None = None
    expires: float | None = None; conflicts_with: str | None = None; source_ref: str | None = None
    embedding_status: str = "none"; last_accessed: float | None = None; provenance: dict | None = None


@dataclass
class Hit:
    memory: Memory
    score: float
    why: dict


def _hash(text: str) -> str:
    return hashlib.sha256(re.sub(r"\s+", " ", text.strip().lower()).encode()).hexdigest()


_STOP = frozenset("""a about above after again all also am an and any are as at be because been before being below between both but
by can could did do does doing down during each few for from further had has have having he her here hers him his how i if in into
is it its just me more most my no nor not of off on once only or other our out over own same she should so some such than that the
their them then there these they this those through to too under until up us very was we were what when where which while who whom
why will with would you your yours tell please""".split())


def _fts_query(q: str) -> str:
    toks = re.findall(r"\w+", q, re.UNICODE)
    kept = [t for t in toks if t.lower() not in _STOP and len(t) > 1]
    toks = kept or toks                                      # an all-stopword query still searches something
    return " OR ".join(f'"{t}"' for t in toks[:16])          # quoted tokens: no FTS syntax injection


class MemoryStore:
    def __init__(self, path: str | Path = ":memory:", *, embedder: Callable[[str], list] | None = None,
                 clock=time.time):
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        self._clock, self._embedder = clock, embedder
        self._listeners: list = []
        with self._lock:
            self._db.executescript(_SCHEMA)
            self._db.execute("INSERT OR IGNORE INTO meta(k,v) VALUES('schema_version',?)", (str(SCHEMA_VERSION),))
            self._db.commit()

    # ---------- change notifications (the Obsidian mirror listens here, so every route into memory is covered) ----------
    def add_listener(self, fn: Callable[[str, str | None], None]) -> None:
        """fn(event, memory_id): event is 'upsert' | 'delete' | 'bulk' (many changed at once; id is None)."""
        self._listeners.append(fn)

    def _notify(self, event: str, mid: str | None = None) -> None:
        for fn in list(self._listeners):
            try: fn(event, mid)
            except Exception: pass                       # a broken listener must never break memory itself

    @property
    def schema_version(self) -> int:
        return int(self._db.execute("SELECT v FROM meta WHERE k='schema_version'").fetchone()[0])

    # ---------- create ----------
    def add(self, content: str, *, category: str, source: str = "user", project: str | None = None,
            agent_id: str | None = None, visibility: str = "private", confidence: float | None = None,
            sensitivity: str = "personal", subject_key: str | None = None, expires: float | None = None,
            source_ref: str | None = None, provenance: dict | None = None, confirmed: bool = False) -> Memory:
        if category not in CATEGORIES:
            raise ValueError(f"unknown category {category!r}")
        if sensitivity not in SENSITIVITY:
            raise ValueError(f"unknown sensitivity {sensitivity!r}")
        if not content.strip():
            raise ValueError("empty memory")
        # Only the user (or explicit confirmation) can create a confirmed preference/procedure.
        if category in NEEDS_CONFIRMATION and not (confirmed and source in ("user", "user_confirmed")):
            status = "proposed"
        elif source in ("web", "tool", "document", "import"):
            status = "unverified"
        elif source == "agent":
            status = "inferred"
        else:
            status = "confirmed"
        h = _hash(content)
        with self._lock:
            dup = self._db.execute(
                "SELECT id FROM memories WHERE content_hash=? AND category=? AND IFNULL(project,'')=IFNULL(?,'') "
                "AND IFNULL(agent_id,'')=IFNULL(?,'')", (h, category, project, agent_id)).fetchone()
            if dup:                                              # duplicate detection: return existing
                return self.get(dup["id"], touch=False)
            conflict = None
            if subject_key:
                row = self._db.execute(
                    "SELECT id,content_hash FROM memories WHERE subject_key=? AND category=? AND IFNULL(project,'')=IFNULL(?,'') "
                    "AND status IN ('confirmed','proposed','inferred') ORDER BY created DESC LIMIT 1",
                    (subject_key, category, project)).fetchone()
                if row and row["content_hash"] != h:
                    conflict = row["id"]                         # preserve both; link them
            mid = "mem_" + uuid.uuid4().hex[:16]
            conf = confidence if confidence is not None else SOURCE_TRUST.get(source, 0.5)
            emb, est = None, "none"
            if self._embedder:
                try:
                    emb, est = json.dumps(self._embedder(content)), "embedded"
                except Exception:
                    est = "failed"
            self._db.execute(
                "INSERT INTO memories(id,category,content,content_hash,subject_key,status,created,source,source_ref,provenance,"
                "project,agent_id,visibility,confidence,sensitivity,expires,embedding_status,embedding,conflicts_with)"
                " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (mid, category, content, h, subject_key, status, self._clock(), source, source_ref,
                 json.dumps(provenance or {}), project, agent_id, visibility, conf, sensitivity, expires, est, emb, conflict))
            if conflict:
                self._db.execute("UPDATE memories SET conflicts_with=? WHERE id=? AND conflicts_with IS NULL", (mid, conflict))
            self._db.commit()
        self._notify("upsert", mid)
        return self.get(mid, touch=False)

    # ---------- read ----------
    def _row(self, r: sqlite3.Row) -> Memory:
        d = {k: r[k] for k in r.keys() if k not in ("content_hash", "embedding", "bm")}
        d["provenance"] = json.loads(d.get("provenance") or "{}")
        return Memory(**d)

    def get(self, mid: str, *, touch: bool = True) -> Memory | None:
        with self._lock:
            r = self._db.execute("SELECT * FROM memories WHERE id=?", (mid,)).fetchone()
            if r and touch:
                self._db.execute("UPDATE memories SET last_accessed=? WHERE id=?", (self._clock(), mid)); self._db.commit()
        return self._row(r) if r else None

    def _visible_sql(self, project, agent_id, include_unconfirmed, alias: str = ""):
        p = f"{alias}." if alias else ""
        w, a = [f"({p}expires IS NULL OR {p}expires > ?)"], [self._clock()]
        if project is None:
            w.append(f"{p}project IS NULL")
        else:
            w.append(f"{p}project = ?"); a.append(project)           # project isolation: no cross-project reads
        if agent_id is not None:
            w.append(f"({p}visibility='shared' OR {p}agent_id IS NULL OR {p}agent_id = ?)"); a.append(agent_id)
        else:
            w.append(f"({p}visibility='shared' OR {p}agent_id IS NULL)")
        if not include_unconfirmed:
            w.append(f"{p}status IN ('confirmed','inferred')")
        return " AND ".join(w), a

    def search(self, query: str, *, project: str | None = None, agent_id: str | None = None, limit: int = 8,
               categories: tuple | None = None, include_unconfirmed: bool = False) -> list[Hit]:
        fq = _fts_query(query)
        if not fq:
            return []
        where, args = self._visible_sql(project, agent_id, include_unconfirmed, alias="m")
        if categories:
            where += f" AND m.category IN ({','.join('?' * len(categories))})"; args += list(categories)
        sql = ("SELECT m.*, bm25(memories_fts) AS bm FROM memories_fts JOIN memories m ON m.rowid = memories_fts.rowid "
               f"WHERE memories_fts MATCH ? AND {where} ORDER BY bm LIMIT ?")
        with self._lock:
            rows = self._db.execute(sql, [fq, *args, limit * 4]).fetchall()
        now, hits = self._clock(), []
        qvec = self._embedder(query) if self._embedder else None
        best_bm = max((-r["bm"] for r in rows), default=0.0)          # bm25: more negative = better match
        for r in rows:
            m = self._row(r)
            # every FTS hit is a keyword match (baseline 0.5); bm25 only ranks among matches (BM25 collapses on tiny corpora)
            lexical = 0.5 + (0.5 * (-r["bm"]) / best_bm if best_bm > 0 else 0.0)
            age_days = max(0.0, (now - (m.last_accessed or m.created)) / 86400)
            recency = 1.0 / (1.0 + age_days / 30.0)
            trust = SOURCE_TRUST.get(m.source, 0.5)
            semantic = 0.0
            if qvec and r["embedding"]:
                semantic = max(0.0, _cos(qvec, json.loads(r["embedding"])))
            score = 0.55 * lexical + 0.15 * recency + 0.15 * trust * m.confidence + 0.15 * semantic
            hits.append(Hit(m, score, {"lexical": round(lexical, 3), "recency": round(recency, 3),
                                       "source_trust": trust, "confidence": m.confidence,
                                       "semantic": round(semantic, 3), "source": m.source, "source_ref": m.source_ref,
                                       "status": m.status, "project": m.project, "conflicts_with": m.conflicts_with}))
        hits.sort(key=lambda h: -h.score)
        out = hits[:limit]
        with self._lock:
            for h in out:
                self._db.execute("UPDATE memories SET last_accessed=? WHERE id=?", (now, h.memory.id))
            self._db.commit()
        return out

    def list(self, *, category: str | None = None, project: str | None = None, status: str | None = None,
             limit: int = 200) -> list[Memory]:
        q, a, w = "SELECT * FROM memories", [], []
        if category: w.append("category=?"); a.append(category)
        if project is not None: w.append("project=?"); a.append(project)
        if status: w.append("status=?"); a.append(status)
        if w: q += " WHERE " + " AND ".join(w)
        q += " ORDER BY created DESC LIMIT ?"; a.append(limit)
        with self._lock:
            return [self._row(r) for r in self._db.execute(q, a).fetchall()]

    # ---------- lifecycle ----------
    def confirm(self, mid: str) -> Memory:
        with self._lock:
            self._db.execute("UPDATE memories SET status='confirmed', confidence=1.0 WHERE id=?", (mid,)); self._db.commit()
        self._notify("upsert", mid)
        return self.get(mid, touch=False)

    def edit(self, mid: str, content: str) -> Memory:
        with self._lock:
            self._db.execute("UPDATE memories SET content=?, content_hash=?, embedding_status=? WHERE id=?",
                             (content, _hash(content), "none" if not self._embedder else "stale", mid)); self._db.commit()
        self._notify("upsert", mid)
        return self.get(mid, touch=False)

    def resolve_conflict(self, keep_id: str, drop_id: str) -> None:
        """User-driven: keep one, delete the other, clear the link. Never automatic."""
        with self._lock:
            self._db.execute("DELETE FROM memories WHERE id=?", (drop_id,))
            self._db.execute("UPDATE memories SET conflicts_with=NULL WHERE id=?", (keep_id,)); self._db.commit()
        self._notify("delete", drop_id)

    def delete(self, mid: str) -> bool:
        with self._lock:
            n = self._db.execute("DELETE FROM memories WHERE id=?", (mid,)).rowcount; self._db.commit()
        if n: self._notify("delete", mid)
        return n > 0

    def delete_where(self, *, category: str | None = None, project: str | None = None, agent_id: str | None = None) -> int:
        w, a = [], []
        if category: w.append("category=?"); a.append(category)
        if project is not None: w.append("project=?"); a.append(project)
        if agent_id is not None: w.append("agent_id=?"); a.append(agent_id)
        if not w:
            raise ValueError("refusing unscoped delete; use wipe() explicitly")
        with self._lock:
            n = self._db.execute("DELETE FROM memories WHERE " + " AND ".join(w), a).rowcount; self._db.commit()
        if n: self._notify("bulk")
        return n

    def wipe(self) -> int:
        with self._lock:
            n = self._db.execute("DELETE FROM memories").rowcount; self._db.commit()
        if n: self._notify("bulk")
        return n

    def expire_due(self) -> int:
        with self._lock:
            n = self._db.execute("DELETE FROM memories WHERE expires IS NOT NULL AND expires <= ?", (self._clock(),)).rowcount
            self._db.commit()
        if n: self._notify("bulk")
        return n

    def find_by_subject(self, subject_key: str) -> Memory | None:
        """The newest memory stored under `subject_key` (the profile uses this for the user's name), or None."""
        with self._lock:
            r = self._db.execute("SELECT * FROM memories WHERE subject_key=? ORDER BY created DESC LIMIT 1", (subject_key,)).fetchone()
        return self._row(r) if r else None

    def count(self, *, exclude_subject: str | None = None) -> int:
        with self._lock:
            if exclude_subject:
                return self._db.execute("SELECT COUNT(*) FROM memories WHERE IFNULL(subject_key,'')<>?", (exclude_subject,)).fetchone()[0]
            return self._db.execute("SELECT COUNT(*) FROM memories").fetchone()[0]

    def storage_stats(self) -> dict:
        with self._lock:
            by = {r[0]: r[1] for r in self._db.execute("SELECT category,COUNT(*) FROM memories GROUP BY category")}
            pages = self._db.execute("PRAGMA page_count").fetchone()[0] * self._db.execute("PRAGMA page_size").fetchone()[0]
        return {"total": sum(by.values()), "by_category": by, "db_bytes": pages}

    # ---------- export / import / reindex ----------
    def export_json(self, *, include_sensitive: bool = False) -> str:
        rows = [asdict(m) for m in self.list(limit=10**9) if include_sensitive or m.sensitivity != "sensitive"]
        return json.dumps({"format": "jarvis-memory", "version": 1, "memories": rows}, indent=2)

    def import_json(self, blob: str) -> int:
        d = json.loads(blob)
        if d.get("format") != "jarvis-memory":
            raise ValueError("not a jarvis-memory export")
        n = 0
        for m in d["memories"]:
            # imported memories never self-confirm: they arrive as source=import, status derived by policy
            before = self.storage_stats()["total"]
            self.add(m["content"], category=m["category"], source="import", project=m.get("project"),
                     agent_id=m.get("agent_id"), visibility=m.get("visibility", "private"),
                     sensitivity=m.get("sensitivity", "personal"), subject_key=m.get("subject_key"),
                     provenance={"imported_from": m.get("id"), "original_source": m.get("source")})
            n += self.storage_stats()["total"] - before
        return n

    def reindex(self) -> dict:
        """Rebuild the FTS index and (if an embedder is configured) all embeddings."""
        with self._lock:
            self._db.execute("INSERT INTO memories_fts(memories_fts) VALUES('rebuild')")
            done = failed = 0
            if self._embedder:
                for r in self._db.execute("SELECT id,content FROM memories").fetchall():
                    try:
                        self._db.execute("UPDATE memories SET embedding=?, embedding_status='embedded' WHERE id=?",
                                         (json.dumps(self._embedder(r["content"])), r["id"])); done += 1
                    except Exception:
                        self._db.execute("UPDATE memories SET embedding_status='failed' WHERE id=?", (r["id"],)); failed += 1
            self._db.commit()
        return {"fts": "rebuilt", "embedded": done, "failed": failed}


def _cos(a, b) -> float:
    if not a or not b or len(a) != len(b): return 0.0
    dot = sum(x * y for x, y in zip(a, b)); na = sum(x * x for x in a) ** .5; nb = sum(y * y for y in b) ** .5
    return dot / (na * nb) if na and nb else 0.0
