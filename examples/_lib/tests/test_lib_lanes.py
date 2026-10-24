"""Tests for the lab-guest, container, lane, strace and raw-sample helpers in ``lib.sh``.

Nothing here starts a VM or runs docker on the host. ``docker`` is a shim on PATH that logs its
arguments and answers from canned JSON; ``guest`` is redefined to run its command locally; the
vsock ssh wrapper is a shim named by LAB_SSH; ``virsh`` is a shim that lists chosen domains.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
LIB = HERE.parent / "lib.sh"
REPO = HERE.parents[2]
FIXTURES = REPO / "examples" / "common" / "measure-fixtures"

CID = "ab" * 32  # the fake container ID; it must never reach any output
IMG_ID = "sha256:" + "1" * 64
DIGEST = "sha256:" + "2" * 64
IMAGE = "registry.example/lowlat/app:1.2.3"

FAKE_DOCKER = r"""#!/usr/bin/env bash
# Fake docker: logs its arguments, answers from FAKE_* variables.
printf '%s\n' "$*" >>"$FAKE_DIR/docker.log"
cmd=$1
shift
[[ ${FAKE_FAIL:-} == "$cmd" ]] && { echo "boom: $cmd" >&2; exit 1; }
case $cmd in
  create) echo "$FAKE_CID" ;;
  start) echo "$2" ;;
  wait)
    sleep 0.3
    rm -rf "$FAKE_SCOPE"
    echo "${FAKE_EXIT:-0}"
    ;;
  logs)
    echo "container says hi from $FAKE_HOME_PATH"
    echo "container stderr line" >&2
    ;;
  rm) ;;
  image)
    printf '[{"Id":"%s","RepoDigests":["registry.example/lowlat/app@%s"]}]\n' \
      "$FAKE_IMG_ID" "$FAKE_DIGEST"
    ;;
  inspect)
    if [[ $1 == --format ]]; then echo "$FAKE_CID"; exit 0; fi
    printf '[{"Id":"%s","Image":"%s",' "$FAKE_CID" "$FAKE_IMG_ID"
    printf '"HostConfig":{"NetworkMode":"%s",' "${FAKE_NET:-default}"
    printf '"NanoCpus":%s,"CpusetCpus":"%s"}}]\n' "${FAKE_NANO:-0}" "${FAKE_CPUSET:-}"
    ;;
esac
"""

FAKE_VIRSH = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/virsh.log"
[[ $* == "-c qemu:///system list --name" ]] || exit 9
printf '%s\n' "${FAKE_DOMAINS:-}"
"""

FAKE_LAB_SSH = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/ssh.log"
shift # the target
cd "$HOME" || exit 1 # ssh starts in the guest home
exec bash -c "$*"
"""


@pytest.fixture
def env(tmp_path: Path) -> dict[str, str]:
    """A PATH with the fake docker and virsh, a fake cgroup tree, and a guest home."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in (("docker", FAKE_DOCKER), ("virsh", FAKE_VIRSH), ("lab-ssh", FAKE_LAB_SSH)):
        (bin_dir / name).write_text(body, encoding="utf-8")
        (bin_dir / name).chmod(0o755)
    scope = tmp_path / "cg" / "system.slice" / f"docker-{CID}.scope"
    scope.mkdir(parents=True)
    (scope / "cpu.max").write_text("150000 100000\n")
    (scope / "cpuset.cpus.effective").write_text("2-3\n")
    (scope / "cpu.stat").write_text(
        "usage_usec 99\nnr_periods 100\nnr_throttled 7\nthrottled_usec 12345\n"
    )
    home = tmp_path / "home"
    (home / "low-latency-engineering").mkdir(parents=True)
    return {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "NO_COLOR": "1",
        "FAKE_DIR": str(tmp_path),
        "FAKE_CID": CID,
        "FAKE_IMG_ID": IMG_ID,
        "FAKE_DIGEST": DIGEST,
        "FAKE_SCOPE": str(scope),
        "FAKE_HOME_PATH": f"/home/{os.environ.get('USER', 'nobody')}/work",
        "CGROUP_ROOT": str(tmp_path / "cg"),
        "CGROUP_POLL": "0.02",
        "CGROUP_WAIT": "2",
        "GUEST_PROFILE": "lab-ready-r04/stock-unpinned",
        "LOWLAT_IMAGES_LOCK": str(tmp_path / "absent.lock"),
        "LAB_SSH": str(bin_dir / "lab-ssh"),
        "HOME": str(home),
    }


