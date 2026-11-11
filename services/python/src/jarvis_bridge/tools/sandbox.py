"""Sandboxed terminal engine: parse -> validate -> run, with the OS enforcing what validation cannot.

Two independent layers, because JavaScript cannot be validated by reading it:

1. VALIDATION (pure Python, testable anywhere). The model's text is parsed into an argv list and is NEVER given to a
   shell. Only a short allow-list of programs runs. `sudo`/`su`/`doas` and every way of deleting files (`rm`, `rmdir`,
   `unlink`, `shred`) are refused by name. Every path argument must resolve inside the workspace folder. Pipes,
   redirects, `&&`, `;`, backticks and `$(...)` are refused rather than silently misread.

2. OS SANDBOX (macOS Seatbelt via /usr/bin/sandbox-exec), applied to `node` only, because Node code can do anything the
   process may do. The profile denies: all network, spawning other programs, every file write outside the workspace,
   file unlink/rename EVERYWHERE (so `fs.unlinkSync` and `rm` via child_process both fail), and reading file contents under
   the user's home folder except the workspace and the Node install. If no OS sandbox is available, `node` is refused
   (fail closed); the plain commands (`ls`, `cat`, ...) still work because validation fully covers them.

Resource limits (CPU seconds, max file size, wall-clock timeout, output cap) apply to every command.
What the sandbox does NOT prevent: JavaScript overwriting or truncating files that live inside the workspace.
"""
from __future__ import annotations
import asyncio, glob, json, os, re, shlex, shutil, signal, socket, sys, time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from ..security.paths import PathEscape, resolve_within
from ..security.redact import redact_text

MAX_COMMAND_CHARS = 8000
MAX_ARGS = 64
DEFAULT_TIMEOUT = 30.0
MAX_STREAM_BYTES = 64 * 1024            # per stream; a flood past this stops the command
MAX_FILE_BYTES = 10 * 1024 * 1024       # RLIMIT_FSIZE: no single file bigger than this

ALLOWED_COMMANDS = ("node", "ls", "cat", "pwd", "echo", "mkdir", "touch", "head", "tail", "wc")

_NEVER = {
    "sudo": "administrator commands (sudo) are never allowed",
    "su": "administrator commands (su) are never allowed",
    "doas": "administrator commands (doas) are never allowed",
    "rm": "deleting files is never allowed",
    "rmdir": "deleting folders is never allowed",
    "unlink": "deleting files is never allowed",
    "shred": "deleting files is never allowed",
    "srm": "deleting files is never allowed",
}

# Node options that are safe to pass. Everything else (-r, --require, --import, --inspect, --env-file, --experimental-*,
# --permission, ...) is refused: they load other code or open debug ports.
_NODE_EVAL = {"-e", "--eval", "-p", "--print", "-pe", "-ep"}      # each takes the JavaScript as the next word
_NODE_FLAGS = {"-c", "--check", "-v", "--version", "--no-warnings",
               "--input-type=module", "--input-type=commonjs"}
_SCRIPT_EXT = (".js", ".mjs", ".cjs")


class CommandRejected(ValueError):
    """The command will not be run. The message is written for the model and the user."""


@dataclass(frozen=True)
class ValidatedCommand:
    argv: tuple            # argv[0] is the bare program name as the user will see it
    exe: str               # absolute path that will actually be executed
    sandboxed: bool        # True when the OS sandbox must wrap it (node)

    @property
    def display(self) -> str:
        return " ".join(shlex.quote(a) for a in self.argv)


@dataclass
class ShellResult:
    argv: tuple
    exit_code: int | None
    stdout: str
    stderr: str
    timed_out: bool = False
    flooded: bool = False
    duration: float = 0.0

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and not self.timed_out and not self.flooded


