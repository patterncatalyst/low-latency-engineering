"""Measurement kit tests: correction, golden fixture, schema, CLI, cross-language."""

from __future__ import annotations

import json
import time
from pathlib import Path

import pytest
from lowlat_measure import Recorder, decode
from lowlat_measure.cli import main

COMMON = Path(__file__).resolve().parents[2]
FIXTURES = COMMON / "measure-fixtures"
INVALID_MEAN = (
    Path(__file__).resolve().parents[4] / "contracts/measurement/examples/invalid-mean.json"
)
MS = 1_000_000


@pytest.fixture
def profile(monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("LOWLAT_PROFILE", str(FIXTURES / "profile.json"))
    return FIXTURES / "profile.json"


def test_correction(profile: Path) -> None:
    corrected = Recorder("correction", "corrected")
    plain = Recorder("correction", "plain")
    for _ in range(1000):
        corrected.record(MS)
        plain.record(MS)
    corrected.record_corrected(1_000 * MS, MS)
    plain.record(1_000 * MS)

    assert corrected.histogram.get_total_count() == 2000
    assert corrected.percentiles()["p99"] > MS
    assert plain.histogram.values_are_equivalent(plain.percentiles()["p99"], MS)


def test_profile_required(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.delenv("LOWLAT_PROFILE", raising=False)
    rec = Recorder("x", "y")
    rec.record(1000)
    with pytest.raises(RuntimeError, match="LOWLAT_PROFILE"):
        rec.write_report(tmp_path / "r.json")


def test_golden_fixture(golden_report: Path, capsys: pytest.CaptureFixture[str]) -> None:
    report = json.loads(golden_report.read_text(encoding="utf-8"))
    assert report["count"] == 10_000
    assert decode(report["hdr_histogram"]).get_total_count() == 10_000
    assert main(["validate", str(golden_report)]) == 0
    assert main(["check", str(golden_report)]) == 0


def test_print_summary(profile: Path, capsys: pytest.CaptureFixture[str]) -> None:
    rec = Recorder("measure-fixtures", "golden")
    rec.record(1000)
    rec.print_summary()
    assert "measure-fixtures" in capsys.readouterr().out


def test_schema_rejects_mean(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["validate", str(INVALID_MEAN)]) == 1
    assert "mean" in capsys.readouterr().err


def test_check_detects_tampering(profile: Path, tmp_path: Path) -> None:
    rec = Recorder("t", "v")
    for i in range(1, 1001):
        rec.record(i * 1000)
    report = rec.write_report(tmp_path / "ok.json")
    report["percentiles"]["p99"] *= 2
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps(report), encoding="utf-8")
    assert main(["check", str(bad)]) == 1


def test_show_table(golden_report: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["show", str(golden_report)]) == 0
    out = capsys.readouterr().out
    assert out.splitlines()[0].split() == [
        "example", "language", "variant", "count", "dropped",
        "p50", "p90", "p99", "p99.9", "max",
    ]  # fmt: skip
    assert "mean" not in out


@pytest.mark.parametrize("language", ["cpp", "java"])
def test_cross_language(language: str, golden_report: Path) -> None:
    other = FIXTURES / f"{language}-golden.json"
    if not other.exists():
        pytest.skip(f"{other.name} not present yet")
    assert main(["check", str(golden_report), str(other)]) == 0


def test_record_cost(profile: Path) -> None:
    rec = Recorder("cost", "record")
    n = 100_000
    t0 = time.perf_counter_ns()
    for i in range(n):
        rec.record(1000 + i)
    per_call = (time.perf_counter_ns() - t0) / n
    print(f"\nRecorder.record cost: {per_call:.0f} ns per call over {n} records")
