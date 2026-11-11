"""Sandboxed terminal. Validation, bounded execution and the approval flow are tested against REAL subprocesses.

NOT tested here (needs a Mac): that the Seatbelt profile itself blocks delete/spawn/network/read. Those tests run on the
user's machine through Settings -> Terminal -> "Test sandbox" (ShellSandbox.selftest). The selftest is itself tested below:
it must FAIL against a backend that does not actually sandbox.
"""
import asyncio, os, shutil, subprocess, sys
import httpx, pytest
from jarvis_bridge.api.server import create_app, Services
from jarvis_bridge.security.audit import AuditLog
from jarvis_bridge.security.policy import PolicyEngine
from jarvis_bridge.tools.sandbox import (CommandRejected, ShellSandbox, SeatbeltBackend, build_seatbelt_profile, find_node, parse_command)
from jarvis_bridge.tools.shell import ShellRunner, TOOL_ID
from jarvis_bridge.settings import SettingsStore
from test_orchestrator import Script, make, kinds, text_of, prompt_text

NODE = find_node()
needs_node = pytest.mark.skipif(NODE is None, reason="node is not installed")


class Passthrough:
    """A backend that does NOT sandbox. Lets us test everything except the OS enforcement itself."""
    name = "passthrough"
    def wrap(self, argv, *, workspace, read_roots): return list(argv)


@pytest.fixture
def sb(tmp_path): return ShellSandbox(tmp_path / "ws", backend=Passthrough())

@pytest.fixture
def sb_nojs(tmp_path): return ShellSandbox(tmp_path / "ws", backend=None, node=None)

async def run(sb, command, **kw): return await sb.execute(sb.check(command), **kw)


# ----------------------------------------------------------------------------- parsing
def test_parse_basic_and_quotes():
    assert parse_command("ls -la") == ["ls", "-la"]
    assert parse_command('node -e "console.log(\'a > b; c | d\')"') == ["node", "-e", "console.log('a > b; c | d')"]
    assert parse_command("$ echo hi") == ["echo", "hi"]
    assert parse_command('node -e "console.log(`${1+1}`)\nconsole.log(2)"')[2].count("\n") == 1      # newline/$ inside quotes are fine

@pytest.mark.parametrize("cmd", ["ls | wc", "echo hi > f.txt", "ls && pwd", "ls; pwd", "echo `id`", "echo $HOME", "echo $(id)",
                                 "ls\npwd", "echo hi 2>&1", "cat < f", "ls &", "(ls)"])
def test_shell_operators_are_refused_not_misread(cmd):
    with pytest.raises(CommandRejected): parse_command(cmd)

@pytest.mark.parametrize("cmd", ["", "   ", 'echo "unterminated', "x" * 9000])
def test_bad_input(cmd):
    with pytest.raises(CommandRejected): parse_command(cmd)


# ----------------------------------------------------------------------------- validation: never allowed
@pytest.mark.parametrize("cmd,word", [("rm -rf x", "deleting"), ("rm x", "deleting"), ("rmdir d", "deleting"), ("unlink f", "deleting"),
                                      ("shred f", "deleting"), ("sudo ls", "sudo"), ("su root", "su"), ("doas ls", "doas"),
                                      ("/bin/rm x", "path"), ("/usr/bin/sudo ls", "path"), ("./rm x", "path")])
def test_rm_and_sudo_are_refused_by_name(sb, cmd, word):
    with pytest.raises(CommandRejected, match=word): sb.check(cmd)

@pytest.mark.parametrize("cmd", ["env rm x", "sh -c ls", "bash -c ls", "xargs rm", "find . -delete", "mv a b", "cp a b", "ln -s a b",
                                 "curl http://x", "python3 -c 1", "npm install", "npx cowsay", "chmod 777 a", "kill 1", "open /", "osascript -e 1"])
def test_everything_else_is_not_on_the_allow_list(sb, cmd):
    with pytest.raises(CommandRejected, match="not available"): sb.check(cmd)

def test_allowed_basics_validate(sb):
    for c in ["ls", "ls -la", "cat a.txt", "pwd", "echo hi there", "mkdir -p sub/dir", "touch a.txt", "head -n 5 a.txt", "tail -n 3 a.txt", "wc -l a.txt"]:
        assert sb.check(c).argv[0] == c.split()[0]


