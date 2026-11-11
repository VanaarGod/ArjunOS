"""What the machine can hold, and how to schedule models on it.

Pure functions plus one reader (`read_system`). Nothing here loads or unloads a model; `governor.py` does that using these numbers.

Memory numbers are ESTIMATES: a model's resident size is guessed from its file size (x1.15 for runtime buffers, plus a fixed
overhead), and extra concurrent requests on one model are charged a flat KV-cache allowance. The planner therefore keeps a
headroom (10% of RAM, at least 1.5 GB) free, and the governor re-checks real free memory before every model load.
"""
from __future__ import annotations
import os, re, subprocess
from dataclasses import dataclass, field
from enum import Enum

GB = 1024 ** 3
MB = 1024 ** 2
KV_EXTRA = int(0.5 * GB)             # each extra concurrent request on a resident model
DEFAULT_UNKNOWN_SIZE = 5 * GB        # when a model's size is unknown, assume a mid-size model rather than a tiny one


# ------------------------------------------------------------------ the machine
@dataclass(frozen=True)
class SystemMemory:
    total: int
    available: int                    # what could be given to a new model right now (free + easily reclaimable)
    swap_used: int = 0
    cpu_count: int = 1
    on_battery: bool | None = None
    source: str = "psutil"
    cpu_percent: float | None = None          # overall CPU load right now, 0-100
    cpu_name: str = ""
    gpu_name: str = ""
    gpu_limit: int | None = None              # most GPU memory models may use (Apple Silicon: a share of unified memory); None = unknown
    unified: bool = False                     # CPU and GPU share one memory pool (Apple Silicon)

    @property
    def headroom(self) -> int: return max(int(1.5 * GB), int(self.total * 0.10))

    def budget(self, reclaimable: int = 0) -> int:
        """Bytes models may use, keeping the headroom free for macOS and the apps you are working in."""
        return max(0, self.available + reclaimable - self.headroom)

    @property
    def pressure(self) -> str:
        if self.available < self.headroom * 0.6: return "critical"
        if self.available < self.headroom * 1.2: return "warn"
        return "normal"

    @property
    def used_pct(self) -> float: return round(100 * (1 - self.available / self.total), 1) if self.total else 0.0

    def as_dict(self) -> dict:
        return {"total": self.total, "available": self.available, "budget": self.budget(), "headroom": self.headroom,
                "pressure": self.pressure, "used_pct": self.used_pct, "swap_used": self.swap_used,
                "cpu_count": self.cpu_count, "on_battery": self.on_battery, "source": self.source,
                "cpu_percent": self.cpu_percent, "cpu_name": self.cpu_name, "gpu_name": self.gpu_name,
                "gpu_limit": self.gpu_limit, "unified": self.unified}

    @property
    def gpu_cap(self) -> int | None:
        """What a set of models may add up to on the GPU: a little under its limit, so the model is never split onto the CPU."""
        return int(self.gpu_limit * 0.92) if self.gpu_limit else None


def default_gpu_limit(total_bytes: int) -> int:
    """macOS lets the GPU use about two thirds of unified memory on smaller Macs and three quarters on bigger ones."""
    return int(total_bytes * (0.75 if total_bytes > 36 * GB else 0.667))


def parse_gpu_name(system_profiler_json: str) -> str:
    try:
        import json
        items = json.loads(system_profiler_json).get("SPDisplaysDataType") or []
        return str(items[0].get("sppci_model") or items[0].get("_name") or "") if items else ""
    except Exception:
        return ""


_HW: dict | None = None
_HW_LOCK = __import__("threading").Lock()


def _run(cmd: list, timeout: float = 4.0) -> str:
    try: return subprocess.check_output(cmd, text=True, timeout=timeout, stderr=subprocess.DEVNULL).strip()
    except Exception: return ""


