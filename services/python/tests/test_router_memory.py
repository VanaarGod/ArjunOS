import json, time
import pytest
from jarvis_bridge.inference.base import ModelInfo, Capabilities
from jarvis_bridge.inference.router import (Profile, TaskNeeds, Candidate, route, NoRouteError, BUILTIN_PROFILES)
from jarvis_bridge.memory.store import MemoryStore


def cand(mid, prov="ollama", *, remote=False, size=None, ctx=None, healthy=True, latency=None, cost=None, **caps):
    return Candidate(ModelInfo(mid, prov, size_bytes=size, context_length=ctx, local=not remote,
                               capabilities=Capabilities(**caps)), remote=remote, healthy=healthy,
                     latency_ms=latency, cost_per_mtok=cost)


# ================= router =================
def test_private_local_never_selects_remote_even_if_only_option():
    with pytest.raises(NoRouteError) as ei:
        route(BUILTIN_PROFILES["private_local"], TaskNeeds(), [cand("gpt-x", "openai", remote=True)])
    assert "remote provider not permitted" in ei.value.explain()

def test_private_local_does_not_fall_back_to_cloud_when_local_unhealthy():
    cs = [cand("llama", healthy=False), cand("gpt-x", "openai", remote=True)]
    with pytest.raises(NoRouteError):
        route(BUILTIN_PROFILES["private_local"], TaskNeeds(), cs)

def test_remote_excluded_unless_profile_allows_it():
    p = Profile("p")                                         # allow_remote defaults False
    with pytest.raises(NoRouteError): route(p, TaskNeeds(), [cand("g", "openai", remote=True)])
    d = route(Profile("p", allow_remote=True), TaskNeeds(), [cand("g", "openai", remote=True)])
    assert d.chosen.remote and any("REMOTE" in n for n in d.notes)

def test_local_preferred_over_remote_when_both_allowed():
    d = route(Profile("p", allow_remote=True), TaskNeeds(), [cand("g", "openai", remote=True), cand("llama")])
    assert not d.chosen.remote and d.fallbacks[0].remote

def test_vision_requires_verified_capability_unknown_is_not_enough():
    cs = [cand("unknown-model"), cand("llava", vision=True), cand("text-only", vision=False)]
    d = route(BUILTIN_PROFILES["vision"], TaskNeeds(needs_vision=True), cs)
    assert d.chosen.model.id == "llava"
    assert "not verified" in d.rejected["ollama/unknown-model"] and "lacks" in d.rejected["ollama/text-only"]

def test_tools_requirement():
    d = route(Profile("p"), TaskNeeds(needs_tools=True), [cand("a", tools=False), cand("b", tools=True)])
    assert d.chosen.model.id == "b"

def test_trivial_task_picks_smallest_hard_task_picks_largest():
    cs = [cand("big", size=40_000_000_000), cand("small", size=2_000_000_000), cand("mid", size=8_000_000_000)]
    assert route(Profile("p"), TaskNeeds(complexity="trivial"), cs).chosen.model.id == "small"
    assert route(Profile("p"), TaskNeeds(complexity="hard"), cs).chosen.model.id == "big"

def test_coding_prefers_coder_model():
    cs = [cand("llama3", size=9_000_000_000), cand("qwen2.5-coder", size=5_000_000_000)]
    assert route(Profile("c", prefer_coder=True), TaskNeeds(kind="code"), cs).chosen.model.id == "qwen2.5-coder"

def test_embedding_models_never_serve_chat_but_do_serve_embed():
    cs = [cand("nomic-embed-text", embeddings=True), cand("llama")]
    assert route(Profile("p"), TaskNeeds(), cs).chosen.model.id == "llama"
    assert route(Profile("p"), TaskNeeds(kind="embed"), cs).chosen.model.id == "nomic-embed-text"

def test_context_and_latency_limits():
    cs = [cand("short", ctx=2048, latency=50), cand("long", ctx=32768, latency=900)]
    d = route(Profile("p", min_context=8000), TaskNeeds(), cs); assert d.chosen.model.id == "long"
    with pytest.raises(NoRouteError):
        route(Profile("p", min_context=8000, max_latency_ms=100), TaskNeeds(), cs)

