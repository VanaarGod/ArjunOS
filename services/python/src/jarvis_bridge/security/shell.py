"""Structured command execution. Model-generated text is NEVER handed to a shell."""
from __future__ import annotations
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from .paths import resolve_within

_SHELL_META = set(";|&$`<>\n\r(){}*?!\\\"'")
_SAFE_ENV_KEYS = {"PATH", "HOME", "LANG", "LC_ALL", "TERM", "TMPDIR", "USER"}


class CommandRejected(ValueError):
    pass


@dataclass(frozen=True)
class CommandPolicy:
    allowed_executables: frozenset            # basenames, e.g. {"git", "ls"}
    max_seconds: float = 30.0
    max_output_bytes: int = 200_000
    denied_args: frozenset = frozenset({"--upload-pack", "--exec", "-exec", "--eval"})


def validate_argv(argv, policy: CommandPolicy) -> list:
    if isinstance(argv, str):
        raise CommandRejected("commands must be an argv list, never a shell string")
    argv = list(argv)
    if not argv or not all(isinstance(a, str) for a in argv):
        raise CommandRejected("argv must be a non-empty list of strings")
    exe = os.path.basename(argv[0])
    if argv[0] != exe and not Path(argv[0]).is_absolute():
        raise CommandRejected("relative executable paths are not allowed")
    if exe not in policy.allowed_executables:
        raise CommandRejected(f"executable {exe!r} is not on the allowlist")
    for a in argv:
        if "\x00" in a:
            raise CommandRejected("NUL byte in argument")
        if a in policy.denied_args:
            raise CommandRejected(f"argument {a!r} is denied")
    if exe in {"sh", "bash", "zsh", "dash", "fish", "env", "sudo", "su", "doas", "xargs", "eval"}:
        raise CommandRejected(f"{exe!r} can run arbitrary commands")
    return argv


def filtered_env(extra: dict | None = None) -> dict:
    env = {k: v for k, v in os.environ.items() if k in _SAFE_ENV_KEYS}
    env.update(extra or {})
    return env


def run_command(argv, *, workspace, policy: CommandPolicy, cwd: str = ".") -> subprocess.CompletedProcess:
    argv = validate_argv(argv, policy)
    work = resolve_within(workspace, cwd)
    proc = subprocess.run(argv, cwd=work, env=filtered_env(), shell=False, capture_output=True,
                          timeout=policy.max_seconds, check=False)
    out = proc.stdout[: policy.max_output_bytes]
    err = proc.stderr[: policy.max_output_bytes]
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)
