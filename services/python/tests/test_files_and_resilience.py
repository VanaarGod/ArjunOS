"""'Create a ___ file' and the never-hang guarantees: stalled models, thinking models, silent models, flaky streams."""
import asyncio, os
import pytest
from jarvis_bridge.chat import orchestrator as orch
from jarvis_bridge.chat.fileintent import extract_content, file_intent, suggested_name
from jarvis_bridge.chat.orchestrator import run_chat
from jarvis_bridge.inference.base import ChatChunk, ChatMessage, ErrorKind, ProviderError
from jarvis_bridge.security.audit import AuditLog
from jarvis_bridge.security.policy import PolicyEngine
from jarvis_bridge.tools.files import FileCreator, FileError, MAX_CHARS, clean_name
from test_orchestrator import Script, make, text_of, prompt_text, collect


# ----------------------------------------------------------------------------- FileCreator
@pytest.fixture
def fc(tmp_path): return FileCreator(tmp_path / "ws", PolicyEngine(AuditLog()))

def test_creates_a_file_inside_the_workspace(fc, tmp_path):
    f = fc.create("notes.md", "# Hello\nworld")
    assert f.rel == "notes.md" and (tmp_path / "ws" / "notes.md").read_text() == "# Hello\nworld\n" and not f.renamed and f.preview.startswith("# Hello")

def test_never_overwrites_an_existing_file(fc, tmp_path):
    fc.create("a.md", "first"); second = fc.create("a.md", "second"); third = fc.create("a.md", "third")
    assert (second.rel, third.rel) == ("a-2.md", "a-3.md") and second.renamed
    assert (tmp_path / "ws" / "a.md").read_text() == "first\n"

@pytest.mark.parametrize("bad", ["../x.md", "a/../../x.md", "/etc/x.md", "~/x.md", "C:/x.md", "run.exe", "go.sh", "x.app", "", "   ", "a" * 200 + ".md"])
def test_unsafe_names_and_types_are_refused(fc, bad):
    with pytest.raises(FileError): fc.create(bad, "x")

@pytest.mark.parametrize("content", ["", "   \n", "a\x00b", "x" * (MAX_CHARS + 1)])
def test_bad_content_is_refused(fc, content):
    with pytest.raises(FileError): fc.create("a.md", content)

def test_names_are_cleaned_and_typed(fc):
    assert clean_name("My Notes!", "md") == "My-Notes-.md" or clean_name("My Notes", "md") == "My-Notes.md"
    assert clean_name("todo", "js") == "todo.js" and clean_name("todo") == "todo.txt" and clean_name('"Plan.MD"') == "Plan.md"
    assert fc.create("docs/guide/intro.md", "hi").rel == "docs/guide/intro.md"

def test_a_symlink_pointing_outside_cannot_be_used(fc, tmp_path):
    (tmp_path / "ws").mkdir(exist_ok=True); os.symlink(tmp_path, tmp_path / "ws" / "out")
    with pytest.raises(FileError): fc.create("out/escaped.md", "x")
    assert not (tmp_path / "escaped.md").exists()

def test_creation_is_audited_without_content(fc):
    fc.create("a.md", "TOP-SECRET-BODY"); rows = fc.policy.audit.query(tool_id="file:create")
    assert rows and "TOP-SECRET-BODY" not in str(rows) and "a.md" in str(rows)


# ----------------------------------------------------------------------------- intent
@pytest.mark.parametrize("msg,ext", [("create a markdown file", "md"), ("Create a markdown file about the solar system", "md"),
    ("can you make me a js file called app.js that prints hello", "js"), ("please write a python script for fizzbuzz", "py"),
    ("write a readme for my project", "md"), ("make a json file with 3 users", "json"), ("generate an html page for my portfolio", "html"),
    ("create a file", "txt"), ("hey, could you create a csv of planets", "csv"), ("write a text file with a grocery list", "txt")])
def test_commands_to_create_files_are_understood(msg, ext):
    i = file_intent(msg); assert i is not None and i.ext == ext and not i.from_previous

@pytest.mark.parametrize("msg", ["how do I create a file in python", "what is a markdown file", "write me a poem", "write an email to my boss", "hello",
                                 "explain how to write a script", "why does my json file fail to parse", "can you open the file", ""])
