"""Five camera counters in shared memory, adjacent against padded (observed).

Python cannot place an object or pad a field, but it can lay out raw memory: a ``memoryview``
cast to ``'Q'`` over ``multiprocessing.shared_memory`` (or an anonymous ``mmap`` for threads) is
an array of 64-bit cells at known offsets from a page boundary. Each camera owns a read cell
and a no-read cell. ``adjacent-counters`` puts the five read cells side by side in the first
64-byte line (cells 0-4) and the five no-read cells in the next (cells 8-12); ``line-padded``
gives each camera a 64-byte line and ``pair-padded`` a 128-byte pair. The mapping is page-aligned,
so the lines are real.

* ``mode="processes"``: five processes, each pinned to its CPU with ``os.sched_setaffinity``,
  writing the shared cells. They run in parallel, so neighbouring cameras can ping-pong a line.
* ``mode="threads"``: five threads in one process. Under the GIL only one runs Python at a time,
  so there is nothing to false-share; the free-threaded build runs them in parallel and the same
  code can.

This module imports nothing from ``lowlat_measure``: importing the HdrHistogram C extension
re-enables the GIL in a free-threaded interpreter, so the measured process only records raw
batch times. ``cli`` turns the raw result into reports in a normal interpreter.
"""

import mmap
import multiprocessing as mp
import os
import sys
import threading
import time
from collections.abc import Callable
from multiprocessing import shared_memory
from pathlib import Path
from typing import Any

BATCH = 1_000
NO_READ_EVERY = 32
CAMERAS = 5
# Bytes between neighbouring cameras' read counters: 8 (one line holds all five), 64 or 128.
STRIDE_BYTES = {"adjacent-counters": 8, "line-padded": 64, "pair-padded": 128}
_NO_READ_CELL_OFFSET = {
    "adjacent-counters": 8,
    "line-padded": 1,
    "pair-padded": 1,
}  # cells after the read cell


def cells_of(layout: str, camera: int) -> tuple[int, int]:
    """Cell index (8 bytes each) of camera ``camera``'s read and no-read counters."""
    read = camera * STRIDE_BYTES[layout] // 8
    return read, read + _NO_READ_CELL_OFFSET[layout]


def _pattern(layout: str, camera: int) -> list[int]:
    """Cell index of each increment in a batch: the read cell, every 32nd one the no-read cell."""
    read, no_read = cells_of(layout, camera)
    return [no_read if i % NO_READ_EVERY == NO_READ_EVERY - 1 else read for i in range(BATCH)]


def _camera(
    cells: memoryview,
    camera: int,
    layout: str,
    cpu: int | None,
    batches: int,
    announce: Callable[[dict[str, Any]], None],
    go: Any,
) -> list[int]:
    if cpu is not None:
        os.sched_setaffinity(0, {cpu})  # pid 0 = the calling thread on Linux
    pattern = _pattern(layout, camera)
    announce({"camera": camera, "pid": os.getpid(), "tid": threading.get_native_id(), "cpu": cpu})
    go.wait()
    batch_ns = []
    perf_counter_ns = time.perf_counter_ns
    for _ in range(batches):
        t0 = perf_counter_ns()
        for idx in pattern:
            cells[idx] += 1
        batch_ns.append(perf_counter_ns() - t0)
    return batch_ns


def _process_main(
    name: str,
    camera: int,
    layout: str,
    cpu: int | None,
    batches: int,
    ready_q: Any,
    go: Any,
    done_q: Any,
    release: Any,
) -> None:
    shm = shared_memory.SharedMemory(name=name)
    cells = shm.buf.cast("Q")
    batch_ns = _camera(cells, camera, layout, cpu, batches, ready_q.put, go)
    done_q.put((camera, batch_ns))
    release.wait()  # parked, so the parent can read where this process last ran
    cells.release()
    shm.close()


