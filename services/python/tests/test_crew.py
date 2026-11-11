import asyncio, json, re
import pytest
from jarvis_bridge.inference.base import ChatMessage
from jarvis_bridge.orchestration.resources import (GB, Mode, ModelRow, SystemMemory, footprint, parse_params_b, pick_worker, plan_schedule, rank_workers, read_system)
from jarvis_bridge.orchestration.governor import Governor, InsufficientMemory
from jarvis_bridge.orchestration.crew import (CrewConfig, CrewEngine, CrewInput, CrewSession, Blackboard, chunk_text, extract_json, parse_control,
                                              relevant_excerpts, split_posts, is_http_url)

BOSS, MINI, VIS = "ol|boss:8b", "ol|mini:3b", "ol|vis:4b"
SIZES = {BOSS: 8 * GB, MINI: 2 * GB, VIS: 3 * GB}


# ---------------------------------------------------------------- a fake machine
class Machine:
    """Fake RAM + fake Ollama: loading a model uses memory, unloading gives it back."""
    def __init__(self, total=16, available=14):
        self.total, self.available, self.resident, self.log = total * GB, available * GB, {}, []
    def sysmem(self): return SystemMemory(self.total, self.available)
    async def loaded(self): return dict(self.resident)
    async def load(self, ref):
        if ref not in self.resident:
            self.resident[ref] = footprint(SIZES[ref]); self.available -= self.resident[ref]; self.log.append(("load", ref))
    async def unload(self, ref):
        if ref in self.resident:
            self.available += self.resident.pop(ref); self.log.append(("unload", ref))
    def can_unload(self, ref): return ref != "lm|unmanaged"


def rows(**over):
    base = {BOSS: ModelRow(BOSS, "boss:8b", SIZES[BOSS], 8, False, context_length=32768),
            MINI: ModelRow(MINI, "mini:3b", SIZES[MINI], 3, False),
            VIS: ModelRow(VIS, "vis:4b", SIZES[VIS], 4, True)}
    base.update(over); return base


# ---------------------------------------------------------------- resources
def test_footprint_and_system_reader():
    assert footprint(2 * GB) > 2 * GB
    s = read_system(); assert s.total > 0 and 0 <= s.available <= s.total

def test_plan_picks_the_most_capable_mode_that_fits():
    boss, w = footprint(8 * GB), [footprint(2 * GB)]
    assert plan_schedule(SystemMemory(32 * GB, 28 * GB), boss, w).mode is Mode.PARALLEL
    p = plan_schedule(SystemMemory(16 * GB, 14 * GB), boss, w); assert p.mode is Mode.BOSS_PLUS_ONE and p.max_workers == 1
    p = plan_schedule(SystemMemory(16 * GB, 12 * GB), boss, w); assert p.mode is Mode.SWAP and p.boss_stays_awake is False
    p = plan_schedule(SystemMemory(16 * GB, 11 * GB), boss, w); assert not p.feasible and "Not enough free memory" in p.reason

def test_plan_respects_the_users_preference_and_never_exceeds_it():
    boss, w = footprint(8 * GB), [footprint(2 * GB)]
    big = SystemMemory(32 * GB, 28 * GB)
    assert plan_schedule(big, boss, w, preference="one_at_a_time").mode is Mode.SWAP
    assert plan_schedule(big, boss, w, preference="boss_and_one").mode is Mode.BOSS_PLUS_ONE

def test_plan_limits_parallelism_under_pressure_or_battery():
    boss, w = footprint(2 * GB), [footprint(1 * GB)]
    p = plan_schedule(SystemMemory(64 * GB, 60 * GB, on_battery=True), boss, w, max_parallel=6)
    assert p.mode is Mode.PARALLEL and p.max_workers == 2 and any("battery" in x for x in p.warnings)

