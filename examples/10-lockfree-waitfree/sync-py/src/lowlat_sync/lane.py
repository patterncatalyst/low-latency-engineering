"""The claim measurement: four threads claim sequence numbers, each timing its own claim.

This module imports nothing that re-enables the GIL (no `lowlat_measure`: its `pyhdrh` C extension
does not declare free-threading support, so importing it turns the GIL back on). It writes the raw
samples and counters; `lowlat_sync.report` turns them into a `lowlat-report/1` report in the GIL
workspace environment. A free-threaded run is refused if the GIL is on at the start or at the end.
"""

import json
import sys
import sysconfig
import threading
import time
from array import array
from dataclasses import dataclass, field
from pathlib import Path

from lowlat_sync import gil_enabled, python_build
from lowlat_sync.claims import claim_for
from lowlat_sync.placement import Gate, ctx_switches, placement_of

RAW_NAME = "raw.json"
SAMPLES_NAME = "samples.bin"


@dataclass
class Run:
    variant: str
    racy: bool
    threads: int
    claims_per_thread: int
    cpus: list[int]
    samples: list[array] = field(default_factory=list)  # one array('q') of claim ns per thread
    claimed: int = 0  # claims the threads made
    distinct: int = 0  # distinct sequence numbers among them
    voluntary: int = 0
    involuntary: int = 0
    gil_at_start: bool = True
    gil_at_end: bool = True

    @property
    def lost_or_duplicated(self) -> int:
        """Sequence numbers in 0..N-1 nobody claimed (a duplicate claim leaves one unclaimed)."""
        return self.threads * self.claims_per_thread - self.distinct


def run(
    variant: str,
    *,
    racy: bool = False,
    threads: int = 4,
    claims_per_thread: int = 100_000,
    cpus: list[int] | None = None,
    hold_ms: int = 0,
    announce: bool = True,
) -> Run:
    """One measurement. The claimer of `seq` marks `bitmap[seq]`; the map is read after join()."""
    pins = cpus if cpus is not None else [-1] * threads
    claim = claim_for(variant, racy=racy).claim
    total = threads * claims_per_thread
    bitmap = bytearray(total)
    result = Run(variant, racy, threads, claims_per_thread, [c for c in pins if c >= 0])
    result.samples = [array("q") for _ in range(threads)]
    gate = Gate(threads, hold_ms, announce=announce)
    switches: list[tuple[int, int]] = [(0, 0)] * threads
    failures: list[BaseException] = []

    def worker(index: int) -> None:
        try:
            gate.worker_ready(pins[index], f"claimer-{index}")
            samples = result.samples[index]
            before = ctx_switches()
            clock = time.perf_counter_ns
            for _ in range(claims_per_thread):
                t0 = clock()
                seq = claim()
                samples.append(clock() - t0)
                bitmap[seq] = 1
            after = ctx_switches()
            switches[index] = (after[0] - before[0], after[1] - before[1])
        except BaseException as exc:  # reported by the coordinator after join()
            failures.append(exc)

    pool = [threading.Thread(target=worker, args=(i,), name=f"claimer-{i}") for i in range(threads)]
    result.gil_at_start = gil_enabled()
    for t in pool:
        t.start()
    gate.release()
    for t in pool:
        t.join()
    result.gil_at_end = gil_enabled()
    if failures:
        raise RuntimeError("a claimer failed") from failures[0]
    result.claimed = sum(len(s) for s in result.samples)
    result.distinct = bitmap.count(1)
    result.voluntary = sum(v for v, _ in switches)
    result.involuntary = sum(i for _, i in switches)
    return result


def write_raw(result: Run, out: Path) -> None:
    """Raw samples (little-endian int64, thread after thread) and the facts the report needs."""
    out.mkdir(parents=True, exist_ok=True)
    with (out / SAMPLES_NAME).open("wb") as fh:
        for samples in result.samples:
            if sys.byteorder == "big":
                samples = array("q", samples)
                samples.byteswap()
            samples.tofile(fh)
    meta = {
        "variant": result.variant,
        "racy_claim": result.racy,
        "threads": result.threads,
        "claims_per_thread": result.claims_per_thread,
        "claims": result.claimed,
        "lost_or_duplicated_claims": result.lost_or_duplicated,
        "voluntary_ctx_switches": result.voluntary,
        "involuntary_ctx_switches": result.involuntary,
        "python_build": python_build(),
        "gil_at_start": result.gil_at_start,
        "gil_at_end": result.gil_at_end,
        "python_version": sys.version.replace("\n", " "),
        "switch_interval_ms": sys.getswitchinterval() * 1000,
        "cpus": result.cpus,
        "placement": placement_of(result.cpus) if result.cpus else None,
        "free_threading_configured": bool(sysconfig.get_config_var("Py_GIL_DISABLED")),
    }
    (out / RAW_NAME).write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
