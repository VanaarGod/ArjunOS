"""The "boss sleeps, workers run together" mode: several workers at once while the boss model is unloaded."""
import asyncio
import pytest
from jarvis_bridge.orchestration.crew import CrewConfig
from jarvis_bridge.orchestration.governor import Governor, InsufficientMemory
from jarvis_bridge.orchestration.resources import GB, Mode, SystemMemory, footprint, next_safer, plan_schedule
from test_crew import BOSS, MINI, PLAN3, SIZES, Machine, Team, engine, of, pdfs, run_crew


# ---------------------------------------------------------------- planning
def test_boss_sleeps_runs_several_workers_where_everyone_awake_would_not_fit():
    boss, w = footprint(8 * GB), [footprint(2 * GB)]
    tight = SystemMemory(16 * GB, 12 * GB)
    assert plan_schedule(tight, boss, w).mode is Mode.SWAP                              # automatic: only one model at a time fits
    p = plan_schedule(tight, boss, w, preference="boss_sleeps", max_parallel=4)
    assert p.feasible and p.mode is Mode.BOSS_SLEEPS and p.max_workers >= 2
    assert p.boss_stays_awake is False and p.boss_sleeps is True and "boss sleeps" in p.reason.lower()

def test_boss_sleeps_needs_the_boss_to_fit_alone_and_falls_back_to_one_at_a_time():
    boss, w = footprint(8 * GB), [footprint(2 * GB)]
    assert plan_schedule(SystemMemory(16 * GB, 12 * GB), boss, w, preference="boss_sleeps", wanted_workers=1).mode is Mode.SWAP     # one file: nothing to parallelise
    huge_workers = [footprint(5 * GB)]                                                  # two of these plus overhead do not fit; one does
    p = plan_schedule(SystemMemory(16 * GB, 12 * GB), boss, huge_workers, preference="boss_sleeps", max_parallel=4)
    assert p.mode in (Mode.BOSS_SLEEPS, Mode.SWAP) and p.feasible
    assert not plan_schedule(SystemMemory(16 * GB, 11 * GB), boss, w, preference="boss_sleeps").feasible

def test_workers_may_share_the_bosses_model_while_the_boss_sleeps():
    p = plan_schedule(SystemMemory(16 * GB, 14 * GB), footprint(8 * GB), [], preference="boss_sleeps", max_parallel=3)
    assert p.mode is Mode.BOSS_SLEEPS and p.max_workers == 3                            # one resident model, extra requests cost a small allowance

def test_battery_and_pressure_limits_still_apply():
    p = plan_schedule(SystemMemory(64 * GB, 60 * GB, on_battery=True), footprint(2 * GB), [footprint(1 * GB)], preference="boss_sleeps", max_parallel=6)
    assert p.mode is Mode.BOSS_SLEEPS and p.max_workers == 2

def test_other_preferences_are_unchanged():
    boss, w = footprint(8 * GB), [footprint(2 * GB)]
    big = SystemMemory(32 * GB, 28 * GB)
    assert plan_schedule(big, boss, w).mode is Mode.PARALLEL and plan_schedule(big, boss, w, preference="boss_and_one").mode is Mode.BOSS_PLUS_ONE
    assert next_safer(Mode.BOSS_SLEEPS) is Mode.SWAP


# ---------------------------------------------------------------- governor
def gov(m, **kw):
    return Governor(m, m.sysmem, {r: footprint(s) for r, s in SIZES.items()}, Mode.BOSS_SLEEPS, boss_ref=BOSS, settle_s=0.1, **kw)

async def test_workers_run_together_and_the_boss_is_asleep_while_they_do():
    m = Machine(16, 12); g = gov(m, max_workers=3); running = peak = 0
    async with g.call(BOSS, "boss"): assert BOSS in m.resident                          # the boss planned the work
    async def work():
        nonlocal running, peak
        async with g.call(MINI, "worker"):
            running += 1; peak = max(peak, running); assert BOSS not in m.resident; await asyncio.sleep(0.03); running -= 1
    await asyncio.gather(*(work() for _ in range(6)))
    assert peak == 3 and [x for x in m.log if x[0] == "load"].count(("load", MINI)) == 1 and ("unload", BOSS) in m.log

