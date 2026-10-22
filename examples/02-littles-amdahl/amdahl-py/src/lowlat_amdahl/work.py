"""The per-parcel work: a parallel part, then a serial update of the shared sort-plan table.

Plain Python: the parallel part is CPU-bound bytecode, which is what the GIL
serialises across threads and what processes run side by side.
"""

import time
from collections.abc import MutableSequence
from contextlib import AbstractContextManager
from typing import Protocol

CELLS = 64
MASK64 = (1 << 64) - 1


def scan_work(parcel: int, iters: int) -> int:
    """Parallel part: a dependent integer mix keyed by the parcel number."""
    x = (parcel * 0x9E3779B97F4A7C15 + 1) & MASK64
    for _ in range(iters):
        x ^= x >> 29
        x = (x * 0xBF58476D1CE4E5B9) & MASK64
    return x


def update_plan(cell: MutableSequence[int], weight: int, iters: int) -> None:
    """Serial part, called with the lock held. Additions only, so the table is order-independent."""
    w = weight
    for j in range(iters):
        cell[(w >> 7) % CELLS] += (w & 0xFFFF) + j
        w = (w * 6364136223846793005 + 1442695040888963407) & MASK64


class Meeting(Protocol):
    """What the workers need of a barrier (``threading`` or ``multiprocessing``)."""

    def wait(self) -> int: ...


def process_share(
    cell: MutableSequence[int],
    lock: AbstractContextManager[object],
    wave: Meeting | None,
    batch: int,
    worker: int,
    workers: int,
    round_parcels: int,
    parallel_iters: int,
    lock_iters: int,
    *,
    timed: bool = False,
) -> int:
    """One worker's share of every wave; returns ns inside the lock when ``timed``.

    A wave is ``round_parcels`` parcels per worker: scan them all (parallel), meet at the barrier,
    commit them all under the lock (serial), meet again. The barriers make the serial part strictly
    serial, which is what Amdahl's formula assumes; ``wave=None`` runs without them.
    """
    in_lock_ns = 0
    span = workers * round_parcels
    for base in range(0, batch, span):
        weights = [
            scan_work(base + worker + j * workers, parallel_iters) for j in range(round_parcels)
        ]
        if wave is not None:
            wave.wait()  # nobody commits while anyone is still scanning
        for weight in weights:
            with lock:
                if timed:
                    t0 = time.perf_counter_ns()
                    update_plan(cell, weight, lock_iters)
                    in_lock_ns += time.perf_counter_ns() - t0
                else:
                    update_plan(cell, weight, lock_iters)
        if wave is not None:
            wave.wait()  # nobody scans the next wave while anyone is still committing
    return in_lock_ns
