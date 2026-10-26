"""verify.sh in RECHECK mode against a synthetic results tree (tests/fakerun.py): the host-side
half of the S9 smoke.

Nothing here touches libvirt or a guest. The tree holds real converter output for synthetic
samples, so what is exercised is verify.sh's own reading: the criteria, the table, and that a
defect in a result is reported.
"""

import gzip
import json
import math
import os
import shutil
import subprocess
from pathlib import Path

import pytest
from fakerun import build_run

HERE = Path(__file__).resolve().parent
VERIFY = HERE.parent / "verify.sh"

pytestmark = pytest.mark.skipif(
    shutil.which("jq") is None or shutil.which("uv") is None, reason="jq and uv are needed"
)


def verify(root: Path, **env: str) -> subprocess.CompletedProcess[str]:
    full = {k: v for k, v in os.environ.items() if k not in ("RECHECK", "VM", "SMOKE")}
    full.update({"NO_COLOR": "1", "RECHECK": str(root), **env})
    return subprocess.run(
        [str(VERIFY)], capture_output=True, text=True, check=False, env=full, timeout=300
    )


def patch(path: Path, change) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))
    change(data)
    path.write_text(json.dumps(data), encoding="utf-8")


@pytest.fixture(scope="module")
def run_dir(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return build_run(tmp_path_factory.mktemp("run"))


def fresh(tmp_path: Path, run_dir: Path) -> Path:
    copy = tmp_path / "run"
    shutil.copytree(run_dir, copy)
    return copy


def test_a_clean_run_passes(run_dir: Path) -> None:
    done = verify(run_dir)
    assert done.returncode == 0, done.stdout + done.stderr
    assert "every criterion holds" in done.stdout
    assert "| id | kind | criterion | measured | bound | result |" in done.stdout
    assert "naive against method" in done.stdout
    assert "haltpoll-forced against idle-default" in done.stdout


def test_no_average_is_printed(run_dir: Path) -> None:
    out = verify(run_dir).stdout.lower()
    assert " avg" not in out and "average" not in out and "mean" not in out


def test_too_few_samples_fail(tmp_path: Path, run_dir: Path) -> None:
    root = fresh(tmp_path, run_dir)
    patch(
        root / "vm/method/alt2/cyclictest.json",
        lambda d: d["runtime"]["counters"].update(samples=250_000),
    )
    done = verify(root)
    assert done.returncode != 0
    assert "alt2 method samples" in done.stdout + done.stderr


def test_an_overflow_fails(tmp_path: Path, run_dir: Path) -> None:
    root = fresh(tmp_path, run_dir)
    patch(
        root / "vm/method/alt1/cyclictest.json",
        lambda d: d["runtime"]["counters"].update(overflows=2),
    )
    done = verify(root)
    assert done.returncode != 0
    assert "histogram overflow" in done.stdout + done.stderr


def test_naive_that_ran_fifo_fails(tmp_path: Path, run_dir: Path) -> None:
    root = fresh(tmp_path, run_dir)
    patch(
        root / "vm/naive/alt3/sched.json", lambda d: d[1].update(policy="SCHED_FIFO", priority=95)
    )
    done = verify(root)
    assert done.returncode != 0
    assert "naive tasks not SCHED_OTHER" in done.stdout + done.stderr


def test_method_not_on_cpu_3_fails(tmp_path: Path, run_dir: Path) -> None:
    root = fresh(tmp_path, run_dir)
    patch(root / "vm/method/alt1/sched.json", lambda d: d[1].update(affinity="0-3"))
    assert verify(root).returncode != 0


def test_probe_three_times_slower_fails_unless_observed(tmp_path: Path) -> None:
    root = build_run(tmp_path / "slow", probe_mu=1.8 + math.log(3))
    done = verify(root)
    assert done.returncode != 0
    assert "probe p99 against cyclictest p99" in done.stdout + done.stderr
    observed = verify(root, CRIT3_ASSERTED="0")
    assert observed.returncode == 0, observed.stdout + observed.stderr
    assert "observed, bound not met" in observed.stdout


def test_a_changed_percentile_fails_the_recomputation(tmp_path: Path, run_dir: Path) -> None:
    root = fresh(tmp_path, run_dir)
    patch(
        root / "vm/idle-default/alt2/cyclictest.json",
        lambda d: d["percentiles"].update(p99_9=d["percentiles"]["p99_9"] + 1000),
    )
    done = verify(root)
    assert done.returncode != 0
    assert "differs from the recomputation" in done.stdout + done.stderr


def test_a_tampered_histfile_fails_the_recomputation(tmp_path: Path, run_dir: Path) -> None:
    root = fresh(tmp_path, run_dir)
    path = root / "vm/method/alt1/cyclictest.hist.gz"
    text = gzip.open(path, "rt", encoding="utf-8").read().replace("000010 ", "000010 9", 1)
    with gzip.open(path, "wt", encoding="utf-8") as fh:
        fh.write(text)
    assert verify(root).returncode != 0


def test_a_different_binary_in_one_lane_fails(tmp_path: Path, run_dir: Path) -> None:
    root = fresh(tmp_path, run_dir)
    patch(root / "vm/timerlat/alt1/lane.json", lambda d: d["binaries"][0].update(sha256="e" * 64))
    assert verify(root).returncode != 0


def test_a_wrong_idle_driver_fails(tmp_path: Path, run_dir: Path) -> None:
    root = fresh(tmp_path, run_dir)
    patch(
        root / "vm/haltpoll-forced/alt1/cpuidle.json", lambda d: d["before"].update(driver="none")
    )
    assert verify(root).returncode != 0


def test_a_missing_file_is_named(tmp_path: Path, run_dir: Path) -> None:
    root = fresh(tmp_path, run_dir)
    (root / "vm/method/alt1/cpp/cyclic-probe.json").unlink()
    done = verify(root)
    assert done.returncode != 0
    assert "vm/method/alt1/cpp/cyclic-probe.json" in done.stderr


def test_plain_run_without_results_says_what_to_do(tmp_path: Path) -> None:
    env = {k: v for k, v in os.environ.items() if k not in ("RECHECK", "VM")}
    env["RESULTS_DIR"] = str(tmp_path / "nothing")
    done = subprocess.run(
        [str(VERIFY)], capture_output=True, text=True, check=False, env=env, timeout=60
    )
    assert done.returncode == 2
    assert "VM=1 ./verify.sh" in done.stderr and "RECHECK=" in done.stderr
