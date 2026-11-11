"""ObsidianService: the one object the rest of the bridge talks to.

  * knowledge base: `context_for()` (automatic notes for a question) and `search()` / `read()` (the model's note tools)
  * the model's own notes: `create_note()` / `append_note()` (new notes in its folder only; see vault.py)
  * memory storage: every memory is mirrored as a note in `<agent folder>/Memories/`, and edits, deletions and new notes made
    in Obsidian flow back (see `sync_memories`)
Everything fails soft: an unreachable or misconfigured vault turns the features off with an explanation; it never breaks chat.
"""
from __future__ import annotations
import hashlib, json, os, re, tempfile, threading, time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from ..security.redact import redact_text
from ..security.untrusted import wrap_untrusted
from .index import Hit, VaultIndex, query_words
from .vault import Vault, VaultError, link_key, parse_frontmatter

MEMORY_SUB = "Memories"
REFRESH_EVERY = 20.0                 # seconds between cheap change checks before a chat turn
SYNC_EVERY = 30.0
MIRROR_SKIP_SENSITIVITY = ("sensitive",)       # never copy sensitive memories into a vault that may sync to the cloud
_EXPLICIT = re.compile(r"\b(obsidian|my (vault|notes?|second brain|knowledge base)|in my notes|from my notes|my notes (say|on|about))\b", re.I)


def _h(text: str) -> str:
    return hashlib.sha256(re.sub(r"\s+", " ", (text or "").strip()).encode()).hexdigest()[:16]


@dataclass
class VaultContext:
    text: str = ""
    uses: list = field(default_factory=list)       # [{"path","title","heading"}]