def test_same_model_for_boss_and_worker_costs_nothing_extra():
    p = plan_schedule(SystemMemory(16 * GB, 12 * GB), footprint(8 * GB), [])
    assert p.feasible

def test_worker_picker_prefers_small_capable_models_and_vision_when_needed():
    ms = list(rows().values()) + [ModelRow("ol|tiny:0.5b", "tiny:0.5b", int(0.4 * GB), 0.5, False), ModelRow("ol|nomic-embed", "nomic-embed-text", 300_000_000, None, None)]
    assert pick_worker(ms).ref == MINI                       # 3B beats the 0.5B (too weak) and the embedder is never chosen
    assert pick_worker(ms, needs_vision=True).ref == VIS
    assert pick_worker([ModelRow("ol|tiny:0.5b", "tiny:0.5b", 400_000_000, 0.5)]).ref == "ol|tiny:0.5b"      # nothing better installed
    assert pick_worker(ms, needs_vision=True, exclude={VIS}) is None

def test_parse_params():
    assert parse_params_b("3.2B") == 3.2 and parse_params_b("494M") == pytest.approx(0.494)
    assert parse_params_b(None, "qwen2.5:7b-instruct") == 7 and parse_params_b(None, "x", 6 * GB) == 10.0


# ---------------------------------------------------------------- helpers
def test_extract_json_handles_fences_and_chatter():
    assert extract_json('Sure!\n```json\n{"a": {"b": [1, 2]}, "c": "x}"}\n```\nDone') == {"a": {"b": [1, 2]}, "c": "x}"}
    assert extract_json("no json here") is None and extract_json("{broken") is None

def test_chunking_respects_limits_and_keeps_everything():
    text = "\n\n".join(f"Paragraph {i}. " + "word " * 80 for i in range(20))
    parts = chunk_text(text, 1000)
    assert all(len(p) <= 1000 for p in parts) and len(parts) > 3
    assert "Paragraph 19" in parts[-1] and "".join(parts).count("Paragraph") == 20
    assert chunk_text("short", 1000) == ["short"] and chunk_text("", 10) == []
    assert all(len(p) <= 50 for p in chunk_text("x" * 500, 50))

def test_control_tags():
    assert parse_control("<ask_boss>Which year?</ask_boss>") == ("ask_boss", "Which year?", None)
    assert parse_control('<ask_peer agent="w2">what is the total?</ask_peer>') == ("ask_peer", "what is the total?", "w2")
    assert parse_control("<browse>https://a.com</browse>")[0] == "browse" and parse_control("  <ask_boss>cut off")[1] == "cut off"
    assert parse_control("The answer is <ask_boss> inside")[0] == "none"
    clean, posts = split_posts('Report text <post key="Currency">EUR</post> more')
    assert posts == [("Currency", "EUR")] and "post" not in clean

def test_blackboard_shares_and_protects():
    b = Blackboard(); b.seed(["Use ISO dates"], {"ARR": "annual recurring revenue"})
    assert b.post("w1", "Currency", "EUR") and not b.post("w1", "", "x")
    assert "ISO dates" in b.render() and "currency = EUR  (from w1)" in b.render() and "ARR" in b.render()
    assert b.post("w2", "key2", "token=sk-abcdefghijklmnopqrstuvwxyz0123456789") and "sk-abcdefghijklmnop" not in b.render()

def test_peer_excerpts_pick_relevant_paragraphs():
    rep = "Intro about the company.\n\nRevenue in 2023 was 4.2 million euros.\n\nThe office is in Berlin."
    assert "4.2 million" in relevant_excerpts(rep, "what was the revenue in 2023?").split("\n\n")[0]

def test_http_url_validation():
    assert is_http_url("https://example.com/a?b=1") and not is_http_url("file:///etc/passwd") and not is_http_url("javascript:alert(1)")


