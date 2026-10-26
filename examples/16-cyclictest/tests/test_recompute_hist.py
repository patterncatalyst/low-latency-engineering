"""The independent recomputation of a cyclictest report's percentiles (check/recompute_hist.py),
against the converter (``lowlat-report from-cyclictest``) on the committed fixtures and on a
run-sized synthetic histogram.

Host only: no guest, no libvirt. The recomputation shares no code with the kit; what must hold
is that the two agree exactly, and that a report that was changed afterwards is caught.
"""

import gzip
import importlib.util
import json
import random
import subprocess
import sys
from pathlib import Path

import pytest
from lowlat_measure.cli import main

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "check" / "recompute_hist.py"
FIXTURES = HERE.parents[1] / "common" / "measure-fixtures" / "cyclictest"

_spec = importlib.util.spec_from_file_location("recompute_hist", SCRIPT)
assert _spec and _spec.loader
recompute = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(recompute)


def convert(tmp_path: Path, json_path: Path, hist: Path, *extra: str) -> list[Path]:
    out = tmp_path / "out"
    assert (
        main(
            [
                "from-cyclictest",
                str(json_path),
                str(hist),
                str(out),
                "--example",
                "16-cyclictest",
                *extra,
            ]
        )
        == 0
    )
    return sorted(out.glob("*.json"))


def run_script(hist: Path, report: Path, *extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(hist), str(report), *extra],
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize("thread", [0, 1])
def test_fixture_matches_converter(lowlat_profile: Path, tmp_path: Path, thread: int) -> None:
    reports = convert(tmp_path, FIXTURES / "ok.json", FIXTURES / "ok.hist")
    done = run_script(FIXTURES / "ok.hist", reports[thread], str(thread))
    assert done.returncode == 0, done.stdout + done.stderr
    assert json.loads(done.stdout)["recomputed"]["count"] == 1000


def test_overflow_fixture_matches_when_the_converter_records_overflows_at_the_maximum(
    lowlat_profile: Path, tmp_path: Path
) -> None:
    reports = convert(
        tmp_path, FIXTURES / "overflow.json", FIXTURES / "overflow.hist", "--allow-overflow"
    )
    done = run_script(FIXTURES / "overflow.hist", reports[0])
    assert done.returncode == 0, done.stdout + done.stderr


def run_sized_histogram(tmp_path: Path, seed: int) -> tuple[Path, Path]:
    """A 300 s, 1 ms run: ~300,000 samples, a tail out to 19,999 us, one thread, -h 20000."""
    rng = random.Random(seed)
    counts: dict[int, int] = {}
    for _ in range(299_950):
        bucket = int(rng.lognormvariate(1.8, 0.35))
        counts[bucket] = counts.get(bucket, 0) + 1
    for bucket in (301, 777, 1500, 5000, 12345, 19_999):  # a sparse tail, as host stalls make it
        counts[bucket] = counts.get(bucket, 0) + 8
    counts = {b: c for b, c in counts.items() if c}
    cycles = sum(counts.values())
    top = max(counts)
    rows = "".join(f"{b:06d} {counts.get(b, 0):06d}\n" for b in range(20_001))
    hist = tmp_path / "ct.hist"
    hist.write_text(
        "# Histogram\n" + rows + f"# Min Latencies: {min(counts):05d}\n# Max Latencies: {top:05d}\n"
        "# Histogram Overflows: 00000\n# Histogram Overflow at cycle number:\n# Thread 0: \n",
        encoding="utf-8",
    )
    meta = {
        "file_version": 1,
        "cmdline:": (
            "cyclictest -m -p95 --policy=fifo -a3 -i 1000 -D 300 -h 20000 --clock=monotonic -q"
        ),
        "rt_test_version:": "2.11",
        "return_code": 0,
        "num_threads": 1,
        "resolution_in_ns": 0,
        "thread": {
            "0": {
                "cycles": cycles,
                "cpu": 3,
                "node": 0,
                "histogram": {str(b): c for b, c in counts.items()},
            }
        },
    }
    source = tmp_path / "ct.json"
    source.write_text(json.dumps(meta), encoding="utf-8")
    return source, hist


@pytest.mark.parametrize("seed", [1, 2, 3])
def test_run_sized_histogram_matches_converter(
    lowlat_profile: Path, tmp_path: Path, seed: int
) -> None:
    source, hist = run_sized_histogram(tmp_path, seed)
    (report,) = convert(tmp_path, source, hist)
    done = run_script(hist, report)
    assert done.returncode == 0, done.stdout + done.stderr
    got = json.loads(done.stdout)["recomputed"]
    # Above 262 us the report holds the top of an HdrHistogram bucket, never below the bucket edge.
    assert got["max"] >= 19_999_000 and got["count"] > 299_000


def test_gzipped_histogram_is_read(lowlat_profile: Path, tmp_path: Path) -> None:
    source, hist = run_sized_histogram(tmp_path, 4)
    (report,) = convert(tmp_path, source, hist)
    packed = tmp_path / "ct.hist.gz"
    with gzip.open(packed, "wt", encoding="utf-8") as fh:
        fh.write(hist.read_text(encoding="utf-8"))
    assert run_script(packed, report).returncode == 0


def test_a_changed_report_is_caught(lowlat_profile: Path, tmp_path: Path) -> None:
    reports = convert(tmp_path, FIXTURES / "ok.json", FIXTURES / "ok.hist")
    data = json.loads(reports[0].read_text(encoding="utf-8"))
    data["percentiles"]["p99"] += 1000
    reports[0].write_text(json.dumps(data), encoding="utf-8")
    done = run_script(FIXTURES / "ok.hist", reports[0])
    assert done.returncode == 1
    assert "recomputed" in done.stdout


def test_a_missing_file_is_a_usage_error(tmp_path: Path) -> None:
    assert run_script(tmp_path / "none.hist", tmp_path / "none.json").returncode == 2


def test_equivalent_top_matches_the_documented_example() -> None:
    assert recompute.equivalent_top(5_000_000) == 5_000_031  # a 5000 us bucket reads 5000031 ns
    assert recompute.equivalent_top(262_143) == 262_143  # exact below 262,144 ns
    assert recompute.equivalent_top(6_000) == 6_000