async def test_boss_wakes_when_asked_workers_pause_and_new_ones_wait_their_turn():
    m = Machine(16, 12); g = gov(m, max_workers=3); order = []
    async def worker(name, dur):
        async with g.call(MINI, "worker"): order.append(name + "+"); await asyncio.sleep(dur); order.append(name + "-")
    async def boss():
        async with g.call(BOSS, "boss"): order.append("boss+"); assert MINI not in m.resident; await asyncio.sleep(0.01); order.append("boss-")
    t1, t2 = asyncio.create_task(worker("w1", 0.06)), asyncio.create_task(worker("w2", 0.06)); await asyncio.sleep(0.02)
    tb = asyncio.create_task(boss()); await asyncio.sleep(0.01)
    t3 = asyncio.create_task(worker("w3", 0.01))                                         # arrives while the boss is waiting
    await asyncio.gather(t1, t2, tb, t3)
    assert order.index("boss+") > max(order.index("w1-"), order.index("w2-"))            # the running workers finish their step first
    assert order.index("boss+") < order.index("w3+")                                      # then the boss goes before anyone new starts
    assert order.index("boss-") < order.index("w3+")

async def test_it_steps_down_to_one_at_a_time_and_says_so_when_memory_runs_short():
    m = Machine(16, 12); events = []; g = gov(m, max_workers=3, emit=events.append)
    async with g.call(MINI, "worker"): pass
    m.available -= 7 * GB                                                                 # another app grabs memory: the boss can no longer wake
    with pytest.raises(InsufficientMemory):
        async with g.call(BOSS, "boss"): pass                                             # a clear error, not a hang
    assert g.mode is Mode.SWAP and g.max_workers == 1 and any("mode_changed" in e for e in events)


# ---------------------------------------------------------------- a whole run
class SlowTeam(Team):
    """Counts how many workers are inside a call at once, and which models were in memory at that moment."""
    def __init__(self, *a, **k):
        super().__init__(*a, **k); self.running = self.peak = 0; self.resident_at_work = []
    async def agent_chat(self, ref, msgs, page=None, agent=None, crew=None):
        self.running += 1; self.peak = max(self.peak, self.running); self.resident_at_work.append(set(self.m.resident))
        try:
            await asyncio.sleep(0.03)
            async for ev in super().agent_chat(ref, msgs, page=page, agent=agent, crew=crew): yield ev
        finally: self.running -= 1

async def test_full_run_workers_overlap_while_the_boss_model_is_unloaded():
    m = Machine(16, 12); t = SlowTeam(m, PLAN3, final="Combined answer.")
    ev = await run_crew(engine(m, t), "Compare these", pdfs(3), CrewConfig(BOSS, preference="boss_sleeps", max_workers=4))
    start = of(ev, "start")[0]["plan"]
    assert start["mode"] == "boss_sleeps" and start["max_workers"] >= 2
    assert t.peak >= 2                                                                    # workers genuinely ran at the same time
    assert all(BOSS not in s for s in t.resident_at_work)                                 # and the boss model was never loaded meanwhile
    assert len(of(ev, "result")) == 3 and of(ev, "final")[0]["text"] == "Combined answer."
    assert m.log.count(("load", BOSS)) >= 2                                               # it woke to plan and again to assemble the answer

async def test_full_run_boss_still_answers_a_worker_question():
    m = Machine(16, 12)
    plan = {"subtasks": [{"title": f"R{i}", "instructions": f"Do {i}", "inputs": [f"doc{i}.pdf"]} for i in (1, 2)]}
    t = SlowTeam(m, plan, workers={"w1": ["<ask_boss>Which fiscal year matters?</ask_boss>", lambda msgs: "Year report. " * 20]}, answers=["Fiscal 2023."])
    ev = await run_crew(engine(m, t), "t", pdfs(2), CrewConfig(BOSS, preference="boss_sleeps"))
    assert of(ev, "answer")[0]["text"] == "Fiscal 2023." and len(of(ev, "result")) == 2 and of(ev, "final")
    assert "Boss's answer: Fiscal 2023." in t.worker_calls[-1][2][-1].content or any("Boss's answer: Fiscal 2023." in c[2][-1].content for c in t.worker_calls)