# ---------------------------------------------------------------- governor
async def test_swap_mode_boss_sleeps_while_a_worker_works_and_wakes_for_a_question():
    m = Machine(16, 12); events = []
    g = Governor(m, m.sysmem, {r: footprint(s) for r, s in SIZES.items()}, Mode.SWAP, boss_ref=BOSS, emit=events.append, settle_s=0.1)
    async with g.call(BOSS, "boss"): assert set(m.resident) == {BOSS}
    async with g.call(MINI, "worker"): assert set(m.resident) == {MINI}            # the boss went to sleep
    async with g.call(BOSS, "boss"): assert set(m.resident) == {BOSS}              # the little one went down for the boss's answer
    async with g.call(MINI, "worker"): assert set(m.resident) == {MINI}
    assert [e["model_event"]["state"] for e in events if "model_event" in e].count("sleeping") == 3

async def test_boss_plus_one_keeps_the_boss_awake_and_runs_workers_one_at_a_time():
    m = Machine(16, 14); running, peak = 0, 0
    g = Governor(m, m.sysmem, {r: footprint(s) for r, s in SIZES.items()}, Mode.BOSS_PLUS_ONE, boss_ref=BOSS, settle_s=0.1)
    async with g.call(BOSS, "boss"): pass
    async def work(ref):
        nonlocal running, peak
        async with g.call(ref, "worker"):
            running += 1; peak = max(peak, running); assert BOSS in m.resident; await asyncio.sleep(0.02); running -= 1
    await asyncio.gather(work(MINI), work(MINI), work(MINI))
    assert peak == 1 and BOSS in m.resident and g.mode is Mode.BOSS_PLUS_ONE

async def test_parallel_mode_allows_the_planned_number_of_workers():
    m = Machine(64, 60); peak = running = 0
    g = Governor(m, m.sysmem, {r: footprint(s) for r, s in SIZES.items()}, Mode.PARALLEL, max_workers=3, boss_ref=BOSS)
    async def work():
        nonlocal running, peak
        async with g.call(MINI, "worker"):
            running += 1; peak = max(peak, running); await asyncio.sleep(0.03); running -= 1
    await asyncio.gather(*(work() for _ in range(6)))
    assert peak == 3 and [x for x in m.log if x[0] == "load"] == [("load", MINI)]    # one shared load, not six

async def test_governor_drops_to_a_safer_mode_instead_of_crashing_when_memory_runs_short():
    m = Machine(16, 14); events = []
    g = Governor(m, m.sysmem, {r: footprint(s) for r, s in SIZES.items()}, Mode.BOSS_PLUS_ONE, boss_ref=BOSS, emit=events.append, settle_s=0.1)
    async with g.call(BOSS, "boss"): pass
    m.available -= 6 * GB                                                           # another app grabs memory
    async with g.call(VIS, "worker"): assert VIS in m.resident
    assert g.mode is Mode.SWAP and any("mode_changed" in e for e in events) and BOSS not in m.resident

async def test_governor_raises_when_even_one_model_cannot_fit():
    m = Machine(16, 3)
    g = Governor(m, m.sysmem, {r: footprint(s) for r, s in SIZES.items()}, Mode.SWAP, boss_ref=BOSS, settle_s=0.1)
    with pytest.raises(InsufficientMemory):
        async with g.call(BOSS, "boss"): pass

async def test_critical_memory_pressure_reduces_parallelism():
    m = Machine(16, 0.5); events = []
    g = Governor(m, m.sysmem, {MINI: footprint(SIZES[MINI])}, Mode.PARALLEL, max_workers=4, boss_ref=BOSS, emit=events.append)
    try:
        async with g.call(MINI, "worker"): pass
    except InsufficientMemory: pass
    assert g.mode is not Mode.PARALLEL

async def test_unmanaged_servers_are_never_loaded_or_evicted():
    m = Machine(16, 12)
    g = Governor(m, m.sysmem, {"lm|unmanaged": 0}, Mode.SWAP, boss_ref=BOSS)
    async with g.call("lm|unmanaged", "worker"): pass
    assert m.log == []


