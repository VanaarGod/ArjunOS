"""Secret redaction. Applied to logs, traces, audit rows, errors and diagnostic exports."""
from __future__ import annotations
import re
from typing import Any

REDACTED = "[REDACTED]"

# Value-shaped secrets (recognisable regardless of the key they appear under).
_VALUE_PATTERNS = [
    re.compile(r"sk-ant-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"sk-[A-Za-z0-9_\-]{16,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),         # GitHub tokens
    re.compile(r"AIza[0-9A-Za-z_\-]{20,}"),            # Google API keys
    re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}"),      # Slack
    re.compile(r"phc_[A-Za-z0-9]{20,}"),               # PostHog project keys
    re.compile(r"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"),  # JWT
]
_BEARER = re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=\-]{8,}")
_URL_CREDS = re.compile(r"(?i)(https?://)([^/\s:@]+):([^/\s@]+)@")
_KV = re.compile(
    r"(?i)((?:api[_-]?key|secret|token|password|passwd|authorization|credential)[\"']?\s*[:=]\s*[\"']?)([^\s\"',;}]{4,})"
)
# "token" only as a whole word: access_token / auth-token match, but usage counters like prompt_tokens do not
_SECRET_KEY_NAMES = re.compile(r"(?i)(api[_-]?key|secret|(?<![a-z])token(?![a-z])|password|passwd|authorization|credential|private[_-]?key)")


def redact_text(text: str) -> str:
    if not text:
        return text
    out = _URL_CREDS.sub(lambda m: f"{m.group(1)}{REDACTED}@", text)
    out = _BEARER.sub(lambda m: m.group(1) + REDACTED, out)
    for p in _VALUE_PATTERNS:
        out = p.sub(REDACTED, out)
    out = _KV.sub(lambda m: m.group(1) + REDACTED, out)
    return out


def redact(obj: Any) -> Any:
    """Recursively redact strings; dict values under secret-looking keys are always masked."""
    if isinstance(obj, str):
        return redact_text(obj)
    if isinstance(obj, dict):
        return {
            k: (REDACTED if isinstance(k, str) and _SECRET_KEY_NAMES.search(k) and isinstance(v, (str, dict, list, tuple)) and v
                else redact(v))
            for k, v in obj.items()
        }
    if isinstance(obj, (list, tuple)):
        return type(obj)(redact(v) for v in obj)
    return obj