def test_questions_and_ordinary_writing_do_not_trigger(msg): assert file_intent(msg) is None

def test_user_given_names_win_and_fallback_names_are_sensible():
    assert suggested_name(file_intent("make a js file called app.js")) == "app.js"
    assert suggested_name(file_intent("create a markdown file")) == "notes.md"
    assert suggested_name(file_intent("write a readme for my project")) == "README.md"
    assert suggested_name(file_intent("please write a python script for fizzbuzz")) == "fizzbuzz.py"

def test_save_that_means_the_previous_reply_only_when_there_is_one():
    assert file_intent("save that to a file", has_previous_reply=True).from_previous
    assert file_intent("save that to a file", has_previous_reply=False) is None or not file_intent("save that to a file", has_previous_reply=False).from_previous

def test_extract_content_from_chat_style_answers():
    md, js = file_intent("create a markdown file"), file_intent("create a js file")
    assert extract_content("Sure!\n```js\nconsole.log(1)\n```\nEnjoy", js) == "console.log(1)"
    assert extract_content("# Title\n\nBody text", md) == "# Title\n\nBody text"                      # plain markdown answer is the file
    assert extract_content("Here:\n```js\nunfinished", js) is None                                      # never save half a block
    assert extract_content("just chatting", js) is None


# ----------------------------------------------------------------------------- in a conversation
def services(tmp_path, **settings):
    svc, _ = make(tmp_path, **settings); svc.files = FileCreator(tmp_path / "ws", PolicyEngine(AuditLog())); return svc

async def test_file_tag_creates_the_file_with_no_prompt_and_no_second_model_round(tmp_path):
    svc = services(tmp_path); model = Script(['<file name="notes.md">', "# Solar system\n", "Eight planets.\n", "</file>"])
    ev = await collect(model, svc, "create a markdown file about the solar system")
    assert (tmp_path / "ws" / "notes.md").read_text() == "# Solar system\nEight planets.\n"
    assert len(model.calls) == 1 and "Created **notes.md**" in text_of(ev) and ev[-1].get("done") is True
    tools = [e["tool"] for e in ev if "tool" in e]
    assert [t["status"] for t in tools][-2:] == ["running", "done"] and tools[-1]["name"] == "file" and tools[-1]["args"]["path"].endswith("notes.md")
    assert "Eight planets" in tools[-1]["output"] and not any("approval" in e for e in ev)

async def test_the_file_instruction_reaches_the_model(tmp_path):
    svc = services(tmp_path); model = Script(["ok"]); await collect(model, svc, "create a markdown file called todo.md")
    p = prompt_text(model.calls[0]); assert "<file name=" in p and 'name="todo.md"' in p

async def test_content_fenced_inside_the_tag_is_unwrapped_and_missing_extension_added(tmp_path):
    svc = services(tmp_path); model = Script(['<file name="app">```js\nconsole.log(1)\n```</file>'])
    await collect(model, svc, "write a js file"); assert (tmp_path / "ws" / "app.js").read_text() == "console.log(1)\n"

async def test_model_that_answers_in_chat_still_gets_a_file(tmp_path):
    svc = services(tmp_path); model = Script(["Sure, here you go:\n```md\n# Plan\n- one\n```\nHope that helps!"])
    ev = await collect(model, svc, "create a markdown file for my plan")
    assert (tmp_path / "ws" / "plan.md").read_text() == "# Plan\n- one\n" and "Created **plan.md**" in text_of(ev) and "Hope that helps" in text_of(ev)

async def test_plain_markdown_answer_is_saved_whole(tmp_path):
    svc = services(tmp_path); model = Script(["# Cats\n\nThey purr."]); ev = await collect(model, svc, "create a markdown file about cats")
    assert (tmp_path / "ws" / "cats.md").read_text() == "# Cats\n\nThey purr.\n"

async def test_questions_never_create_files(tmp_path):
    svc = services(tmp_path); model = Script(["Use open():\n```python\nopen('a.txt','w')\n```"]); ev = await collect(model, svc, "how do I create a file in python")
    assert not (tmp_path / "ws").exists() or not any((tmp_path / "ws").iterdir()) and "Created" not in text_of(ev)