def hardware_info(total_bytes: int | None = None, *, force: bool = False) -> dict:
    """CPU and GPU facts that do not change while the app runs. Read once and cached (system_profiler is slow)."""
    global _HW
    with _HW_LOCK:
        if _HW is not None and not force: return _HW
        import platform
        info = {"cpu_name": "", "gpu_name": "", "gpu_limit_mb": None, "unified": False}
        if platform.system() == "Darwin":
            info["cpu_name"] = _run(["sysctl", "-n", "machdep.cpu.brand_string"])
            info["unified"] = platform.machine() == "arm64"
            info["gpu_name"] = parse_gpu_name(_run(["system_profiler", "SPDisplaysDataType", "-json"], 8.0))
            lim = _run(["sysctl", "-n", "iogpu.wired_limit_mb"])
            info["gpu_limit_mb"] = int(lim) if lim.isdigit() and int(lim) > 0 else None
        else:
            info["cpu_name"] = platform.processor() or platform.machine()
        _HW = info
        return info


def warm_hardware() -> None:
    """Start reading hardware facts in the background so the first memory reading is never slow."""
    import threading
    threading.Thread(target=hardware_info, daemon=True).start()


def read_system() -> SystemMemory:
    cpu = os.cpu_count() or 1
    try:
        import psutil
        vm = psutil.virtual_memory()
        battery = None
        try:
            b = psutil.sensors_battery()
            battery = (not b.power_plugged) if b is not None else None
        except Exception: pass
        hw = _HW or {}                                                     # cached facts only: never block the scheduler here
        total = int(vm.total)
        limit = (int(hw["gpu_limit_mb"]) * MB if hw.get("gpu_limit_mb") else (default_gpu_limit(total) if hw.get("unified") else None))
        return SystemMemory(total, int(vm.available), int(psutil.swap_memory().used), cpu, battery, "psutil",
                            psutil.cpu_percent(interval=None), hw.get("cpu_name", ""), hw.get("gpu_name", ""), limit, bool(hw.get("unified")))
    except ImportError:
        pass
    try:                                                              # Linux
        info = {l.split(":")[0]: int(l.split()[1]) * 1024 for l in open("/proc/meminfo") if ":" in l}
        return SystemMemory(info["MemTotal"], info.get("MemAvailable", info["MemFree"]), 0, cpu, None, "/proc/meminfo")
    except Exception: pass
    try:                                                              # macOS without psutil
        total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip())
        vm = subprocess.check_output(["vm_stat"], text=True)
        page = int(re.search(r"page size of (\d+)", vm).group(1))
        pages = {k: int(v) for k, v in re.findall(r"Pages (free|inactive|speculative):\s+(\d+)", vm)}
        return SystemMemory(total, sum(pages.values()) * page, 0, cpu, None, "vm_stat")
    except Exception:
        return SystemMemory(8 * GB, 4 * GB, 0, cpu, None, "unknown (assumed 8 GB machine)")


def footprint(size_bytes: int | None) -> int:
    """Estimated resident bytes of a loaded model."""
    return int((size_bytes or DEFAULT_UNKNOWN_SIZE) * 1.15 + 0.4 * GB)


# ------------------------------------------------------------------ modes
class Mode(str, Enum):
    PARALLEL = "parallel"             # boss and several workers awake together
    BOSS_PLUS_ONE = "boss_plus_one"   # boss stays awake, workers take turns, one at a time
    SWAP = "swap"                     # one model awake at a time: the boss sleeps while workers work, and wakes for questions
    BOSS_SLEEPS = "boss_sleeps"       # the boss sleeps while SEVERAL workers run together; it wakes (workers pause) for questions and the final answer

RANK = {Mode.SWAP: 1, Mode.BOSS_SLEEPS: 1.5, Mode.BOSS_PLUS_ONE: 2, Mode.PARALLEL: 3}
PREFERENCES = {"auto": Mode.PARALLEL, "parallel": Mode.PARALLEL, "boss_and_one": Mode.BOSS_PLUS_ONE, "one_at_a_time": Mode.SWAP, "boss_sleeps": Mode.BOSS_SLEEPS}

MODE_TEXT = {
    Mode.PARALLEL: "Everyone awake: the boss and several workers run together.",
    Mode.BOSS_PLUS_ONE: "The boss stays awake and workers take turns, one at a time.",
    Mode.SWAP: "One model at a time: the boss sleeps while workers work, and wakes up only to answer a question.",
    Mode.BOSS_SLEEPS: "The boss sleeps while several workers run together. It wakes up (the workers pause) to answer a question or write the final answer.",
}