def run(
    layout: str,
    mode: str,
    cpus: list[int] | None,
    batches: int,
    hold_ms: int = 0,
    cameras: int = CAMERAS,
) -> dict[str, Any]:
    """Run the cameras and return the raw result: batch times per camera and where each one ran."""
    stride = STRIDE_BYTES[layout]
    size = max(cells_of(layout, cameras - 1)) * 8 + 128
    cpu_of = [None] * cameras if cpus is None else cpus
    placements: list[dict[str, Any]] = []
    batch_ns: dict[int, list[int]] = {}

    if mode == "processes":
        ctx = mp.get_context("spawn")
        shm = shared_memory.SharedMemory(create=True, size=size)
        cells = shm.buf.cast("Q")
        ready_q, done_q = ctx.Queue(), ctx.Queue()
        go, release = ctx.Event(), ctx.Event()
        procs = [
            ctx.Process(
                target=_process_main,
                args=(shm.name, c, layout, cpu_of[c], batches, ready_q, go, done_q, release),
            )
            for c in range(cameras)
        ]
        for p in procs:
            p.start()
        placements = [ready_q.get() for _ in procs]
        go.set()
        for _ in procs:
            camera, ns = done_q.get()
            batch_ns[camera] = ns
        totals = [sum(cells[i] for i in cells_of(layout, c)) for c in range(cameras)]
        _announce(placements, pinned=cpus is not None)
        time.sleep(hold_ms / 1000)
        release.set()
        for p in procs:
            p.join()
        cells.release()
        shm.close()
        shm.unlink()
    elif mode == "threads":
        mm = mmap.mmap(-1, size)
        cells = memoryview(mm).cast("Q")
        # Two barriers of cameras + 1 parties (the cameras and this thread) replace polling.
        # The first opens once every camera has announced its placement, and is the start signal;
        # the second opens when every camera has stored its batch times. This thread sleeps
        # in both, so it never wakes during the run.
        go, finished = threading.Barrier(cameras + 1), threading.Barrier(cameras + 1)
        release = threading.Event()
        lock = threading.Lock()

        def announce(info: dict[str, Any]) -> None:
            with lock:
                placements.append(info)

        def worker(c: int) -> None:
            batch_ns[c] = _camera(cells, c, layout, cpu_of[c], batches, announce, go)
            finished.wait()
            release.wait()

        threads = [threading.Thread(target=worker, args=(c,)) for c in range(cameras)]
        for t in threads:
            t.start()
        go.wait()
        finished.wait()
        totals = [sum(cells[i] for i in cells_of(layout, c)) for c in range(cameras)]
        _announce(placements, pinned=cpus is not None)
        time.sleep(hold_ms / 1000)
        release.set()
        for t in threads:
            t.join()
        cells.release()
        mm.close()
    else:
        raise ValueError(f"mode must be processes or threads, got {mode}")

    expected = batches * BATCH
    lost = [c for c, t in enumerate(totals) if t != expected]
    if lost:
        raise RuntimeError(f"cameras {lost} lost increments: {totals} != {expected}")
    return {
        "layout": layout,
        "mode": mode,
        "stride_bytes": stride,
        "cameras": cameras,
        "batches": batches,
        "batch_size": BATCH,
        "cpus": [p["cpu"] for p in sorted(placements, key=lambda p: p["camera"])],
        "python": sys.version.split()[0],
        "gil_enabled": sys._is_gil_enabled(),
        "batch_ns": [batch_ns[c] for c in range(cameras)],
    }


def _announce(placements: list[dict[str, Any]], *, pinned: bool) -> None:
    """The placement lines verify.sh reads while the cameras are parked."""
    if not pinned:
        return
    for p in sorted(placements, key=lambda p: p["camera"]):
        announce_placement(p["pid"], p["tid"], p["cpu"], "camera")


def announce_placement(pid: int, tid: int, cpu: int, role: str) -> None:
    """Print a placement line and append it to ``LOWLAT_PLACEMENT_FILE`` (perf holds stdout)."""
    line = f"placement pid={pid} tid={tid} cpu={cpu} role={role}"
    print(line, flush=True)
    if path := os.environ.get("LOWLAT_PLACEMENT_FILE"):
        with Path(path).open("a", encoding="utf-8") as out:
            out.write(line + "\n")
