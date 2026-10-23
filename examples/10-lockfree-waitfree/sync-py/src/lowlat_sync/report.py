"""Raw claim samples to a `lowlat-report/1` report. Runs in the GIL workspace environment only.

`lowlat_measure` imports `pyhdrh`, which re-enables the GIL under a free-threaded interpreter, so a
free-threaded measurement is recorded here, in a GIL process, from the raw file the measuring
process wrote. `runtime.python_build` comes from that raw file, never from this process.
"""

import json
from array import array
from pathlib import Path
from typing import Any

from lowlat_measure import Recorder, placement, runtime_block

from lowlat_sync.lane import RAW_NAME, SAMPLES_NAME

EXAMPLE = "10-lockfree-waitfree"


def build_report(raw_dir: Path, out: Path) -> dict[str, Any]:
    meta = json.loads((raw_dir / RAW_NAME).read_text(encoding="utf-8"))
    samples = array("q")
    with (raw_dir / SAMPLES_NAME).open("rb") as fh:
        samples.fromfile(fh, meta["claims"])
    recorder = Recorder(EXAMPLE, meta["variant"])
    for value in samples:
        recorder.record(max(1, value))
    pinned = None
    if meta["placement"]:
        pinned = placement(
            meta["placement"]["cpus"],
            distinct_cores=meta["placement"]["distinct_cores"],
            smt_siblings=meta["placement"]["smt_siblings"],
        )
    counters = {
        "claims": meta["claims"],
        "lost_or_duplicated_claims": meta["lost_or_duplicated_claims"],
    }
    runtime = runtime_block(
        pinned=pinned,
        event_counts=counters,
        build=meta["python_build"],
        ctx_switches={
            "voluntary": meta["voluntary_ctx_switches"],
            "involuntary": meta["involuntary_ctx_switches"],
        },
    )
    notes = (
        f"claim; threads={meta['threads']}; claims_per_thread={meta['claims_per_thread']}; "
        f"racy_claim={str(meta['racy_claim']).lower()}; "
        f"switch_interval_ms={meta['switch_interval_ms']:g}; "
        f"gil_at_start={str(meta['gil_at_start']).lower()}; "
        f"gil_at_end={str(meta['gil_at_end']).lower()}; "
        "claim time is time.perf_counter_ns around the claim only"
    )
    build = {"compiler": meta["python_version"], "gil_enabled": meta["gil_at_end"]}
    return recorder.write_report(out, notes, build=build, runtime=runtime)