def sh(script: str, env: dict[str, str], *, local_guest: bool = True):
    """Run a snippet with lib.sh sourced; ``guest`` runs its command locally unless told not to."""
    prelude = 'guest() { "$@"; }\n' if local_guest else ""
    return subprocess.run(
        ["bash", "-c", f'. "{LIB}"\n{prelude}{script}'],
        capture_output=True,
        text=True,
        env={**os.environ, **env},
        check=False,
    )


def calls(tmp_path: Path, name: str = "docker.log") -> list[str]:
    log = tmp_path / name
    return log.read_text().splitlines() if log.exists() else []


# ---- container_run ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "flags",
    [
        "--privileged",
        "--privileged=true",
        "--cap-add=ALL",
        "--cap-add ALL",
        "--security-opt seccomp=unconfined",
        "--security-opt=seccomp=unconfined",
        "--pid=host",
        "--pid host",
        "--cgroupns=host",
        "--rm",
        "-d",
    ],
)
def test_container_run_refuses_unsafe_flags_before_any_docker_call(
    env: dict[str, str], tmp_path: Path, flags: str
) -> None:
    run = sh(f"container_run t1 --env-out {tmp_path}/e.json {flags} -- {IMAGE}@{DIGEST} true", env)
    assert run.returncode != 0
    assert "refused" in run.stderr
    assert calls(tmp_path) == []
    assert not (tmp_path / "e.json").exists()


@pytest.mark.parametrize(
    ("image", "needle"),
    [
        ("registry.example/lowlat/app", "no tag"),
        ("registry.example/lowlat/app:latest", ":latest"),
        ("registry.example/lowlat/app:1@sha256:abc", "not name:tag"),
        ("registry.example:5000/lowlat/app", "no tag"),
    ],
)
def test_container_run_requires_a_pinned_image(
    env: dict[str, str], tmp_path: Path, image: str, needle: str
) -> None:
    run = sh(f"container_run t1 --env-out {tmp_path}/e.json -- {image} true", env)
    assert run.returncode != 0
    assert needle in run.stderr
    assert calls(tmp_path) == []


def test_container_run_needs_guest_profile_and_env_out(env: dict[str, str], tmp_path: Path) -> None:
    no_profile = {**env, "GUEST_PROFILE": ""}
    assert (
        "GUEST_PROFILE"
        in sh(f"container_run t1 --env-out {tmp_path}/e.json -- {IMAGE} x", no_profile).stderr
    )
    assert "--env-out" in sh(f"container_run t1 -- {IMAGE} x", env).stderr
    assert calls(tmp_path) == []


def test_container_run_records_the_merged_environment_and_hides_the_id(
    env: dict[str, str], tmp_path: Path
) -> None:
    run_env = {**env, "FAKE_NANO": "1500000000", "FAKE_CPUSET": "2,3", "FAKE_NET": "host"}
    out = tmp_path / "env.json"
    run = sh(
        f"container_run lowlat-t1 --env-out {out} --cpus 1.5 --cpuset-cpus 2,3 --network host"
        f" --security-opt seccomp=/x/y/profile.json -- {IMAGE}@{DIGEST} app --flag 'a b'",
        run_env,
    )
    assert run.returncode == 0, run.stderr
    assert json.loads(out.read_text()) == {
        "runtime": {
            "environment": {
                "kind": "container",
                "guest_profile": "lab-ready-r04/stock-unpinned",
                "container": {
                    "runtime": "docker",
                    "image": IMAGE,
                    "image_digest": DIGEST,
                    "network": "host",
                    "cpu_quota": "1.5",
                    "cpuset": "2,3",
                    "seccomp": "profile.json",
                },
                "cgroup": {
                    "cpu_max": "150000 100000",
                    "cpuset_effective": "2-3",
                    "nr_throttled": 7,
                    "throttled_usec": 12345,
                },
            }
        }
    }
    everything = run.stdout + run.stderr + out.read_text()
    assert CID not in everything
    assert "container says hi" in run.stdout
    assert f"/home/{os.environ.get('USER', 'nobody')}/" not in everything  # scrubbed
    log = calls(tmp_path)
    create = next(line for line in log if line.startswith("create"))
    assert "--name lowlat-t1 --cpus 1.5 --cpuset-cpus 2,3 --network host" in create
    assert create.endswith(f"{IMAGE}@{DIGEST} app --flag a b")
    assert [
        line.split()[0] for line in log if line.split()[0] in {"create", "start", "wait", "rm"}
    ] == [
        "create",
        "start",
        "wait",
        "rm",
    ]
    assert log[-1] == "rm -f lowlat-t1"


