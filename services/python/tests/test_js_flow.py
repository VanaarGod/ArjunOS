"""A realistic 'write a JavaScript file, then run it' conversation, through the real orchestrator, policy and subprocess runner."""
import pytest
from jarvis_bridge.chat.orchestrator import run_chat
from jarvis_bridge.inference.base import ChatMessage
from jarvis_bridge.tools.sandbox import ShellSandbox, find_node
from test_shell import Driver, Passthrough, chat_services
from test_orchestrator import Script, prompt_text, text_of

pytestmark = pytest.mark.skipif(find_node() is None, reason="node is not installed")

SCRIPT = ("const fs = require('fs');\n"
          "fs.writeFileSync('fizz.js', [\n"
          "  'for (let i = 1; i <= 15; i++) {',\n"
          "  '  console.log(i % 15 === 0 ? \"FizzBuzz\" : i % 5 === 0 ? \"Buzz\" : i % 3 === 0 ? \"Fizz\" : i);',\n"
          "  '}'\n"
          "].join('\\n'));")

async def drive(stream, svc, drv, text):
    events = []
    async for ev in run_chat(stream, "m", [ChatMessage("user", text)], svc):
        events.append(ev)
        if "approval" in ev: drv.policy.resolve(ev["approval"]["id"], True)
    return events

async def test_write_then_run_a_js_file_in_one_conversation(tmp_path):
    sb = ShellSandbox(tmp_path / "ws", backend=Passthrough())
    svc, drv = chat_services(tmp_path, sb)
    model = Script([f'<shell>node -e "{SCRIPT.replace(chr(34), chr(92) + chr(34))}"</shell>'],
                   ["<shell>node fizz.js</shell>"],
                   ["I wrote fizz.js and ran it: it prints FizzBuzz up to 15."])
    ev = await drive(model, svc, drv, "write a fizzbuzz js file and run it")
    assert (sb.workspace / "fizz.js").read_text().startswith("for (let i = 1")
    assert "FizzBuzz" in prompt_text(model.calls[2]) and "exit code: 0" in prompt_text(model.calls[2])     # the model SAW the real output
    shell_done = [e["tool"] for e in ev if "tool" in e and e["tool"]["name"] == "shell" and e["tool"]["status"] == "done"]
    assert len(shell_done) == 2 and "Buzz" in shell_done[1]["output"]
    assert text_of(ev).startswith("I wrote fizz.js") and "<shell>" not in text_of(ev)
    assert ev[-1].get("done") is True

async def test_a_syntax_error_in_the_script_is_reported_not_fatal(tmp_path):
    sb = ShellSandbox(tmp_path / "ws", backend=Passthrough())
    svc, drv = chat_services(tmp_path, sb)
    (sb.workspace / "bad.js").write_text("console.log(")
    model = Script(["<shell>node bad.js</shell>"], ["That script has a syntax error."])
    ev = await drive(model, svc, drv, "run bad.js")
    err = [e["tool"] for e in ev if "tool" in e and e["tool"]["name"] == "shell"][-1]
    assert err["status"] == "error" and err["exit_code"] != 0 and "SyntaxError" in err["output"]
    assert ev[-1].get("done") is True and "syntax error" in text_of(ev)

async def test_fourth_tool_request_is_shown_as_text_not_run(tmp_path):
    sb = ShellSandbox(tmp_path / "ws", backend=Passthrough())
    svc, drv = chat_services(tmp_path, sb)
    model = Script(["<shell>pwd</shell>"], ["<shell>ls</shell>"], ["<shell>pwd</shell>"], ["<shell>ls</shell>"])
    ev = await drive(model, svc, drv, "keep going")
    assert len(drv.policy.audit.query(tool_id="shell:run", decision="allow")) <= 6 and ev[-1].get("done") is True
