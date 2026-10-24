"""Tests for the lab-guest, container, lane, strace and raw-sample helpers in ``lib.sh``.

Nothing here starts a VM or runs docker on the host. ``docker`` is a shim on PATH that logs its
arguments and answers from canned JSON; ``guest`` is redefined to run its command locally; the
vsock ssh wrapper is a shim named by LAB_SSH; ``virsh`` is a shim that lists chosen domains.
"""

import json
import os
import shutil
import signal
import subprocess
import time
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
# Fake docker: logs its arguments, answers from FAKE_* variables. A container "exists" while the
# marker file c_NAME does; create makes it, rm removes it.
printf '%s\n' "$*" >>"$FAKE_DIR/docker.log"
cmd=$1
shift
if [[ ${FAKE_FAIL:-} == "$cmd" ]]; then echo "boom: $cmd" >&2; exit 1; fi
marker() { echo "$FAKE_DIR/c_$1"; }
case $cmd in
  create)
    while (($#)); do [[ $1 == --name ]] && { touch "$(marker "$2")"; break; }; shift; done
    echo "$FAKE_CID"
    ;;
  start) echo "$1" ;;
  wait)
    sleep "${FAKE_WAIT_SLEEP:-0}"
    echo "${FAKE_EXIT:-0}"
    ;;
  logs)
    if [[ -n ${FAKE_PARTIAL:-} ]]; then
      printf 'partial\n' # the workload's last line had no newline; the wrapper's own \n ended it
    else
      echo "container says hi from $FAKE_HOME_PATH"
      echo # the wrapper's leading newline
    fi
    case ${FAKE_BLOCK:-ok} in
      none) ;;
      *)
        if [[ $FAKE_BLOCK == fake-begin ]]; then
          # a workload's unterminated fake block
          printf '@@LOWLAT_CGROUP_BEGIN\nnr_throttled 999\n\n'
        fi
        echo "@@LOWLAT_CGROUP_BEGIN"
        rc=${FAKE_EXIT:-0}
        [[ $FAKE_BLOCK != badrc ]] || rc=99
        [[ $FAKE_BLOCK == norc ]] || echo "rc $rc"
        case $FAKE_BLOCK in
          garbage) echo "nr_throttled many" ;;
          *)
            printf 'usage_usec 99\nnr_periods 100\n'
            nr=7
            [[ $FAKE_BLOCK != negative ]] || nr=-1
            echo "nr_throttled $nr"
            [[ $FAKE_BLOCK != dup ]] || echo "nr_throttled 8"
            [[ $FAKE_BLOCK != inner-end ]] || echo "@@LOWLAT_CGROUP_END"
            echo "throttled_usec 12345"
            cm="150000 100000"
            [[ $FAKE_BLOCK != badcpu ]] || cm=lots
            echo "cpu.max $cm"
            cs=2-3
            [[ $FAKE_BLOCK != badcpuset ]] || cs="2;3"
            echo "cpuset.cpus.effective $cs"
            ;;
        esac
        [[ $FAKE_BLOCK == no-end ]] || echo "@@LOWLAT_CGROUP_END"
        [[ $FAKE_BLOCK != trailing ]] || echo "late output"
        ;;
    esac
    echo "container stderr line" >&2
    ;;
  rm) rm -f "$(marker "${!#}")" ;;
  image)
    printf '[{"Id":"%s","RepoDigests":["registry.example/lowlat/app@%s"]}]\n' \
      "$FAKE_IMG_ID" "$FAKE_DIGEST"
    ;;
  inspect)
    if [[ $1 == --format ]]; then
      [[ -e $(marker "$3") ]] || exit 1
      echo "$FAKE_CID"
      exit 0
    fi
    [[ -e $(marker "$1") ]] || exit 1
    printf '[{"Id":"%s","Image":"%s",' "$FAKE_CID" "$FAKE_IMG_ID"
    printf '"HostConfig":{"NetworkMode":"%s",' "${FAKE_NET:-default}"
    printf '"NanoCpus":%s,"CpusetCpus":"%s"}}]\n' "${FAKE_NANO:-0}" "${FAKE_CPUSET:-}"
    ;;