@dataclass
class Plan:
    feasible: bool
    mode: Mode | None
    max_workers: int
    budget: int
    boss_bytes: int
    worker_bytes: int                 # the largest distinct worker model
    reason: str
    warnings: list = field(default_factory=list)

    @property
    def boss_stays_awake(self) -> bool: return self.mode in (Mode.PARALLEL, Mode.BOSS_PLUS_ONE)

    @property
    def boss_sleeps(self) -> bool: return self.mode in (Mode.SWAP, Mode.BOSS_SLEEPS)

    def as_dict(self) -> dict:
        return {"feasible": self.feasible, "mode": self.mode.value if self.mode else None, "label": MODE_TEXT.get(self.mode, ""),
                "max_workers": self.max_workers, "budget": self.budget, "boss_bytes": self.boss_bytes,
                "worker_bytes": self.worker_bytes, "reason": self.reason, "warnings": list(self.warnings)}


def _gb(n: int) -> str: return f"{n / GB:.1f} GB"


def parallel_cost(boss: int, workers: list, k: int) -> int:
    """Memory for the boss plus k workers at once. `workers` = footprints of the DISTINCT worker models."""
    if not workers: return boss + max(k - 1, 0) * KV_EXTRA
    ws = sorted(workers, reverse=True)
    resident = ws[:k]
    extra_requests = max(0, k - len(ws))
    return boss + sum(resident) + extra_requests * KV_EXTRA


def sleeping_boss_cost(boss: int, workers: list, k: int) -> int:
    """Memory for k workers at once while the boss is ASLEEP. With no distinct worker model the workers share the boss's model,
    so that one model is resident plus a flat allowance for each extra concurrent request."""
    if not workers: return boss + max(k - 1, 0) * KV_EXTRA
    ws = sorted(workers, reverse=True)
    return sum(ws[:k]) + max(0, k - len(ws)) * KV_EXTRA


def plan_schedule(sysmem: SystemMemory, boss: int, workers: list, *, preference: str = "auto", max_parallel: int = 4,
                  reclaimable: int = 0, wanted_workers: int | None = None) -> Plan:
    """Pick the most capable mode that fits. `boss` and `workers` are model footprints in bytes (workers: distinct models only;
    a worker that is the same model as the boss costs nothing extra and is simply left out of the list)."""
    ram_budget = sysmem.budget(reclaimable)
    budget = min(ram_budget, sysmem.gpu_cap) if sysmem.gpu_cap is not None else ram_budget     # models bigger than the GPU's share would spill onto the slow CPU path
    wmax = max(workers) if workers else 0
    want = max(1, min(max_parallel, wanted_workers or max_parallel))
    warnings = []
    if sysmem.on_battery:
        want = min(want, 2); warnings.append("On battery: limiting parallel workers to save power.")
    if sysmem.pressure != "normal":
        want = min(want, 2); warnings.append("Memory is already tight: limiting parallel workers.")
    if sysmem.cpu_percent is not None and sysmem.cpu_percent > 85:
        warnings.append("The CPU is already busy with other work, so everything will run slower than usual.")
    if sysmem.swap_used > 2 * GB:
        warnings.append(f"{_gb(sysmem.swap_used)} is already swapped to disk, so things may be slow. Close big apps if you can.")
    top = PREFERENCES.get(preference, Mode.PARALLEL)

    def search(limit_bytes: int) -> list:
        found = []
        if top is Mode.BOSS_SLEEPS:
            # several workers together with the boss asleep; the boss must still fit alone for when it wakes up
            if want >= 2 and boss <= limit_bytes:
                for n in range(want, 1, -1):
                    if sleeping_boss_cost(boss, workers, n) <= limit_bytes: found.append((Mode.BOSS_SLEEPS, n)); break
            if max(boss, wmax) <= limit_bytes: found.append((Mode.SWAP, 1))
            return found
        if RANK[top] >= RANK[Mode.PARALLEL] and want >= 2:
            k = 0
            for n in range(want, 1, -1):                                   # most workers that still fit alongside the boss
                if parallel_cost(boss, workers, n) <= limit_bytes: k = n; break
            if k: found.append((Mode.PARALLEL, k))
        if RANK[top] >= RANK[Mode.BOSS_PLUS_ONE] and boss + wmax <= limit_bytes:
            found.append((Mode.BOSS_PLUS_ONE, 1))
        if max(boss, wmax) <= limit_bytes:
            found.append((Mode.SWAP, 1))
        return found

    candidates = search(budget)
    if budget < ram_budget and (search(ram_budget)[:1] != candidates[:1]):      # only mention the GPU when it actually changed the plan
        warnings.append(f"Your GPU can hold about {_gb(sysmem.gpu_cap)} of models, so that is the limit here even though more RAM is free.")

    if not candidates:
        need = max(boss, wmax)
        return Plan(False, None, 0, budget, boss, wmax,
                    f"Not enough free memory: the biggest model needs about {_gb(need)} but only {_gb(budget)} can be used right now "
                    f"({_gb(sysmem.available)} free, {_gb(sysmem.headroom)} kept for your Mac"
                    + (f", and your GPU can hold about {_gb(sysmem.gpu_cap)}" if budget < ram_budget else "")
                    + "). Close apps, or pick a smaller boss or worker model.", warnings)
    mode, k = candidates[0]
    reason = MODE_TEXT[mode]
    if RANK[mode] < RANK[top]:
        reason += f" (Your choice needed more memory than the {_gb(budget)} available, so this is the best that fits.)"
    return Plan(True, mode, k, budget, boss, wmax, reason, warnings)