class ObsidianService:
    def __init__(self, settings, state_dir: str | Path, memory=None, audit=None, clock=time.time):
        self.settings, self.memory, self._audit, self._clock = settings, memory, audit, clock
        self.state_dir = Path(state_dir); self.state_dir.mkdir(parents=True, exist_ok=True)
        self.index = VaultIndex(self.state_dir / "vault_index.db")
        self._state_path = self.state_dir / "obsidian_sync.json"
        self._lock = threading.RLock()
        self._vault: Vault | None = None
        self._vault_key: tuple | None = None
        self.issue: str | None = None
        self._last_refresh = 0.0
        self._last_sync = 0.0
        self._syncing = False
        self.last_report: dict | None = None
        if memory is not None: memory.add_listener(self._on_memory)

    # ------------------------------------------------------------ configuration
    @property
    def cfg(self): return self.settings.value

    def _vault_now(self) -> Vault | None:
        """The configured vault, or None (with `self.issue` explaining why)."""
        c = self.cfg
        if not c.obsidian_enabled or not c.obsidian_vault_path:
            self._vault, self._vault_key, self.issue = None, None, None
            return None
        key = (c.obsidian_vault_path, c.obsidian_agent_folder)
        with self._lock:
            if self._vault is not None and self._vault_key == key and self._vault.reachable(): return self._vault
            try:
                self._vault = Vault(c.obsidian_vault_path, c.obsidian_agent_folder); self._vault_key = key; self.issue = None
                self._last_refresh = 0.0
            except VaultError as e:
                self._vault, self._vault_key, self.issue = None, None, str(e)
            return self._vault

    @property
    def active(self) -> bool: return self._vault_now() is not None

    def _log(self, decision: str, **detail):
        if self._audit:
            try: self._audit(actor="assistant", decision=decision, detail=detail)
            except Exception: pass

    # ------------------------------------------------------------ index freshness
    def refresh(self, *, force: bool = False, max_seconds: float = 20.0) -> dict:
        v = self._vault_now()
        if v is None: return {"notes": 0, "chunks": 0, "changed": 0, "removed": 0, "pending": 0}
        r = self.index.refresh(v, max_seconds=max_seconds, force=force)
        self._last_refresh = self._clock()
        return r

    def ensure_fresh(self) -> None:
        if self._clock() - self._last_refresh >= REFRESH_EVERY: self.refresh(max_seconds=1.5)

    def status(self) -> dict:
        v = self._vault_now()
        c = self.cfg
        st = self.index.stats() if v else {"notes": 0, "chunks": 0, "fts": self.index.fts}
        return {"enabled": c.obsidian_enabled, "configured": bool(c.obsidian_vault_path), "active": v is not None,
                "vault_path": c.obsidian_vault_path, "vault_name": Path(c.obsidian_vault_path).name if c.obsidian_vault_path else "",
                "issue": self.issue, "notes": st["notes"], "chunks": st["chunks"], "agent_folder": c.obsidian_agent_folder,
                "memories_folder": f"{c.obsidian_agent_folder}/{MEMORY_SUB}", "fts": st["fts"],
                "last_index": self._last_refresh or None, "last_sync": self.last_report}

    # ------------------------------------------------------------ knowledge base
    def search(self, query: str, limit: int = 6, **kw) -> list:
        if self._vault_now() is None: return []
        self.ensure_fresh()
        return self.index.search(query, limit=limit, **kw)

    def read(self, ref: str, max_chars: int = 12_000) -> dict | None:
        """A whole note by path, title, alias or [[link]]. Returns None if there is no such note."""
        v = self._vault_now()
        if v is None: return None
        self.ensure_fresh()
        rel = self.index.resolve(ref)
        if rel is None:
            try: v.safe_path(ref if ref.lower().endswith(".md") else ref + ".md"); rel = ref if ref.lower().endswith(".md") else ref + ".md"
            except VaultError: return None
        try: note = v.read_note(rel)
        except VaultError: return None
        body = note.body.strip()
        cut = len(body) > max_chars
        return {"path": note.rel, "title": note.title, "tags": note.tags, "aliases": note.aliases, "body": body[:max_chars] + ("\n[…note shortened]" if cut else ""),
                "truncated": cut, "links": [{"name": l, "path": self.index.resolve(l)} for l in note.links[:40]],
                "backlinks": self.index.backlinks(note.rel), "mtime": note.mtime, "frontmatter": note.frontmatter,
                "agent_note": v.in_agent_area(note.rel)}

    def context_for(self, prompt: str, *, budget: int | None = None, force: bool | None = None, limit: int = 5) -> VaultContext:
        """The notes worth showing the model for this question: sections that really match, within a character budget."""
        if not self.cfg.obsidian_auto_context or self._vault_now() is None or not (prompt or "").strip(): return VaultContext()
        explicit = bool(_EXPLICIT.search(prompt)) if force is None else force
        words = query_words(prompt)
        if not words or (len(prompt.split()) < 3 and not explicit): return VaultContext()
        self.ensure_fresh()
        hits = self.index.search(prompt, limit=limit * 2)
        need = min(2, len(words))
        keep = [h for h in hits if h.title_match or h.matched >= need]
        if not explicit: keep = [h for h in keep if h.title_match or h.matched >= max(need, 2) or len(words) == 1]
        keep = keep[:limit]
        if not keep: return VaultContext()
        budget = budget or self.cfg.obsidian_context_chars
        blocks, uses, used = [], [], 0
        for i, h in enumerate(keep, 1):
            room = budget - used
            if room < 300: break
            text = redact_text(h.text.strip())
            if len(text) > room: text = text[:room].rsplit(" ", 1)[0] + " […]"
            head = f"[{i}] {h.title}" + (f" › {h.heading}" if h.heading else "") + f"  (path: {h.rel})"
            blocks.append(head + "\n" + text); used += len(text) + len(head)
            uses.append({"path": h.rel, "title": h.title, "heading": h.heading or None})
        if keep:
            out = [l for l, p in self.index.outgoing(keep[0].rel)[:6] if p]
            if out and blocks: blocks[0] += "\nLinked notes you can open: " + ", ".join(f"[[{l}]]" for l in out)
        return VaultContext(wrap_untrusted("obsidian vault", "\n\n".join(blocks)), uses)

    # ------------------------------------------------------------ the model's own notes
    def create_note(self, title: str, body: str, tags: list | None = None) -> dict:
        v = self._vault_now()
        if v is None: raise VaultError(self.issue or "No Obsidian vault is connected.")
        if not self.cfg.obsidian_allow_write: raise VaultError("Writing notes to the vault is turned off in Settings.")
        rel, renamed = v.create_note(title, body, tags)
        self._log("vault_note_created", path=rel, chars=len(body))
        self.refresh(max_seconds=2.0)
        return {"path": rel, "title": Path(rel).stem, "renamed": renamed}

    def create_note_as_user(self, title: str, body: str, tags: list | None = None) -> dict:
        """Same as create_note, for something the USER chose to save (so the model-writing switch does not apply)."""
        v = self._vault_now()
        if v is None: raise VaultError(self.issue or "No Obsidian vault is connected.")
        rel, renamed = v.create_note(title, body, tags)
        self._log("vault_note_created", path=rel, chars=len(body), by="user")
        self.refresh(max_seconds=2.0)
        return {"path": rel, "title": Path(rel).stem, "renamed": renamed}

    def append_note(self, ref: str, text: str) -> dict:
        v = self._vault_now()
        if v is None: raise VaultError(self.issue or "No Obsidian vault is connected.")
        if not self.cfg.obsidian_allow_write: raise VaultError("Writing notes to the vault is turned off in Settings.")
        rel = v.append_note(self.index.resolve(ref) or ref, text)
        self._log("vault_note_appended", path=rel, chars=len(text))
        self.refresh(max_seconds=2.0)
        return {"path": rel, "title": Path(rel).stem}

    # ------------------------------------------------------------ memory storage
    def _load_state(self) -> dict:
        try: return json.loads(self._state_path.read_text())
        except (OSError, ValueError): return {"vault": None, "memories": {}}

    def _save_state(self, st: dict) -> None:
        fd, tmp = tempfile.mkstemp(dir=self.state_dir, prefix=".obs-")
        with os.fdopen(fd, "w") as f: json.dump(st, f)
        os.replace(tmp, self._state_path)

    def _mem_active(self) -> Vault | None:
        return self._vault_now() if (self.cfg.obsidian_store_memories and self.memory is not None) else None

    @staticmethod
    def _mirrorable(m) -> bool:
        return m.sensitivity not in MIRROR_SKIP_SENSITIVITY and redact_text(m.content) == m.content

    def _note_text(self, m) -> str:
        fm = ["---", f"arjunos_id: {m.id}", f"category: {m.category}", f"status: {m.status}", f"source: {m.source}"]
        if m.project: fm.append(f"project: {m.project}")
        fm += [f"created: {datetime.fromtimestamp(m.created).replace(microsecond=0).isoformat()}", f"tags: [arjunos/memory, arjunos/{m.category}]", "---", ""]
        return "\n".join(fm) + m.content.strip() + "\n"

    def _mem_rel(self, v: Vault, m, st: dict) -> str:
        known = st["memories"].get(m.id)
        if known: return known["rel"]
        from .vault import clean_title
        return f"{v.agent_folder}/{MEMORY_SUB}/{clean_title(m.content[:50])} - {m.id[-6:]}.md"

    def _on_memory(self, event: str, mid: str | None) -> None:
        """Called by the memory store on every change: keep the vault copy current (skipped while a sync is already running)."""
        if self._syncing: return
        v = self._mem_active()
        if v is None or not v.reachable(): return
        with self._lock:
            try:
                if event == "bulk": self.sync_memories(); return
                st = self._load_state()
                if event == "delete" and mid:
                    k = st["memories"].pop(mid, None)
                    if k: v.delete_agent_file(k["rel"])
                elif event == "upsert" and mid:
                    m = self.memory.get(mid, touch=False)
                    if m is None or not self._mirrorable(m): return
                    rel = self._mem_rel(v, m, st)
                    v.write_agent_file(rel, self._note_text(m))
                    st["memories"][mid] = {"rel": rel, "hash": _h(m.content), "mtime": (v.safe_path(rel).stat().st_mtime)}
                st["vault"] = str(v.root); self._save_state(st)
            except (VaultError, OSError): pass

    def sync_memories(self) -> dict:
        """Reconcile memories and their notes, both ways. Rules:
          * a note you edited in Obsidian wins and updates the memory; a memory changed in the app updates its note
          * a note you deleted in Obsidian deletes the memory (unless most notes vanished at once: then the vault is probably
            unavailable, nothing is deleted, and a warning is reported)
          * a note you drop into the Memories folder becomes a memory
          * a memory deleted in the app deletes its note; sensitive memories are never copied into the vault"""
        rep = {"written": 0, "imported": 0, "memory_updated": 0, "note_updated": 0, "notes_deleted": 0, "memories_deleted": 0, "warnings": []}
        v = self._mem_active()
        if v is None:
            if self.cfg.obsidian_enabled and self.cfg.obsidian_store_memories and self.issue: rep["warnings"].append(self.issue + " Nothing was synced and nothing was deleted.")
            return rep
        if not v.reachable(): rep["warnings"].append("The vault isn't reachable, so nothing was synced."); return rep
        from ..memory.store import CATEGORIES
        with self._lock:
            self._syncing = True
            try:
                st = self._load_state()
                if st.get("vault") not in (None, str(v.root)): st = {"vault": str(v.root), "memories": {}}        # a different vault: start fresh
                tracked = st["memories"]
                mems = {m.id: m for m in self.memory.list(limit=100_000)}
                folder = f"{v.agent_folder}/{MEMORY_SUB}"
                on_disk = {}
                for rel, _mt, _sz in v.iter_notes():
                    if rel.startswith(folder + "/"):
                        try: text, _, _ = v.read_text(rel)
                        except VaultError: continue
                        fm, body = parse_frontmatter(text); on_disk[rel] = (fm, body.strip(), text)
                by_id = {fm.get("arjunos_id"): rel for rel, (fm, _b, _t) in on_disk.items() if isinstance(fm.get("arjunos_id"), str)}
                gone = [mid for mid, k in tracked.items() if k["rel"] not in on_disk and mid in mems]
                guard_trip = bool(tracked) and len(gone) > max(5, len(tracked) // 2)
                if guard_trip: rep["warnings"].append(f"{len(gone)} memory notes disappeared at once, so I kept those memories and recreated their notes instead of deleting them.")

                # notes on disk
                for rel, (fm, body, text) in on_disk.items():
                    mid = fm.get("arjunos_id") if isinstance(fm.get("arjunos_id"), str) else None
                    if mid and mid in mems:
                        m, k = mems[mid], tracked.get(mid)
                        note_changed = (k is None) or _h(body) != k["hash"]
                        mem_changed = (k is None) or _h(m.content) != k["hash"]
                        if note_changed and body and _h(body) != _h(m.content):
                            if redact_text(body) != body: rep["warnings"].append(f"{Path(rel).name} looks like it contains a secret, so I did not import the edit."); continue
                            self.memory.edit(mid, body); rep["memory_updated"] += 1; m = self.memory.get(mid, touch=False)
                        elif mem_changed and _h(m.content) != _h(body) and self._mirrorable(m):
                            v.write_agent_file(rel, self._note_text(m)); rep["note_updated"] += 1
                        tracked[mid] = {"rel": rel, "hash": _h(m.content), "mtime": v.safe_path(rel).stat().st_mtime}
                    elif mid and mid not in mems and mid in tracked:
                        v.delete_agent_file(rel); tracked.pop(mid, None); rep["notes_deleted"] += 1       # deleted in the app
                    elif body:                                                                              # a new note you dropped in (or a memory DB that was reset)
                        if redact_text(body) != body: rep["warnings"].append(f"{Path(rel).name} looks like it contains a secret, so I did not import it."); continue
                        cat = fm.get("category") if fm.get("category") in CATEGORIES else "knowledge"
                        try: m = self.memory.add(body, category=cat, source="user", confirmed=True, provenance={"via": "obsidian", "path": rel})
                        except ValueError: continue
                        new_text = self._note_text(m); v.write_agent_file(rel, new_text)                  # stamp it with its memory id
                        mems[m.id] = m; tracked[m.id] = {"rel": rel, "hash": _h(m.content), "mtime": v.safe_path(rel).stat().st_mtime}; rep["imported"] += 1

                # memories without a note
                for mid, m in mems.items():
                    if mid in by_id or (mid in tracked and tracked[mid]["rel"] in on_disk): continue
                    if not self._mirrorable(m): continue
                    if mid in tracked and not guard_trip:                                                   # had a note, now gone: you deleted it in Obsidian
                        self.memory.delete(mid)
                        tracked.pop(mid, None); rep["memories_deleted"] += 1; continue
                    rel = self._mem_rel(v, m, {"memories": {}}) if mid not in tracked else tracked[mid]["rel"]
                    v.write_agent_file(rel, self._note_text(m))
                    tracked[mid] = {"rel": rel, "hash": _h(m.content), "mtime": v.safe_path(rel).stat().st_mtime}; rep["written"] += 1
                for mid in [i for i in tracked if i not in mems and tracked[i]["rel"] not in on_disk]: tracked.pop(mid, None)   # tidy: gone from both sides
                st["vault"] = str(v.root); st["memories"] = tracked; self._save_state(st)
            finally:
                self._syncing = False
        self._last_sync = self._clock(); rep["at"] = self._last_sync; self.last_report = rep
        if any(rep[k] for k in ("written", "imported", "memory_updated", "note_updated", "notes_deleted", "memories_deleted")):
            self._log("vault_memory_sync", **{k: v_ for k, v_ in rep.items() if k != "warnings"})
        self.refresh(max_seconds=2.0)
        return rep

    def sync_if_due(self) -> None:
        if self._mem_active() is not None and self._clock() - self._last_sync >= SYNC_EVERY:
            try: self.sync_memories()
            except Exception: self._last_sync = self._clock()
