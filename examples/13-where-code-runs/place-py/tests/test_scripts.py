"""Checks on the Ch13 lane scripts that need no VM, no Docker and no build: syntax and dry runs."""

import os
import subprocess
from pathlib import Path

import pytest

EXAMPLE = Path(__file__).resolve().parents[2]
VM = EXAMPLE / "vm"
SCRIPTS = {
    "bash": [
        EXAMPLE / "verify.sh",
        EXAMPLE / "lanes.sh",
        VM / "run.sh",
        VM / "guest-run.sh",
        VM / "local-shell.sh",
    ],
    "sh": [VM / "lane-cpp.sh", VM / "service-lane.sh"],
}


@pytest.mark.parametrize(
    ("shell", "script"),
    [(s, p) for s, ps in SCRIPTS.items() for p in ps],
    ids=lambda v: getattr(v, "name", v),
)
def test_script_parses(shell: str, script: Path) -> None:
    subprocess.run([shell, "-n", str(script)], check=True)


def dry_run(*args: str) -> str:
    env = {**os.environ, "DRY_RUN": "1", "SMOKE": "1"}
    return subprocess.run(
        [str(VM / "guest-run.sh"), *args], env=env, check=True, capture_output=True, text=True
    ).stdout


@pytest.mark.parametrize(
    ("lane", "expected"),
    [
        ("container-host-net", "--network host"),
        ("container-bridge", "--mode consumer"),
        ("container-cpu-quota", "--cpus 2"),
        ("container-cpuset", "--cpuset-cpus 2\\,3"),
    ],
)
def test_container_lanes_go_through_container_run(lane: str, expected: str) -> None:
    out = dry_run("lane", lane, "1")
    assert "container_run" in out
    assert expected in out
    assert "docker run" not in out
    assert "--privileged" not in out


def test_limit_lanes_run_the_pool_and_the_service() -> None:
    out = dry_run("lane", "container-cpu-quota", "1")
    assert "--pool" in out
    assert "service-lane.sh" in out


def test_the_bridge_lane_runs_its_simulators_in_the_guest() -> None:
    out = dry_run("lane", "container-bridge", "1")
    assert "--mode sims" in out


def test_an_unknown_lane_is_refused() -> None:
    result = subprocess.run(
        [str(VM / "guest-run.sh"), "lane", "host", "1"],
        env={**os.environ, "DRY_RUN": "1"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