# ----------------------------------------------------------------------------- validation: paths
@pytest.mark.parametrize("cmd", ["cat /etc/passwd", "ls /", "cat ../x", "ls ..", "mkdir -p ../x", "touch -r /etc/hosts f", "cat ~/../../etc/passwd",
                                 "head -n 1 /etc/hosts", "ls /Users"])
def test_paths_must_stay_inside_the_workspace(sb, cmd):
    with pytest.raises(CommandRejected, match="outside the sandbox workspace"): sb.check(cmd)

def test_symlink_pointing_outside_is_followed_and_refused(sb, tmp_path):
    os.symlink("/etc", sb.workspace / "link")
    with pytest.raises(CommandRejected): sb.check("cat link/hosts")

def test_sensitive_folder_names_are_refused_even_inside_workspace(sb):
    with pytest.raises(CommandRejected): sb.check("cat .ssh/id_rsa")


# ----------------------------------------------------------------------------- validation: node
@needs_node
@pytest.mark.parametrize("cmd", ['node -e "1+1"', "node script.js", "node -pe '1+1'", 'node -p "2" arg1', "node --version", "node -c a.js",
                                 'node --no-warnings -e "1"', 'node -e "1" extra --not-a-node-flag'])
def test_node_forms_that_are_allowed(sb, cmd): assert sb.check(cmd).sandboxed

@needs_node
@pytest.mark.parametrize("cmd", ["node", "node -e", "node ../a.js", "node /tmp/a.js", "node a.txt", "node -r evil.js a.js", "node --require x a.js",
                                 "node --import x a.js", "node --inspect a.js", "node --inspect-brk -e 1", "node --env-file=.env a.js",
                                 "node --experimental-permission a.js", 'node -e "1" --require ./x.js', "node -i", "node --eval"])
def test_node_forms_that_are_refused(sb, cmd):
    with pytest.raises(CommandRejected): sb.check(cmd)

def test_node_is_refused_without_an_os_sandbox(tmp_path):
    s = ShellSandbox(tmp_path / "ws", backend=None, node="/usr/bin/node")
    with pytest.raises(CommandRejected, match="operating-system sandbox"): s.check('node -e "1"')
    assert s.check("ls").sandboxed is False                           # plain commands do not need it

def test_node_is_refused_when_not_installed(tmp_path):
    s = ShellSandbox(tmp_path / "ws", backend=Passthrough(), node=None)
    with pytest.raises(CommandRejected, match="not found"): s.check('node -e "1"')

def test_default_backend_is_none_off_macos(tmp_path):
    s = ShellSandbox(tmp_path / "ws")
    assert (s.backend is not None) == SeatbeltBackend.available()
    if sys.platform != "darwin": assert s.status()["javascript_ready"] is False


# ----------------------------------------------------------------------------- Seatbelt profile (text only)
def test_profile_orders_each_deny_before_its_narrow_allow():
    p = build_seatbelt_profile("/Users/me/Library/Application Support/JarvisOS/state/workspace", "/opt/homebrew/Cellar/node/22/bin/node",
                               ["/opt/homebrew/Cellar/node/22"], ["/Users/me", "/Users"])
    L = p.splitlines(); at = {l: i for i, l in enumerate(L)}
    assert "(deny network*)" in L and "(deny process-fork)" in L and "(allow default)" == L[1]
    assert at["(deny process-exec*)"] < next(i for i, l in enumerate(L) if l.startswith("(allow process-exec*"))
    assert at["(deny file-write*)"] < next(i for i, l in enumerate(L) if l.startswith("(allow file-write*"))
    assert next(i for i, l in enumerate(L) if l.startswith("(allow file-write*")) < at["(deny file-write-unlink)"]    # unlink stays denied inside the workspace too
    assert next(i for i, l in enumerate(L) if l.startswith("(deny file-read-data")) < next(i for i, l in enumerate(L) if l.startswith("(allow file-read-data"))
    assert '(literal "/opt/homebrew/Cellar/node/22/bin/node")' in p and 'JarvisOS/state/workspace"' in p

@pytest.mark.parametrize("bad", ['/tmp/a"b', "/tmp/a\\b", "/tmp/a\nb"])
def test_profile_refuses_paths_it_cannot_quote(bad):
    with pytest.raises(ValueError): build_seatbelt_profile(bad, "/bin/node", [], ["/Users"])

