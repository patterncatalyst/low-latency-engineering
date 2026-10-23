"""amdahl-py: Amdahl's Law, Python edition (threads under the GIL versus processes).

Same experiment as the C++ and Java programs: a fixed batch of parcels shared among N workers,
every parcel updating one shared sort-plan table under one lock. Two executors from
``concurrent.futures`` run it:

* ``ThreadPoolExecutor`` with ``threading.Lock``: the workers are threads of one interpreter and
  the parallel part is pure Python bytecode, so the GIL lets one thread run at a time. Speedup
  stays near 1 however large N is.
* ``ProcessPoolExecutor`` with ``multiprocessing.Lock`` and a shared ``multiprocessing.Array``:
  one interpreter per worker, the table is shared memory, the lock is a cross-process semaphore.

Each repetition's wall time is recorded in the measurement kit (variant ``amdahl-<mode>-n<N>``).
"""

import argparse
import multiprocessing as mp
import threading
from collections.abc import MutableSequence, Sequence
from concurrent.futures import Executor, ProcessPoolExecutor, ThreadPoolExecutor
from contextlib import AbstractContextManager, ExitStack
from dataclasses import dataclass
from pathlib import Path
from time import perf_counter_ns
from typing import Any

from lowlat_measure import Recorder
from lowlat_measure.recorder import require_profile
from lowlat_measure.table import format_rows

from lowlat_amdahl.model import amdahl_speedup
from lowlat_amdahl.work import CELLS, Meeting, process_share

# Process-pool workers get the shared table through the pool initializer (the only place a
# multiprocessing.Array may be handed over) and keep it here.
_shared: dict[str, Any] = {}

# Lock-section length per parcel that makes the serial fraction about 10 % in each mode (a list
# element and a ctypes array element cost differently). The fraction is measured regardless.
LOCK_ITERS = {"threads": 85, "processes": 60}


def _init_worker(
    cell: MutableSequence[int], lock: AbstractContextManager[object], wave: Meeting | None
) -> None:
    _shared["cell"] = cell
    _shared["lock"] = lock
    _shared["wave"] = wave


def _share_in_process(args: tuple[int, int, int, int, int, int, bool]) -> int:
    batch, worker, workers, round_parcels, parallel_iters, lock_iters, timed = args
    return process_share(
        _shared["cell"],
        _shared["lock"],
        _shared["wave"],
        batch,
        worker,
        workers,
        round_parcels,
        parallel_iters,
        lock_iters,
        timed=timed,
    )


@dataclass(frozen=True, slots=True)
class Options:
    batch: int
    round_parcels: int
    phased: bool
    parallel_iters: int
    lock_iters: int
    reps: int
    warmup: int
    calibration_runs: int
    workers: tuple[int, ...]
    report_dir: Path
    example: str


class Bench:
    """One mode (threads or processes): pools per N, a shared table, one batch per call.

    A context manager: leaving the ``with`` block shuts the pools down, and so does a
    failure while they are being built.
    """

    def __init__(self, mode: str, opts: Options) -> None:
        self.mode = mode
        self.opts = opts
        self.cell: MutableSequence[int]
        self.lock: AbstractContextManager[object]
        self.waves: dict[int, Meeting]
        self.pools: dict[int, Executor]
        with ExitStack() as stack:
            if mode == "threads":
                self.cell = [0] * CELLS
                self.lock = threading.Lock()
                self.waves = {n: threading.Barrier(n, timeout=60) for n in opts.workers}
                self.pools = {
                    n: stack.enter_context(ThreadPoolExecutor(max_workers=n)) for n in opts.workers
                }
            else:
                self.cell = mp.Array("q", CELLS, lock=False)
                self.lock = mp.Lock()
                self.waves = {n: mp.Barrier(n, timeout=60) for n in opts.workers}
                self.pools = {
                    n: stack.enter_context(
                        ProcessPoolExecutor(
                            max_workers=n,
                            initializer=_init_worker,
                            initargs=(self.cell, self.lock, self.waves[n] if opts.phased else None),
                        )
                    )
                    for n in opts.workers
                }
            for n, pool in self.pools.items():  # start every worker before anything is timed
                list(pool.map(_noop, range(n * 2)))
            self._stack = stack.pop_all()

    def __enter__(self) -> Bench:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self._stack.close()

    def run(self, n: int, *, timed: bool = False) -> tuple[int, int]:
        """One batch on ``n`` workers. Returns (wall ns, ns inside the lock when timed)."""
        o = self.opts
        self.cell[:] = [0] * CELLS
        pool = self.pools[n]
        t0 = perf_counter_ns()
        if self.mode == "threads":
            wave = self.waves[n] if o.phased else None
            futures = [
                pool.submit(
                    process_share,
                    self.cell,
                    self.lock,
                    wave,
                    o.batch,
                    w,
                    n,
                    o.round_parcels,
                    o.parallel_iters,
                    o.lock_iters,
                    timed=timed,
                )
                for w in range(n)
            ]
            in_lock = sum(f.result() for f in futures)
        else:
            jobs = [
                (o.batch, w, n, o.round_parcels, o.parallel_iters, o.lock_iters, timed)
                for w in range(n)
            ]
            in_lock = sum(pool.map(_share_in_process, jobs))
        return perf_counter_ns() - t0, in_lock

    def checksum(self) -> int:
        return sum(self.cell)


