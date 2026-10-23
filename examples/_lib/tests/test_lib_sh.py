"""Tests for the placement and counter helpers in ``examples/_lib/lib.sh``.

The helpers read sysfs and /proc and drive ``perf`` and ``valgrind`` as an unprivileged user.
Tests that need a facility the machine lacks (SMT, four physical cores, a usable PMU, valgrind,
a C compiler) skip with the reason, so a CI container without a PMU stays green.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
LIB = HERE.parent / "lib.sh"
REPO = HERE.parents[2]
SYS_CPU = Path("/sys/devices/system/cpu")


def sh(script: str, *, cwd: Path | None = None, env: dict[str, str] | None = None):
    """Run a bash snippet with lib.sh sourced; return the CompletedProcess."""
    return subprocess.run(
        ["bash", "-c", f'. "{LIB}"\n{script}'],
        capture_output=True,
        text=True,
        cwd=cwd,
        env={**os.environ, "NO_COLOR": "1", **(env or {})},
        check=False,
    )


def core_id(cpu: int) -> tuple[str, str]:
    topo = SYS_CPU / f"cpu{cpu}" / "topology"
    return (topo / "physical_package_id").read_text().strip(), (
        topo / "core_id"
    ).read_text().strip()


def allowed_cpus() -> list[int]:
    return sorted(os.sched_getaffinity(0))


def physical_cores() -> int:
    try:
        return len({core_id(c) for c in allowed_cpus()})
    except OSError:
        return 0


# ---- distinct_cores, smt_pair, interleave ----------------------------------------------------


@pytest.mark.skipif(physical_cores() < 4, reason="fewer than 4 physical cores available")
def test_distinct_cores_prints_four_cpus_on_four_physical_cores() -> None:
    run = sh("distinct_cores 4")
    assert run.returncode == 0, run.stderr
    cpus = [int(x) for x in run.stdout.split()]
    assert len(cpus) == 4
    assert len({core_id(c) for c in cpus}) == 4, "two of the CPUs share a physical core"
    assert set(cpus) <= set(allowed_cpus())


@pytest.mark.parametrize("arg", ["100000", "0", "abc", "-1", ""])
def test_distinct_cores_rejects_bad_or_impossible_n_with_empty_stdout(arg: str) -> None:
    run = sh(f'distinct_cores "{arg}"')
    assert run.returncode != 0
    assert run.stdout == ""
    assert run.stderr


@pytest.mark.skipif(physical_cores() < 1, reason="no sysfs topology")
def test_smt_pair_prints_two_siblings_or_fails_when_smt_is_off() -> None:
    run = sh("smt_pair")
    cpus_with_siblings = [
        c for c in allowed_cpus() if sum(core_id(o) == core_id(c) for o in allowed_cpus()) > 1
    ]
    if not cpus_with_siblings:
        assert run.returncode != 0
        assert "SMT" in run.stderr
        return
    assert run.returncode == 0, run.stderr
    a, b = (int(x) for x in run.stdout.split())
    assert a != b
    assert core_id(a) == core_id(b)


def test_interleave_alternates_variants() -> None:
    run = sh("interleave 3 old new")
    assert run.stdout.split() == ["old", "new"] * 3
    assert sh("interleave 0 a").returncode != 0
    assert sh("interleave 2").returncode != 0


# ---- assert_placement ------------------------------------------------------------------------


def test_assert_placement_passes_for_a_pinned_thread_and_fails_otherwise() -> None:
    cpus = allowed_cpus()
    if len(cpus) < 2:
        pytest.skip("needs two CPUs")
    pinned, other = cpus[0], cpus[1]
    taskset = shutil.which("taskset")
    if not taskset:
        pytest.skip("taskset not installed")
    proc = subprocess.Popen([taskset, "-c", str(pinned), "sleep", "30"])
    try:
        # taskset execs sleep; wait until the process has been scheduled on its CPU.
        for _ in range(100):
            stat = Path(f"/proc/{proc.pid}/stat").read_text()
            if stat.rsplit(") ", 1)[1].split()[36] == str(pinned):
                break
            time.sleep(0.02)
        good = sh(f"assert_placement {proc.pid} {proc.pid} {pinned}")
        assert good.returncode == 0, good.stderr
        bad = sh(f"assert_placement {proc.pid} {proc.pid} {other}")
        assert bad.returncode != 0
        assert f"last ran on CPU {pinned}, expected CPU {other}" in bad.stderr
    finally:
        proc.kill()
        proc.wait()


# ---- perf_region and cachegrind_run ----------------------------------------------------------


@pytest.fixture(scope="session")
def region_prog(tmp_path_factory: pytest.TempPathFactory) -> Path:
    cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if not cc:
        pytest.skip("no C compiler")
    out = tmp_path_factory.mktemp("region") / "region_prog"
    subprocess.run([cc, "-O1", "-g", "-o", str(out), str(HERE / "region_prog.c")], check=True)
    return out


def perf_usable() -> bool:
    perf = shutil.which("perf")
    if not perf:
        return False
    probe = subprocess.run(
        [perf, "stat", "-x,", "-e", "L1-dcache-load-misses:u", "--", "true"],
        capture_output=True,
        text=True,
        check=False,
    )
    return (
        probe.returncode == 0 and re.search(r"^\d+,", probe.stderr + probe.stdout, re.M) is not None
    )


needs_perf = pytest.mark.skipif(
    not perf_usable(), reason="perf cannot count user-space events here"
)


def run_region(prog: Path, tmp: Path, name: str, outside: int, region: int, after: int = 0) -> dict:
    out = tmp / f"{name}.json"
    run = sh(f'perf_region "{out}" -- "{prog}" {outside} {region} {after}', cwd=tmp)
    assert run.returncode == 0, run.stdout + run.stderr
    return json.loads(out.read_text())


@needs_perf
def test_perf_region_counts_cache_misses_and_excludes_work_outside_the_region(
    region_prog: Path, tmp_path: Path
) -> None:
    region = 1_000_000
    quiet = run_region(region_prog, tmp_path, "quiet", 0, region)
    noisy = run_region(region_prog, tmp_path, "noisy", 8 * region, region, 8 * region)
    assert quiet["source"] == "perf"
    assert quiet["ops"] == region
    misses = quiet["per_op"]["L1-dcache-load-misses"]
    assert misses > 0.3, f"expected most accesses to miss L1, got {misses} per op"
    # Eight times as much work before and after the region must not move the count.
    outside_moved = abs(noisy["per_op"]["L1-dcache-load-misses"] - misses) / misses
    assert outside_moved < 0.10, (quiet["per_op"], noisy["per_op"])
    # The shape is runtime.hw_counters: no extra keys, no negative numbers.
    assert set(quiet) == {"source", "ops", "per_op"}
    assert all(v >= 0 for v in quiet["per_op"].values())


@needs_perf
def test_perf_region_takes_ops_from_the_environment(region_prog: Path, tmp_path: Path) -> None:
    out = tmp_path / "env.json"
    run = sh(
        f'LOWLAT_OPS=500000 perf_region "{out}" -- "{region_prog}" 0 500000',
        cwd=tmp_path,
    )
    assert run.returncode == 0, run.stderr
    assert json.loads(out.read_text())["ops"] == 500000


@needs_perf
def test_perf_region_without_ops_fails(tmp_path: Path) -> None:
    run = sh(f'perf_region "{tmp_path}/x.json" -- true', cwd=tmp_path)
    assert run.returncode != 0
    assert "ops unknown" in run.stderr


@pytest.mark.skipif(not shutil.which("valgrind"), reason="valgrind not installed")
def test_cachegrind_run_summarises_misses_deterministically_and_leaves_no_raw_files(
    region_prog: Path, tmp_path: Path
) -> None:
    results = []
    for n in (1, 2):
        out = tmp_path / f"cg{n}.json"
        cmd = f'cachegrind_run "{out}" -- "{region_prog}" 50000 20000'
        run = sh(f"CACHEGRIND_FUNCTION=region_work {cmd}", cwd=tmp_path)
        assert run.returncode == 0, run.stdout + run.stderr
        results.append(json.loads(out.read_text()))
    first = results[0]
    assert first["source"] == "cachegrind"
    assert first["ops"] == 20000
    assert first["totals"]["D1-read-misses"] > 10000
    assert first["totals"] == results[1]["totals"], "cachegrind counts should be deterministic"
    # CACHEGRIND_FUNCTION=region_work counts that function only: work in outside_work is excluded.
    out = tmp_path / "cg-no-outside.json"
    run = sh(
        f'CACHEGRIND_FUNCTION=region_work cachegrind_run "{out}" -- "{region_prog}" 0 20000',
        cwd=tmp_path,
    )
    assert run.returncode == 0, run.stdout + run.stderr
    assert json.loads(out.read_text())["totals"]["D-reads"] == first["totals"]["D-reads"]
    assert not list(tmp_path.glob("cachegrind.out.*"))


# ---- profile.sh ------------------------------------------------------------------------------


def test_profile_records_caches_topology_and_tool_versions_without_the_kernel_build() -> None:
    run = subprocess.run(
        [str(REPO / "scripts" / "profile.sh")], capture_output=True, text=True, check=True
    )
    profile = json.loads(run.stdout)
    perf = profile["tools"]["perf"]
    assert perf is None or re.fullmatch(r"\d+\.\d+", perf), perf
    valgrind = profile["tools"]["valgrind"]
    assert valgrind is None or re.fullmatch(r"\d+\.\d+(\.\d+)?", valgrind), valgrind
    if profile["cpu"]["caches"]:
        assert profile["cpu"]["caches"]["l1d"]["line_bytes"] > 0
    if profile["cpu"]["topology"]:
        assert {"cpu", "core_id"} <= set(profile["cpu"]["topology"][0])
    build = subprocess.run(
        ["uname", "-r"], capture_output=True, text=True, check=True
    ).stdout.strip()
    assert build not in run.stdout


# ---- interrupts ------------------------------------------------------------------------------


@needs_perf
@pytest.mark.parametrize("sig", ["INT", "TERM"])
@pytest.mark.parametrize("fn", ["perf_region", "cachegrind_run"])
def test_interrupted_runs_write_no_json_and_leave_no_temp_dir(
    fn: str, sig: str, tmp_path: Path
) -> None:
    if fn == "cachegrind_run" and not shutil.which("valgrind"):
        pytest.skip("valgrind not installed")
    tmpdir = tmp_path / "tmp"
    tmpdir.mkdir()
    out = tmp_path / "out.json"
    script = f'LOWLAT_OPS=1 {fn} "{out}" -- sleep 60'
    proc = subprocess.Popen(
        ["bash", "-c", f'. "{LIB}"\n{script}'],
        env={**os.environ, "TMPDIR": str(tmpdir), "NO_COLOR": "1"},
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(250):  # wait for the temp dir: the helper is then past its traps
            if any(tmpdir.glob("lowlat-*")):
                break
            time.sleep(0.02)
        time.sleep(0.5)  # let perf or valgrind start the sleeper
        # Signal the helper's subshell (the child of the outer bash), as Ctrl-C would reach it.
        children = subprocess.run(
            ["pgrep", "-P", str(proc.pid)], capture_output=True, text=True, check=False
        ).stdout.split()
        target = children[0] if children else str(proc.pid)
        os.kill(int(target), getattr(signal, f"SIG{sig}"))
        proc.wait(timeout=30)
    finally:
        if proc.poll() is None:
            proc.kill()
        try:
            os.killpg(proc.pid, signal.SIGKILL)  # the helper ran in its own session
        except ProcessLookupError:
            pass
    assert not out.exists()
    # valgrind's own vgdb pipes may remain after a hard kill; the helper's lowlat-* dir must not.
    leftovers = list(tmpdir.glob("lowlat-*"))
    assert not leftovers, leftovers
