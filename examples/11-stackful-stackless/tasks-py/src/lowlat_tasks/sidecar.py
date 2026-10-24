"""The raw sample file and its sidecar: what a free-threaded measuring process writes.

`lowlat_measure` imports `pyhdrh`, which re-enables the GIL under a free-threaded interpreter, so
the measuring process writes `array('q').tofile` samples (little-endian int64 nanoseconds) and a
JSON sidecar carrying the report metadata. A GIL process turns them into a report with
`lowlat-report from-samples`. The sidecar holds the facts of the measured process itself:
`build.compiler` is its `sys.version` and `build.gil_enabled` its `sys._is_gil_enabled()` at the
end of the run.
"""

import json
import sys
from array import array
from pathlib import Path
from typing import Any

from lowlat_tasks import EXAMPLE, gil_enabled, python_build
from lowlat_tasks.placement import placement_of
from lowlat_tasks.workloads import Run

SAMPLES_NAME = "samples.bin"
SIDECAR_NAME = "sidecar.json"


def write_samples(samples: array, path: Path) -> None:
    """Little-endian int64 nanoseconds, the layout `lowlat-report from-samples` reads."""
    out = array("q", samples)
    if sys.byteorder == "big":
        out.byteswap()
    with path.open("wb") as fh:
        out.tofile(fh)


def sidecar_for(run: Run, variant: str, *, gil_at_start: bool) -> dict[str, Any]:
    """The sidecar for `run`: the keys `from-samples` requires, python_build and the placement."""
    runtime: dict[str, Any] = {"python_build": python_build()}
    if run.cpus:
        runtime["placement"] = placement_of(run.cpus)
    if run.counters:
        runtime["counters"] = dict(run.counters)
    if run.voluntary or run.involuntary:
        runtime["ctx_switches"] = {"voluntary": run.voluntary, "involuntary": run.involuntary}
    gil = f"gil_at_start={str(gil_at_start).lower()}; gil_at_end={str(gil_enabled()).lower()}"
    notes = f"{run.notes}; {gil}"
    return {
        "example": EXAMPLE,
        "variant": variant,
        "count": len(run.samples),
        "dropped": 0,
        "notes": notes,
        "build": {"compiler": sys.version.replace("\n", " "), "gil_enabled": gil_enabled()},
        "runtime": runtime,
    }


def write(out: Path, run: Run, variant: str, *, gil_at_start: bool) -> tuple[Path, Path]:
    """Writes samples.bin and sidecar.json into `out`; returns their paths."""
    out.mkdir(parents=True, exist_ok=True)
    samples_path, sidecar_path = out / SAMPLES_NAME, out / SIDECAR_NAME
    write_samples(run.samples, samples_path)
    sidecar_path.write_text(
        json.dumps(sidecar_for(run, variant, gil_at_start=gil_at_start), indent=2) + "\n",
        encoding="utf-8",
    )
    return samples_path, sidecar_path
