"""Convert a raw nanosecond sample file to a ``lowlat-report/1`` report.

A free-threaded CPython process must not import this package: the HdrHistogram C extension
re-enables the GIL on import, which is the thing under test. The measured process therefore
writes its samples with ``array('q', samples).tofile(f)`` (little-endian signed 64-bit
nanoseconds on every platform the lab runs on) plus a small JSON sidecar, and a GIL process
converts them here (``lowlat-report from-samples``).

The sidecar holds the report metadata and nothing measured: ``example``, ``variant``, ``count``
(must equal the number of samples), ``dropped``, and optionally ``language`` (default
``python``), ``notes``, ``model``, ``build`` (default: this interpreter's ``sys.version`` with the
sidecar's ``gil_enabled``) and ``runtime`` (for example ``python_build`` and ``environment``).
The percentiles come from the same recorder as every other report, so the same samples give the
same percentiles and histogram as recording them in-process.
"""

import json
import sys
from array import array
from pathlib import Path
from typing import Any

from lowlat_measure.recorder import Recorder

SAMPLE_BYTES = 8
_REQUIRED = ("example", "variant", "count")
_ALLOWED = {*_REQUIRED, "language", "dropped", "notes", "model", "build", "runtime", "gil_enabled"}


def read_samples(path: Path) -> array:
    """Load a raw little-endian int64 nanosecond file; reject a torn or negative file."""
    data = path.read_bytes()
    if len(data) % SAMPLE_BYTES:
        raise ValueError(f"{path}: {len(data)} bytes is not a whole number of int64 samples")
    samples = array("q")
    samples.frombytes(data)
    if sys.byteorder == "big":
        samples.byteswap()
    if samples and min(samples) < 0:
        raise ValueError(f"{path}: negative sample {min(samples)}")
    return samples


def read_sidecar(path: Path) -> dict[str, Any]:
    side = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(side, dict):
        raise ValueError(f"{path}: the sidecar must be a JSON object")
    missing = [k for k in _REQUIRED if k not in side]
    if missing:
        raise ValueError(f"{path}: missing {', '.join(missing)}")
    unknown = sorted(set(side) - _ALLOWED)
    if unknown:
        raise ValueError(f"{path}: unknown keys {', '.join(unknown)}")
    return side


def report_from_samples(samples_path: Path, sidecar_path: Path) -> dict[str, Any]:
    """The report for the samples and sidecar; ``LOWLAT_PROFILE`` supplies the profile."""
    samples = read_samples(samples_path)
    side = read_sidecar(sidecar_path)
    if side["count"] != len(samples):
        raise ValueError(f"sidecar count {side['count']} but {len(samples)} samples in the file")
    runtime = side.get("runtime")
    gil = side.get("gil_enabled")
    build = side.get("build")
    if build is None and gil is not None:
        build = {"compiler": sys.version, "gil_enabled": bool(gil)}
    if gil is False and runtime and runtime.get("python_build") == "gil":
        raise ValueError("gil_enabled is false but runtime.python_build is 'gil'")
    rec = Recorder(side["example"], side["variant"])
    for ns in samples:
        rec.record(ns)
    rec.add_dropped(int(side.get("dropped", 0)))
    return rec.build_report(
        side.get("notes"),
        side.get("model"),
        language=side.get("language", "python"),
        build=build,
        runtime=runtime,
    )


def write_report(samples_path: Path, sidecar_path: Path, out: Path) -> dict[str, Any]:
    report = report_from_samples(samples_path, sidecar_path)
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report