def test_container_run_defaults_are_null_bridge_and_default_seccomp(
    env: dict[str, str], tmp_path: Path
) -> None:
    out = tmp_path / "env.json"
    run = sh(f"container_run t2 --env-out {out} -- {IMAGE} app", env)
    assert run.returncode == 0, run.stderr
    block = json.loads(out.read_text())["runtime"]["environment"]
    assert block["container"] | {} == {
        "runtime": "docker",
        "image": IMAGE,
        "image_digest": IMG_ID,  # no digest given: the image ID the container ran
        "network": "bridge",
        "cpu_quota": None,
        "cpuset": None,
        "seccomp": "default",
    }


def test_container_run_returns_the_container_status_and_still_cleans_up(
    env: dict[str, str], tmp_path: Path
) -> None:
    out = tmp_path / "env.json"
    run = sh(f"container_run t3 --env-out {out} -- {IMAGE} app", {**env, "FAKE_EXIT": "7"})
    assert run.returncode == 7
    assert out.exists()
    assert calls(tmp_path)[-1] == "rm -f t3"


@pytest.mark.parametrize("fail", ["start", "wait", "inspect"])
def test_container_run_cleanup_trap_fires_on_failure(
    env: dict[str, str], tmp_path: Path, fail: str
) -> None:
    run = sh(
        f"container_run t4 --env-out {tmp_path}/e.json -- {IMAGE} app", {**env, "FAKE_FAIL": fail}
    )
    assert run.returncode != 0
    assert calls(tmp_path)[-1] == "rm -f t4"
    assert CID not in run.stdout + run.stderr
    assert not (tmp_path / "e.json").exists()
    assert not list(tmp_path.glob("lowlat-container.*"))


