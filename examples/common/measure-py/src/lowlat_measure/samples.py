"""Convert a raw nanosecond sample file to a ``lowlat-report/1`` report.

A free-threaded CPython process must not import this package: the HdrHistogram C extension
re-enables the GIL on import, which is the thing under test. The measured process therefore
writes its samples with ``array('q', samples).tofile(f)`` (little-endian signed 64-bit
nanoseconds on every platform the lab runs on) plus a JSON sidecar, and a GIL process converts
them here (``lowlat-report from-samples``).

The sidecar holds the report metadata and nothing measured. Required: ``example``, ``variant``,
``count`` (must equal the number of samples) and ``build`` (``compiler``, the measured process's
own ``sys.version``, and ``gil_enabled``, its ``sys._is_gil_enabled()``, a real boolean): the
converter never fills these from itself, because it runs under the GIL and would write the wrong
fact. Optional: ``dropped`` (default 0), ``language`` (default ``python``), ``notes``, ``model``,
``runtime`` (for example ``python_build`` and ``environment``) and a top-level ``gil_enabled``
that must agree with ``build.gil_enabled``. A report claiming ``python_build`` ``free-threaded``
with ``gil_enabled`` true is rejected (the GIL came back), and so is the reverse. The percentiles
come from the same recorder as every other report; the caller validates the result against the
schema before writing it.
"""

import json
import sys
from array import array
from pathlib import Path
from typing import Any

from lowlat_measure.recorder import HIGHEST_TRACKABLE_NS, Recorder

SAMPLE_BYTES = 8
_REQUIRED = ("example", "variant", "count", "build")
_ALLOWED = {*_REQUIRED, "language", "dropped", "notes", "model", "build", "runtime", "gil_enabled"}


def read_samples(path: Path) -> array[int]:
    """Load a raw little-endian int64 nanosecond file.

    Rejects a torn file, a negative sample and one above the histogram's highest trackable value.
    """
    data = path.read_bytes()
    if len(data) % SAMPLE_BYTES:
        raise ValueError(f"{path}: {len(data)} bytes is not a whole number of int64 samples")
    samples = array("q")
    samples.frombytes(data)
    if sys.byteorder == "big":
        samples.byteswap()
    if samples and min(samples) < 0:
        raise ValueError(f"{path}: negative sample {min(samples)}")
    if samples and max(samples) > HIGHEST_TRACKABLE_NS:
        raise ValueError(
            f"{path}: sample {max(samples)} ns is above the highest trackable "
            f"value {HIGHEST_TRACKABLE_NS} ns"
        )
    return samples


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _text(side: dict[str, Any], key: str) -> str:
    value = side[key]
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"sidecar {key} must be a non-empty string")
    return value


def read_sidecar(path: Path) -> dict[str, Any]:
    """Load and type-check the sidecar; raise ``ValueError`` for anything off."""
    side = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(side, dict):
        raise ValueError(f"{path}: the sidecar must be a JSON object")
    missing = [k for k in _REQUIRED if k not in side]
    if missing:
        raise ValueError(f"{path}: missing {', '.join(missing)}")
    unknown = sorted(set(side) - _ALLOWED)
    if unknown:
        raise ValueError(f"{path}: unknown keys {', '.join(unknown)}")
    for key in ("example", "variant"):
        _text(side, key)
    if "language" in side:
        _text(side, "language")
    if not _is_int(side["count"]) or side["count"] < 1:
        raise ValueError("sidecar count must be an integer of at least 1")
    if "dropped" in side and (not _is_int(side["dropped"]) or side["dropped"] < 0):
        raise ValueError("sidecar dropped must be a non-negative integer")
    if "notes" in side and not isinstance(side["notes"], str):
        raise ValueError("sidecar notes must be a string")
    for key in ("model", "runtime", "build"):
        if key in side and not isinstance(side[key], dict):
            raise ValueError(f"sidecar {key} must be a JSON object")
    build = side["build"]
    if not isinstance(build.get("compiler"), str) or not build["compiler"].strip():
        raise ValueError("sidecar build.compiler (the measured process's sys.version) is required")
    if not isinstance(build.get("gil_enabled"), bool):
        raise ValueError(
            "sidecar build.gil_enabled must be a boolean written by the measured process"
        )
    if "gil_enabled" in side:
        if not isinstance(side["gil_enabled"], bool):
            raise ValueError("sidecar gil_enabled must be a boolean")
        if side["gil_enabled"] != build["gil_enabled"]:
            raise ValueError("sidecar gil_enabled conflicts with build.gil_enabled")
    pyb = side.get("runtime", {}).get("python_build")
    if pyb not in ("gil", "free-threaded"):
        raise ValueError("sidecar runtime.python_build ('gil' or 'free-threaded') is required")
    if pyb == "free-threaded" and build["gil_enabled"]:
        raise ValueError(
            "runtime.python_build is 'free-threaded' but gil_enabled is true: the GIL came back"
        )
    if pyb == "gil" and not build["gil_enabled"]:
        raise ValueError("runtime.python_build is 'gil' but gil_enabled is false")
    # "free-threaded" needs the interpreter's own version string to say free-threading. (The reverse
    # is already covered: a free-threading binary with the GIL off must say "free-threaded", or the
    # gil_enabled check above fails; with the GIL back on it legitimately reports "gil".)
    ft_string = "free-threading" in build["compiler"].lower()
    if pyb == "free-threaded" and not ft_string:
        raise ValueError(
            "runtime.python_build is 'free-threaded' but build.compiler is not a "
            "free-threading build"
        )
    return side


def report_from_samples(samples_path: Path, sidecar_path: Path) -> dict[str, Any]:
    """The report for the samples and sidecar; ``LOWLAT_PROFILE`` supplies the profile.

    Not yet schema-checked: ``lowlat-report from-samples`` validates it before writing.
    """
    samples = read_samples(samples_path)
    side = read_sidecar(sidecar_path)
    if side["count"] != len(samples):
        raise ValueError(f"sidecar count {side['count']} but {len(samples)} samples in the file")
    rec = Recorder(side["example"], side["variant"])
    for ns in samples:
        rec.record(ns)
    total = int(rec.histogram.get_total_count())
    if total != len(samples):
        raise ValueError(f"the histogram holds {total} of {len(samples)} samples")
    rec.add_dropped(side.get("dropped", 0))
    return rec.build_report(
        side.get("notes"),
        side.get("model"),
        language=side.get("language", "python"),
        build=side["build"],
        runtime=side.get("runtime"),
    )