# ---------------------------------------------------------------- crew engine
def worker_id(msgs):
    m = re.search(r"You are (w\d+)", msgs[0].content)
    return m.group(1) if m else "boss"

class Team:
    """Scripted boss + workers. `workers[id]` is a list of replies (one per call) or a callable(msgs) -> reply."""
    def __init__(self, machine, plan=None, workers=None, answers=None, final="FINAL ANSWER", fix="Try smaller steps.", review=None):
        self.m, self.plan, self.workers, self.answers, self.final, self.fix, self.review = machine, plan, workers or {}, list(answers or []), final, fix, review
        self.worker_calls, self.boss_calls, self.seen_resident = [], [], []
    async def llm(self, ref, msgs):
        sys = msgs[0].content; self.boss_calls.append(sys[:30]); self.seen_resident.append(set(self.m.resident))
        if sys.startswith("You are the BOSS agent. Split"): return self.plan if isinstance(self.plan, str) else json.dumps(self.plan)
        if "answering a worker's question" in sys: return self.answers.pop(0) if self.answers else "Use 2023."
        if "A worker failed" in sys: return self.fix
        if "reviewing your workers" in sys: self.review_prompt = msgs[1].content; return json.dumps(self.review) if isinstance(self.review, (dict, list)) else (self.review or "")
        if "Workers have finished" in sys: return self.final + "\n" + msgs[1].content[:0]
        return ""
    async def agent_chat(self, ref, msgs, page=None, agent=None, crew=None):
        wid = worker_id(msgs); self.seen_resident.append(set(self.m.resident))
        self.worker_calls.append((wid, ref, msgs, page))
        script = self.workers.get(wid, ["A" * 200])
        r = script if callable(script) else (script.pop(0) if script else "B" * 200)
        if callable(r): r = r(msgs)
        if isinstance(r, Exception): raise r
        if isinstance(r, dict): yield r; return
        for i in range(0, len(r), 40): yield {"delta": r[i:i + 40]}
        yield {"done": True}

def engine(machine, team, models=None):
    return CrewEngine(llm=team.llm, agent_chat=team.agent_chat, models=models or rows(), runtime=machine, sysmem=machine.sysmem)

async def run_crew(eng, task, inputs, cfg, *, user=None, browse=None, ui_browser=False, timeout=15):
    s = CrewSession(); s.has_ui_browser = ui_browser; eng.start(s, task, inputs, cfg); out = []
    async def consume():
        async for ev in eng.stream(s):
            out.append(ev)
            if "needs_user" in ev and user: s.answer(ev["needs_user"]["id"], user(ev["needs_user"]))
            if "browse" in ev and browse: s.browse_result(ev["browse"]["id"], browse(ev["browse"]))
    await asyncio.wait_for(consume(), timeout); return out

def pdfs(n=3, size=500): return [CrewInput(f"doc{i}.pdf", "pdf", text=f"Doc {i}. " + ("fact " * size)) for i in range(1, n + 1)]
def kinds(ev): return [next(iter(e)) for e in ev]
def of(ev, k): return [e[k] for e in ev if k in e]

PLAN3 = {"subtasks": [{"title": f"Read doc{i}", "instructions": f"Summarise doc{i}.pdf in full detail.", "inputs": [f"doc{i}.pdf"]} for i in (1, 2, 3)],
         "conventions": ["Dates as YYYY-MM-DD"], "glossary": {"ARR": "annual recurring revenue"}}