def test_container_run_does_not_remove_a_container_it_did_not_create(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = sh(
        f"container_run t5 --env-out {tmp_path}/e.json -- {IMAGE} app",
        {**env, "FAKE_FAIL": "create"},
    )
    assert run.returncode == 3
    assert not any(line.startswith("rm") for line in calls(tmp_path))


def test_container_run_cleanup_trap_fires_on_sigterm(env: dict[str, str], tmp_path: Path) -> None:
    proc = subprocess.Popen(
        [
            "bash",
            "-c",
            f'. "{LIB}"\nguest() {{ "$@"; }}\n'
            f"container_run t6 --env-out {tmp_path}/e.json -- {IMAGE} app",
        ],
        env={**os.environ, **env},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    for _ in range(100):
        if any(line.startswith("start") for line in calls(tmp_path)):
            break
        subprocess.run(["sleep", "0.01"], check=False)
    os.killpg(proc.pid, 15)
    proc.communicate(timeout=20)
    assert calls(tmp_path)[-1] == "rm -f t6"


def test_container_run_checks_images_lock_when_present(env: dict[str, str], tmp_path: Path) -> None:
    lock = tmp_path / "IMAGES.lock"
    base = {**env, "LOWLAT_IMAGES_LOCK": str(lock)}
    cmd = f"container_run t7 --env-out {tmp_path}/e.json -- "
    warn = sh(cmd + f"{IMAGE} app", env)  # lock absent: a warning, not an error
    assert warn.returncode == 0
    assert "warning: no IMAGES.lock" in warn.stderr

    lock.write_text("# images\nother.example/x:1 sha256:" + "3" * 64 + "\n")
    unlisted = sh(cmd + f"{IMAGE} app", base)
    assert unlisted.returncode != 0
    assert "not listed" in unlisted.stderr

    lock.write_text(f"# images\n{IMAGE}@{'sha256:' + '4' * 64}\n")
    wrong = sh(cmd + f"{IMAGE} app", base)  # lock digest 4.. but the guest ran 2..
    assert wrong.returncode != 0
    assert "is not sha256:" in wrong.stderr

    lock.write_text(f"{IMAGE}@{DIGEST}\n")
    good = sh(cmd + f"{IMAGE} app", base)
    assert good.returncode == 0, good.stderr
    assert (
        json.loads((tmp_path / "e.json").read_text())["runtime"]["environment"]["container"][
            "image_digest"
        ]
        == DIGEST
    )


def test_container_run_leaves_cgroup_nulls_when_the_cgroup_never_appears(
    env: dict[str, str], tmp_path: Path
) -> None:
    shutil.rmtree(env["FAKE_SCOPE"])
    out = tmp_path / "env.json"
    run = sh(f"container_run t8 --env-out {out} -- {IMAGE} app", env)
    assert run.returncode == 0, run.stderr
    cg = json.loads(out.read_text())["runtime"]["environment"]["cgroup"]
    assert cg == {
        "cpu_max": None,
        "cpuset_effective": None,
        "nr_throttled": None,
        "throttled_usec": None,
    }


# ---- cgroup_stat -----------------------------------------------------------------------------


def test_cgroup_stat_reads_a_running_containers_scope(env: dict[str, str]) -> None:
    run = sh("cgroup_stat lowlat-x", env)
    assert run.returncode == 0, run.stderr
    assert json.loads(run.stdout) == {
        "nr_throttled": 7,
        "throttled_usec": 12345,
        "cpu_max": "150000 100000",
        "cpuset_effective": "2-3",
    }


def test_cgroup_stat_finds_the_cgroupfs_driver_layout(env: dict[str, str], tmp_path: Path) -> None:
    shutil.move(env["FAKE_SCOPE"], tmp_path / "cg" / "docker-moved")
    (tmp_path / "cg" / "docker").mkdir()
    shutil.move(str(tmp_path / "cg" / "docker-moved"), tmp_path / "cg" / "docker" / CID)
    run = sh("cgroup_stat lowlat-x", env)
    assert run.returncode == 0, run.stderr
    assert json.loads(run.stdout)["nr_throttled"] == 7


def test_cgroup_stat_of_a_stopped_container_returns_3(env: dict[str, str]) -> None:
    shutil.rmtree(env["FAKE_SCOPE"])
    run = sh("cgroup_stat lowlat-x", env)
    assert run.returncode == 3
    assert run.stdout == ""
    assert "no cgroup" in run.stderr


# ---- guest, guest_fetch ----------------------------------------------------------------------


def test_guest_runs_in_the_repo_root_and_quotes_each_word(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = sh("guest printf '[%s]' 'a b' '$HOME' ';'", env, local_guest=False)
    assert run.returncode == 0, run.stderr
    assert run.stdout == "[a b][$HOME][;]"
    assert sh("guest pwd", env, local_guest=False).stdout.strip() == str(
        tmp_path / "home" / "low-latency-engineering"
    )
    assert (
        (tmp_path / "ssh.log")
        .read_text()
        .startswith("lowlat-target cd low-latency-engineering && ")
    )


def test_guest_refuses_a_target_outside_the_lab_prefix(env: dict[str, str], tmp_path: Path) -> None:
    for vm in ("ebpf-target", "systems-vm", "lowlat"):
        run = sh("guest true", {**env, "TARGET_VM": vm}, local_guest=False)
        assert run.returncode != 0
        assert "refusing" in run.stderr
    assert calls(tmp_path, "ssh.log") == []


def test_guest_fetch_copies_a_file_and_a_directory(env: dict[str, str], tmp_path: Path) -> None:
    out = Path(env["HOME"]) / "out"
    (out / "sub").mkdir(parents=True)
    (out / "a.txt").write_text("hello\n")
    (out / "sub" / "b.txt").write_text("deep\n")
    got = tmp_path / "got.txt"
    assert sh(f"guest_fetch out/a.txt {got}", env, local_guest=False).returncode == 0
    assert got.read_text() == "hello\n"
    got_dir = tmp_path / "got-dir"
    assert sh(f"guest_fetch out/ {got_dir}", env, local_guest=False).returncode == 0
    assert (got_dir / "sub" / "b.txt").read_text() == "deep\n"
    assert sh(f"guest_fetch out/missing {tmp_path}/m", env, local_guest=False).returncode != 0


# ---- require_quiet_host ----------------------------------------------------------------------


def quiet(
    env: dict[str, str], tmp_path: Path, args: str, domains: str, load: str = "0.10"
) -> tuple:
    start = tmp_path / "run-start.json"
    start.write_text('{"example": "13"}\n')
    script = (
        f"guest() {{ echo '{load} 0.2 0.3 1/200 99'; }}\n"
        f"RUN_START_JSON={start} require_quiet_host {args}"
    )
    run = sh(script, {**env, "FAKE_DOMAINS": domains}, local_guest=False)
    return run, json.loads(start.read_text())


def test_quiet_host_without_the_flag_still_refuses_any_running_lab_vm(
    env: dict[str, str], tmp_path: Path
) -> None:
    run, rec = quiet(env, tmp_path, "", "lowlat-target")
    assert run.returncode != 0
    assert "lab VM running" in run.stderr
    assert rec == {"example": "13"}
    assert quiet(env, tmp_path, "", "")[0].returncode == 0
    assert quiet(env, tmp_path, "", "ebpf-vm\nsystems-vm")[0].returncode == 0  # unchanged: ignored


def test_quiet_host_lab_idle_accepts_an_idle_target_and_records_it(
    env: dict[str, str], tmp_path: Path
) -> None:
    run, rec = quiet(env, tmp_path, "--lab-idle", "lowlat-target", "0.50")
    assert run.returncode == 0, run.stderr
    assert rec == {"example": "13", "lab_vm": "up (idle)", "lab_vm_load1": 0.5}
    # only the domain list was read from libvirt
    assert set(calls(tmp_path, "virsh.log")) == {"-c qemu:///system list --name"}


def test_quiet_host_lab_idle_refuses_a_busy_target(env: dict[str, str], tmp_path: Path) -> None:
    run, rec = quiet(env, tmp_path, "--lab-idle", "lowlat-target", "0.51")
    assert run.returncode != 0
    assert "not idle" in run.stderr
    assert "lab_vm" not in rec


@pytest.mark.parametrize(
    "domains",
    [
        "lowlat-target\nebpf-vm",
        "lowlat-target\nsystems-vm",
        "ebpf-vm",
        "lowlat-target\nlowlat-peer",
        "lowlat-peer",
    ],
)
def test_quiet_host_lab_idle_refuses_other_domains(
    env: dict[str, str], tmp_path: Path, domains: str
) -> None:
    run, rec = quiet(env, tmp_path, "--lab-idle", domains)
    assert run.returncode != 0
    assert "lab_vm" not in rec


def test_quiet_host_lab_idle_records_a_down_lab_and_honours_allow_busy(
    env: dict[str, str], tmp_path: Path
) -> None:
    run, rec = quiet(env, tmp_path, "--lab-idle", "")
    assert run.returncode == 0
    assert rec["lab_vm"] == "down"
    assert (
        quiet({**env, "ALLOW_BUSY": "1"}, tmp_path, "--lab-idle", "lowlat-target", "9.0")[
            0
        ].returncode
        == 0
    )


def test_quiet_host_lab_idle_refuses_a_target_outside_the_lab_prefix(
    env: dict[str, str], tmp_path: Path
) -> None:
    run, _ = quiet({**env, "TARGET_VM": "ebpf-target"}, tmp_path, "--lab-idle", "ebpf-target")
    assert run.returncode != 0
    assert calls(tmp_path, "ssh.log") == []


# ---- interleave_env --------------------------------------------------------------------------


def test_interleave_env_runs_lanes_in_abc_order_with_the_alternation_number(
    env: dict[str, str],
) -> None:
    run = sh('run_lane() { echo "$1:$2"; }\ninterleave_env 3 host vm container', env)
    assert run.stdout.split() == [
        f"{lane}:{alt}" for alt in (1, 2, 3) for lane in ("host", "vm", "container")
    ]


def test_interleave_env_stops_at_a_failing_lane_and_checks_its_input(env: dict[str, str]) -> None:
    run = sh(
        'run_lane() { echo "$1:$2"; [[ $1 != vm ]] || return 5; }\n'
        "interleave_env 3 host vm container",
        env,
    )
    assert run.returncode == 5
    assert run.stdout.split() == ["host:1", "vm:1"]
    assert sh("interleave_env 2 host", env).returncode != 0  # no run_lane
    assert sh("run_lane() { :; }\ninterleave_env 0 a", env).returncode != 0
    assert sh("run_lane() { :; }\ninterleave_env 2", env).returncode != 0
    assert sh("run_lane() { :; }\ninterleave_env 2 'bad lane'", env).returncode != 0


# ---- strace_summary --------------------------------------------------------------------------


def strace_works() -> bool:
    if not shutil.which("strace"):
        return False
    return (
        subprocess.run(["strace", "-f", "-c", "-o", os.devnull, "true"], check=False).returncode
        == 0
    )


def test_strace_summary_skips_with_code_3_when_strace_is_missing(
    env: dict[str, str], tmp_path: Path
) -> None:
    bare = tmp_path / "bare"
    bare.mkdir()
    for tool in ("dirname", "cat"):
        (bare / tool).symlink_to(shutil.which(tool) or "")
    run = subprocess.run(
        [
            shutil.which("bash") or "bash",
            "-c",
            f'. "{LIB}"\nstrace_summary {tmp_path}/o.txt -- true',
        ],
        capture_output=True,
        text=True,
        env={**os.environ, **env, "PATH": str(bare)},
        check=False,
    )
    assert run.returncode == 3
    assert "strace is not installed" in run.stderr
    assert not (tmp_path / "o.txt").exists()


@pytest.mark.skipif(not strace_works(), reason="strace is not installed or cannot trace here")
def test_strace_summary_writes_only_the_scrubbed_table_and_no_raw_file(
    env: dict[str, str], tmp_path: Path
) -> None:
    out = tmp_path / "summary.txt"
    run = sh(
        f"strace_summary {out} -- bash -c 'echo traced-output; cat /proc/self/status >/dev/null'",
        env,
    )
    assert run.returncode == 0, run.stderr
    assert "traced-output" in run.stdout
    text = out.read_text()
    assert text.startswith("% time")
    assert "syscall" in text
    assert "execve" not in text.splitlines()[0]
    assert not Path(f"{out}.raw").exists()
    assert sh(f"strace_summary {out} -- false", env).returncode == 1  # the command's status
    assert sh(f"strace_summary {out} true", env).returncode != 0  # usage


# ---- from_samples ----------------------------------------------------------------------------


@pytest.mark.skipif(not shutil.which("uv"), reason="uv is not installed")
def test_from_samples_wraps_the_cli(env: dict[str, str], tmp_path: Path) -> None:
    from array import array

    raw, side, out = tmp_path / "s.i64", tmp_path / "s.json", tmp_path / "report.json"
    with raw.open("wb") as f:
        array("q", [1000 * i for i in range(1, 101)]).tofile(f)
    side.write_text(
        json.dumps(
            {
                "example": "11-stackful-stackless",
                "variant": "threads-ft",
                "count": 100,
                "dropped": 0,
                "gil_enabled": False,
                "runtime": {"python_build": "free-threaded"},
            }
        )
    )
    run_env = {**env, "LOWLAT_PROFILE": str(FIXTURES / "profile.json"), "HOME": os.environ["HOME"]}
    run = sh(f"from_samples {raw} {side} {out}", run_env)
    assert run.returncode == 0, run.stderr
    report = json.loads(out.read_text())
    assert report["count"] == 100
    assert report["build"]["gil_enabled"] is False
    assert report["runtime"]["python_build"] == "free-threaded"
    assert sh(f"from_samples {raw}", run_env).returncode != 0
