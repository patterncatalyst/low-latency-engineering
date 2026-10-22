"""Measurement kit tests: correction, golden fixture, schema, CLI, cross-language."""

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
EXAMPLES = Path(__file__).resolve().parents[4] / "contracts/measurement/examples"
MS = 1_000_000


def test_correction(lowlat_profile: Path) -> None:
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


def test_golden_fixture(golden_report: Path) -> None:
    report = json.loads(golden_report.read_text(encoding="utf-8"))
    assert report["count"] == 10_000
    assert decode(report["hdr_histogram"]).get_total_count() == 10_000
    assert main(["validate", str(golden_report)]) == 0
    assert main(["check", str(golden_report)]) == 0


def test_print_summary(lowlat_profile: Path, capsys: pytest.CaptureFixture[str]) -> None:
    rec = Recorder("measure-fixtures", "golden")
    rec.record(1000)
    rec.print_summary()
    assert "measure-fixtures" in capsys.readouterr().out


def test_schema_rejects_mean(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["validate", str(INVALID_MEAN)]) == 1
    assert "mean" in capsys.readouterr().err


def test_check_detects_tampering(lowlat_profile: Path, tmp_path: Path) -> None:
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
    assert main(["check", "--same-dataset", str(golden_report), str(other)]) == 0


def test_different_workloads_are_not_cross_compared(
    golden_report: Path, lowlat_profile: Path, tmp_path: Path
) -> None:
    report = json.loads(golden_report.read_text(encoding="utf-8"))
    rec = Recorder(report["example"], report["variant"])
    for v in (5_000, 6_000, 7_000):
        rec.record(v)
    other = tmp_path / "java-like.json"
    rec.write_report(other)
    assert main(["check", str(golden_report), str(other)]) == 0
    assert main(["check", "--same-dataset", str(golden_report), str(other)]) == 1


def test_record_cost(lowlat_profile: Path, capsys: pytest.CaptureFixture[str]) -> None:
    rec = Recorder("cost", "record")
    n = 100_000
    t0 = time.perf_counter_ns()
    for i in range(n):
        rec.record(1000 + i)
    per_call = (time.perf_counter_ns() - t0) / n
    with capsys.disabled():
        print(f"\nRecorder.record cost: {per_call:.0f} ns per call over {n} records")
    assert per_call < 100_000  # a loose bound: a call costs microseconds, not 100 us


def test_java_rank_convention_sparse_tail() -> None:
    # Real Java-kit output with a back-filled sparse tail (03-coordinated-omission):
    # Java rounds the percentile rank up, C and Python round half up, so the half-up
    # recomputation lands one bucket lower. `check` must use the report's own convention.
    report = FIXTURES / "java-sparse-tail.json"
    assert main(["check", str(report)]) == 0


def test_model_block_only_when_given(lowlat_profile: Path, tmp_path: Path) -> None:
    rec = Recorder("t", "v")
    rec.record(1000)
    assert "model" not in rec.build_report()
    assert "model" not in rec.build_report("n", {})
    model = {"law": "Little: L = lambda * W", "W_mean_seconds_modelling_input": 0.25}
    out = tmp_path / "m.json"
    report = rec.write_report(out, model=model)
    assert report["model"] == model
    assert "notes" not in report
    assert json.loads(out.read_text(encoding="utf-8")) == report
    assert main(["validate", str(out)]) == 0
    plain = tmp_path / "p.json"
    rec.write_report(plain)
    assert "model" not in json.loads(plain.read_text(encoding="utf-8"))


def test_runtime_block_validates_and_checks(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["check", str(EXAMPLES / "valid-runtime.json")]) == 0


def test_runtime_block_rejects_mean(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["check", str(EXAMPLES / "invalid-runtime-mean.json")]) == 1
    assert "pause_mean_ns" in capsys.readouterr().err


@pytest.mark.parametrize(
    "key",
    [
        "mean",
        "mean_ns",
        "pause_mean",
        "pause_mean_ns",
        "mean_compile_ns",
        "avg",
        "avg_ns",
        "pause_avg_ns",
        "average",
        "average_ns",
        "meanNs",
        "avgNs",
        "pauseMeanNs",
        "MEAN_NS",
        "Mean",
        "avgns",
    ],
)
def test_runtime_rejects_mean_anywhere(
    lowlat_profile: Path, tmp_path: Path, key: str, capsys: pytest.CaptureFixture[str]
) -> None:
    rec = Recorder("t", "v")
    rec.record(1000)
    for runtime in ({key: 1}, {"jit": {"steady": {key: 1}}}, {"gc": {key: 1}}):
        out = tmp_path / "bad.json"
        rec.write_report(out, runtime=runtime)
        assert main(["check", str(out)]) == 1
    capsys.readouterr()


def test_runtime_only_when_given(lowlat_profile: Path, tmp_path: Path) -> None:
    rec = Recorder("t", "v")
    rec.record(1000)
    assert "runtime" not in rec.build_report()
    assert "runtime" not in rec.build_report(runtime={})
    runtime = {
        "gc": {"name": "G1", "collectors": ["G1 Young Generation"]},
        "alloc_bytes_per_parcel": 48.5,
    }
    out = tmp_path / "r.json"
    report = rec.write_report(out, runtime=runtime)
    assert list(report)[-1] == "runtime"
    assert json.loads(out.read_text(encoding="utf-8"))["runtime"] == runtime
    assert main(["check", str(out)]) == 0


@pytest.mark.parametrize("name", ["invalid-runtime-avg.json", "invalid-runtime-camel.json"])
def test_runtime_rejects_average_fixtures(name: str, capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["check", str(EXAMPLES / name)]) == 1
    assert capsys.readouterr().err


@pytest.mark.parametrize(
    "key",
    [
        "p50_ns",
        "max_ns",
        "count",
        "compilations",
        "alloc_bytes_per_parcel",
        "first-1000",
        "meaning",
        "averted",
        "pause_p99_ns",
    ],
)
def test_runtime_accepts_legitimate_keys(lowlat_profile: Path, tmp_path: Path, key: str) -> None:
    rec = Recorder("t", "v")
    rec.record(1000)
    out = tmp_path / "ok.json"
    rec.write_report(out, runtime={"jit": {"steady": {key: 1}}})
    assert main(["check", str(out)]) == 0
