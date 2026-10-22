"""HdrHistogram recorder that writes a ``lowlat-report/1`` JSON report."""

import json
import math
import os
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from hdrh.histogram import HdrHistogram

from lowlat_measure.table import format_rows

LOWEST_DISCERNIBLE_NS = 1
HIGHEST_TRACKABLE_NS = 3_600_000_000_000  # one hour
SIGNIFICANT_DIGITS = 3

PROFILE_ENV = "LOWLAT_PROFILE"
SCHEMA_ID = "lowlat-report/1"
LANGUAGE = "python"

# Report key -> percentile passed to the library.
PERCENTILES: dict[str, float] = {"p50": 50, "p90": 90, "p99": 99, "p99_9": 99.9}


def new_histogram() -> HdrHistogram:
    """An empty histogram with the parameters every kit shares."""
    return HdrHistogram(LOWEST_DISCERNIBLE_NS, HIGHEST_TRACKABLE_NS, SIGNIFICANT_DIGITS)


def decode(b64: str) -> HdrHistogram:
    """Decode a report's ``hdr_histogram`` (compressed V2, base64) into a histogram."""
    return HdrHistogram.decode(b64)


def percentiles_of(hist: HdrHistogram, language: str = LANGUAGE) -> dict[str, int]:
    """The five report percentiles, taken from the library, as `language`'s kit reports them.

    The HdrHistogram ports disagree on the rank behind a percentile: C (0.12.1) and
    Python (0.10.8) round p*N/100 half up, Java (2.2.2) rounds it up (ceil, after
    nudging the percentile down by one ulp). With dense data both ranks fall in one
    bucket; in a sparse tail they can be a bucket apart. For a Java report, ask the
    library for the percentile whose half-up rank equals Java's ceil rank, so the
    check reproduces what the Java kit emitted without re-implementing the lookup.
    """
    total = hist.get_total_count()
    values = {}
    for key, p in PERCENTILES.items():
        if language == "java" and total:
            rank = max(math.ceil(math.nextafter(p, -math.inf) * total / 100), 1)
            p = 100 * rank / total
        values[key] = int(hist.get_value_at_percentile(p))
    values["max"] = int(hist.get_max_value())
    return values


def load_profile() -> dict[str, Any]:
    """Read the machine profile named by ``LOWLAT_PROFILE``; fail clearly if unset."""
    name = os.environ.get(PROFILE_ENV)
    if not name:
        raise RuntimeError(
            f"{PROFILE_ENV} is not set: a number without a machine profile is not "
            "publishable. Run scripts/profile.sh --out FILE and export "
            f"{PROFILE_ENV}=FILE."
        )
    path = Path(name)
    if not path.is_file():
        raise RuntimeError(f"{PROFILE_ENV}={name} does not name a readable file")
    return json.loads(path.read_text(encoding="utf-8"))


def require_profile(prog: str) -> bool:
    """Check the machine profile before a run; on failure print ``prog: reason`` to stderr.

    A CLI ``main`` returns exit code 2 when this is false, so a run fails before it
    measures anything rather than after.
    """
    try:
        load_profile()
    except RuntimeError as exc:
        print(f"{prog}: {exc}", file=sys.stderr)
        return False
    return True


class Recorder:
    """Records latencies in nanoseconds and reports percentiles, never a mean."""

    def __init__(self, example: str, variant: str) -> None:
        self.example = example
        self.variant = variant
        self.dropped = 0
        self.histogram = new_histogram()

    def record(self, latency_ns: int, count: int = 1) -> None:
        """Record ``latency_ns`` ``count`` times."""
        self.histogram.record_value(latency_ns, count)

    def record_corrected(self, latency_ns: int, expected_interval_ns: int) -> None:
        """Record and back-fill the samples a stalled sender failed to take."""
        self.histogram.record_corrected_value(latency_ns, expected_interval_ns)

    def add_dropped(self, n: int) -> None:
        self.dropped += n

    def percentiles(self) -> dict[str, int]:
        return percentiles_of(self.histogram)

    def build_report(
        self,
        notes: str | None = None,
        model: Mapping[str, Any] | None = None,
        *,
        language: str = LANGUAGE,
        build: Mapping[str, Any] | None = None,
        runtime: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """The ``lowlat-report/1`` document. ``model`` is the optional ``model`` block and
        ``runtime`` the optional ``runtime`` block (GC, JIT, AOT, context switches).

        ``language`` and ``build`` are for a report that speaks for another language than
        this kit (converted harness output); the percentiles then follow that language's
        HdrHistogram rank convention.
        """
        report: dict[str, Any] = {
            "schema": SCHEMA_ID,
            "example": self.example,
            "language": language,
            "variant": self.variant,
            "unit": "ns",
            "count": int(self.histogram.get_total_count()),
            "dropped": self.dropped,
            "percentiles": percentiles_of(self.histogram, language),
            "hdr_histogram": self.histogram.encode().decode("ascii"),
            "build": dict(build)
            if build is not None
            else {"compiler": sys.version, "gil_enabled": sys._is_gil_enabled()},
            "profile": load_profile(),
        }
        if notes:
            report["notes"] = notes
        if model:
            report["model"] = dict(model)
        if runtime:
            report["runtime"] = dict(runtime)
        return report

    def write_report(
        self,
        path: str | Path,
        notes: str | None = None,
        model: Mapping[str, Any] | None = None,
        *,
        language: str = LANGUAGE,
        build: Mapping[str, Any] | None = None,
        runtime: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        report = self.build_report(
            notes, model, language=language, build=build, runtime=runtime
        )
        Path(path).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        return report

    def print_summary(self) -> None:
        print(format_rows([self.build_report()]))
