import pytest
from jarvis_bridge.chat.orchestrator import ChatServices, run_chat
from jarvis_bridge.inference.base import ChatMessage
from jarvis_bridge.memory.store import MemoryStore
from jarvis_bridge.profile import (MAX_BLOCK_CHARS, PROFILE_NAME_KEY, Profile, ProfileError, ProfileStore, compile_block, estimate_tokens)
from jarvis_bridge.settings import SettingsStore
from jarvis_bridge.tools.websearch import DuckDuckGoSearch
from mockservers import free_port
from test_api import Env
from test_orchestrator import Script, text_of


# ---------------- compiling: small, terse, deterministic ----------------
def test_empty_profile_adds_nothing():
    assert compile_block(Profile()) == "" and estimate_tokens("") == 0

def test_only_filled_fields_appear_and_defaults_say_nothing():
    p = Profile(call_me="Arjun", directness="balanced", formality="neutral", length="balanced", emoji="sometimes").validate()
    assert compile_block(p) == "User: Arjun. Address them as Arjun."          # "balanced/neutral" are the model's default, so they cost zero tokens

def test_full_profile_is_terse_and_cheap():
    p = Profile(call_me="Arjun", name="Arjun Rao", pronouns="he/him", language="English", time_zone="America/New_York", role="CS student",
                directness="direct", length="brief", emoji="never", about="Builds local AI tools.", instructions="Show code before explanations.").validate()
    block = compile_block(p)
    assert block.startswith("User: Arjun (full name Arjun Rao). Address them as Arjun.")
    assert "Reply style: direct, no hedging, brief, no emoji." in block and "Show code before explanations." in block
    assert estimate_tokens(block) < 100                                       # a realistic profile costs well under 100 tokens

def test_compile_is_deterministic():
    p = Profile(call_me="A", about="x", instructions="y").validate()
    assert compile_block(p) == compile_block(Profile(**p.__dict__))

def test_switched_off_sends_nothing_but_keeps_the_data():
    p = Profile(call_me="Arjun", instructions="be brief", include=False).validate()
    assert compile_block(p) == "" and p.call_me == "Arjun"

def test_limits_are_enforced_per_field_and_for_the_whole_block():
    with pytest.raises(ProfileError, match="instructions"): Profile(instructions="x" * 1201).validate()
    with pytest.raises(ProfileError, match="too long"): Profile(about="a" * 500, instructions="b" * 1200).validate()
    assert len(compile_block(Profile(about="a" * 500, instructions="b" * 900).validate())) <= MAX_BLOCK_CHARS
    with pytest.raises(ProfileError, match="directness"): Profile(directness="shouty").validate()

def test_store_roundtrip_atomic_and_corrupt_file_is_kept(tmp_path):
    s = ProfileStore(tmp_path / "p.json"); s.update(call_me="Arjun", onboarded=True)
    assert ProfileStore(tmp_path / "p.json").value.call_me == "Arjun" and ProfileStore(tmp_path / "p.json").value.onboarded
    with pytest.raises(ProfileError): s.update(bogus="x")
    (tmp_path / "bad.json").write_text("{nope"); assert ProfileStore(tmp_path / "bad.json").value == Profile()
    assert (tmp_path / "bad.corrupt").exists()


# ---------------- in the prompt: first, once, and not duplicated ----------------
def svc_with(tmp_path, **profile):
    mem = MemoryStore(); store = ProfileStore(tmp_path / "p.json"); store.update(**profile)
    st = SettingsStore(tmp_path / "s.json")
    return ChatServices(mem, st, DuckDuckGoSearch(), profile=store), mem

async def chat(svc, text, stream=None):
    stream = stream or Script(["ok"])
    ev = [e async for e in run_chat(stream, "m", [ChatMessage("user", text)], svc)]
    return stream, ev

async def test_profile_is_the_start_of_the_system_message(tmp_path):
    svc, _ = svc_with(tmp_path, call_me="Arjun", instructions="Keep answers short.")
    stream, ev = await chat(svc, "hello")
    system = stream.calls[0][0]
    assert system.role == "system" and system.content.startswith("User: Arjun. Address them as Arjun.") and "Keep answers short." in system.content
    assert sum("Address them as Arjun" in m.content for m in stream.calls[0]) == 1          # exactly once per request

async def test_profile_comes_before_changing_context_so_the_prefix_stays_identical(tmp_path):
    svc, mem = svc_with(tmp_path, call_me="Arjun")
    mem.add("The user's dog is called Max", category="knowledge", confirmed=True)
    first, _ = await chat(svc, "what is my dog called")                        # recalled memory is appended AFTER the profile
    second, _ = await chat(svc, "tell me a joke")
    a, b = first.calls[0][0].content, second.calls[0][0].content
    assert "dog is called Max" in a and "dog is called Max" not in b
    assert a.startswith("User: Arjun. Address them as Arjun.") and b.startswith("User: Arjun. Address them as Arjun.")