def test_seatbelt_wrap_puts_profile_before_the_command():
    argv = SeatbeltBackend().wrap(["/usr/local/bin/node", "-e", "1"], workspace=__import__("pathlib").Path("/tmp"), read_roots=["/usr/local"])
    assert argv[0] == "/usr/bin/sandbox-exec" and argv[1] == "-p" and argv[3:] == ["/usr/local/bin/node", "-e", "1"] and "(deny network*)" in argv[2]


# ----------------------------------------------------------------------------- real execution
async def test_plain_commands_really_run_in_the_workspace(sb):
    r = await run(sb, "echo hello world"); assert r.ok and r.stdout.strip() == "hello world"
    assert (await run(sb, "pwd")).stdout.strip() == str(sb.workspace)
    assert (await run(sb, "mkdir -p sub/dir")).ok and (sb.workspace / "sub" / "dir").is_dir()
    assert (await run(sb, "touch sub/a.txt")).ok and "a.txt" in (await run(sb, "ls sub")).stdout
    (sb.workspace / "n.txt").write_text("1\n2\n3\n"); assert (await run(sb, "wc -l n.txt")).stdout.split()[0] == "3"
    assert (await run(sb, "head -n 1 n.txt")).stdout.strip() == "1"

async def test_failure_is_reported_not_raised(sb):
    r = await run(sb, "cat missing.txt"); assert not r.ok and r.exit_code != 0 and "missing.txt" in r.stderr

@needs_node
async def test_node_runs_and_can_write_inside_the_workspace(sb):
    assert (await run(sb, 'node -e "console.log(6*7)"')).stdout.strip() == "42"
    r = await run(sb, "node -e \"require('fs').writeFileSync('hello.js', 'console.log(\\'hi\\')')\""); assert r.ok
    assert (await run(sb, "node hello.js")).stdout.strip() == "hi"
    assert (await run(sb, "node -p '1+1'")).stdout.strip() == "2"
    assert (await run(sb, 'node -e "process.exit(3)"')).exit_code == 3
    assert "boom" in (await run(sb, "node -e \"console.error('boom')\"")).stderr

@needs_node
async def test_child_environment_has_no_secrets_and_a_private_home(sb, monkeypatch):
    monkeypatch.setenv("MY_API_SECRET_TOKEN", "s3cret-value"); monkeypatch.setenv("NODE_OPTIONS", "--require /tmp/evil.js")
    r = await run(sb, "node -p \"JSON.stringify(Object.keys(process.env).sort())\"")
    keys = r.stdout; assert "MY_API_SECRET_TOKEN" not in keys and "NODE_OPTIONS" not in keys and "s3cret" not in r.stdout
    assert (await run(sb, 'node -p "process.env.HOME"')).stdout.strip() == str(sb.workspace)

@needs_node
async def test_infinite_loop_is_stopped_by_the_timeout(sb):
    r = await run(sb, 'node -e "while(true){}"', timeout=1)
    assert r.timed_out and r.exit_code is None and r.duration < 6

@needs_node
async def test_output_flood_is_stopped_and_bounded(sb):
    r = await run(sb, "node -e \"setInterval(()=>process.stdout.write('x'.repeat(100000)),1)\"", timeout=20)
    assert r.flooded and len(r.stdout) <= 64 * 1024 + 10 and r.duration < 15

@needs_node
async def test_huge_files_are_refused_by_the_file_size_limit(sb):
    r = await run(sb, "node -e \"require('fs').writeFileSync('big.bin', Buffer.alloc(30*1024*1024))\"")
    assert not r.ok and (not (sb.workspace / "big.bin").exists() or (sb.workspace / "big.bin").stat().st_size <= 10 * 1024 * 1024)

@needs_node
@pytest.mark.skipif(shutil.which("pgrep") is None, reason="pgrep missing")
async def test_timeout_kills_the_whole_process_group_including_children(sb):
    js = "require('child_process').spawn('sleep',['31.7'],{stdio:'ignore'});while(true){}"
    r = await run(sb, f"node -e \"{js}\"", timeout=1); assert r.timed_out
    await asyncio.sleep(0.3)
    assert subprocess.run(["pgrep", "-f", "sleep 31.7"], capture_output=True).returncode != 0