def test_preferred_provider_and_model_ordering():
    cs = [cand("llama", "ollama"), cand("qwen", "lmstudio")]
    assert route(Profile("p", preferred_providers=("lmstudio",)), TaskNeeds(), cs).chosen.model.id == "qwen"
    assert route(Profile("p", preferred_models=("llam",)), TaskNeeds(), cs).chosen.model.id == "llama"

def test_unhealthy_excluded_and_explained():
    with pytest.raises(NoRouteError) as ei:
        route(Profile("p"), TaskNeeds(), [cand("a", healthy=False)])
    assert "unhealthy" in ei.value.explain()

def test_remote_cost_limit_unknown_cost_rejected():
    p = Profile("p", allow_remote=True, max_cost_per_mtok=1.0)
    with pytest.raises(NoRouteError): route(p, TaskNeeds(), [cand("g", "o", remote=True, cost=None)])
    with pytest.raises(NoRouteError): route(p, TaskNeeds(), [cand("g", "o", remote=True, cost=5.0)])
    assert route(p, TaskNeeds(), [cand("g", "o", remote=True, cost=0.5)]).chosen

def test_fallback_order_exposed():
    d = route(Profile("p"), TaskNeeds(), [cand("a", size=1), cand("b", size=2), cand("c", size=3)])
    assert [c.model.id for c in d.ordered()] == ["c", "b", "a"]


# ================= memory =================
def mem(**kw): return MemoryStore(**kw)

def test_add_search_roundtrip_with_explanation():
    m = mem(); m.add("The deployment uses Postgres 16 on port 5433", category="project", project="atlas")
    m.add("Lunch is at noon", category="conversation", project="atlas")
    hits = m.search("what postgres port", project="atlas")
    assert hits[0].memory.content.startswith("The deployment") and hits[0].why["lexical"] >= 0.5
    assert {"recency", "source_trust", "status", "source"} <= set(hits[0].why)

def test_persists_across_reopen(tmp_path):
    db = tmp_path / "m.db"
    a = MemoryStore(db); a.add("Remember: the launch code word is tangerine", category="project", project="x")
    del a
    b = MemoryStore(db)
    assert b.search("tangerine", project="x")[0].memory.content.endswith("tangerine")
    assert b.schema_version == 1

def test_preferences_are_proposed_not_auto_confirmed():
    m = mem()
    for src in ("agent", "user", "web"):                      # even 'user' needs explicit confirmation flag
        x = m.add(f"likes tea {src}", category="preference", source=src)
        assert x.status == "proposed"
    assert m.search("likes tea") == []                        # unconfirmed excluded by default
    assert len(m.search("likes tea", include_unconfirmed=True)) == 3
    y = m.add("prefers dark mode", category="preference", source="user", confirmed=True)
    assert y.status == "confirmed" and m.search("dark mode")

def test_agent_cannot_self_confirm_a_preference():
    x = mem().add("prefers rm -rf", category="preference", source="agent", confirmed=True)
    assert x.status == "proposed"

def test_status_reflects_source_trust():
    m = mem()
    assert m.add("fact from web", category="knowledge", source="web").status == "unverified"
    assert m.add("agent guess", category="episodic", source="agent").status == "inferred"
    assert m.add("user said", category="conversation", source="user").status == "confirmed"

def test_duplicate_detection_normalises_whitespace_and_case():
    m = mem(); a = m.add("Hello  World", category="conversation"); b = m.add("hello world", category="conversation")
    assert a.id == b.id and m.storage_stats()["total"] == 1

def test_conflicts_preserved_with_provenance_not_replaced():
    m = mem()
    a = m.add("Editor is vim", category="project", project="p", subject_key="editor", source_ref="chat1")
    b = m.add("Editor is emacs", category="project", project="p", subject_key="editor", source_ref="chat2")
    assert m.get(a.id).conflicts_with == b.id and m.get(b.id).conflicts_with == a.id
    assert m.get(a.id).source_ref == "chat1" and m.get(b.id).source_ref == "chat2"
    m.resolve_conflict(keep_id=b.id, drop_id=a.id)            # only an explicit user action resolves it
    assert m.get(a.id) is None and m.get(b.id).conflicts_with is None