async def test_three_pdfs_one_worker_each_then_boss_assembles():
    m = Machine(32, 28); t = Team(m, PLAN3, final="Combined answer.")
    ev = await run_crew(engine(m, t), "Read these PDFs and compare them.", pdfs(3), CrewConfig(BOSS))
    plan = of(ev, "plan")[0]
    assert [s["inputs"] for s in plan["subtasks"]] == [["doc1.pdf"], ["doc2.pdf"], ["doc3.pdf"]]
    assert {s["model"] for s in plan["subtasks"]} == {MINI}                          # the small model was chosen automatically
    assert len(of(ev, "result")) == 3 and all(r["summary"] for r in of(ev, "result"))
    fin = of(ev, "final")[0]
    assert fin["text"] == "Combined answer." and "doc2.pdf" in fin["context"] and len(fin["reports"]) == 3
    assert kinds(ev)[-2:] == ["final", "done"] or kinds(ev)[-1] == "done"
    # every worker saw the boss's conventions and glossary (shared variables)
    assert all("YYYY-MM-DD" in c[2][0].content and "ARR" in c[2][0].content for c in t.worker_calls)
    # and each got only its own file as an attachment
    assert all(len(c[2][1].attachments) == 1 for c in t.worker_calls)

async def test_swap_mode_loads_only_one_model_at_a_time_throughout_a_whole_run():
    m = Machine(16, 12); t = Team(m, PLAN3)
    ev = await run_crew(engine(m, t), "go", pdfs(3), CrewConfig(BOSS))
    assert of(ev, "start")[0]["plan"]["mode"] == "swap"
    assert all(len(s) <= 1 for s in t.seen_resident)                                 # never two models in memory together
    assert len(of(ev, "final")) == 1

async def test_boss_wakes_for_a_worker_question_and_goes_back_to_sleep():
    m = Machine(16, 12)
    t = Team(m, {"subtasks": [{"title": "A", "instructions": "Do A", "inputs": ["doc1.pdf"]}]},
             workers={"w1": ["<ask_boss>Which fiscal year matters?</ask_boss>", lambda msgs: "Year-specific report. " * 20]}, answers=["Fiscal 2023."])
    ev = await run_crew(engine(m, t), "t", pdfs(1), CrewConfig(BOSS))
    q, a = of(ev, "question")[0], of(ev, "answer")[0]
    assert q["from"] == "w1" and "fiscal year" in q["text"] and a["text"] == "Fiscal 2023."
    answered_with = t.worker_calls[1][2][-1].content
    assert "Boss's answer: Fiscal 2023." in answered_with                            # the worker got the answer and carried on
    seq = [x for x in m.log]
    assert seq.index(("load", BOSS)) < seq.index(("unload", BOSS)) and seq.count(("load", BOSS)) >= 2   # boss slept, then woke
    assert "<ask_boss" not in "".join(e["ev"]["delta"] for e in ev if "agent" in e and "delta" in e["ev"])   # the raw request is never shown as an answer

async def test_boss_can_hand_a_question_back_to_the_user():
    m = Machine(32, 28)
    t = Team(m, {"subtasks": [{"title": "A", "instructions": "x", "inputs": ["doc1.pdf"]}]},
             workers={"w1": ["<ask_boss>Do you want metric or imperial?</ask_boss>", "Report in metric. " * 20]}, answers=["ASK_USER: Metric or imperial units?"])
    ev = await run_crew(engine(m, t), "t", pdfs(1), CrewConfig(BOSS), user=lambda n: "metric")
    nu = of(ev, "needs_user")[0]
    assert nu["kind"] == "boss_needs_user" and "Metric or imperial" in nu["question"]
    assert of(ev, "answer")[0]["text"] == "metric"

