"""The model governor: decides which models are awake, and when, so a boss plus workers never run the machine out of memory.

Every model call by the crew goes through `Governor.call(ref, role)`:
  1. waits its turn (how many may run at once depends on the current mode),
  2. makes sure the model is loaded, putting idle models to sleep first if the memory is not there (lazy eviction: a model
     that is still needed soon stays awake until the space is actually wanted, so a worker model is not reloaded between jobs),
  3. runs the call.
If memory runs short mid-run it drops to a safer mode (parallel -> boss+one -> one at a time) instead of crashing.
"""
from __future__ import annotations
import asyncio, contextlib, time
from typing import Callable, Protocol
from .resources import GB, Mode, SystemMemory, next_safer, MODE_TEXT, footprint


class InsufficientMemory(Exception):
    pass


class ModelRuntime(Protocol):
    async def loaded(self) -> dict: ...                  # ref -> resident bytes, for models the bridge can see and manage
    async def load(self, ref: str) -> None: ...
    async def unload(self, ref: str) -> None: ...
    def can_unload(self, ref: str) -> bool: ...


class ProviderRuntime:
    """Ollama-backed runtime. `providers()` yields (endpoint_key, provider) for every usable endpoint; refs are 'endpoint|model'."""
    def __init__(self, providers: Callable[[], list]):
        self._providers = providers

    def _find(self, ref: str):
        key, _, model = ref.partition("|")
        for k, p in self._providers():
            if k == key: return p, model
        return None, model

    def can_unload(self, ref: str) -> bool:
        p, _ = self._find(ref)
        return bool(p is not None and getattr(p, "can_manage_memory", False))

    async def loaded(self) -> dict:
        out = {}
        for k, p in self._providers():
            if getattr(p, "can_manage_memory", False):
                try:
                    for name, size in (await p.loaded_models()).items(): out[f"{k}|{name}"] = size
                except Exception: pass
        return out

    async def load(self, ref: str) -> None:
        p, model = self._find(ref)
        if p is not None and getattr(p, "can_manage_memory", False): await p.load_model(model)

    async def unload(self, ref: str) -> None:
        p, model = self._find(ref)
        if p is not None and getattr(p, "can_manage_memory", False): await p.unload_model(model)