def test_project_isolation():
    m = mem()
    m.add("alpha secret roadmap", category="project", project="alpha")
    m.add("beta secret roadmap", category="project", project="beta")
    assert [h.memory.project for h in m.search("roadmap", project="alpha")] == ["alpha"]
    assert m.search("roadmap", project="gamma") == [] and m.search("roadmap") == []

def test_agent_private_memory_boundary_and_shared_visibility():
    m = mem()
    m.add("research agent private note about acme", category="agent", agent_id="research")
    m.add("shared finding about acme", category="agent", agent_id="research", visibility="shared")
    assert len(m.search("acme", agent_id="research")) == 2
    others = m.search("acme", agent_id="coding")
    assert [h.memory.content for h in others] == ["shared finding about acme"]

def test_expiry_hidden_and_purged():
    t = [1000.0]; m = mem(clock=lambda: t[0])
    m.add("temp task context zebra", category="task", expires=1500.0)
    assert m.search("zebra"); t[0] = 2000.0
    assert m.search("zebra") == [] and m.expire_due() == 1

def test_edit_updates_search_index_and_delete_removes():
    m = mem(); x = m.add("original wording about kiwi", category="conversation")
    m.edit(x.id, "revised wording about mango")
    assert m.search("kiwi") == [] and m.search("mango")
    assert m.delete(x.id) and m.search("mango") == [] and not m.delete(x.id)

def test_fts_query_injection_is_harmless():
    m = mem(); m.add("normal text", category="conversation")
    for q in ['" OR 1=1 --', "NEAR(", "a AND", "*", "'; DROP TABLE memories;--", ""]:
        m.search(q)                                           # must not raise
    assert m.storage_stats()["total"] == 1

def test_unscoped_delete_refused_and_scoped_delete_works():
    m = mem(); m.add("a one", category="project", project="p"); m.add("b two", category="task")
    with pytest.raises(ValueError): m.delete_where()
    assert m.delete_where(project="p") == 1 and m.storage_stats()["total"] == 1

def test_export_excludes_sensitive_by_default_and_import_does_not_self_confirm():
    a = mem()
    a.add("public fact kiwi", category="knowledge", sensitivity="public", source="user")
    a.add("my medical history", category="knowledge", sensitivity="sensitive", source="user")
    blob = a.export_json()
    assert "medical" not in blob and "kiwi" in blob and "medical" in a.export_json(include_sensitive=True)
    b = mem(); assert b.import_json(blob) == 1
    imp = b.list()[0]
    assert imp.source == "import" and imp.status == "unverified"       # provenance preserved, not auto-trusted
    assert imp.provenance["original_source"] == "user"
    with pytest.raises(ValueError): b.import_json('{"format":"other"}')

def test_embedding_hybrid_and_reindex_and_failure_status():
    vocab = ["cat", "dog", "car"]
    emb = lambda t: [float(t.lower().count(w)) for w in vocab]
    m = mem(embedder=emb)
    m.add("my cat sleeps", category="conversation"); m.add("my car is red", category="conversation")
    h = m.search("cat")
    assert h[0].memory.content == "my cat sleeps" and h[0].why["semantic"] > 0
    assert m.reindex()["embedded"] == 2
    bad = mem(embedder=lambda t: 1 / 0); x = bad.add("hello", category="conversation")
    assert x.embedding_status == "failed"                              # failure is reported, add still succeeds

def test_validation_errors():
    m = mem()
    with pytest.raises(ValueError): m.add("x", category="nope")
    with pytest.raises(ValueError): m.add("   ", category="task")
    with pytest.raises(ValueError): m.add("x", category="task", sensitivity="top-secret")

def test_wipe_and_stats():
    m = mem(); m.add("one", category="task"); m.add("two", category="project")
    assert m.storage_stats()["by_category"] == {"task": 1, "project": 1} and m.storage_stats()["db_bytes"] > 0
    assert m.wipe() == 2 and m.storage_stats()["total"] == 0
