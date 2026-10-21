"""HdrHistogram recorder that writes a ``lowlat-report/1`` JSON report."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

from hdrh.histogram import HdrHistogram

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


def percentiles_of(hist: HdrHistogram) -> dict[str, int]:
    """The five report percentiles, taken from the library."""
    values = {key: int(hist.get_value_at_percentile(p)) for key, p in PERCENTILES.items()}
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


class Recorder:
    """Records latencies in nanoseconds and reports percentiles, never a mean."""

    def __init__(self, example: str, variant: str) -> None:
        self.example = example
        self.variant = variant
        self.dropped = 0
        self.histogram = new_histogram()

    def record(self, latency_ns: int) -> None:
        self.histogram.record_value(latency_ns)

    def record_corrected(self, latency_ns: int, expected_interval_ns: int) -> None:
        """Record and back-fill the samples a stalled sender failed to take."""
        self.histogram.record_corrected_value(latency_ns, expected_interval_ns)

    def add_dropped(self, n: int) -> None:
        self.dropped += n

    def percentiles(self) -> dict[str, int]:
        return percentiles_of(self.histogram)

    def build_report(self) -> dict[str, Any]:
        return {
            "schema": SCHEMA_ID,
            "example": self.example,
            "language": LANGUAGE,
            "variant": self.variant,
            "unit": "ns",
            "count": int(self.histogram.get_total_count()),
            "dropped": self.dropped,
            "percentiles": self.percentiles(),
            "hdr_histogram": self.histogram.encode().decode("ascii"),
            "build": {"compiler": sys.version, "gil_enabled": sys._is_gil_enabled()},
            "profile": load_profile(),
        }

    def write_report(self, path: str | Path) -> dict[str, Any]:
        report = self.build_report()
        Path(path).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        return report

    def print_summary(self) -> None:
        from lowlat_measure.table import format_rows

        print(format_rows([self.build_report()]))