# ----------------------------------------------------------------------------- the self-test must catch a fake sandbox
async def test_selftest_reports_missing_sandbox(sb_nojs):
    checks = await sb_nojs.selftest(); assert [c.ok for c in checks] == [False, False]

@needs_node
async def test_selftest_fails_loudly_against_a_backend_that_does_not_sandbox(sb, tmp_path):
    checks = {c.name: c for c in await sb.selftest(tmp_path)}
    assert checks["Can write inside the workspace"].ok                        # the probe itself works ...
    for name in ["Cannot delete files", "Cannot write outside the workspace", "Cannot start other programs", "Cannot use the network"]:
        assert not checks[name].ok, f"selftest wrongly passed {name!r} with no sandbox"      # ... and exposes that nothing is blocked
    assert not (sb.workspace.parent / "arjunos-sandbox-outside.txt").exists() and not (sb.workspace / "probe.txt").exists()   # probes clean up


# ----------------------------------------------------------------------------- approval flow
class Driver:
    def __init__(self, sandbox, **kw):
        self.policy = PolicyEngine(AuditLog()); self.runner = ShellRunner(sandbox, self.policy); self.runner.APPROVAL_WAIT = kw.get("wait", 10)
        self.events = []
    async def go(self, command, decision):
        """decision: True/False resolves the approval when it appears; None leaves it pending."""
        task = asyncio.create_task(self.runner.run(command, self.events.append, 1))
        for _ in range(300):
            if task.done(): break
            pend = self.policy.pending()
            if pend and decision is not None: self.policy.resolve(pend[0].approval_id, decision); break
            await asyncio.sleep(0.01)
        return await task
    def statuses(self): return [e["tool"]["status"] for e in self.events if "tool" in e]

async def test_approved_command_runs_and_result_is_fenced_untrusted(sb):
    d = Driver(sb); out = await d.go("echo hello", True)
    assert d.statuses() == ["waiting_approval", "running", "done"]
    assert any("approval" in e and e["approval"]["args"] == {"command": "echo hello"} for e in d.events)
    assert out.startswith("<<<UNTRUSTED:") and "hello" in out and "exit code: 0" in out
    done = d.events[-1]["tool"]; assert done["exit_code"] == 0 and "hello" in done["output"]

async def test_denied_command_never_runs(sb):
    d = Driver(sb); out = await d.go("touch should_not_exist.txt", False)
    assert "denied" in out and not (sb.workspace / "should_not_exist.txt").exists() and d.statuses() == ["waiting_approval", "error"]

async def test_unanswered_approval_times_out_without_running(sb):
    d = Driver(sb, wait=0.4); out = await d.go("touch late.txt", None)
    assert "did not respond" in out and not (sb.workspace / "late.txt").exists()

@pytest.mark.parametrize("cmd", ["rm -rf .", "sudo ls", "cat /etc/passwd", "ls | wc", "bash -c ls"])
async def test_refused_commands_never_ask_for_approval(sb, cmd):
    d = Driver(sb); out = await d.go(cmd, True)
    assert out.startswith("Blocked:") and d.policy.pending() == [] and not any("approval" in e for e in d.events) and d.statuses() == ["error"]

async def test_every_command_needs_its_own_approval(sb):
    d = Driver(sb); await d.go("touch a.txt", True); await d.go("touch a.txt", True)
    ids = [e["approval"]["id"] for e in d.events if "approval" in e]; assert len(ids) == 2 and ids[0] != ids[1]

def test_standing_grants_are_impossible_for_the_terminal(sb):
    p = Driver(sb).policy
    with pytest.raises(ValueError): p.grant_standing(TOOL_ID)

async def test_audit_records_program_and_exit_code_but_not_output(sb):
    d = Driver(sb); (sb.workspace / "secret.txt").write_text("TOP-SECRET-CONTENT"); await d.go("cat secret.txt", True)
    rows = d.policy.audit.query(tool_id=TOOL_ID); blob = str(rows)
    assert any(r["outcome"] == "ok" for r in rows) and "cat" in blob and "TOP-SECRET-CONTENT" not in blob

async def test_a_crashing_sandbox_becomes_an_error_not_an_exception(tmp_path):
    class Boom(Passthrough):
        def wrap(self, *a, **k): raise RuntimeError("profile exploded")
    s = ShellSandbox(tmp_path / "ws", backend=Boom())
    if NODE is None: pytest.skip("node missing")
    d = Driver(s); out = await d.go('node -e "1"', True)
    assert "could not be run" in out and d.statuses()[-1] == "error"