# ----------------------------------------------------------------------------- parsing
def _unquoted_hazards(text: str) -> None:
    """Newlines, `$` and backticks OUTSIDE quotes would mean something to a real shell, so refuse them clearly."""
    state, i = "none", 0
    while i < len(text):
        c = text[i]
        if state == "none":
            if c == "\\": i += 2; continue
            if c == "'": state = "single"
            elif c == '"': state = "double"
            elif c in "\n\r": raise CommandRejected("run one command on one line (newlines are only allowed inside quotes)")
            elif c in "$`": raise CommandRejected("variables and command substitution ($VAR, $(...), backticks) are not supported; use plain text")
        elif state == "single":
            if c == "'": state = "none"
        else:
            if c == "\\": i += 2; continue
            if c == '"': state = "none"
        i += 1


def parse_command(text: str) -> list:
    text = (text or "").strip()
    text = re.sub(r"^\$\s+", "", text)                                  # models like to write "$ ls"
    if not text: raise CommandRejected("the command is empty")
    if len(text) > MAX_COMMAND_CHARS: raise CommandRejected(f"the command is longer than {MAX_COMMAND_CHARS} characters")
    if "\x00" in text: raise CommandRejected("the command contains a NUL byte")
    _unquoted_hazards(text)
    lex = shlex.shlex(text, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        tokens = list(lex)
    except ValueError as e:
        raise CommandRejected(f"could not read the command ({e})") from None
    for t in tokens:
        if t and all(ch in "();<>|&" for ch in t):
            raise CommandRejected(f"{t!r}: pipes, redirects, `&&`, `;` and subshells are not supported. Run ONE command; "
                                  "use node itself for anything more complex (it can read and write files in the workspace)")
    if not tokens: raise CommandRejected("the command is empty")
    if len(tokens) > MAX_ARGS: raise CommandRejected(f"too many arguments (limit {MAX_ARGS})")
    return tokens


# ----------------------------------------------------------------------------- validation
def _check_path(workspace: Path, arg: str) -> None:
    try:
        resolve_within(workspace, arg)
    except PathEscape:
        raise CommandRejected(f"{arg!r} is outside the sandbox workspace. Only files inside the workspace can be used") from None


def _validate_node(args: list, workspace: Path) -> None:
    if not args: raise CommandRejected("give node some code or a script: node -e \"console.log(1+1)\" or node script.js")
    eval_mode, i = False, 0
    if any(a in ("-v", "--version") for a in args[:1]): return           # `node --version` needs nothing else
    while i < len(args):
        a = args[i]
        if a == "--": return
        if a in _NODE_EVAL or a.startswith(("--eval=", "--print=")):
            eval_mode = True
            if a in _NODE_EVAL:
                if i + 1 >= len(args): raise CommandRejected(f"{a} needs some JavaScript after it")
                i += 2; continue
            i += 1; continue
        if a in _NODE_FLAGS: i += 1; continue
        if a.startswith("-"):
            raise CommandRejected(f"node option {a!r} is not allowed (it could load other code or open a debug port)")
        break                                                            # first non-option: the script (or eval's arguments)
    else:
        if not eval_mode: raise CommandRejected("give node a script file or -e \"code\"")
        return
    if eval_mode: return                                                 # remaining words are plain arguments to the code
    script = args[i]
    if not script.lower().endswith(_SCRIPT_EXT): raise CommandRejected("node can only run .js, .mjs or .cjs files")
    _check_path(workspace, script)


def validate_argv(argv: list, workspace: Path, *, node: str | None, node_sandboxed: bool) -> ValidatedCommand:
    name = argv[0]
    if "/" in name or "\\" in name:
        raise CommandRejected("write the program name only (for example `ls`), not a path")
    if name in _NEVER: raise CommandRejected(_NEVER[name] + ". Do not try another way to do it")
    if name not in ALLOWED_COMMANDS:
        raise CommandRejected(f"{name!r} is not available in the sandbox. Allowed: {', '.join(ALLOWED_COMMANDS)}")
    args = argv[1:]
    if name == "node":
        if node is None: raise CommandRejected("Node.js was not found on this Mac, so JavaScript can't run. Install it (nodejs.org or `brew install node`)")
        if not node_sandboxed:
            raise CommandRejected("JavaScript needs the operating-system sandbox, which isn't available here, so it is not run")
        _validate_node(args, workspace)
        return ValidatedCommand(tuple(argv), node, True)
    if name != "echo":
        for a in args:
            if not a.startswith("-"): _check_path(workspace, a)           # every non-option word is a path (head -n 5: "5" is harmless)
    for d in ("/bin", "/usr/bin"):
        p = os.path.join(d, name)
        if os.access(p, os.X_OK): return ValidatedCommand(tuple(argv), p, False)
    raise CommandRejected(f"{name!r} is not installed on this system")


# ----------------------------------------------------------------------------- finding node
def _real_home() -> str:
    try:
        import pwd
        return pwd.getpwuid(os.getuid()).pw_dir
    except Exception:
        return os.path.expanduser("~")


def _natural(path: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", path))


def find_node() -> str | None:
    home = _real_home()
    cands = [os.environ.get("JARVIS_NODE") or "", "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    cands += sorted(glob.glob(f"{home}/.nvm/versions/node/*/bin/node"), key=_natural, reverse=True)
    cands += [f"{home}/.volta/bin/node", f"{home}/.fnm/aliases/default/bin/node"]
    w = shutil.which("node")
    if w: cands.insert(1, w)
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK): return os.path.realpath(c)
    return None


# ----------------------------------------------------------------------------- OS sandbox backends
def _sb(path: str) -> str:
    if any(ch in path for ch in '"\\\n\r\x00'):
        raise ValueError(f"path contains characters the sandbox profile cannot express: {path!r}")
    return f'"{path}"'


def build_seatbelt_profile(workspace: str, exec_path: str, read_roots: list, home_dirs: list) -> str:
    """macOS Seatbelt profile (SBPL). Later rules override earlier ones, so each deny is followed by its narrow allow."""
    reads = " ".join(f"(subpath {_sb(p)})" for p in [workspace, *read_roots])
    homes = " ".join(f"(subpath {_sb(p)})" for p in home_dirs)
    return "\n".join([
        "(version 1)",
        "(allow default)",
        "(deny network*)",                                                # no sockets at all, loopback included
        "(deny process-fork)",                                            # child_process.spawn/exec cannot start anything
        "(deny process-exec*)",
        f"(allow process-exec* (literal {_sb(exec_path)}))",             # ... and only this one binary may be executed
        "(deny file-write*)",
        f'(allow file-write* (subpath {_sb(workspace)}) (literal "/dev/null"))',
        "(deny file-write-unlink)",                                       # no deleting or renaming ANYWHERE, workspace included
        f"(deny file-read-data {homes})",                                 # contents of the home folder are off limits ...
        f"(allow file-read-data {reads})",                                # ... except the workspace and the Node install
        "",
    ])


class SandboxBackend(Protocol):
    name: str
    def wrap(self, argv: list, *, workspace: Path, read_roots: list) -> list: ...


class SeatbeltBackend:
    name = "seatbelt"
    EXE = "/usr/bin/sandbox-exec"

    @classmethod
    def available(cls) -> bool:
        return sys.platform == "darwin" and os.access(cls.EXE, os.X_OK)

    def wrap(self, argv: list, *, workspace: Path, read_roots: list) -> list:
        homes = sorted({_real_home(), "/Users"})
        prof = build_seatbelt_profile(str(workspace.resolve()), argv[0], read_roots, homes)
        return [self.EXE, "-p", prof, *argv]


_AUTO = object()

# Applies resource limits, then replaces itself with the real command (so limits are inherited and the pid is the command's).
_LAUNCHER = ("import os,sys,resource\n"
             "cpu,fsize=int(sys.argv[1]),int(sys.argv[2])\n"
             "resource.setrlimit(resource.RLIMIT_CPU,(cpu,cpu))\n"
             "resource.setrlimit(resource.RLIMIT_FSIZE,(fsize,fsize))\n"
             "resource.setrlimit(resource.RLIMIT_CORE,(0,0))\n"
             "os.execv(sys.argv[3],sys.argv[3:])\n")

_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def _clean(b: bytes) -> str:
    return redact_text(_ANSI.sub("", b.decode("utf-8", "replace")))


async def _drain(stream, cap: int, over: asyncio.Event) -> bytes:
    buf = bytearray()
    while True:
        chunk = await stream.read(65536)
        if not chunk: return bytes(buf)
        room = cap - len(buf)
        if room > 0: buf += chunk[:room]
        if len(chunk) > room: over.set()


# ----------------------------------------------------------------------------- the sandbox
@dataclass
class Check:
    name: str
    ok: bool
    detail: str = ""


class ShellSandbox:
    def __init__(self, workspace: str | Path, *, backend=_AUTO, node: str | None | object = _AUTO, timeout: float = DEFAULT_TIMEOUT):
        self.workspace = Path(workspace).expanduser()
        self.workspace.mkdir(parents=True, exist_ok=True)
        self.workspace = self.workspace.resolve()
        (self.workspace / ".tmp").mkdir(exist_ok=True)
        self.backend = (SeatbeltBackend() if SeatbeltBackend.available() else None) if backend is _AUTO else backend
        self.node = find_node() if node is _AUTO else node
        self.timeout = timeout

    # ---- introspection (shown in Settings) ----
    def status(self) -> dict:
        return {"workspace": str(self.workspace), "node": self.node, "sandbox": self.backend.name if self.backend else "none",
                "allowed": list(ALLOWED_COMMANDS), "javascript_ready": bool(self.node and self.backend)}

    # ---- parse + validate ----
    def check(self, command: str) -> ValidatedCommand:
        return validate_argv(parse_command(command), self.workspace, node=self.node, node_sandboxed=self.backend is not None)

    # ---- run ----
    def _node_read_roots(self) -> list:
        if not self.node: return []
        roots = {str(Path(self.node).parent.parent)}                      # <prefix>/bin/node -> <prefix>
        home = _real_home()
        for d in (".nvm", ".volta", ".fnm", ".asdf"):
            if self.node.startswith(os.path.join(home, d)): roots.add(os.path.join(home, d))
        return sorted(roots)

    def _env(self) -> dict:
        node_dir = str(Path(self.node).parent) if self.node else ""
        return {"PATH": ":".join(p for p in (node_dir, "/usr/bin", "/bin") if p), "HOME": str(self.workspace),
                "TMPDIR": str(self.workspace / ".tmp"), "LANG": "en_US.UTF-8", "NO_COLOR": "1", "NODE_NO_WARNINGS": "1"}

    async def execute(self, v: ValidatedCommand, *, timeout: float | None = None) -> ShellResult:
        timeout = timeout or self.timeout
        real = [v.exe, *v.argv[1:]]
        if v.sandboxed:
            if self.backend is None: raise CommandRejected("no OS sandbox is available, so JavaScript is not run")
            real = self.backend.wrap(real, workspace=self.workspace, read_roots=self._node_read_roots())
        cmd = [sys.executable, "-I", "-S", "-c", _LAUNCHER, str(int(timeout) + 2), str(MAX_FILE_BYTES), *real]
        t0 = time.monotonic()
        proc = await asyncio.create_subprocess_exec(*cmd, cwd=str(self.workspace), env=self._env(), stdin=asyncio.subprocess.DEVNULL,
                                                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, start_new_session=True)
        over = asyncio.Event()
        out_t = asyncio.create_task(_drain(proc.stdout, MAX_STREAM_BYTES, over))
        err_t = asyncio.create_task(_drain(proc.stderr, MAX_STREAM_BYTES, over))
        wait_t = asyncio.create_task(proc.wait())
        flood_t = asyncio.create_task(over.wait())
        timed_out = flooded = False
        try:
            done, _ = await asyncio.wait({wait_t, flood_t}, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
            if wait_t not in done:
                timed_out, flooded = flood_t not in done, flood_t in done
                self._kill(proc)
            await asyncio.wait_for(wait_t, 5)
        finally:
            if proc.returncode is None: self._kill(proc)
            flood_t.cancel()
        out, err = await asyncio.gather(out_t, err_t)
        return ShellResult(v.argv, None if (timed_out or flooded) else proc.returncode, _clean(out), _clean(err),
                           timed_out=timed_out, flooded=flooded, duration=time.monotonic() - t0)

    @staticmethod
    def _kill(proc) -> None:
        try: os.killpg(proc.pid, signal.SIGKILL)                          # the whole group: nothing is left running
        except (ProcessLookupError, PermissionError): pass

    # ---- self-test: proves the sandbox really blocks things on THIS machine ----
    async def selftest(self, state_dir: str | Path | None = None) -> list:
        checks = [Check("Node.js found", bool(self.node), self.node or "not found"),
                  Check("OS sandbox available", self.backend is not None, self.backend.name if self.backend else "none (macOS sandbox-exec not found)")]
        if not (self.node and self.backend): return checks
        outside = self.workspace.parent / "arjunos-sandbox-outside.txt"
        read_target = None
        if state_dir:
            cand = Path(state_dir) / "audit.db"
            home = Path(_real_home()).resolve()
            try:
                if cand.exists() and cand.resolve().is_relative_to(home): read_target = str(cand.resolve())
            except OSError: pass
        listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(1)
        port = listener.getsockname()[1]
        js = (
            "const fs=require('fs'),net=require('net');const o={};"
            "try{fs.writeFileSync('probe.txt','x');o.write_workspace='ok'}catch(e){o.write_workspace='failed '+e.code}"
            "try{fs.unlinkSync('probe.txt');o.delete='DELETED'}catch(e){o.delete='blocked'}"
            "try{fs.writeFileSync(process.argv[1],'x');o.write_outside='WROTE'}catch(e){o.write_outside='blocked'}"
            "try{require('child_process').execSync('echo hi');o.spawn='SPAWNED'}catch(e){o.spawn='blocked'}"
            "try{if(process.argv[3]){fs.readFileSync(process.argv[3]);o.read_home='READ'}else{o.read_home='skipped'}}catch(e){o.read_home='blocked'}"
            "const done=()=>console.log(JSON.stringify(o));"
            "const s=net.connect(Number(process.argv[2]),'127.0.0.1');"
            "s.on('connect',()=>{o.network='CONNECTED';s.destroy();done()});"
            "s.on('error',()=>{o.network='blocked';done()});"
            "setTimeout(()=>{o.network=o.network||'blocked';done();process.exit(0)},4000);")
        try:
            v = ValidatedCommand(("node", "-e", js, str(outside), str(port), read_target or ""), self.node, True)
            r = await self.execute(v, timeout=15)
        finally:
            listener.close()
            for p in (outside, self.workspace / "probe.txt"):
                try: p.unlink()
                except OSError: pass
        try:
            res = json.loads(r.stdout.strip().splitlines()[-1])
        except Exception:
            return checks + [Check("Probe ran", False, (r.stderr or r.stdout or "no output")[:300])]
        def chk(name, key, want):
            got = res.get(key, "missing"); checks.append(Check(name, got == want, got))
        chk("Can write inside the workspace", "write_workspace", "ok")
        chk("Cannot delete files", "delete", "blocked")
        chk("Cannot write outside the workspace", "write_outside", "blocked")
        chk("Cannot start other programs", "spawn", "blocked")
        chk("Cannot use the network", "network", "blocked")
        if res.get("read_home") != "skipped": chk("Cannot read your home folder", "read_home", "blocked")
        return checks
