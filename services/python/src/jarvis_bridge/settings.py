"""User settings owned by the bridge (JSON file, atomic writes, validated). Defaults are privacy-conservative."""
from __future__ import annotations
import json, os, tempfile
from dataclasses import dataclass, asdict, fields
from pathlib import Path

WEB_MODES = ("off", "keyword", "auto")


@dataclass
class BridgeSettings:
    web_search_mode: str = "auto"           # off | keyword (explicit 'search ...' only) | auto (also time-sensitive questions)
    web_search_consented: bool = False      # one-time consent: search QUERIES (not chats) go to DuckDuckGo
    web_search_max_results: int = 5
    memory_auto_inject: bool = True         # surface relevant saved memories to the model
    attachment_context_chars: int = 12000   # max characters of attached-file text given to the model per answer
    browser_enabled: bool = True            # the built-in browser's page can be given to the assistant as context
    page_context_chars: int = 16000         # max characters of the open page given to the model per answer
    read_paths: bool = True                 # files and folders the user names by path in a message are read and given to the model (any file type)
    files_enabled: bool = True              # "create a markdown file": write files into the workspace without a prompt (no overwrite, safe types)
    shell_enabled: bool = True              # master switch for the sandboxed terminal (each command still needs approval)
    obsidian_enabled: bool = False          # use an Obsidian vault as a knowledge base and as storage for memories
    obsidian_vault_path: str = ""           # full path of the vault folder
    obsidian_auto_context: bool = True      # automatically give the model the notes that match what you ask
    obsidian_store_memories: bool = True    # keep memories as notes in the vault (two-way: edit or delete them in Obsidian)
    obsidian_allow_write: bool = True       # the model may create NEW notes in its own folder (it never edits your notes)
    obsidian_context_chars: int = 6000      # most note text given to the model per answer
    obsidian_agent_folder: str = "ArjunOS"  # the only folder the assistant writes to

    def validate(self) -> "BridgeSettings":
        if self.web_search_mode not in WEB_MODES:
            raise ValueError(f"web_search_mode must be one of {WEB_MODES}")
        if not (1 <= int(self.web_search_max_results) <= 10):
            raise ValueError("web_search_max_results must be between 1 and 10")
        if not (2000 <= int(self.attachment_context_chars) <= 100_000):
            raise ValueError("attachment_context_chars must be between 2000 and 100000")
        self.attachment_context_chars = int(self.attachment_context_chars)
        if not (2000 <= int(self.page_context_chars) <= 100_000):
            raise ValueError("page_context_chars must be between 2000 and 100000")
        self.page_context_chars = int(self.page_context_chars)
        self.web_search_max_results = int(self.web_search_max_results)
        self.web_search_consented = bool(self.web_search_consented)
        self.memory_auto_inject = bool(self.memory_auto_inject)
        self.shell_enabled = bool(self.shell_enabled)
        self.files_enabled = bool(self.files_enabled)
        self.read_paths = bool(self.read_paths)
        self.browser_enabled = bool(self.browser_enabled)
        self.obsidian_enabled = bool(self.obsidian_enabled)
        self.obsidian_auto_context = bool(self.obsidian_auto_context)
        self.obsidian_store_memories = bool(self.obsidian_store_memories)
        self.obsidian_allow_write = bool(self.obsidian_allow_write)
        if not (1500 <= int(self.obsidian_context_chars) <= 40_000):
            raise ValueError("obsidian_context_chars must be between 1500 and 40000")
        self.obsidian_context_chars = int(self.obsidian_context_chars)
        p = str(self.obsidian_vault_path or "").strip()
        if len(p) > 1000 or "\x00" in p: raise ValueError("obsidian_vault_path is not a valid path")
        self.obsidian_vault_path = p
        f = str(self.obsidian_agent_folder or "").strip()
        if not f or len(f) > 40 or f.startswith(".") or any(c in f for c in '/\\:*?"<>|\x00') or f in ("..", "."):
            raise ValueError("obsidian_agent_folder must be a simple folder name")
        self.obsidian_agent_folder = f
        return self

    @property
    def web_search_active(self) -> bool:
        return self.web_search_consented and self.web_search_mode != "off"


class SettingsStore:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.value = self._load()

    def _load(self) -> BridgeSettings:
        try:
            raw = json.loads(self.path.read_text())
            known = {f.name for f in fields(BridgeSettings)}
            return BridgeSettings(**{k: v for k, v in raw.items() if k in known}).validate()
        except FileNotFoundError:
            return BridgeSettings()
        except Exception:                       # corrupt/invalid file: fall back to safe defaults, keep the bad file
            try: self.path.rename(self.path.with_suffix(".corrupt"))
            except OSError: pass
            return BridgeSettings()

    def update(self, **changes) -> BridgeSettings:
        known = {f.name for f in fields(BridgeSettings)}
        bad = set(changes) - known
        if bad: raise ValueError(f"unknown settings: {sorted(bad)}")
        new = BridgeSettings(**{**asdict(self.value), **changes}).validate()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".settings-")
        with os.fdopen(fd, "w") as f: json.dump(asdict(new), f, indent=2)
        os.replace(tmp, self.path)
        self.value = new
        return new