async def test_failing_worker_gets_boss_guidance_a_stronger_model_then_goes_back_to_the_user():
    m = Machine(32, 28); err = RuntimeError
    from jarvis_bridge.inference.base import ProviderError, ErrorKind
    boom = lambda msgs: {"error": {"kind": "http", "message": "model crashed"}}
    t = Team(m, {"subtasks": [{"title": "Flaky", "instructions": "x", "inputs": ["doc1.pdf"]}]}, workers={"w1": [boom, boom, "Recovered report. " * 20]}, fix="Read it in small pieces.")
    ev = await run_crew(engine(m, t), "t", pdfs(1), CrewConfig(BOSS), user=lambda n: "try again but focus on numbers")
    probs = of(ev, "agent_problem")
    assert [p["attempt"] for p in probs] == [1, 2] and "model crashed" in probs[0]["message"]
    assert "Read it in small pieces." in t.worker_calls[1][2][1].content              # boss guidance reached the retry
    nu = of(ev, "needs_user")[0]; assert nu["kind"] == "worker_failed" and "Flaky" in nu["question"]
    assert "focus on numbers" in t.worker_calls[2][2][1].content                     # the user's instructions reached the third try
    assert of(ev, "result")[0]["summary"].startswith("Recovered")

async def test_user_can_skip_a_stuck_worker_and_the_others_still_finish():
    m = Machine(32, 28); boom = lambda msgs: {"error": {"kind": "http", "message": "nope"}}
    t = Team(m, PLAN3, workers={"w2": [boom, boom]}, final="Done without doc2.")
    ev = await run_crew(engine(m, t), "t", pdfs(3), CrewConfig(BOSS), user=lambda n: "skip")
    res = {r["id"]: r for r in of(ev, "result")}
    assert res["w2"].get("skipped") and res["w1"]["summary"] and res["w3"]["summary"]
    assert of(ev, "final")[0]["reports"][1]["status"] == "skipped"

async def test_worker_that_never_recovers_is_reported_not_hidden():
    m = Machine(32, 28); boom = lambda msgs: {"error": {"kind": "http", "message": "nope"}}
    t = Team(m, {"subtasks": [{"title": "Bad", "instructions": "x", "inputs": ["doc1.pdf"]}]}, workers={"w1": [boom, boom, boom]})
    ev = await run_crew(engine(m, t), "t", pdfs(1), CrewConfig(BOSS), user=lambda n: "retry")
    assert of(ev, "result")[0]["failed"]
    assert any(a["state"] == "failed" for a in of(ev, "agent_state"))
    assert of(ev, "final")[0]["reports"][0]["status"] == "failed"

async def test_unusable_boss_plan_falls_back_to_one_worker_per_file_and_never_drops_a_file():
    m = Machine(32, 28)
    t = Team(m, "I think you should... [no json]"); ev = await run_crew(engine(m, t), "t", pdfs(3), CrewConfig(BOSS))
    assert any("split the work by file" in n for n in of(ev, "notice")) and len(of(ev, "plan")[0]["subtasks"]) == 3
    t2 = Team(m, {"subtasks": [{"title": "Only one", "instructions": "x", "inputs": ["doc1.pdf"]}]})
    ev2 = await run_crew(engine(Machine(32, 28), t2), "t", pdfs(3), CrewConfig(BOSS))
    covered = {n for s in of(ev2, "plan")[0]["subtasks"] for n in s["inputs"]}
    assert covered == {"doc1.pdf", "doc2.pdf", "doc3.pdf"}

async def test_big_documents_are_read_in_sections_with_an_overview():
    m = Machine(32, 28)
    big = CrewInput("big.pdf", "pdf", text="\n\n".join(f"Section {i}. " + "detail " * 200 for i in range(12)))
    t = Team(m, {"subtasks": [{"title": "Big", "instructions": "x", "inputs": ["big.pdf"]}]}, workers={"w1": lambda msgs: "Notes. " * 40})
    ev = await run_crew(engine(m, t), "t", [big], CrewConfig(BOSS, attachment_chars=4000))
    report = of(ev, "result")[0]["summary"]
    assert report.startswith("## Overview") and "## Detailed notes" in report and "### big.pdf, section 1" in report
    calls = [c for c in t.worker_calls]; assert len(calls) > 3
    assert all(len(c[2][1].attachments[0]["text"]) <= 3400 for c in calls if c[2][1].attachments)       # every section fits the file budget

