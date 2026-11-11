"""The user's profile: who they are, how they like answers, and their own standing instructions (the "system prompt").

Everything here is context given to the model on every chat turn, so it is built to cost as few tokens as possible:

  * Terse key/value lines, never prose. Only fields the user filled in produce any text; an empty profile adds nothing at all.
  * Hard length limits per field and for the whole block (`MAX_BLOCK_CHARS`, roughly 400 tokens), enforced on save.
  * Deterministic: the same profile always compiles to the same text, with no dates or counters. The block goes FIRST in the
    system message, so engines that reuse the already-processed start of the prompt (Ollama, llama.cpp) compute it once per
    chat instead of on every turn.
  * Sent once per request, in the system message only. It is never copied into the saved conversation, never given to the
    small helper calls (memory rewriting) and never given to Crew workers.
"""
from __future__ import annotations
import json, os, tempfile, time
from dataclasses import dataclass, asdict, fields
from pathlib import Path

# choice fields: value -> the few words that go into the prompt ("" = say nothing, i.e. the model's default)
DIRECTNESS = {"": "", "direct": "direct, no hedging", "balanced": "", "gentle": "gentle, diplomatic"}
FORMALITY = {"": "", "casual": "casual", "neutral": "", "formal": "formal"}
LENGTH = {"": "", "brief": "brief", "balanced": "", "detailed": "detailed"}
HUMOR = {"": "", "none": "no jokes", "light": "light humor", "playful": "playful"}
EMOJI = {"": "", "never": "no emoji", "sometimes": "", "often": "emoji welcome"}
FEEDBACK = {"": "", "blunt": "blunt feedback", "balanced": "", "gentle": "gentle feedback"}

PROFILE_NAME_KEY = "profile.name"      # subject_key of the memory that records what to call the user

LIMITS = {"name": 60, "call_me": 40, "pronouns": 30, "language": 60, "time_zone": 60, "role": 80,
          "about": 500, "instructions": 1200}
MAX_BLOCK_CHARS = 1600          # about 400 tokens; the whole compiled block is never longer than this
CHOICES = {"directness": DIRECTNESS, "formality": FORMALITY, "length": LENGTH, "humor": HUMOR, "emoji": EMOJI, "feedback": FEEDBACK}


class ProfileError(ValueError):
    pass


@dataclass
class Profile:
    call_me: str = ""             # what to call the user (the one thing asked at first launch)
    name: str = ""                # full name, if different
    pronouns: str = ""
    language: str = ""
    time_zone: str = ""
    role: str = ""                # what they do, in a few words
    about: str = ""               # anything else worth knowing about them
    directness: str = ""
    formality: str = ""
    length: str = ""
    humor: str = ""
    emoji: str = ""
    feedback: str = ""
    instructions: str = ""        # the user's own standing instructions (their system prompt)
    include: bool = True          # master switch: false sends nothing at all
    onboarded: bool = False       # the first-launch question has been answered or skipped
    updated: float = 0.0

    def validate(self) -> "Profile":
        for key, limit in LIMITS.items():
            v = str(getattr(self, key) or "")
            v = "\n".join(line.rstrip() for line in v.replace("\r\n", "\n").replace("\x00", "").strip().split("\n"))
            if key != "instructions" and key != "about": v = " ".join(v.split())
            if len(v) > limit: raise ProfileError(f"{key} can be at most {limit} characters")
            setattr(self, key, v)
        for key, table in CHOICES.items():
            v = str(getattr(self, key) or "")
            if v not in table: raise ProfileError(f"{key} must be one of {[k for k in table if k]}")
        self.include, self.onboarded = bool(self.include), bool(self.onboarded)
        if len(compile_block(self, _force=True)) > MAX_BLOCK_CHARS:
            raise ProfileError(f"Your profile is too long ({len(compile_block(self, _force=True))} characters; the limit is {MAX_BLOCK_CHARS}). "
                               "Shorten the instructions or the About box. Every character here is sent with every message.")
        return self


def _style(p: Profile) -> str:
    parts = [DIRECTNESS[p.directness], FORMALITY[p.formality], LENGTH[p.length], HUMOR[p.humor], EMOJI[p.emoji], FEEDBACK[p.feedback]]
    return ", ".join(x for x in parts if x)


def compile_block(p: Profile, *, _force: bool = False) -> str:
    """The text added to the system message. Empty string when there is nothing to say (or the profile is switched off)."""
    if not p.include and not _force: return ""
    lines: list[str] = []
    who = p.call_me or p.name
    if who:
        s = f"User: {who}"
        if p.name and p.call_me and p.name != p.call_me: s += f" (full name {p.name})"
        s += ". Address them as " + (p.call_me or p.name) + "."
        if p.pronouns: s += f" Pronouns: {p.pronouns}."
        lines.append(s)
    elif p.pronouns:
        lines.append(f"User pronouns: {p.pronouns}.")
    facts = [f"{k}: {v}" for k, v in (("Role", p.role), ("Language", p.language), ("Time zone", p.time_zone)) if v]
    if facts: lines.append(". ".join(facts) + ".")
    style = _style(p)
    if style: lines.append(f"Reply style: {style}.")
    if p.about: lines.append(f"About them: {p.about}")
    if p.instructions: lines.append("Their standing instructions (follow them): " + p.instructions)
    return "\n".join(lines)


def estimate_tokens(text: str) -> int:
    """A deliberately simple estimate (about 4 characters per token for English); the exact count depends on the model."""
    return (len(text) + 3) // 4


class ProfileStore:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.value = self._load()

    def _load(self) -> Profile:
        try:
            raw = json.loads(self.path.read_text())
            known = {f.name for f in fields(Profile)}
            return Profile(**{k: v for k, v in raw.items() if k in known}).validate()
        except FileNotFoundError:
            return Profile()
        except Exception:                                      # corrupt file: start empty, keep the bad file
            try: self.path.rename(self.path.with_suffix(".corrupt"))
            except OSError: pass
            return Profile()

    def update(self, **changes) -> Profile:
        known = {f.name for f in fields(Profile)} - {"updated"}
        bad = set(changes) - known
        if bad: raise ProfileError(f"unknown profile fields: {sorted(bad)}")
        new = Profile(**{**asdict(self.value), **changes}).validate()
        new.updated = time.time()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".profile-")
        with os.fdopen(fd, "w") as f: json.dump(asdict(new), f, indent=2)
        os.replace(tmp, self.path)
        self.value = new
        return new

    def block(self) -> str:
        return compile_block(self.value)

    def describe(self) -> dict:
        block = self.block()
        return {**asdict(self.value), "compiled": block, "chars": len(block), "tokens": estimate_tokens(block),
                "max_chars": MAX_BLOCK_CHARS, "limits": LIMITS}
