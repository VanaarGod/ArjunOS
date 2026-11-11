"""End to end: does memory creation reach Obsidian when you chat? Real HTTP API, real bridge services, a real (temporary) vault,
and a scripted local model standing in for Ollama. Nothing is mocked inside the bridge."""
import json, re
import pytest
from fastapi import Request
from fastapi.responses import StreamingResponse
from jarvis_bridge.obsidian.service import MEMORY_SUB
from mockservers import fake_ollama, free_port, serve
from test_api import Env
from test_obsidian import vault_dir  # noqa: F401  (pytest fixture)


def scripted_ollama(rules):
    """An Ollama whose replies come from `rules(messages) -> str`, and which remembers everything it was sent."""
    app = fake_ollama()
    app.router.routes = [r for r in app.router.routes if getattr(r, "path", "") != "/api/chat"]
    sent = []
    @app.post("/api/chat")
    async def chat(req: Request):
        b = await req.json(); sent.append(b)
        text = rules(b["messages"])
        async def gen():
            yield json.dumps({"message": {"role": "assistant", "content": text}, "done": False}) + "\n"
            yield json.dumps({"message": {"content": ""}, "done": True, "done_reason": "stop", "prompt_eval_count": 5, "eval_count": 5}) + "\n"
        return StreamingResponse(gen(), media_type="application/x-ndjson")
    app.state.sent = sent
    return app

def system_of(m): return next((x["content"] for x in m if x["role"] == "system"), "")
def last_user(m): return next((x["content"] for x in reversed(m) if x["role"] == "user"), "")

def model_rules(messages):
    sys, user = system_of(messages), last_user(messages)
    if sys.startswith("Rewrite the user's message as ONE short factual note"): return "The user's favorite color is green."
    if "save a note" in user.lower():
        return '<vaultnote name="Trip ideas" tags="travel, ideas">Kyoto in April, then Osaka.</vaultnote>'
    if "Saved **" in "".join(m["content"] for m in messages if m["role"] == "tool"): return "Done."
    return "OK."

async def chat(c, key, text, history=()):
    body = {"endpoint": key, "model": "llama3.2:3b", "messages": [*history, {"role": "user", "content": text}]}
    async with c.stream("POST", "/v1/chat", json=body) as r:
        assert r.status_code == 200
        return [json.loads(l[6:]) async for l in r.aiter_lines() if l.startswith("data: ")]

def memory_notes(vault): 
    d = vault / "ArjunOS" / MEMORY_SUB
    return sorted(d.glob("*.md")) if d.exists() else []


async def test_remembering_in_chat_creates_a_memory_AND_an_obsidian_note_and_recalls_it_later(tmp_path, vault_dir):
    app = scripted_ollama(model_rules)
    with serve(app) as port:
        e = Env(tmp_path / "state", port) if (tmp_path / "state").mkdir(exist_ok=True) is None else None
        async with e.client() as c:
            await c.post("/v1/providers/scan")
            assert (await c.post("/v1/obsidian/connect", json={"path": str(vault_dir)})).json()["active"]

            ev = await chat(c, e.key, "remember that my favorite color is green")
            saved = [x["memory_saved"] for x in ev if "memory_saved" in x]
            assert saved and saved[0]["content"] == "The user's favorite color is green." and not any("error" in x for x in ev)

            mems = (await c.get("/v1/memory")).json()                                   # 1. it is a real, confirmed memory
            assert [m["content"] for m in mems] == ["The user's favorite color is green."] and mems[0]["status"] == "confirmed"

            notes = memory_notes(vault_dir)                                               # 2. and it is a note in the vault
            assert len(notes) == 1
            text = notes[0].read_text()
            assert "favorite color is green" in text and f"arjunos_id: {mems[0]['id']}" in text and "category: preference" in text

            ev = await chat(c, e.key, "what is my favorite color?")                      # 3. and it is used in a later chat
            assert any("memory_used" in x for x in ev)
            assert "favorite color is green" in system_of(app.state.sent[-1]["messages"])

            await c.delete(f"/v1/memory/{mems[0]['id']}")                                # 4. deleting the memory removes the note
            assert memory_notes(vault_dir) == []


async def test_the_model_can_write_a_note_into_the_vault_from_chat(tmp_path, vault_dir):
    app = scripted_ollama(model_rules)
    with serve(app) as port:
        e = Env(tmp_path / "state", port) if (tmp_path / "state").mkdir(exist_ok=True) is None else None
        async with e.client() as c:
            await c.post("/v1/providers/scan"); await c.post("/v1/obsidian/connect", json={"path": str(vault_dir)})
            ev = await chat(c, e.key, "Please save a note with my trip ideas")
            saved = [x["vault_saved"] for x in ev if "vault_saved" in x]
            assert saved and saved[0]["path"].startswith("ArjunOS/") and saved[0]["title"] == "Trip ideas"
            made = vault_dir / saved[0]["path"]
            assert made.exists() and "Kyoto in April" in made.read_text() and "travel" in made.read_text()
            assert (vault_dir / "Suppliers.md").read_text().startswith("# Suppliers")      # the user's own notes are untouched


async def test_profile_name_memory_also_lands_in_the_vault(tmp_path, vault_dir):
    app = scripted_ollama(model_rules)
    with serve(app) as port:
        e = Env(tmp_path / "state", port) if (tmp_path / "state").mkdir(exist_ok=True) is None else None
        async with e.client() as c:
            await c.post("/v1/obsidian/connect", json={"path": str(vault_dir)})
            await c.put("/v1/profile", json={"call_me": "Arjun", "onboarded": True})
            notes = memory_notes(vault_dir)
            assert len(notes) == 1 and "goes by Arjun" in notes[0].read_text()
            await c.put("/v1/profile", json={"call_me": "AJ"})                              # renaming updates the SAME note
            notes = memory_notes(vault_dir)
            assert len(notes) == 1 and "goes by AJ" in notes[0].read_text()


async def test_turning_the_vault_memory_switch_off_keeps_memories_out_of_the_vault(tmp_path, vault_dir):
    app = scripted_ollama(model_rules)
    with serve(app) as port:
        e = Env(tmp_path / "state", port) if (tmp_path / "state").mkdir(exist_ok=True) is None else None
        async with e.client() as c:
            await c.post("/v1/providers/scan"); await c.post("/v1/obsidian/connect", json={"path": str(vault_dir)})
            await c.put("/v1/settings", json={"obsidian_store_memories": False})
            ev = await chat(c, e.key, "remember that my favorite color is green")
            assert any("memory_saved" in x for x in ev) and memory_notes(vault_dir) == []
            assert len((await c.get("/v1/memory")).json()) == 1                              # still remembered by the app