async def test_scanned_pdf_pages_go_to_a_vision_model_three_at_a_time():
    m = Machine(32, 28)
    scan = CrewInput("scan.pdf", "pdf", text="", images_b64=[f"img{i}" for i in range(7)])
    t = Team(m, {"subtasks": [{"title": "Scan", "instructions": "x", "inputs": ["scan.pdf"]}]}, workers={"w1": lambda msgs: "Page notes. " * 30})
    ev = await run_crew(engine(m, t), "t", [scan], CrewConfig(BOSS))
    assert {c[1] for c in t.worker_calls} == {VIS}
    page_calls = [c for c in t.worker_calls if c[2][1].attachments]
    assert [len(c[2][1].attachments) for c in page_calls] == [3, 3, 1] and all(a["kind"] == "image" for a in page_calls[0][2][1].attachments)

async def test_per_input_model_assignment_overrides_automatic_choice():
    m = Machine(32, 28); ins = pdfs(2); ins[1].worker_model = VIS
    t = Team(m, {"subtasks": [{"title": "A", "instructions": "x", "inputs": ["doc1.pdf"]}, {"title": "B", "instructions": "x", "inputs": ["doc2.pdf"]}]})
    ev = await run_crew(engine(m, t), "t", ins, CrewConfig(BOSS))
    assert [s["model"] for s in of(ev, "plan")[0]["subtasks"]] == [MINI, VIS]

async def test_workers_share_facts_and_can_read_a_finished_colleagues_report():
    m = Machine(16, 14)                                   # boss+one: workers run in order
    done = asyncio.Event()
    def w1(msgs): return 'Doc one says revenue is 4.2 million EUR. <post key="currency">EUR</post> ' * 3
    def w2(msgs):
        last = msgs[-1].content
        if "Excerpts" in last: return "Using the colleague's figure of 4.2 million. " * 5
        return '<ask_peer agent="w1">What is the revenue?</ask_peer>'
    t = Team(m, {"subtasks": [{"title": "One", "instructions": "x", "inputs": ["doc1.pdf"]}, {"title": "Two", "instructions": "x", "inputs": ["doc2.pdf"]}]}, workers={"w1": w1, "w2": w2})
    ev = await run_crew(engine(m, t), "t", pdfs(2), CrewConfig(BOSS))
    assert of(ev, "shared")[0] == {"agent": "w1", "key": "currency", "value": "EUR"}
    w2_second = [c for c in t.worker_calls if c[0] == "w2"][-1][2]
    assert "currency = EUR  (from w1)" in w2_second[0].content                         # w2 saw w1's posted fact
    assert "4.2 million" in w2_second[-1].content            # the colleague's excerpt reached w2
    assert of(ev, "peer")[0]["to"] == "w1"

async def test_each_agent_can_open_pages_in_its_own_browser_and_gets_the_page_as_context():
    m = Machine(32, 28); page = {"url": "https://example.com", "title": "Ex", "text": "Example page text"}
    t = Team(m, {"subtasks": [{"title": "Web", "instructions": "check the site", "inputs": []}]},
             workers={"w1": ["<browse>https://example.com</browse>", "Report from the page. " * 20]})
    ev = await run_crew(engine(m, t), "t", [], CrewConfig(BOSS), ui_browser=True, browse=lambda b: {"ok": True, "page": page})
    b = of(ev, "browse")[0]; assert b["agent"] == "w1" and b["url"] == "https://example.com"
    assert t.worker_calls[0][3] is None and t.worker_calls[1][3] == page             # the second call carries that agent's page