async def test_empty_or_off_profile_adds_no_system_message(tmp_path):
    for kw in ({}, {"call_me": "Arjun", "include": False}):
        svc, _ = svc_with(tmp_path, **kw)
        stream, _ = await chat(svc, "hello")
        assert [m.role for m in stream.calls[0]] == ["user"]

async def test_name_memory_is_not_repeated_when_the_profile_already_says_it(tmp_path):
    svc, mem = svc_with(tmp_path, call_me="Arjun")
    mem.add("The user goes by Arjun. Address them as Arjun.", category="preference", subject_key=PROFILE_NAME_KEY, confirmed=True)
    stream, ev = await chat(svc, "what should you call me, Arjun?")
    assert not any("memory_used" in e for e in ev) and "previously asked you to remember" not in stream.calls[0][0].content

async def test_name_memory_alone_does_not_switch_on_the_recall_tool(tmp_path):
    svc, mem = svc_with(tmp_path, call_me="Arjun")
    mem.add("The user goes by Arjun.", category="preference", subject_key=PROFILE_NAME_KEY, confirmed=True)
    stream, _ = await chat(svc, "hello")
    assert "<recall>" not in stream.calls[0][0].content                       # no extra tool instructions for a user with no other memories
    mem.add("Likes tea", category="knowledge", confirmed=True)
    stream, _ = await chat(svc, "hello")
    assert "<recall>" in stream.calls[0][0].content


# ---------------- API: profile, preview, first memory, memory list ----------------
async def test_profile_api_first_memory_and_rename(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        p = (await c.get("/v1/profile")).json()
        assert p["onboarded"] is False and p["compiled"] == "" and p["tokens"] == 0 and p["max_chars"] == MAX_BLOCK_CHARS
        assert (await c.get("/v1/memory")).json() == []
        p = (await c.put("/v1/profile", json={"call_me": "Arjun", "onboarded": True})).json()
        assert p["call_me"] == "Arjun" and p["onboarded"] and p["compiled"].startswith("User: Arjun")
        mems = (await c.get("/v1/memory")).json()
        assert len(mems) == 1 and mems[0]["content"] == "The user goes by Arjun. Address them as Arjun." and mems[0]["status"] == "confirmed"
        await c.put("/v1/profile", json={"call_me": "Arjun", "about": "hi"})             # unrelated change: still one memory
        await c.put("/v1/profile", json={"call_me": "AJ"})                              # rename edits the same memory, no duplicates
        mems = (await c.get("/v1/memory")).json()
        assert len(mems) == 1 and "AJ" in mems[0]["content"]
        await c.delete(f"/v1/memory/{mems[0]['id']}")                                   # user deleted it: an unrelated save does not bring it back
        await c.put("/v1/profile", json={"role": "student"})
        assert (await c.get("/v1/memory")).json() == []

async def test_profile_api_validation_and_preview(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        assert (await c.put("/v1/profile", json={"directness": "shouty"})).status_code == 422
        assert (await c.put("/v1/profile", json={"instructions": "x" * 5000})).status_code == 422
        pv = (await c.post("/v1/profile/preview", json={"call_me": "Arjun", "instructions": "Be brief."})).json()
        assert pv["ok"] and pv["tokens"] == estimate_tokens(pv["compiled"]) and "Be brief." in pv["compiled"]
        assert (await c.get("/v1/profile")).json()["call_me"] == ""                       # a preview never saves
        bad = (await c.post("/v1/profile/preview", json={"about": "a" * 500, "instructions": "b" * 1200})).json()
        assert not bad["ok"] and "too long" in bad["error"]

async def test_profile_requires_the_token(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client(token=None) as c:
        assert (await c.get("/v1/profile")).status_code == 401 and (await c.get("/v1/memory")).status_code == 401

async def test_memory_list_shows_everything_without_a_search(tmp_path):
    e = Env(tmp_path, free_port())
    async with e.client() as c:
        for t in ("Likes tea", "Lives in Cary"):
            await c.post("/v1/memory", json={"content": t, "category": "knowledge", "confirmed": True})
        await c.post("/v1/memory", json={"content": "Prefers dark mode", "category": "preference"})        # a proposal: shown, flagged
        got = (await c.get("/v1/memory")).json()
        assert [m["content"] for m in got][0] == "Prefers dark mode" and len(got) == 3
        assert {m["status"] for m in got} == {"confirmed", "proposed"}
        assert len((await c.get("/v1/memory?category=knowledge")).json()) == 2 and len((await c.get("/v1/memory?limit=1")).json()) == 1
