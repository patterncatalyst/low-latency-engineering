"""``lowlat-report from-cyclictest``: cyclictest --json and --histfile to per-thread reports."""

import json
import math
from pathlib import Path

import pytest
from lowlat_measure.cli import main
from lowlat_measure.cyclictest import parse_cmdline

FIXTURES = Path(__file__).resolve().parents[2] / "measure-fixtures" / "cyclictest"
# Fixture ok.hist: bucket (us) -> count, per thread, copied from the file's rows.
THREADS = [
    {5: 400, 6: 300, 7: 200, 8: 90, 9: 9, 40: 1},
    {4: 600, 5: 300, 6: 80, 7: 19, 12: 1},
]
# Hand-worked: rank = round-half-up(p x N / 100) (at least 1) in the sorted samples.
EXPECTED = [
    {"p50": 6, "p90": 7, "p99": 8, "p99_9": 9, "max": 40},
    {"p50": 4, "p90": 5, "p99": 7, "p99_9": 7, "max": 12},
]
BANNED = ("avg", "mean", "average")


def _convert(tmp_path: Path, stem: str = "ok", *extra: str, cmdline: str | None = None) -> int:
    src = FIXTURES / f"{stem}.json"
    if cmdline is not None:
        data = json.loads(src.read_text(encoding="utf-8"))
        data["cmdline:"] = cmdline
        src = tmp_path / "in.json"
        src.write_text(json.dumps(data), encoding="utf-8")
    return main(
        ["from-cyclictest", str(src), str(FIXTURES / f"{stem}.hist"), str(tmp_path / "out"),
         "--example", "14-preempt-rt", *extra]
    )  # fmt: skip


def _reports(tmp_path: Path) -> list[dict]:
    return [
        json.loads(p.read_text(encoding="utf-8")) for p in sorted((tmp_path / "out").glob("*.json"))
    ]


def _us(report: dict) -> dict[str, int]:
    return {k: v // 1000 for k, v in report["percentiles"].items()}


def _keys(node: object) -> list[str]:
    if isinstance(node, dict):
        return [str(k) for k in node] + [k for v in node.values() for k in _keys(v)]
    if isinstance(node, list):
        return [k for v in node for k in _keys(v)]
    return []


def test_percentiles_from_known_buckets(lowlat_profile: Path, tmp_path: Path) -> None:
    assert _convert(tmp_path) == 0
    reports = _reports(tmp_path)
    assert [r["variant"] for r in reports] == ["cyclictest-t0", "cyclictest-t1"]
    assert [_us(r) for r in reports] == EXPECTED
    assert [r["count"] for r in reports] == [1000, 1000]
    assert reports[0]["runtime"]["counters"] == {"samples": 1000, "overflows": 0}
    assert "max is the worst of 1000 samples" in reports[0]["notes"]


@pytest.mark.parametrize("thread", [0, 1])
def test_recomputation_from_raw_buckets_matches(
    lowlat_profile: Path, tmp_path: Path, thread: int
) -> None:
    # Independent of the kit: expand every bucket to its samples and index the sorted list.
    samples = sorted(b for b, n in THREADS[thread].items() for _ in range(n))
    total = len(samples)

    def at(p: float) -> int:
        return samples[max(math.floor(p * total / 100 + 0.5), 1) - 1]

    assert _convert(tmp_path) == 0
    got = _us(_reports(tmp_path)[thread])
    assert got == {
        "p50": at(50),
        "p90": at(90),
        "p99": at(99),
        "p99_9": at(99.9),
        "max": samples[-1],
    }


def test_no_average_anywhere(lowlat_profile: Path, tmp_path: Path) -> None:
    source = json.loads((FIXTURES / "ok.json").read_text(encoding="utf-8"))
    assert "avg" in source["thread"]["0"]  # the input does carry one
    assert "Avg Latencies" in (FIXTURES / "ok.hist").read_text(encoding="utf-8")
    assert _convert(tmp_path) == 0
    for report in _reports(tmp_path):
        text = json.dumps({k: v for k, v in report.items() if k != "hdr_histogram"})
        assert not [k for k in _keys(report) if any(b in k.lower() for b in BANNED)]
        assert "6.12" not in text and "4.55" not in text


def test_nodename_and_cmdline_are_not_copied(lowlat_profile: Path, tmp_path: Path) -> None:
    assert _convert(tmp_path) == 0
    for report in _reports(tmp_path):
        text = json.dumps({k: v for k, v in report.items() if k != "profile"})
        assert "nodename" not in text and "guest-fixture" not in text
        assert "--histfile" not in text and 'realtime": 0' not in text


def test_overflow_fails_then_passes_with_allow(
    lowlat_profile: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert _convert(tmp_path, "overflow") == 1
    assert "overflow" in capsys.readouterr().err
    assert not (tmp_path / "out").exists()

    assert _convert(tmp_path, "overflow", "--allow-overflow") == 0
    first, second = _reports(tmp_path)
    assert "HISTOGRAM OVERFLOW: 3 samples" in first["notes"]
    assert first["runtime"]["counters"] == {"samples": 1003, "overflows": 3}
    assert "OVERFLOW" not in second["notes"]
    assert first["count"] == 1000


@pytest.mark.parametrize(
    ("args", "clock"),
    [
        ("--clock=monotonic", "monotonic"),
        ("-c 0", "monotonic"),
        ("-c monotonic", "monotonic"),
        ("-c0", "monotonic"),
        ("--clock realtime", "realtime"),
        ("-c 1", "realtime"),
        ("", "realtime"),  # absent: v2.11 uses CLOCK_REALTIME
    ],
)
def test_clock_forms(lowlat_profile: Path, tmp_path: Path, args: str, clock: str) -> None:
    cmdline = f"cyclictest -m -p 95 {args} -h 50 --histfile=h --json=o"
    assert parse_cmdline(cmdline).clock == clock
    assert _convert(tmp_path, cmdline=cmdline) == 0
    assert f"clock {clock};" in _reports(tmp_path)[0]["notes"]


def test_policy_priority_and_units() -> None:
    cmd = parse_cmdline("cyclictest -m -p95 --policy=rr -a 2 -N")
    assert (cmd.policy, cmd.priority, cmd.nsecs) == ("rr", 95, True)
    assert parse_cmdline("cyclictest -p 80").policy == "fifo"
    assert parse_cmdline("cyclictest").policy == "other"


def test_nanosecond_histogram_is_not_scaled(lowlat_profile: Path, tmp_path: Path) -> None:
    data = json.loads((FIXTURES / "ok.json").read_text(encoding="utf-8"))
    data["cmdline:"] += " -N"
    data["resolution_in_ns"] = 1
    src = tmp_path / "ns.json"
    src.write_text(json.dumps(data), encoding="utf-8")
    args = ["from-cyclictest", str(src), str(FIXTURES / "ok.hist"), str(tmp_path / "out")]
    assert main([*args, "--example", "x"]) == 0
    assert _reports(tmp_path)[0]["percentiles"]["p50"] == 6
    assert "buckets of 1 ns" in _reports(tmp_path)[0]["notes"]


def test_output_passes_check(lowlat_profile: Path, tmp_path: Path) -> None:
    assert (
        _convert(tmp_path, "overflow", "--allow-overflow", "--guest-profile", "lab-rt/isolated")
        == 0
    )
    files = [str(p) for p in sorted((tmp_path / "out").glob("*.json"))]
    assert main(["check", *files]) == 0
    assert _reports(tmp_path)[0]["runtime"]["environment"] == {
        "kind": "vm",
        "guest_profile": "lab-rt/isolated",
    }
