"""The per-tick due sweep in Python: a list of objects against array columns (observed).

``fat-record`` walks a list of ``@dataclass(slots=True)`` records; ``hot-cold`` walks an
``array('Q')`` of due ticks and a ``bytearray`` of states. The columns are compact (9 bytes a
slot), but iterating them in Python still builds an ``int`` object for every element, so the
layout does not carry over the way it does in C++ and Java: the lever in Python is fewer
objects, not tighter ones.
"""

import time
from array import array

from lowlat_locality.records import (
    DIVERT_TICKS,
    IN_FLIGHT,
    ParcelRecord,
    keys,
    make_record,
    scan_of,
)


def build_objects(parcels: int) -> list[ParcelRecord]:
    return [make_record(scan_of(k, i), k) for i, k in enumerate(keys(parcels))]


def build_columns(parcels: int) -> tuple[array, bytearray]:
    due = array("Q", (i + DIVERT_TICKS for i in range(parcels)))
    state = bytearray([IN_FLIGHT]) * parcels
    return due, state


def sweep_objects(rows: list[ParcelRecord], tick: int) -> int:
    return sum(1 for r in rows if r.state == IN_FLIGHT and r.due_tick <= tick)


def sweep_columns(due: array, state: bytearray, tick: int) -> int:
    return sum(1 for d, s in zip(due, state, strict=True) if s == IN_FLIGHT and d <= tick)


def time_sweeps(variant: str, parcels: int, samples: int) -> list[int]:
    """Nanoseconds of ``samples`` sweeps (after three untimed ones) of the named variant."""
    tick = parcels // 2
    if variant == "fat-record":
        rows = build_objects(parcels)

        def run() -> int:
            return sweep_objects(rows, tick)

    else:
        due, state = build_columns(parcels)

        def run() -> int:
            return sweep_columns(due, state, tick)

    expected = tick - DIVERT_TICKS + 1
    for _ in range(3):
        if run() != expected:
            raise RuntimeError("the sweep counted the wrong number of due parcels")
    out = []
    for _ in range(samples):
        t0 = time.perf_counter_ns()
        run()
        out.append(time.perf_counter_ns() - t0)
    return out
