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

from jsonschema import Draft202012Validator, ValidationError, validators

from lowlat_measure.recorder import HIGHEST_TRACKABLE_NS, Recorder

SAMPLE_BYTES = 8
_REQUIRED = ("example", "variant", "count", "build")


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


def _checker() -> Any:
    """Draft 2020-12 types, but ``integer`` means an int: not a boolean and not ``1.0``."""
    return Draft202012Validator.TYPE_CHECKER.redefine(
        "integer", lambda _checker, value: isinstance(value, int) and not isinstance(value, bool)
    )


_NON_BLANK = {"type": "string", "pattern": r"\S", "description": "a non-empty string"}
_OBJECT = {"type": "object", "description": "a JSON object"}

#: The sidecar's structure: types, required keys and the allowed top-level keys. The rules that
#: relate fields (the GIL claims) stay in ``read_sidecar``. A ``description`` ends "must be ...".
_SIDECAR_SCHEMA: dict[str, Any] = {
    "type": "object",
    "description": "a JSON object",
    "required": list(_REQUIRED),
    "additionalProperties": False,
    "properties": {
        "example": _NON_BLANK,
        "variant": _NON_BLANK,
        "language": _NON_BLANK,
        "count": {"type": "integer", "minimum": 1, "description": "an integer of at least 1"},
        "dropped": {"type": "integer", "minimum": 0, "description": "a non-negative integer"},
        "notes": {"type": "string", "description": "a string"},
        "model": _OBJECT,
        "runtime": _OBJECT,
        "gil_enabled": {"type": "boolean", "description": "a boolean"},
        "build": {
            **_OBJECT,
            "required": ["compiler", "gil_enabled"],
            "properties": {
                "compiler": {
                    "type": "string",
                    "pattern": r"\S",
                    "description": "a non-empty string (the measured process's sys.version)",
                },
                "gil_enabled": {
                    "type": "boolean",
                    "description": "a boolean written by the measured process",
                },
            },
        },
    },
}
_VALIDATOR = validators.extend(Draft202012Validator, type_checker=_checker())(_SIDECAR_SCHEMA)


def _describe(error: ValidationError, path: Path) -> str:
    """One schema error as a specific sentence naming the field and what it must be."""
    where = ".".join(str(part) for part in error.absolute_path)
    if error.validator == "required":
        missing = [k for k in error.validator_value if k not in error.instance]
        if not where:
            return f"{path}: missing {', '.join(missing)}"
        return f"sidecar {', '.join(f'{where}.{k}' for k in missing)} is required"
    if error.validator == "additionalProperties":
        known = error.schema.get("properties", {})
        return f"{path}: unknown keys {', '.join(sorted(set(error.instance) - set(known)))}"
    if not where:
        return f"{path}: the sidecar must be {error.schema['description']}"
    return f"sidecar {where} must be {error.schema.get('description', error.message)}"


def read_sidecar(path: Path) -> dict[str, Any]:
    """Load and check the sidecar; raise ``ValueError`` for anything off."""
    side = json.loads(path.read_text(encoding="utf-8"))
    errors = sorted(_VALIDATOR.iter_errors(side), key=lambda e: [str(p) for p in e.absolute_path])
    if errors:
        raise ValueError("; ".join(_describe(error, path) for error in errors))
    build = side["build"]
    if "gil_enabled" in side and side["gil_enabled"] != build["gil_enabled"]:
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