async def test_existing_names_are_not_overwritten_in_chat(tmp_path):
    svc = services(tmp_path); (tmp_path / "ws").mkdir(); (tmp_path / "ws" / "notes.md").write_text("MINE")
    ev = await collect(Script(['<file name="notes.md">new</file>']), svc, "create a markdown file")
    assert (tmp_path / "ws" / "notes.md").read_text() == "MINE" and (tmp_path / "ws" / "notes-2.md").exists() and "already taken" in text_of(ev)

async def test_a_reply_cut_off_mid_file_is_kept_and_flagged(tmp_path):
    svc = services(tmp_path); ev = await collect(Script(['<file name="long.md">line one\nline two']), svc, "create a markdown file")
    assert (tmp_path / "ws" / "long.md").read_text().startswith("line one") and "cut off" in text_of(ev)

async def test_refused_file_is_explained_not_crashed(tmp_path):
    svc = services(tmp_path); ev = await collect(Script(['<file name="evil.exe">MZ</file>']), svc, "create a file")
    assert "couldn't create" in text_of(ev) and ev[-1].get("done") is True and any(e.get("tool", {}).get("status") == "error" for e in ev)

async def test_file_creation_can_be_turned_off(tmp_path):
    svc = services(tmp_path, files_enabled=False); model = Script(["# Cats"]); ev = await collect(model, svc, "create a markdown file about cats")
    assert "<file name=" not in prompt_text(model.calls[0]) and not (tmp_path / "ws").exists() or not list((tmp_path / "ws").iterdir())

async def test_save_that_to_a_file_uses_the_previous_answer_without_calling_the_model(tmp_path):
    svc = services(tmp_path); model = Script(["should not be called"])
    hist = [ChatMessage("user", "explain cats"), ChatMessage("assistant", "# Cats\n\nThey purr.")]
    ev = await collect(model, svc, "save that to a file", history=hist)
    assert model.calls == [] and "Created **notes.md**" in text_of(ev) and "They purr." in (tmp_path / "ws" / "notes.md").read_text()


# ----------------------------------------------------------------------------- never hang, never end in silence
def stream_of(*steps):
    """steps: strings -> deltas; 'THINK' -> thinking chunk; an Exception -> raise; ('sleep', s) -> pause."""
    def stream(model, msgs):
        async def gen():
            for s in steps:
                if isinstance(s, Exception): raise s
                if isinstance(s, tuple): await asyncio.sleep(s[1]); continue
                yield ChatChunk(thinking=True) if s == "THINK" else ChatChunk(delta=s)
            yield ChatChunk(done=True)
        return gen()
    return stream

async def run(stream, svc, text="hello", history=()): return [e async for e in run_chat(stream, "m", [*history, ChatMessage("user", text)], svc)]

async def test_a_thinking_model_shows_it_is_alive(tmp_path):
    svc, _ = make(tmp_path); ev = await run(stream_of("THINK", "THINK", ("sleep", 0.01), "THINK", "The answer."), svc)
    assert any(e.get("thinking") for e in ev) and text_of(ev) == "The answer." and ev[-1].get("done")

async def test_a_model_that_goes_silent_is_stopped_with_a_clear_error(tmp_path, monkeypatch):
    monkeypatch.setattr(orch, "HEARTBEAT", 0.05); monkeypatch.setattr(orch, "IDLE_FIRST", 0.3); monkeypatch.setattr(orch, "IDLE_NEXT", 0.3)
    svc, _ = make(tmp_path); t0 = asyncio.get_event_loop().time()
    ev = await run(stream_of(("sleep", 30)), svc)
    err = [e["error"] for e in ev if "error" in e]
    assert err and err[0]["kind"] == "timeout" and "went silent" in err[0]["message"] and asyncio.get_event_loop().time() - t0 < 3
    assert any(e.get("ping") for e in ev)                                       # the app is told it is still alive while waiting

async def test_silence_after_the_first_words_is_also_caught(tmp_path, monkeypatch):
    monkeypatch.setattr(orch, "HEARTBEAT", 0.05); monkeypatch.setattr(orch, "IDLE_FIRST", 5); monkeypatch.setattr(orch, "IDLE_NEXT", 0.3)
    svc, _ = make(tmp_path); ev = await run(stream_of("Hello", ("sleep", 30)), svc)
    assert text_of(ev) == "Hello" and any(e.get("error", {}).get("kind") == "timeout" for e in ev)