# ----------------------------------------------------------------------------- inside a chat
def chat_services(tmp_path, sandbox, **settings):
    svc, _ = make(tmp_path, **settings); drv = Driver(sandbox); svc.shell = drv.runner; return svc, drv

async def collect_approving(stream, svc, drv, text, approve=True):
    events = []
    async for ev in __import__("jarvis_bridge.chat.orchestrator", fromlist=["run_chat"]).run_chat(stream, "m", [__import__("jarvis_bridge.inference.base", fromlist=["ChatMessage"]).ChatMessage("user", text)], svc):
        events.append(ev)
        if "approval" in ev: drv.policy.resolve(ev["approval"]["id"], approve)
    return events

async def test_model_runs_a_command_through_the_tag_protocol(tmp_path, sb):
    svc, drv = chat_services(tmp_path, sb)
    model = Script(["<shell>echo from-the-model</shell>"], ["It printed it."])
    ev = await collect_approving(model, svc, drv, "run echo")
    assert "<shell>command</shell>" in prompt_text(model.calls[0]) and "no pipes" in prompt_text(model.calls[0]).lower()
    assert "from-the-model" in prompt_text(model.calls[1]) and "[Tool result]" in prompt_text(model.calls[1])
    assert text_of(ev) == "It printed it." and "<shell>" not in text_of(ev)
    assert [e["tool"]["status"] for e in ev if "tool" in e and e["tool"]["name"] == "shell"] == ["waiting_approval", "running", "done"]

async def test_denied_in_chat_tells_the_model_not_to_retry(tmp_path, sb):
    svc, drv = chat_services(tmp_path, sb); model = Script(["<shell>touch nope.txt</shell>"], ["Okay, I won't."])
    ev = await collect_approving(model, svc, drv, "make a file", approve=False)
    assert "denied" in prompt_text(model.calls[1]) and not (sb.workspace / "nope.txt").exists() and text_of(ev) == "Okay, I won't."

async def test_model_asking_for_rm_is_blocked_without_a_prompt(tmp_path, sb):
    svc, drv = chat_services(tmp_path, sb); model = Script(["<shell>rm -rf notes</shell>"], ["I can't delete files."])
    ev = await collect_approving(model, svc, drv, "clean up")
    assert "Blocked" in prompt_text(model.calls[1]) and not any("approval" in e for e in ev)

async def test_terminal_switch_in_settings_removes_the_tool(tmp_path, sb):
    svc, drv = chat_services(tmp_path, sb, shell_enabled=False); model = Script(["<shell>echo hi</shell>"])
    ev = await collect_approving(model, svc, drv, "run echo hi")
    assert "<shell>" not in prompt_text(model.calls[0]) and drv.policy.pending() == [] and not any("approval" in e for e in ev)

async def test_instructions_do_not_offer_javascript_when_it_is_unavailable(tmp_path, sb_nojs):
    svc, drv = chat_services(tmp_path, sb_nojs); model = Script(["Sure."])
    await collect_approving(model, svc, drv, "hello"); p = prompt_text(model.calls[0])
    assert "<shell>" in p and "JavaScript (node) is not available" in p and "node -e" not in p


# ----------------------------------------------------------------------------- HTTP API
async def test_status_selftest_and_settings_switch(tmp_path):
    svc = Services(tmp_path / "state", sandbox=ShellSandbox(tmp_path / "ws", backend=None, node=None))
    app = create_app(tmp_path / "state", "t" * 40, services=svc)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1:1",
                                 headers={"Host": "127.0.0.1:1", "Authorization": "Bearer " + "t" * 40}) as c:
        st = (await c.get("/v1/shell/status")).json()
        assert st["enabled"] is True and st["sandbox"] == "none" and st["javascript_ready"] is False and "rm" not in st["allowed"] and "sudo" not in st["allowed"]
        t = (await c.post("/v1/shell/selftest")).json(); assert t["ok"] is False and t["checks"][0]["name"] == "Node.js found"
        await c.put("/v1/settings", json={"shell_enabled": False})
        assert (await c.get("/v1/shell/status")).json()["enabled"] is False
    await svc.close()