class Governor:
    def __init__(self, runtime: ModelRuntime, sysmem: Callable[[], SystemMemory], footprints: dict, mode: Mode, *,
                 max_workers: int = 1, boss_ref: str | None = None, emit: Callable[[dict], None] = lambda e: None,
                 settle_s: float = 4.0):
        self.runtime, self.sysmem, self.footprints = runtime, sysmem, dict(footprints)
        self.mode, self.max_workers, self.boss_ref, self._emit = mode, max(1, max_workers), boss_ref, emit
        self.settle_s = settle_s
        self._active = {"boss": 0, "worker": 0}
        self._boss_waiting = 0
        self._cv = asyncio.Condition()
        self._load_lock = asyncio.Lock()
        self._refs: dict = {}                        # ref -> calls in flight
        self.loaded_by_us: set = set()
        self._last_degrade = 0.0
        self.working: dict = {}                      # ref -> number of calls running (for the UI)

    # ---------------------------------------------------------------- snapshots
    async def snapshot(self) -> dict:
        try: loaded = await self.runtime.loaded()
        except Exception: loaded = {}
        return {**self.sysmem().as_dict(), "mode": self.mode.value, "mode_label": MODE_TEXT[self.mode], "max_workers": self.max_workers,
                "loaded": [{"ref": r, "bytes": b, "busy": self._refs.get(r, 0) > 0} for r, b in sorted(loaded.items())]}

    async def _announce(self):
        self._emit({"memory": await self.snapshot()})

    def degrade(self, why: str) -> bool:
        safer = next_safer(self.mode)
        if safer is None: return False
        old = self.mode
        self.mode = safer; self.max_workers = 1; self._last_degrade = time.monotonic()
        self._emit({"mode_changed": {"from": old.value, "to": safer.value, "why": why, "label": MODE_TEXT[safer]}})
        return True

    # ---------------------------------------------------------------- turn-taking
    def _can_enter(self, role: str) -> bool:
        w, b = self._active["worker"], self._active["boss"]
        if self.mode is Mode.PARALLEL:
            return b < 1 if role == "boss" else w < self.max_workers
        if self.mode is Mode.BOSS_PLUS_ONE:
            return b < 1 if role == "boss" else w < 1
        if self.mode is Mode.BOSS_SLEEPS:
            if role == "boss": return w + b < 1                              # the boss wakes alone: running workers finish their current step first
            return b < 1 and self._boss_waiting == 0 and w < self.max_workers   # several workers together, but none start while the boss is waiting
        if role == "boss": return w + b < 1                                  # SWAP: strictly one at a time, and the boss gets priority
        return w + b < 1 and self._boss_waiting == 0

    @contextlib.asynccontextmanager
    async def call(self, ref: str, role: str):
        self._check_pressure()
        async with self._cv:
            if role == "boss": self._boss_waiting += 1
            try: await self._cv.wait_for(lambda: self._can_enter(role))
            finally:
                if role == "boss": self._boss_waiting -= 1
            self._active[role] += 1; self._refs[ref] = self._refs.get(ref, 0) + 1
        try:
            if role == "worker" and self.mode is Mode.BOSS_SLEEPS and self.boss_ref and self._refs.get(self.boss_ref, 0) == 0:
                await self.sleep_model(self.boss_ref)                      # the boss goes to sleep up front, so the room it held can serve more workers
            try:
                await self._ensure_loaded(ref)
            except InsufficientMemory as first:
                if not self.degrade(str(first)): raise
                await self._ensure_loaded(ref)
            yield
        finally:
            async with self._cv:
                self._active[role] -= 1; self._refs[ref] -= 1
                self._cv.notify_all()

    def _check_pressure(self):
        if self.sysmem().pressure == "critical" and time.monotonic() - self._last_degrade > 10:
            self.degrade("Memory is nearly full, so I'm slowing down to keep your Mac responsive.")

    # ---------------------------------------------------------------- loading and sleeping
    async def _ensure_loaded(self, ref: str):
        if not self.runtime.can_unload(ref): return                           # unmanaged server: assumed resident, nothing to do
        async with self._load_lock:
            actual = await self.runtime.loaded()
            if ref in actual: return
            need = self.footprints.get(ref) or footprint(None)
            idle = [r for r in actual if r != ref and self._refs.get(r, 0) == 0 and self.runtime.can_unload(r)]
            # Put idle workers to sleep first (biggest first). The boss only goes to sleep in swap mode; in the other modes, if
            # that is still not enough we raise and the caller drops to a safer mode.
            victims = sorted((r for r in idle if r != self.boss_ref), key=lambda r: -actual[r])
            if self.mode in (Mode.SWAP, Mode.BOSS_SLEEPS) and self.boss_ref in idle: victims.append(self.boss_ref)
            for victim in victims:
                if need <= self.sysmem().budget(): break
                await self._sleep(victim, actual[victim])
            if need > self.sysmem().budget():
                raise InsufficientMemory(f"Not enough memory to wake {ref.partition('|')[2]}: it needs about {need / GB:.1f} GB and "
                                         f"{self.sysmem().budget() / GB:.1f} GB can be used right now.")
            self._emit({"model_event": {"ref": ref, "state": "loading"}})
            await self.runtime.load(ref); self.loaded_by_us.add(ref)
            self._emit({"model_event": {"ref": ref, "state": "awake"}})
        await self._announce()

    async def _sleep(self, ref: str, size: int):
        self._emit({"model_event": {"ref": ref, "state": "sleeping"}})
        before = self.sysmem().available
        await self.runtime.unload(ref)
        deadline = time.monotonic() + self.settle_s                            # give the OS a moment to hand the memory back
        while time.monotonic() < deadline and self.sysmem().available < before + size * 0.6:
            await asyncio.sleep(0.2)

    async def sleep_model(self, ref: str):
        """Explicitly put an idle model to sleep (used when the crew finishes)."""
        if self._refs.get(ref, 0) == 0 and self.runtime.can_unload(ref):
            async with self._load_lock:
                actual = await self.runtime.loaded()
                if ref in actual: await self._sleep(ref, actual[ref])
        await self._announce()

    async def finish(self, *, keep: set = frozenset()):
        for ref in list(self.loaded_by_us):
            if ref not in keep: await self.sleep_model(ref)