async def test_browse_is_refused_without_a_ui_and_for_unsafe_addresses():
    m = Machine(32, 28)
    t = Team(m, {"subtasks": [{"title": "Web", "instructions": "x", "inputs": []}]}, workers={"w1": ["<browse>file:///etc/passwd</browse>", "Report. " * 30]})
    ev = await run_crew(engine(m, t), "t", [], CrewConfig(BOSS), ui_browser=True)
    assert not of(ev, "browse") and "only http and https" in t.worker_calls[1][2][-1].content
    t2 = Team(Machine(32, 28), {"subtasks": [{"title": "Web", "instructions": "x", "inputs": []}]}, workers={"w1": ["<browse>https://a.com</browse>", "Report. " * 30]})
    ev2 = await run_crew(engine(Machine(32, 28), t2), "t", [], CrewConfig(BOSS), ui_browser=False)
    assert not of(ev2, "browse") and "No browser panel" in t2.worker_calls[1][2][-1].content

async def test_each_worker_gets_its_own_page_not_a_neighbours():
    m = Machine(32, 28); s = CrewSession(); s.has_ui_browser = True
    s.pages["w2"] = {"url": "https://w2.example", "text": "only for w2"}
    t = Team(m, PLAN3); eng = engine(m, t); eng.start(s, "t", pdfs(3), CrewConfig(BOSS))
    async for _ in eng.stream(s): pass
    pages = {c[0]: c[3] for c in t.worker_calls}
    assert pages["w2"] == {"url": "https://w2.example", "text": "only for w2"} and pages["w1"] is None and pages["w3"] is None

async def test_not_enough_memory_stops_early_with_a_clear_message():
    m = Machine(16, 5); t = Team(m, PLAN3)
    ev = await run_crew(engine(m, t), "t", pdfs(3), CrewConfig(BOSS))
    err = of(ev, "error")[0]; assert err["kind"] == "memory" and "smaller" in err["message"] and not t.worker_calls
    assert kinds(ev)[-1] == "done"

async def test_memory_snapshots_and_mode_are_streamed_for_the_ui():
    m = Machine(16, 12); t = Team(m, PLAN3); ev = await run_crew(engine(m, t), "t", pdfs(3), CrewConfig(BOSS))
    snaps = of(ev, "memory"); assert snaps and {"total", "available", "pressure", "mode", "loaded"} <= set(snaps[-1])
    assert any(model["ref"] == MINI for s in snaps for model in s["loaded"])

async def test_workers_models_are_put_to_sleep_when_the_crew_finishes():
    m = Machine(32, 28); t = Team(m, PLAN3); await run_crew(engine(m, t), "t", pdfs(3), CrewConfig(BOSS))
    assert MINI not in m.resident and BOSS in m.resident

async def test_cancel_stops_everything_cleanly():
    m = Machine(32, 28)
    async def slow(msgs): await asyncio.sleep(5)
    t = Team(m, PLAN3)
    async def hang(ref, msgs, page=None, agent=None, crew=None):
        await asyncio.sleep(30); yield {"done": True}
    eng = CrewEngine(llm=t.llm, agent_chat=hang, models=rows(), runtime=m, sysmem=m.sysmem)
    s = CrewSession(); eng.start(s, "t", pdfs(3), CrewConfig(BOSS)); out = []
    async def consume():
        async for ev in eng.stream(s):
            out.append(ev)
            if "plan" in ev: await asyncio.sleep(0.05); s.cancel()
    await asyncio.wait_for(consume(), 10)
    assert {"cancelled": True} in out and out[-1] == {"done": True}

async def test_no_secrets_leak_through_error_events():
    m = Machine(32, 28)
    async def bad_llm(ref, msgs): raise RuntimeError("boom sk-abcdefghijklmnopqrstuvwxyz0123456789")
    t = Team(m, PLAN3); eng = CrewEngine(llm=bad_llm, agent_chat=t.agent_chat, models=rows(), runtime=m, sysmem=m.sysmem)
    ev = await run_crew(eng, "t", pdfs(1), CrewConfig(BOSS))
    assert "sk-abcdefghijklmnop" not in json.dumps(ev)
