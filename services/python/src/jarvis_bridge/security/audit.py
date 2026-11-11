"""Append-only audit log (SQLite). Content is redacted before it is stored; no prompts or file bodies."""
from __future__ import annotations
import json
import sqlite3
import threading
import time
from pathlib import Path
from .redact import redact, redact_text

_SCHEMA = """
CREATE TABLE IF NOT EXISTS audit_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts REAL NOT NULL,
  actor TEXT NOT NULL,
  agent_id TEXT,
  tool_id TEXT,
  target TEXT,
  decision TEXT NOT NULL,
  approval_id TEXT,
  outcome TEXT,
  detail TEXT
);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_events(ts);
"""


class AuditLog:
    def __init__(self, path: str | Path = ":memory:"):
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock:
            self._db.executescript(_SCHEMA)

    def record(self, *, actor: str, decision: str, agent_id: str | None = None, tool_id: str | None = None,
               target: str | None = None, approval_id: str | None = None, outcome: str | None = None,
               detail: dict | None = None) -> int:
        with self._lock:
            cur = self._db.execute(
                "INSERT INTO audit_events(ts,actor,agent_id,tool_id,target,decision,approval_id,outcome,detail)"
                " VALUES(?,?,?,?,?,?,?,?,?)",
                (time.time(), actor, agent_id, tool_id, redact_text(target) if target else None, decision,
                 approval_id, outcome, json.dumps(redact(detail or {}), default=str)),
            )
            self._db.commit()
            return int(cur.lastrowid)

    def query(self, *, limit: int = 100, tool_id: str | None = None, decision: str | None = None) -> list[dict]:
        q, args = "SELECT id,ts,actor,agent_id,tool_id,target,decision,approval_id,outcome,detail FROM audit_events", []
        cond = []
        if tool_id:
            cond.append("tool_id=?"); args.append(tool_id)
        if decision:
            cond.append("decision=?"); args.append(decision)
        if cond:
            q += " WHERE " + " AND ".join(cond)
        q += " ORDER BY id DESC LIMIT ?"; args.append(limit)
        with self._lock:
            rows = self._db.execute(q, args).fetchall()
        keys = ("id", "ts", "actor", "agent_id", "tool_id", "target", "decision", "approval_id", "outcome", "detail")
        return [dict(zip(keys, r)) | {"detail": json.loads(r[9] or "{}")} for r in rows]

    def purge_older_than(self, seconds: float) -> int:
        with self._lock:
            cur = self._db.execute("DELETE FROM audit_events WHERE ts < ?", (time.time() - seconds,))
            self._db.commit()
            return cur.rowcount

    def export_json(self) -> str:
        return json.dumps(self.query(limit=10**9), indent=2)