async def test_empty_reply_after_a_command_never_leaves_silence(tmp_path):
    from test_shell import Driver, Passthrough
    from jarvis_bridge.tools.sandbox import ShellSandbox
    svc, _ = make(tmp_path); drv = Driver(ShellSandbox(tmp_path / "w", backend=Passthrough())); svc.shell = drv.runner
    model = Script(["<shell>echo hi</shell>"], [""])
    ev = []
    async for e in run_chat(model, "m", [ChatMessage("user", "run echo hi")], svc):
        ev.append(e)
        if "approval" in e: drv.policy.resolve(e["approval"]["id"], True)
    assert "I ran the command above" in text_of(ev) and ev[-1].get("done")

async def test_a_totally_empty_reply_says_so(tmp_path):
    svc, _ = make(tmp_path); ev = await run(Script([""]), svc)
    assert "didn't send a reply" in text_of(ev) and ev[-1].get("done")

async def test_one_quiet_retry_for_a_network_hiccup(tmp_path):
    svc, _ = make(tmp_path); ev = await run(Script(ProviderError(ErrorKind.PROTOCOL, "malformed stream line"), ["Recovered."]), svc)
    assert text_of(ev) == "Recovered." and not any("error" in e for e in ev)

async def test_a_second_failure_is_reported_not_retried_forever(tmp_path):
    svc, _ = make(tmp_path); model = Script(ProviderError(ErrorKind.UNREACHABLE, "down"), ProviderError(ErrorKind.UNREACHABLE, "down"))
    ev = await run(model, svc); assert len(model.calls) == 2 and any(e.get("error", {}).get("kind") == "unreachable" for e in ev)

async def test_waiting_for_approval_keeps_the_stream_alive(tmp_path, monkeypatch):
    from test_shell import Driver, Passthrough
    from jarvis_bridge.tools.sandbox import ShellSandbox
    monkeypatch.setattr(orch, "HEARTBEAT", 0.1)
    svc, _ = make(tmp_path); drv = Driver(ShellSandbox(tmp_path / "w", backend=Passthrough())); svc.shell = drv.runner
    ev = []
    async def approve_later():
        await asyncio.sleep(0.6); drv.policy.resolve(drv.policy.pending()[0].approval_id, True)
    asyncio.create_task(approve_later())
    async for e in run_chat(Script(["<shell>echo hi</shell>"], ["Done."]), "m", [ChatMessage("user", "run it")], svc): ev.append(e)
    assert sum(1 for e in ev if e.get("ping")) >= 3 and text_of(ev) == "Done."


# ----------------------------------------------------------------------------- providers surface 'thinking'
async def test_ollama_reports_thinking_chunks_instead_of_dropping_them():
    import httpx, json
    from jarvis_bridge.inference.ollama import OllamaProvider
    lines = [{"message": {"role": "assistant", "content": "", "thinking": "hmm"}, "done": False},
             {"message": {"role": "assistant", "content": "", "thinking": "still hmm"}, "done": False},
             {"message": {"role": "assistant", "content": "Hi"}, "done": False}, {"message": {"content": ""}, "done": True}]
    transport = httpx.MockTransport(lambda r: httpx.Response(200, text="\n".join(json.dumps(l) for l in lines)))
    o = OllamaProvider("http://127.0.0.1:11434", transport=transport)
    chunks = [c async for c in o.chat_stream("qwen", [ChatMessage("user", "x")])]
    assert [c.thinking for c in chunks] == [True, True, False, False] and "".join(c.delta for c in chunks) == "Hi"

async def test_openai_compatible_reports_reasoning_chunks():
    import httpx, json
    from jarvis_bridge.inference.openai_compat import OpenAICompatProvider
    ev = [{"choices": [{"delta": {"reasoning_content": "thinking…"}}]}, {"choices": [{"delta": {"content": "Hi"}}]}, {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
    body = "".join("data: " + json.dumps(e) + "\n\n" for e in ev) + "data: [DONE]\n\n"
    o = OpenAICompatProvider("http://127.0.0.1:1234/v1", provider_id="lmstudio", transport=httpx.MockTransport(lambda r: httpx.Response(200, text=body)))
    chunks = [c async for c in o.chat_stream("m", [ChatMessage("user", "x")])]
    assert chunks[0].thinking and "".join(c.delta for c in chunks) == "Hi"