def next_safer(mode: Mode) -> Mode | None:
    return {Mode.PARALLEL: Mode.BOSS_PLUS_ONE, Mode.BOSS_PLUS_ONE: Mode.SWAP, Mode.BOSS_SLEEPS: Mode.SWAP, Mode.SWAP: None}[mode]


# ------------------------------------------------------------------ picking small worker models
@dataclass(frozen=True)
class ModelRow:
    ref: str                          # "endpointkey|model"
    id: str
    size_bytes: int | None = None
    params_b: float | None = None     # billions of parameters, when known
    vision: bool | None = None
    chat: bool = True
    manageable: bool = True           # can the bridge unload it? (Ollama yes; LM Studio and other servers no)
    context_length: int | None = None


_PARAMS = re.compile(r"(\d+(?:\.\d+)?)\s*([bm])\b", re.I)
_EMBED = re.compile(r"(embed|bge-|nomic|e5-|minilm)", re.I)


def parse_params_b(parameter_size: str | None, model_id: str = "", size_bytes: int | None = None) -> float | None:
    for text in (parameter_size or "", model_id):
        m = _PARAMS.search(text)
        if m:
            v = float(m.group(1))
            return v / 1000 if m.group(2).lower() == "m" else v
    if size_bytes: return round(size_bytes / (0.6 * GB), 1)            # rough: ~0.6 GB per billion parameters at 4-bit
    return None


def is_embedding(model_id: str) -> bool: return bool(_EMBED.search(model_id))


def rank_workers(models: list, *, needs_vision: bool = False, floor_b: float = 1.5) -> list:
    """Smallest capable models first. Models below `floor_b` billion parameters go last: they are fast but too weak to write
    a long, accurate summary, so they are only used when nothing bigger is installed."""
    ok = [m for m in models if m.chat and not is_embedding(m.id) and (not needs_vision or m.vision is True)]
    def size(m: ModelRow) -> float: return m.params_b if m.params_b is not None else ((m.size_bytes or DEFAULT_UNKNOWN_SIZE) / (0.6 * GB))
    good = sorted((m for m in ok if size(m) >= floor_b), key=size)
    weak = sorted((m for m in ok if size(m) < floor_b), key=size, reverse=True)
    return good + weak


def pick_worker(models: list, *, needs_vision: bool = False, exclude: set | None = None) -> ModelRow | None:
    ranked = [m for m in rank_workers(models, needs_vision=needs_vision) if m.ref not in (exclude or set())]
    return ranked[0] if ranked else None
