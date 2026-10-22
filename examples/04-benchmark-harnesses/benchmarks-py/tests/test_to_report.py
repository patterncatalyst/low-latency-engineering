"""bench-to-report writes percentiles that `lowlat-report check` reproduces."""

from pathlib import Path

import pytest
from lowlat_bench.to_report import from_jmh
from lowlat_measure.cli import main as lowlat_report

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.mark.usefixtures("lowlat_profile")
def test_jmh_reports_use_the_java_rank_convention(tmp_path: Path) -> None:
    # Real JMH SampleTime output whose sparse p99.9 sits where the half-up rank
    # (C, Python) and Java's ceil rank fall one bucket apart (r01, run 1).
    reports = from_jmh(FIXTURES / "jmh-sparse-tail.json", tmp_path)
    assert reports
    assert lowlat_report(["check", *map(str, reports)]) == 0