esac
"""

FAKE_VIRSH = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/virsh.log"
[[ $* == "-c qemu:///system list --name" ]] || exit 9
[[ -z ${FAKE_VIRSH_FAIL:-} ]] || exit 1
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
    (tmp_path / "c_lowlat-x").touch()  # a running container for cgroup_stat
    groot = tmp_path / "groot"
    for d in ("out/run1", "out/r", "other"):
        (groot / d).mkdir(parents=True)
    (groot / "out" / "link").symlink_to("/etc")
    (groot / "out" / "docker.sock").touch()
    (groot / "outlink").symlink_to("/etc")
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
        "LOWLAT_GUEST_ROOT": str(groot),
        "CONTAINER_OUT_DIR": str(groot / "out"),
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


REFUSED = [
    # capabilities, every spelling
    "--privileged",
    "--privileged=true",
    "--cap-add=ALL",
    "--cap-add=All",
    "--cap-add ALL",
    "--cap-add all",
    "--cap-add=' all'",
    "--cap-add=SYS_ADMIN",
    "--cap-add CAP_SYS_ADMIN",
    "--cap-add=sys_ptrace",
    "--cap-drop=ALL",
    # devices
    "--device /dev/kvm",
    "--device=/dev/mem",
    # mounts outside the declared output directory, or onto protected targets
    "-v /:/host",
    "--volume=/:/host",
    "--volume /:/host",
    "--mount type=bind,src=/,dst=/host",
    "--mount=type=bind,source=/,target=/host",
    "-v /var/run/docker.sock:/var/run/docker.sock",
    "-v {OUT}/../etc:/data",
    "-v {OUT}:/",
    "-v {OUT}:/proc",
    "-v {OUT}:/sys/fs",
    "-v {OUT}:/dev/x",
    "-v {OUT}:/var/run/docker.sock",
    "-v {OUT}:/data:suid",
    "-v namedvolume:/data",
    "--mount type=volume,src={OUT},dst=/data",
    "--mount type=bind,src={OUT},dst=/data,bind-propagation=shared",
    # canonical-path bypasses (a // or . component, run/etc/sys targets, symlinks, sockets)
    "-v {OUT}://",
    "-v {OUT}://proc",
    "-v {OUT}:/./proc",
    "-v {OUT}://sys/fs/cgroup",
    "-v {OUT}:/sys/fs/cgroup",
    "-v {OUT}:/run",
    "-v {OUT}:/run/x",
    "-v {OUT}:/var/run",
    "-v {OUT}:/etc",
    "-v {OUT}:/etc/x",
    "-v {OUT}:/bin",
    "-v {OUT}:/bin/sh",
    "-v {OUT}:/sbin",
    "-v {OUT}:/usr",
    "-v {OUT}:/usr/bin/cat",
    "-v {OUT}:/lib",
    "-v {OUT}:/lib64/ld-linux.so",
    "-v {OUT}:/opt/venv",
    "-v {OUT}:/opt/venv/bin",
    "-v {OUT}//run1:/out",
    "-v {OUT}/./run1:/out",
    "-v {OUT}/link:/out",
    "-v {OUT}/docker.sock:/out",
    "--mount type=bind,src={OUT},dst=//sys/fs/cgroup",
    "--mount type=bind,src={OUT},dst=/./proc",
    "--mount type=bind,src={OUT},dst=/sys/fs/cgroup",
    "--mount type=bind,src={OUT}/link,dst=/out",
    # namespaces
    "--userns=host",
    "--userns host",
    "--ipc=host",
    "--ipc host",
    "--uts=host",
    "--uts host",
    "--pid=host",
    "--pid=HOST",
    "--pid host",
    "--cgroupns=host",
    "--cgroupns host",
    "--cgroupns=private",
    # security options
    "--security-opt seccomp=unconfined",
    "--security-opt=seccomp=unconfined",
    "--security-opt=SECCOMP=Unconfined",
    "--security-opt 'seccomp=unconfined '",
    "--security-opt seccomp=default",
    "--security-opt seccomp=/x/profile.json",
    "--security-opt seccomp=../a.json",
    "--security-opt seccomp=a.json.txt",
    "--security-opt no-new-privileges=false",
    "--security-opt NO-NEW-PRIVILEGES",
    "--security-opt Seccomp=a.json",
    "--security-opt apparmor=unconfined",
    "--security-opt=label=disable",
    "--security-opt systempaths=unconfined",
    "--security-opt seccomp=a.json,seccomp=unconfined",
    # other knobs
    "--sysctl net.core.somaxconn=1",
    "--sysctl=kernel.shmmax=1",
    "--cgroup-parent=/",
    "--oom-kill-disable",
    "--cpus 0",
    "--cpus 0.0",
    "--cpus=0",
    "--memory 0",
    "--memory=0m",
    "-e FOO",
    "--env FOO",
    "--env=FOO",
    "--network=container:other",
    "--network mynet",
    "--net=HOST2",
    "--name other",
    "--entrypoint sh",
    "--restart=always",
    "--ulimit nofile=1",
    "--pids-limit=-1",
    # detach and removal, every spelling
    "--rm",
    "--rm=true",
    "-d",
    "--detach",
    "--detach=true",
    "-di",
    "-dit",
    "-it",
    "-i",
    "-t",
    # not options at all
    "stray",
    " --privileged",
]

ALLOWED = [
    "--cpus 1.5",
    "--cpus=2",
    "--cpus 0.5",
    "--cpuset-cpus 2,3",
    "--cpuset-cpus=2-3",
    "--memory 512m",
    "--memory=1G",
    "--network host",
    "--net=none",
    "--network=BRIDGE",
    "--security-opt seccomp=profile.json",
    "--security-opt=seccomp=profile.json",
    "--security-opt no-new-privileges",
    "--security-opt=no-new-privileges=true",
    "-e FOO=bar",
    "--env=FOO=bar",
    "-eFOO=bar",
    "--hostname lane-a",
    "--init",
    "--user 1000:1000",
    "-u root",
    "--workdir /work",
    "-w /work",
    "-v {OUT}/run1:/out",
    "--volume={OUT}:/out:ro",
    "--mount type=bind,src={OUT}/r,dst=/out",
    "--mount type=bind,source={OUT},target=/out,readonly",
]


BAD_BLOCKS = [
    "none",
    "garbage",
    "trailing",
    "no-end",
    "dup",
    "inner-end",
    "badcpu",
    "badcpuset",
    "negative",
    "badrc",
    "norc",
]


def run_container(env: dict[str, str], tmp_path: Path, opts: str, name: str = "tx"):
    opts = opts.replace("{OUT}", env["CONTAINER_OUT_DIR"])
    return sh(
        f"container_run {name} --env-out {tmp_path}/e.json {opts} -- {IMAGE}@{DIGEST} true",
        env,
    )


@pytest.mark.parametrize("flags", REFUSED)
def test_container_run_refuses_everything_off_the_allowlist_before_any_docker_call(
    env: dict[str, str], tmp_path: Path, flags: str
) -> None:
    run = run_container(env, tmp_path, flags)
    assert run.returncode != 0, flags
    assert "refused" in run.stderr
    assert calls(tmp_path) == []
    assert not (tmp_path / "e.json").exists()


@pytest.mark.parametrize("flags", ALLOWED)
def test_container_run_passes_the_allowed_options(
    env: dict[str, str], tmp_path: Path, flags: str
) -> None:
    run = run_container(env, tmp_path, flags)
    assert run.returncode == 0, run.stderr
    assert (tmp_path / "e.json").exists()


def test_container_run_refuses_a_mount_without_an_output_dir(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = sh(
        f"container_run t --env-out {tmp_path}/e.json -v {env['LOWLAT_GUEST_ROOT']}/out/r:/out"
        f" -- {IMAGE} true",
        {**env, "CONTAINER_OUT_DIR": ""},
    )
    assert run.returncode != 0
    assert "CONTAINER_OUT_DIR" in run.stderr
    assert calls(tmp_path) == []


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
    out = sh(f"container_run t1 --env-out {tmp_path}/e.json -- {IMAGE} x", no_profile)
    assert "GUEST_PROFILE" in out.stderr
    assert "--env-out" in sh(f"container_run t1 -- {IMAGE} x", env).stderr
    assert calls(tmp_path) == []


def test_container_run_records_the_merged_environment_and_hides_the_id(
    env: dict[str, str], tmp_path: Path
) -> None:
    run_env = {**env, "FAKE_NANO": "1500000000", "FAKE_CPUSET": "2,3"}
    out = tmp_path / "env.json"
    run = sh(
        f"container_run lowlat-t1 --env-out {out} --cpus 1.5 --cpuset-cpus 2,3 --network host"
        f" --security-opt seccomp=profile.json -- {IMAGE}@{DIGEST} app --flag 'a b'",
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
    assert f"/home/{os.environ.get('USER', 'nobody')}/" not in everything  # scrubbed
    log = calls(tmp_path)
    create = next(line for line in log if line.startswith("create"))
    # the wrapper, entrypoint, private cgroupns and default hostname are added; the command follows
    assert create.startswith(
        "create --name lowlat-t1 --cgroupns=private --entrypoint sh --cpus 1.5 --cpuset-cpus 2,3"
        " --network host --security-opt seccomp="
        + env["LOWLAT_GUEST_ROOT"]
        + "/examples/13-where-code-runs/containers/seccomp/profile.json"
    )
    assert "--hostname lowlat-t1" in create
    assert f"{IMAGE}@{DIGEST} -c " in create
    assert (tmp_path / "docker.log").read_text().count("exit $rc sh app --flag a b\n") == 1
    assert [
        line.split()[0] for line in log if line.split()[0] in {"create", "start", "wait", "rm"}
    ] == ["create", "start", "wait", "rm"]
    assert log[-1] == "rm -f lowlat-t1"


def test_container_run_passes_the_log_through_without_the_fenced_block(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = run_container(env, tmp_path, "--cpus 1")
    assert run.returncode == 0, run.stderr
    assert "container says hi" in run.stdout
    assert "container stderr line" in run.stderr
    assert "@@LOWLAT" not in run.stdout + run.stderr
    assert "nr_throttled" not in run.stdout + run.stderr
    assert "cpu.max" not in run.stdout + run.stderr


def test_container_run_defaults_are_null_bridge_default_seccomp_and_own_hostname(
    env: dict[str, str], tmp_path: Path
) -> None:
    out = tmp_path / "env.json"
    run = sh(f"container_run t2 --env-out {out} -- {IMAGE} app", env)
    assert run.returncode == 0, run.stderr
    block = json.loads(out.read_text())["runtime"]["environment"]
    assert block["container"] == {
        "runtime": "docker",
        "image": IMAGE,
        "image_digest": IMG_ID,  # no digest given: the image ID the container ran
        "network": "bridge",
        "cpu_quota": None,
        "cpuset": None,
        "seccomp": "default",
    }
    create = next(line for line in calls(tmp_path) if line.startswith("create"))
    assert "--hostname t2" in create
    assert CID not in create
    # a caller's own hostname replaces the default
    sh(f"container_run t2b --env-out {out} --hostname other -- {IMAGE} app", env)
    create_b = next(line for line in calls(tmp_path) if line.startswith("create --name t2b"))
    assert "--hostname other" in create_b
    assert "--hostname t2b" not in create_b


@pytest.mark.parametrize("block", BAD_BLOCKS)
@pytest.mark.parametrize("limit", ["--cpus 1", "--cpuset-cpus 2"])
def test_container_run_fails_a_limited_lane_without_a_usable_cgroup_block(
    env: dict[str, str], tmp_path: Path, block: str, limit: str
) -> None:
    run = run_container({**env, "FAKE_BLOCK": block}, tmp_path, limit)
    assert run.returncode == 4, run.stderr
    assert "no usable cgroup block" in run.stderr
    assert not (tmp_path / "e.json").exists()
    assert calls(tmp_path)[-1] == "rm -f tx"
    assert "@@LOWLAT" not in run.stdout


@pytest.mark.parametrize("block", BAD_BLOCKS)
def test_container_run_records_null_cgroup_for_an_unlimited_lane(
    env: dict[str, str], tmp_path: Path, block: str
) -> None:
    run = run_container({**env, "FAKE_BLOCK": block}, tmp_path, "--network none")
    assert run.returncode == 0, run.stderr
    cg = json.loads((tmp_path / "e.json").read_text())["runtime"]["environment"]["cgroup"]
    assert cg == {
        "cpu_max": None,
        "cpuset_effective": None,
        "nr_throttled": None,
        "throttled_usec": None,
    }


def test_container_run_returns_the_container_status_and_still_cleans_up(
    env: dict[str, str], tmp_path: Path
) -> None:
    out = tmp_path / "env.json"
    run = sh(f"container_run t3 --env-out {out} -- {IMAGE} app", {**env, "FAKE_EXIT": "7"})
    assert run.returncode == 7
    assert out.exists()
    assert calls(tmp_path)[-1] == "rm -f t3"


@pytest.mark.parametrize("fail", ["create", "start", "wait", "inspect"])
def test_container_run_cleanup_trap_fires_on_failure(
    env: dict[str, str], tmp_path: Path, fail: str
) -> None:
    run = sh(
        f"container_run t4 --env-out {tmp_path}/e.json -- {IMAGE} app", {**env, "FAKE_FAIL": fail}
    )
    assert run.returncode != 0
    # created is set before docker create, so even a failed or interrupted create is cleaned up
    assert calls(tmp_path)[-1] == "rm -f t4"
    assert CID not in run.stdout + run.stderr
    assert not (tmp_path / "e.json").exists()
    assert not list(tmp_path.glob("lowlat-container.*"))


def test_container_run_refuses_a_name_that_already_exists_and_does_not_remove_it(
    env: dict[str, str], tmp_path: Path
) -> None:
    (tmp_path / "c_t5").touch()
    run = sh(f"container_run t5 --env-out {tmp_path}/e.json -- {IMAGE} app", env)
    assert run.returncode != 0
    assert "already exists" in run.stderr
    assert not any(line.startswith(("create", "rm")) for line in calls(tmp_path))


@pytest.mark.parametrize("sig", [signal.SIGINT, signal.SIGTERM])
def test_container_run_cleanup_trap_fires_on_a_signal(
    env: dict[str, str], tmp_path: Path, sig: signal.Signals
) -> None:
    proc = subprocess.Popen(
        [
            "bash",
            "-c",
            f'. "{LIB}"\nguest() {{ "$@"; }}\n'
            f"container_run t6 --env-out {tmp_path}/e.json -- {IMAGE} app",
        ],
        env={**os.environ, **env, "FAKE_WAIT_SLEEP": "20"},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    for _ in range(300):
        if any(line.startswith("wait") for line in calls(tmp_path)):
            break
        time.sleep(0.01)
    os.killpg(proc.pid, sig)
    proc.communicate(timeout=30)
    assert proc.returncode in (130, 143, -sig)
    assert calls(tmp_path)[-1] == "rm -f t6"
    assert not list(tmp_path.glob("lowlat-container.*"))


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
    env_block = json.loads((tmp_path / "e.json").read_text())["runtime"]["environment"]
    assert env_block["container"]["image_digest"] == DIGEST


def test_container_run_takes_the_last_begin_and_never_merges_a_fake_block(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = run_container({**env, "FAKE_BLOCK": "fake-begin"}, tmp_path, "--cpus 1")
    assert run.returncode == 0, run.stderr
    cg = json.loads((tmp_path / "e.json").read_text())["runtime"]["environment"]["cgroup"]
    assert cg["nr_throttled"] == 7  # the real block, not the workload's 999
    assert cg["throttled_usec"] == 12345
    assert "nr_throttled 999" in run.stdout  # the fake lines stay workload output


def test_container_run_keeps_a_partial_last_stdout_line_and_still_finds_the_block(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = run_container({**env, "FAKE_PARTIAL": "1"}, tmp_path, "--cpus 1")
    assert run.returncode == 0, run.stderr
    assert run.stdout.splitlines() == ["partial"]
    cg = json.loads((tmp_path / "e.json").read_text())["runtime"]["environment"]["cgroup"]
    assert cg["nr_throttled"] == 7


def test_container_run_drops_exactly_one_blank_line_before_the_block(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = run_container(env, tmp_path, "--cpus 1")
    assert len(run.stdout.splitlines()) == 1
    assert run.stdout.endswith("\n")
    assert not run.stdout.endswith("\n\n")


def test_container_run_wrapper_starts_its_block_on_a_fresh_line(
    env: dict[str, str], tmp_path: Path
) -> None:
    run_container(env, tmp_path, "--cpus 1")
    assert "printf '\\n@@LOWLAT_CGROUP_BEGIN\\n'" in (tmp_path / "docker.log").read_text()


@pytest.mark.parametrize(
    "out",
    [
        "/",
        "//",
        "/var/run",
        "/etc",
        "relative/dir",
        "{ROOT}",
        "{ROOT}//out",
        "{ROOT}/./out",
        "{ROOT}/../out",
        "{ROOT}/outlink",
        "{ROOT}/missing",
        "/var/run/{ROOT}",
    ],
)
def test_container_run_validates_the_output_directory_itself(
    env: dict[str, str], tmp_path: Path, out: str
) -> None:
    out_dir = out.replace("{ROOT}", env["LOWLAT_GUEST_ROOT"])
    run = sh(
        f"container_run t --env-out {tmp_path}/e.json -v {out_dir}:/out -- {IMAGE} true",
        {**env, "CONTAINER_OUT_DIR": out_dir},
    )
    assert run.returncode != 0, out
    assert "refused" in run.stderr
    assert calls(tmp_path) == []


@pytest.mark.parametrize("root", ["/etc", "/", "/usr/share", "/var/lib", "/proc", "/opt/x"])
def test_container_run_refuses_a_system_tree_as_the_guest_root(
    env: dict[str, str], tmp_path: Path, root: str
) -> None:
    out = f"{root.rstrip('/')}/ssh"
    run = sh(
        f"container_run t --env-out {tmp_path}/e.json -v {out}:/out -- {IMAGE} true",
        {**env, "LOWLAT_GUEST_ROOT": root, "CONTAINER_OUT_DIR": out},
    )
    assert run.returncode != 0
    assert "refused" in run.stderr or "system tree" in run.stderr
    assert calls(tmp_path) == []


def test_container_run_refuses_a_guest_root_that_is_a_symlink_to_a_system_tree(
    env: dict[str, str], tmp_path: Path
) -> None:
    link = tmp_path / "rootlink"
    link.symlink_to("/etc")
    run = sh(
        f"container_run t --env-out {tmp_path}/e.json -v {link}/ssh:/out -- {IMAGE} true",
        {**env, "LOWLAT_GUEST_ROOT": str(link), "CONTAINER_OUT_DIR": f"{link}/ssh"},
    )
    assert run.returncode != 0
    assert calls(tmp_path) == []


def test_container_run_rejects_a_block_whose_rc_differs_from_docker_wait(
    env: dict[str, str], tmp_path: Path
) -> None:
    # the workload exited 7 (docker wait) but a forged block says 0
    run = run_container({**env, "FAKE_EXIT": "7", "FAKE_BLOCK": "badrc"}, tmp_path, "--cpus 1")
    assert run.returncode == 4
    ok = run_container({**env, "FAKE_EXIT": "7"}, tmp_path, "--cpus 1", name="ty")
    assert ok.returncode == 7
    assert (tmp_path / "e.json").exists()


def test_container_run_resolves_a_planted_symlink_in_the_guest(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = run_container(env, tmp_path, "-v {OUT}/link:/out")
    assert run.returncode != 0
    assert "outside" in run.stderr or "not under" in run.stderr
    assert calls(tmp_path) == []


def test_container_run_refuses_an_image_starting_with_a_dash(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = sh(f"container_run t --env-out {tmp_path}/e.json -- --privileged:1 true", env)
    assert run.returncode != 0
    assert "starts with '-'" in run.stderr
    assert calls(tmp_path) == []


def test_container_run_refuses_a_pending_lock_entry_before_docker(
    env: dict[str, str], tmp_path: Path
) -> None:
    lock = tmp_path / "IMAGES.lock"
    lock.write_text(f"# images\n{IMAGE}@sha256:PENDING registry.example/base:1@sha256:{'5' * 64}\n")
    run = sh(
        f"container_run t --env-out {tmp_path}/e.json -- {IMAGE} app",
        {**env, "LOWLAT_IMAGES_LOCK": str(lock)},
    )
    assert run.returncode != 0
    assert "PENDING" in run.stderr
    assert calls(tmp_path) == []


def test_container_run_matches_only_field_1_of_the_lock(
    env: dict[str, str], tmp_path: Path
) -> None:
    lock = tmp_path / "IMAGES.lock"
    lock.write_text(f"other/x:1@sha256:{'3' * 64} {IMAGE}@{DIGEST}\n")
    run = sh(
        f"container_run t --env-out {tmp_path}/e.json -- {IMAGE} app",
        {**env, "LOWLAT_IMAGES_LOCK": str(lock)},
    )
    assert run.returncode != 0
    assert "not listed" in run.stderr
    assert calls(tmp_path) == []


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


@pytest.mark.parametrize("kind", ["symlink", "hardlink"])
def test_guest_fetch_refuses_an_archive_with_links(
    env: dict[str, str], tmp_path: Path, kind: str
) -> None:
    out = Path(env["HOME"]) / "evil"
    out.mkdir()
    (out / "a.txt").write_text("x\n")
    if kind == "symlink":
        (out / "link").symlink_to("/etc/passwd")
    else:
        (out / "link").hardlink_to(out / "a.txt")
    dest = tmp_path / "dest"
    run = sh(f"guest_fetch evil/ {dest}", env, local_guest=False)
    if kind == "hardlink":
        # tar stores the second name as a hard link member
        assert run.returncode != 0
    else:
        assert run.returncode != 0
    assert "link or special file" in run.stderr
    assert not dest.exists()


# ---- require_quiet_host ----------------------------------------------------------------------


def quiet(
    env: dict[str, str], tmp_path: Path, args: str, domains: str, load: str = "0.10"
) -> tuple:
    start = tmp_path / "run-start.json"
    start.write_text('{"example": "13"}\n')
    script = (
        f"lab_ssh() {{ echo '{load} 0.2 0.3 1/200 99'; }}\n"
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


def test_quiet_host_without_the_flag_dies_when_virsh_fails(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = sh("require_quiet_host", {**env, "FAKE_VIRSH_FAIL": "1"})
    assert run.returncode != 0
    assert "cannot read the libvirt domain list" in run.stderr
    assert (
        sh("require_quiet_host", {**env, "FAKE_VIRSH_FAIL": "1", "ALLOW_BUSY": "1"}).returncode == 0
    )


def test_quiet_host_without_the_flag_treats_a_missing_virsh_as_no_lab(
    env: dict[str, str], tmp_path: Path
) -> None:
    bare = tmp_path / "bare"
    bare.mkdir()
    for tool in ("dirname", "cat"):
        (bare / tool).symlink_to(shutil.which(tool) or "")
    run = subprocess.run(
        [shutil.which("bash") or "bash", "-c", f'. "{LIB}"\nrequire_quiet_host'],
        capture_output=True,
        text=True,
        env={**os.environ, **env, "PATH": str(bare)},
        check=False,
    )
    assert run.returncode == 0, run.stderr


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
    assert rec["lab_vm"] == "down (require_quiet_host)"
    busy, rec = quiet({**env, "ALLOW_BUSY": "1"}, tmp_path, "--lab-idle", "lowlat-target", "9.0")
    assert busy.returncode == 0
    assert rec["lab_vm"] == "unchecked (ALLOW_BUSY)"


def test_quiet_host_lab_idle_never_records_down_when_virsh_fails(
    env: dict[str, str], tmp_path: Path
) -> None:
    run, rec = quiet({**env, "FAKE_VIRSH_FAIL": "1"}, tmp_path, "--lab-idle", "")
    assert run.returncode != 0
    assert "cannot read the libvirt domain list" in run.stderr
    assert rec["lab_vm"] == "unknown"


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


def test_strace_summary_skips_with_code_77_when_strace_is_missing(
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
    assert run.returncode == 77
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
    # a command that itself exits 3 is its status, not a skip (the skip code is 77)
    assert sh(f"strace_summary {out} -- bash -c 'exit 3'", env).returncode == 3
    assert not Path(f"{out}.raw").exists()


@pytest.mark.skipif(not strace_works(), reason="strace is not installed or cannot trace here")
@pytest.mark.parametrize("sig", [signal.SIGINT, signal.SIGTERM])
def test_strace_summary_removes_the_raw_file_on_a_signal(
    env: dict[str, str], tmp_path: Path, sig: signal.Signals
) -> None:
    out = tmp_path / "summary.txt"
    proc = subprocess.Popen(
        ["bash", "-c", f'. "{LIB}"\nstrace_summary {out} -- sleep 30'],
        env={**os.environ, **env},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    for _ in range(300):
        if Path(f"{out}.raw").exists():
            break
        time.sleep(0.01)
    assert Path(f"{out}.raw").exists()
    os.killpg(proc.pid, sig)
    proc.communicate(timeout=30)
    assert not Path(f"{out}.raw").exists()


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
                "build": {"compiler": "CPython 3.14 free-threading build", "gil_enabled": False},
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
