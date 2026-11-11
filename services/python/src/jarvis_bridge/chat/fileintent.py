"""Understands "create a markdown file", "write me a js script called app.js", "save that to a file" without any model call.

It only fires on a COMMAND at the start of the message (so "how do I create a file in Python?" does nothing), and the message
must name a file-ish thing. The result steers the model (suggested type and name) and also powers a fallback: if the model answers
with a code block instead of the file tag, the block is saved anyway, so "create X" always ends with a file.
"""
from __future__ import annotations
import re
from dataclasses import dataclass
from ..tools.files import ALLOWED_EXT

_EXT_WORDS = [
    (r"markdown|\.md\b|readme|\bmd\b", "md"), (r"typescript|\.ts\b", "ts"), (r"javascript|node ?script|\.js\b|\bjs\b", "js"),
    (r"python|\.py\b", "py"), (r"json", "json"), (r"html|web ?page|website|landing page", "html"), (r"css|stylesheet", "css"),
    (r"csv|spreadsheet", "csv"), (r"ya?ml", "yml"), (r"toml", "toml"), (r"xml", "xml"), (r"svg", "svg"),
    (r"text file|plain text|\.txt\b|\btxt\b", "txt"),
]
_EXTS = "|".join(ALLOWED_EXT)
_LEAD = (r"^\W*(?:(?:hey|hi|ok|okay|yo|so|now|then|and)[,.\s]+)*(?:(?:can|could|would|will) you\s+(?:please\s+)?|please\s+|pls\s+"
         r"|i(?:'d| would)? (?:like|want|need)(?: you)? to\s+|i (?:want|need) )?")
_MAKE = re.compile(_LEAD + r"(?:create|make|write|generate|build|draft|produce|compose|put together|set up)\b", re.I)
_SAVE = re.compile(_LEAD + r"(?:save|put|store|export|write|copy)\b", re.I)
_NOUN = re.compile(rf"\b(?:files?|markdown|readme|scripts?|json|csv|ya?ml|html|web ?page|website|stylesheet|text document|txt|[\w\-]+\.(?:{_EXTS}))\b", re.I)
_NAME = re.compile(rf"""["'`]?\b([A-Za-z0-9][\w\-./]{{0,80}}\.(?:{_EXTS}))\b["'`]?""", re.I)
_PREV = re.compile(r"\b(?:that|this|it|the (?:above|last|previous)(?: (?:answer|reply|response|text))?|your (?:answer|reply|response))\b", re.I)


@dataclass(frozen=True)
class FileIntent:
    ext: str                  # md, js, ...
    name: str | None          # name the user gave, if any
    from_previous: bool       # "save that to a file": use the last assistant reply
    topic: str                # leftover words, for naming a file when nothing else is available


def _ext_from_words(text: str) -> str | None:
    for pat, ext in _EXT_WORDS:
        if re.search(pat, text, re.I): return ext
    return None


def file_intent(message: str, *, has_previous_reply: bool = False) -> FileIntent | None:
    text = (message or "").strip()
    if not text or len(text) > 2000: return None
    head = text[:220]
    make, save = _MAKE.match(head), _SAVE.match(head)
    m = make or save
    if not m or not _NOUN.search(head[m.end():]): return None
    name_m = _NAME.search(head)
    name = name_m.group(1) if name_m else ("README.md" if re.search(r"\breadme\b", head, re.I) else None)
    from_prev = bool(save and not make and has_previous_reply and _PREV.search(head))
    ext = (name.rsplit(".", 1)[-1].lower() if name else None) or _ext_from_words(head) or ("md" if from_prev or re.search(r"\bnotes?\b|\bdoc(?:ument)?\b", head, re.I) else "txt")
    if save and not make and not from_prev and not re.search(r"\b(?:create|make|new)\b", head, re.I):
        if not (name or _ext_from_words(head)): return None
    topic = re.sub(rf"(?i){_LEAD}|\b(?:create|make|write|generate|build|draft|produce|compose|save|put|store|a|an|the|me|new|file|files|called|named|about|for|with|that|which|says?|in|to|of|my|on|markdown|readme|python|javascript|typescript|script|scripts|json|csv|yaml|yml|html|web|page|webpage|website|spreadsheet|text|plain|txt|md|js|py|css|stylesheet|document|and|then|please)\b|\.[a-z]{{1,4}}\b", " ", head)
    topic = re.sub(r"[^A-Za-z0-9 ]", " ", topic)
    return FileIntent(ext=ext if ext in ALLOWED_EXT else "txt", name=name, from_previous=from_prev, topic=" ".join(topic.split()[:5]))


def suggested_name(intent: FileIntent) -> str:
    if intent.name: return intent.name
    slug = "-".join(w.lower() for w in intent.topic.split()[:4]) or {"md": "notes", "js": "script", "py": "script", "html": "index", "css": "styles", "json": "data", "csv": "data"}.get(intent.ext, "file")
    return f"{slug}.{intent.ext}"


_FENCE = re.compile(r"```[ \t]*([\w+-]*)[ \t]*\n(.*?)```", re.S)


def extract_content(reply: str, intent: FileIntent) -> str | None:
    """What to save when the model answered in chat instead of using the file tag."""
    text = (reply or "").strip()
    if not text: return None
    fences = _FENCE.findall(text)
    if "```" in text and not fences: return None                         # an unfinished block: don't save half a file
    for lang, body in fences:                                            # a block labelled as the document itself: that IS the file
        if intent.ext in ("md", "txt") and lang.lower() in ("md", "markdown", "text", "txt"): return body.strip("\n")
    if fences and intent.ext not in ("md", "txt"): return max((b for _, b in fences), key=len).strip("\n")
    if len(fences) == 1 and text.startswith("```") and text.endswith("```"): return fences[0][1].strip("\n")
    return text if intent.ext in ("md", "txt") else None