def _noop(_: int) -> int:
    return 0


def run_mode(mode: str, opts: Options) -> list[dict[str, Any]]:
    with Bench(mode, opts) as bench:
        for _ in range(opts.warmup):
            for n in opts.workers:
                bench.run(n)
        bench.run(1)
        reference = bench.checksum()

        lock_total = wall_total = 0
        for _ in range(opts.calibration_runs):
            wall, in_lock = bench.run(1, timed=True)
            wall_total += wall
            lock_total += in_lock
        s = lock_total / wall_total
        print(
            f"amdahl-py[{mode}]: batch {opts.batch} parcels, serial fraction s = {s:.4f} "
            f"(time in lock / wall, N=1, {opts.calibration_runs} instrumented runs); "
            f"ideal limit 1/s = {1 / s:.2f}x"
        )

        recorders = {n: Recorder(opts.example, f"amdahl-{mode}-n{n}") for n in opts.workers}
        for _ in range(opts.reps):  # interleaved across N so background load lands on all alike
            for n in opts.workers:
                wall, _ = bench.run(n)
                if bench.checksum() != reference:
                    raise RuntimeError(f"N={n}: sort-plan table differs from the one-worker table")
                recorders[n].record(wall)

    p50_one = recorders[opts.workers[0]].percentiles()["p50"]
    reports = []
    for n in opts.workers:
        rec = recorders[n]
        p50 = rec.percentiles()["p50"]
        predicted = amdahl_speedup(s, n)
        measured = p50_one / p50
        model = {
            "law": "Amdahl: S(N) = 1 / ((1 - p) + p / N), p = 1 - s",
            "workers": n,
            "executor": "ThreadPoolExecutor" if mode == "threads" else "ProcessPoolExecutor",
            "serial_fraction_modelling_input": s,
            "serial_fraction_basis": (
                "time inside the lock / wall time, one worker, instrumented runs"
            ),
            "predicted_speedup": predicted,
            "measured_speedup_p50": measured,
            "relative_error": (measured - predicted) / predicted,
            "wall_p50_ns_n1": p50_one,
            "wall_p50_ns": p50,
            "batch_parcels": opts.batch,
            "sync": "phased: barriers between the parallel and serial parts of a wave"
            if opts.phased
            else "free: no barriers",
            "parcels_per_worker_per_wave": opts.round_parcels,
            "lock": "threading.Lock" if mode == "threads" else "multiprocessing.Lock",
        }
        path = opts.report_dir / f"python-amdahl-{mode}-n{n}.json"
        report = rec.write_report(
            path,
            f"{opts.reps} repetitions after {opts.warmup} warm-up rounds; wall time of the whole "
            "batch (pool already started); repetitions interleaved across N; "
            f"sync={'phased' if opts.phased else 'free'}",
            model,
        )
        print(format_rows([report]))
        scope = "the lock only; the GIL is not in the model" if mode == "threads" else "the lock"
        print(
            f"  {mode} N={n}: Amdahl predicts {predicted:.2f}x ({scope}), "
            f"measured {measured:.2f}x (p50 wall {p50 / 1e6:.1f} ms)"
        )
        reports.append(report)
    return reports


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="amdahl-py", description=__doc__.split("\n\n")[0])
    ap.add_argument("--batch", type=int, default=1200)
    ap.add_argument("--round-parcels", type=int, default=60, help="parcels per worker per wave")
    ap.add_argument("--sync", choices=["phased", "free"], default="phased")
    ap.add_argument("--parallel-iters", type=int, default=1000)
    ap.add_argument(
        "--lock-iters",
        type=int,
        default=None,
        help="table updates per parcel inside the lock (default sizes the lock to ~10%%: "
        f"{LOCK_ITERS['threads']} for threads, {LOCK_ITERS['processes']} for processes)",
    )
    ap.add_argument("--reps", type=int, default=30)
    ap.add_argument("--warm-up", dest="warmup", type=int, default=3)
    ap.add_argument("--workers", type=int, nargs="+", default=[1, 2, 4])
    ap.add_argument("--report-dir", type=Path, default=Path("."))
    ap.add_argument("--example", default="02-littles-amdahl")
    ap.add_argument(
        "--modes", nargs="+", choices=["threads", "processes"], default=["threads", "processes"]
    )
    return ap


def main(argv: Sequence[str] | None = None) -> int:
    ap = build_parser()
    a = ap.parse_args(argv)
    for n in a.workers:
        if a.batch % (n * a.round_parcels):
            ap.error(f"--batch must be a multiple of N x --round-parcels for N={n}")
    if not require_profile("amdahl-py"):  # a number without a profile is not publishable
        return 2
    a.report_dir.mkdir(parents=True, exist_ok=True)
    for mode in a.modes:
        opts = Options(
            batch=a.batch,
            round_parcels=a.round_parcels,
            phased=a.sync == "phased",
            parallel_iters=a.parallel_iters,
            lock_iters=LOCK_ITERS[mode] if a.lock_iters is None else a.lock_iters,
            reps=a.reps,
            warmup=a.warmup,
            calibration_runs=5,
            workers=tuple(a.workers),
            report_dir=a.report_dir,
            example=a.example,
        )
        run_mode(mode, opts)
    return 0
