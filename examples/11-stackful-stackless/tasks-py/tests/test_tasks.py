"""The deterministic parts of the Ch11 Python lane, under both interpreter builds.

GIL (default workspace run):  uv run pytest 11-stackful-stackless/tasks-py
free-threaded:                LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft \
                                uv run --python 3.14t --all-packages pytest <this package>
Nothing is pinned, so no particular host is needed.
"""

import json
import os
import subprocess
import sys
from array import array
from pathlib import Path

import pytest
from lowlat_tasks import gil_enabled, python_build, sidecar, workloads
from lowlat_tasks.cli import main as cli_main
from lowlat_tasks.placement import parse_cpus
from lowlat_tasks.procinfo import kib, memory


def test_python_build_is_one_of_the_two_builds() -> None:
    assert python_build() in {"gil", "free-threaded"}
    if python_build() == "gil":
        assert gil_enabled()


@pytest.mark.skipif(
    os.environ.get("LOWLAT_EXPECT_FREE_THREADED") != "1",
    reason="set LOWLAT_EXPECT_FREE_THREADED=1 when running under python3.14t",
)
def test_free_threaded_build_was_requested() -> None:
    assert sys._is_gil_enabled() is False
    assert gil_enabled() is False
    assert python_build() == "free-threaded"


def test_cpu_lists_parse() -> None:
    assert parse_cpus("2,5,9") == [2, 5, 9]
    for bad in ("", "2,x", "-1"):
        with pytest.raises(ValueError):
            parse_cpus(bad)


def test_proc_files_parse() -> None:
    assert kib("/proc/self/status", "VmRSS") > 0
    assert kib("/proc/self/status", "NoSuchKey") == 0
    assert memory().rss_kib > 0


@pytest.mark.parametrize("variant", workloads.VARIANTS)
def test_parked_tasks_all_arrive_and_wake(variant: str) -> None:
    run = (
        workloads.parked_threads(40, 40, announce=False)
        if variant == "threads"
        else workloads.parked_asyncio(40, 40, announce=False)
    )
    assert len(run.samples) == 40
    assert run.counters["tasks_armed"] == 40
    assert run.counters["rss_parked_kib"] > 0
    assert min(run.samples) >= 1
    if variant == "asyncio-tasks":
        assert run.counters["tracemalloc_bytes_per_task"] > 0


@pytest.mark.parametrize("variant", workloads.VARIANTS)
def test_pingpong_serves_every_round_trip_and_keeps_the_payload(variant: str) -> None:
    run = (
        workloads.pingpong_threads(2000, 100, warmup_batches=2, announce=False)
        if variant == "threads"
        else workloads.pingpong_asyncio(2000, 100, warmup_batches=2, announce=False)
    )
    assert len(run.samples) == 20
    assert run.counters["round_trips_served"] == 2200
    assert run.counters["payload_mismatch"] == 0


def test_asyncio_neighbours_report_slow_callbacks_in_debug_mode() -> None:
    run = workloads.neighbours_asyncio(
        20, 20, 2000, blocking=True, debug=True, slow_callback_ms=1.0, announce=False
    )
    assert len(run.samples) == 400
    assert run.counters["blocking_calls"] == 2
    # Each time.sleep(2 ms) in a coroutine makes a task step longer than 1 ms: asyncio logs it.
    assert run.counters["slow_callback_warnings"] >= 2
    quiet = workloads.neighbours_asyncio(20, 20, 2000, blocking=False, debug=True, announce=False)
    assert quiet.counters["blocking_calls"] == 0
    assert any(s >= 1_000_000 for s in run.samples)  # some neighbour woke at least 1 ms late


def test_samples_are_little_endian_int64(tmp_path: Path) -> None:
    samples = array("q", [1, 2, 3_000_000_000])
    path = tmp_path / "samples.bin"
    sidecar.write_samples(samples, path)
    assert path.read_bytes() == b"".join(v.to_bytes(8, "little", signed=True) for v in samples)


def test_sidecar_carries_what_the_converter_requires(tmp_path: Path) -> None:
    run = workloads.Run(samples=array("q", [5, 6, 7]), counters={"tasks": 3}, cpus=[], notes="unit")
    out = tmp_path / "out"
    samples_path, sidecar_path = sidecar.write(out, run, "threads", gil_at_start=gil_enabled())
    side = json.loads(sidecar_path.read_text(encoding="utf-8"))
    assert side["count"] == 3 == samples_path.stat().st_size // 8
    assert side["variant"] == "threads"
    assert side["build"]["compiler"] == sys.version.replace("\n", " ")
    assert side["build"]["gil_enabled"] is gil_enabled()
    assert side["runtime"]["python_build"] == python_build()
    assert side["runtime"]["counters"] == {"tasks": 3}
    assert "gil_at_end=" in side["notes"]


def test_gil_process_converts_the_samples(tmp_path: Path, lowlat_profile: Path) -> None:
    """The conversion runs in its own process, as in verify.sh; only it imports lowlat_measure."""
    run = workloads.Run(samples=array("q", [100, 200, 300]), counters={"tasks": 3}, notes="unit")
    samples_path, sidecar_path = sidecar.write(
        tmp_path / "raw", run, "threads", gil_at_start=gil_enabled()
    )
    report = tmp_path / "report.json"
    done = subprocess.run(
        [
            sys.executable,
            "-m",
            "lowlat_measure",
            "from-samples",
            str(samples_path),
            str(sidecar_path),
            str(report),
        ],
        env={**os.environ, "LOWLAT_PROFILE": str(lowlat_profile)},
        capture_output=True,
        text=True,
        check=False,
    )
    assert done.returncode == 0, done.stderr
    loaded = json.loads(report.read_text(encoding="utf-8"))
    assert loaded["count"] == 3
    assert loaded["runtime"]["python_build"] == python_build()


def test_cli_rejects_an_unknown_variant(tmp_path: Path) -> None:
    rc = cli_main(["measure", "parked", "--variant", "greenlets", "--out", str(tmp_path)])
    assert rc == 2
