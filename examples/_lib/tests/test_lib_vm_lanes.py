"""Tests for the VM-lane helpers in ``lib.sh`` (r05): lane_revert, require_quiet_host --lab-run,
guest_noise, interrupts_delta, cyclictest_run, thread_cpus and vcpupin_record.

Nothing here starts a VM or touches libvirt. The guest is a directory: ``lab-ssh`` is a shim that
runs the command with a PATH of its own (``guest-bin``) holding fake ``timeout``, ``taskset``,
``stress-ng``, ``hackbench``, ``cyclictest``, ``sudo`` and ``sha256sum`` that log their arguments
to ``guest.log``, plus symlinks to the few real tools the commands need. ``virsh`` and the revert
script are shims on PATH.
"""

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
LIB = HERE.parent / "lib.sh"
REPO = HERE.parents[2]
FIXTURES = REPO / "examples" / "common" / "measure-fixtures"

FAKE_LAB_SSH = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/ssh.log"
shift # the target
if [[ $1 == true ]] && [[ -n ${FAKE_SSH_FAILS:-} ]]; then
  n=$(cat "$FAKE_DIR/ssh.fails" 2>/dev/null || echo 0)
  if ((n < FAKE_SSH_FAILS)); then echo $((n + 1)) >"$FAKE_DIR/ssh.fails"; exit 255; fi
fi
cd "$HOME" || exit 1 # ssh starts in the guest home
exec env PATH="$GUEST_BIN" bash -c "$*"
"""

# Fake guest tools: log, then run what they wrap (timeout, taskset, sudo) or stand in for it.
WRAPPER = r"""#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$FAKE_DIR/guest.log"
case $(basename "$0") in
  timeout) while [[ $1 == -* ]]; do [[ $1 == -s || $1 == -k ]] && shift; shift; done; shift ;;
  taskset) shift 2 ;;
  sudo) ;;
esac
exec "$@"
"""
LEAF = r"""#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$FAKE_DIR/guest.log"
case $(basename "$0") in
  cyclictest)
    for a in "$@"; do
      case $a in
        --json=*) cp "$FAKE_CT_JSON" "${a#--json=}" ;;
        --histfile=*) cp "$FAKE_CT_HIST" "${a#--histfile=}" ;;
      esac
    done
    exit "${FAKE_CT_EXIT:-0}"
    ;;
esac
exit 0
"""
FAKE_SHA = r"""#!/usr/bin/env bash
[[ -z ${FAKE_BAD_SUM:-} ]] || { printf '%s  %s\n' "$(printf '0%.0s' {1..64})" "$1"; exit 0; }
exec "$REAL_SHA256SUM" "$@"
"""
FAKE_VIRSH = r"""#!/usr/bin/env bash
printf '%s|%s\n' "${LIBVIRT_DEFAULT_URI:-}" "$*" >>"$FAKE_DIR/virsh.log"
[[ $1 == vcpupin ]] || exit 9
cat <<EOT
 VCPU   CPU Affinity
----------------------
 0      4
 1      6-7
 
EOT
"""
FAKE_REVERT = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/revert.log"
exit "${FAKE_REVERT_EXIT:-0}"
"""

REAL_TOOLS = (
    "bash sh cat sleep awk sed cut mkdir chmod rm tr head tee date env basename dirname mktemp "
    "tar gzip kill nohup realpath ls grep wc sort cp touch"
).split()
PROC = """\
           CPU0       CPU1       CPU2       CPU3
  0:         10          0          0          0   IO-APIC   2-edge      timer
 25:        100        200        300        400   PCI-MSI 1-edge      virtio0-config
LOC:       1000       2000       3000       4000   Local timer interrupts
RES:         50         60         70         80   Rescheduling interrupts
ERR:          0
MIS:          0
"""


@pytest.fixture
def env(tmp_path: Path) -> dict[str, str]:
    bin_dir = tmp_path / "bin"
    gbin = tmp_path / "guest-bin"
    bin_dir.mkdir()
    gbin.mkdir()
    for name, body in (("lab-ssh", FAKE_LAB_SSH), ("virsh", FAKE_VIRSH), ("revert", FAKE_REVERT)):
        (bin_dir / name).write_text(body, encoding="utf-8")
        (bin_dir / name).chmod(0o755)
    for name in ("timeout", "taskset", "sudo"):
        (gbin / name).write_text(WRAPPER, encoding="utf-8")
    for name in ("stress-ng", "hackbench", "cyclictest"):
        (gbin / name).write_text(LEAF, encoding="utf-8")
    (gbin / "sha256sum").write_text(FAKE_SHA, encoding="utf-8")
    for p in gbin.iterdir():
        p.chmod(0o755)
    for tool in REAL_TOOLS:
        found = shutil.which(tool)
        if found and not (gbin / tool).exists():
            (gbin / tool).symlink_to(found)
    home = tmp_path / "home"
    (home / "low-latency-engineering").mkdir(parents=True)
    return {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "NO_COLOR": "1",
        "FAKE_DIR": str(tmp_path),
        "GUEST_BIN": str(gbin),
        "REAL_SHA256SUM": shutil.which("sha256sum") or "sha256sum",
        "LAB_SSH": str(bin_dir / "lab-ssh"),
        "LAB_REVERT": str(bin_dir / "revert"),
        "HOME": str(home),
        "FAKE_CT_JSON": str(FIXTURES / "cyclictest" / "ok.json"),
        "FAKE_CT_HIST": str(FIXTURES / "cyclictest" / "ok.hist"),
        "LOWLAT_PROFILE": str(FIXTURES / "profile.json"),
        "LANE_SSH_SLEEP": "0",
    }


def sh(script: str, env: dict[str, str]):
    return subprocess.run(
        ["bash", "-c", f'. "{LIB}"\n{script}'],
        capture_output=True,
        text=True,
        env={**os.environ, **env},
        check=False,
    )


def log(tmp_path: Path, name: str) -> list[str]:
    f = tmp_path / name
    return f.read_text().splitlines() if f.exists() else []


# ---- lane_revert -----------------------------------------------------------------------------


def bin_dir(tmp_path: Path, files: dict[str, bytes], sums: dict[str, str] | None = None) -> Path:
    import hashlib

    d = tmp_path / "run-bin"
    d.mkdir()
    lines = []
    for name, data in files.items():
        (d / name).write_bytes(data)
        lines.append(f"{(sums or {}).get(name, hashlib.sha256(data).hexdigest())}  {name}")
    (d / "SHA256SUMS").write_text("\n".join(lines) + "\n")
    return d


def test_lane_revert_reverts_waits_pushes_and_verifies(env: dict[str, str], tmp_path: Path) -> None:
    d = bin_dir(tmp_path, {"probe": b"#!/bin/sh\necho hi\n", "other": b"bytes\n"})
    run = sh("lane_revert lab-ready-r05-rt", {**env, "LANE_BIN_DIR": str(d), "FAKE_SSH_FAILS": "2"})
    assert run.returncode == 0, run.stderr
    assert log(tmp_path, "revert.log") == ["lowlat-target lab-ready-r05-rt"]
    pushed = tmp_path / "home" / "low-latency-engineering" / "lane-bin"
    assert (pushed / "probe").read_bytes() == b"#!/bin/sh\necho hi\n"
    assert os.access(pushed / "probe", os.X_OK)
    assert (tmp_path / "ssh.fails").read_text().strip() == "2"  # it waited out two failed ssh tries


def test_lane_revert_aborts_when_the_guest_hash_differs(
    env: dict[str, str], tmp_path: Path
) -> None:
    d = bin_dir(tmp_path, {"probe": b"x\n"})
    run = sh("lane_revert lab-ready-r05-rt", {**env, "LANE_BIN_DIR": str(d), "FAKE_BAD_SUM": "1"})
    assert run.returncode != 0
    assert "sha256 mismatch for probe" in run.stderr


def test_lane_revert_refuses_stale_sums_before_touching_the_vm(
    env: dict[str, str], tmp_path: Path
) -> None:
    d = bin_dir(tmp_path, {"probe": b"x\n"}, {"probe": "1" * 64})
    run = sh("lane_revert lab-ready-r05-rt", {**env, "LANE_BIN_DIR": str(d)})
    assert run.returncode != 0
    assert "does not match" in run.stderr
    assert log(tmp_path, "revert.log") == []


def test_lane_revert_unpacks_a_verified_tarball(env: dict[str, str], tmp_path: Path) -> None:
    src = tmp_path / "src"
    src.mkdir()
    (src / "tool").write_text("t\n")
    tar = tmp_path / "t.tar.gz"
    subprocess.run(["tar", "-C", str(src), "-czf", str(tar), "tool"], check=True)
    d = bin_dir(tmp_path, {"bins.tar.gz": tar.read_bytes()})
    run = sh("lane_revert lab-ready-r05-rt", {**env, "LANE_BIN_DIR": str(d)})
    assert run.returncode == 0, run.stderr
    assert (
        tmp_path / "home" / "low-latency-engineering" / "lane-bin" / "tool"
    ).read_text() == "t\n"


def test_lane_revert_stops_when_the_revert_fails_and_refuses_a_foreign_domain(
    env: dict[str, str], tmp_path: Path
) -> None:
    d = bin_dir(tmp_path, {"probe": b"x\n"})
    run = sh("lane_revert nope", {**env, "LANE_BIN_DIR": str(d), "FAKE_REVERT_EXIT": "1"})
    assert run.returncode != 0
    assert "failed" in run.stderr
    assert log(tmp_path, "ssh.log") == []
    run = sh("lane_revert nope", {**env, "LANE_BIN_DIR": str(d), "TARGET_VM": "ebpf-target"})
    assert run.returncode != 0
    assert "refusing" in run.stderr


# ---- require_quiet_host --lab-run ------------------------------------------------------------


def loadavg(tmp_path: Path, load1: str) -> str:
    f = tmp_path / "loadavg"
    f.write_text(f"{load1} 0.50 0.40 1/300 12345\n")
    return str(f)


def test_lab_run_records_load1_and_passes_at_the_threshold(
    env: dict[str, str], tmp_path: Path
) -> None:
    start = tmp_path / "run-start.json"
    start.write_text('{"example": "14"}\n')
    out = tmp_path / "load1.txt"
    e = {**env, "LOWLAT_LOADAVG": loadavg(tmp_path, "2.00"), "RUN_START_JSON": str(start),
         "LAB_RUN_LOAD1_FILE": str(out)}  # fmt: skip
    run = sh("require_quiet_host --lab-run", e)
    assert run.returncode == 0, run.stderr
    assert out.read_text().strip() == "2.00"
    assert json.loads(start.read_text()) == {"example": "14", "host_load1": 2.0}


def test_lab_run_aborts_above_the_threshold_but_keeps_the_evidence(
    env: dict[str, str], tmp_path: Path
) -> None:
    out = tmp_path / "load1.txt"
    e = {**env, "LOWLAT_LOADAVG": loadavg(tmp_path, "2.01"), "LAB_RUN_LOAD1_FILE": str(out),
         "LAB_RUN_SETTLE": "0"}  # fmt: skip
    run = sh("require_quiet_host --lab-run", e)
    assert run.returncode != 0
    assert "host is busy" in run.stderr
    assert out.read_text().strip() == "2.01"
    # the threshold is an environment variable; ALLOW_BUSY records but does not abort
    assert sh("require_quiet_host --lab-run", {**e, "LAB_RUN_LOAD1": "3"}).returncode == 0
    assert sh("require_quiet_host --lab-run", {**e, "ALLOW_BUSY": "1"}).returncode == 0
    assert sh("require_quiet_host --lab-run extra", e).returncode != 0


def test_lab_run_waits_for_a_busy_host_to_settle(env: dict[str, str], tmp_path: Path) -> None:
    # The guest's previous lane lingers in the host's 1-minute load average; the gate re-reads it
    # and starts the lane once it is back under the bound, recording the load1 it started at.
    f = Path(loadavg(tmp_path, "2.75"))
    out = tmp_path / "load1.txt"
    e = {**env, "LOWLAT_LOADAVG": str(f), "LAB_RUN_LOAD1_FILE": str(out), "LAB_RUN_SETTLE": "5",
         "LAB_RUN_POLL": "1"}  # fmt: skip
    settle = f"(sleep 1.5; echo '1.40 0.5 0.4 1/300 1' > {f}) &"
    script = f"{settle}\nrequire_quiet_host --lab-run\necho waited=$LAB_RUN_WAITED_S"
    run = sh(script, e)
    assert run.returncode == 0, run.stderr
    assert out.read_text().strip() == "1.40"
    assert "waited=2" in run.stdout


def test_lab_run_gives_up_after_the_settle_window(env: dict[str, str], tmp_path: Path) -> None:
    e = {
        **env,
        "LOWLAT_LOADAVG": loadavg(tmp_path, "3.10"),
        "LAB_RUN_SETTLE": "2",
        "LAB_RUN_POLL": "1",
    }
    run = sh("require_quiet_host --lab-run", e)
    assert run.returncode != 0
    assert "after waiting 2 s" in run.stderr


# ---- guest_noise -----------------------------------------------------------------------------


def test_guest_noise_starts_bounded_pinned_load_and_returns_a_pid_file(
    env: dict[str, str], tmp_path: Path
) -> None:
    run = sh(
        'handle=$(guest_noise 0-1 3 cpu) && echo "$handle" && guest_noise_wait "$handle"',
        {**env, "GUEST_NOISE_DIR": str(tmp_path)},
    )
    assert run.returncode == 0, run.stderr
    handle = run.stdout.strip()
    assert re.fullmatch(rf"{tmp_path}/lowlat-noise-cpu-\d+-\d+\.pid", handle)
    assert not Path(handle).exists()  # guest_noise_wait removed it
    guest = log(tmp_path, "guest.log")
    assert "timeout -s KILL 5 taskset -c 0-1 stress-ng --cpu 2 --timeout 3s" in guest
    assert "taskset -c 0-1 stress-ng --cpu 2 --timeout 3s" in guest
    assert not any(line.startswith("sudo") for line in guest)


@pytest.mark.parametrize(
    ("kind", "expect"),
    [
        ("cpu", "stress-ng --cpu 2 --timeout 4s"),
        ("hdd", "stress-ng --hdd 2 --temp-path /tmp --timeout 4s"),
        ("stream", "stress-ng --stream 2 --timeout 4s"),
        ("cache", "stress-ng --cache 2 --timeout 4s"),
        ("hackbench", "hackbench -g 2 -l 1000000000"),
    ],
)
def test_guest_noise_kinds(env: dict[str, str], tmp_path: Path, kind: str, expect: str) -> None:
    run = sh(f"guest_noise 0,1 4 {kind} && sleep 0.3", {**env, "GUEST_NOISE_DIR": str(tmp_path)})
    assert run.returncode == 0, run.stderr
    assert any(
        line.endswith(expect) and "taskset -c 0,1" in line for line in log(tmp_path, "guest.log")
    )
    kill = "4" if kind == "hackbench" else "6"
    assert f"timeout -s KILL {kill} taskset -c 0,1 {expect}" in log(tmp_path, "guest.log")


def test_guest_noise_refuses_a_guest_without_timeout(env: dict[str, str], tmp_path: Path) -> None:
    (Path(env["GUEST_BIN"]) / "timeout").unlink()
    run = sh("guest_noise 0-1 3 cpu", env)
    assert run.returncode == 1
    assert "no timeout" in run.stderr
    assert not any(line.startswith("stress-ng") for line in log(tmp_path, "guest.log"))


def test_guest_noise_refuses_a_missing_generator(env: dict[str, str], tmp_path: Path) -> None:
    (Path(env["GUEST_BIN"]) / "stress-ng").unlink()
    run = sh("guest_noise 0-1 3 cpu", env)
    assert run.returncode == 1
    assert "no stress-ng" in run.stderr


@pytest.mark.parametrize("cpus", ["2", "1-2", "0,3", "2-3"])
def test_guest_noise_refuses_cpus_in_the_isolated_set(
    env: dict[str, str], tmp_path: Path, cpus: str
) -> None:
    run = sh(f"guest_noise {cpus} 3 cpu", {**env, "ISOLATED_CPUS": "2-3"})
    assert run.returncode == 1
    assert "isolated set" in run.stderr
    assert log(tmp_path, "guest.log") == []


def test_guest_noise_allows_housekeeping_cpus_and_the_shared_lane(
    env: dict[str, str], tmp_path: Path
) -> None:
    e = {**env, "ISOLATED_CPUS": "2-3", "GUEST_NOISE_DIR": str(tmp_path)}
    assert sh("guest_noise 0-1 3 cpu", e).returncode == 0
    assert sh("guest_noise 2-3 3 cpu", {**e, "NOISE_SHARED_LANE": "1"}).returncode == 0


@pytest.mark.parametrize("args", ["a 3 cpu", "0-1 0 cpu", "0-1 3 disk", "0-1 3x cpu"])
def test_guest_noise_refuses_bad_arguments(env: dict[str, str], tmp_path: Path, args: str) -> None:
    assert sh(f"guest_noise {args}", env).returncode == 1
    assert log(tmp_path, "guest.log") == []


# ---- interrupts_delta ------------------------------------------------------------------------


def fake_proc(env: dict[str, str], before: str, after: str) -> None:
    """The guest's /proc/interrupts: `before` until $HOME/stage exists, then `after`."""
    home = Path(env["HOME"])
    (home / "proc.before").write_text(before)
    (home / "proc.after").write_text(after)
    cat = Path(env["GUEST_BIN"]) / "cat"
    cat.unlink()
    cat.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ $1 == /proc/interrupts ]]; then\n"
        "  if [[ -e $HOME/stage ]]; then f=after; else f=before; fi\n"
        f'  exec {shutil.which("cat")} "$HOME/proc.$f"\n'
        "fi\n"
        f'exec {shutil.which("cat")} "$@"\n'
    )
    cat.chmod(0o755)


def test_interrupts_delta_writes_per_row_per_cpu_counts(
    env: dict[str, str], tmp_path: Path
) -> None:
    after = PROC.replace(
        "1000       2000       3000       4000", "1010       2020       3033       4044"
    )
    after = after.replace(
        " 25:        100        200        300        400",
        " 25:        100        200        301        400",
    )
    fake_proc(env, PROC, after)
    out = tmp_path / "irq.json"
    # the command runs in the guest (here: guest is a local function) and lets time pass
    run = sh(f'guest() {{ touch "$HOME/stage"; }}; interrupts_delta {out} 2 3 -- anything', env)
    assert run.returncode == 0, run.stderr
    got = json.loads(out.read_text())
    assert got["LOC"] == {"2": 33, "3": 44}
    assert got["RES"] == {"2": 0, "3": 0}
    assert got["25-virtio0-config"] == {"2": 1, "3": 0}
    assert got["0-timer"] == {"2": 0, "3": 0}
    assert "ERR" not in got and "MIS" not in got  # rows with one count, not one per CPU


def test_interrupts_delta_dies_for_a_cpu_the_guest_lacks_and_for_a_count_that_fell(
    env: dict[str, str], tmp_path: Path
) -> None:
    fake_proc(env, PROC, PROC.replace("1000", "5"))
    out = tmp_path / "irq.json"
    run = sh(f"guest() {{ true; }}; interrupts_delta {out} 9 -- true", env)
    assert run.returncode != 0
    assert "no CPU 9" in run.stderr
    assert not out.exists()
    run = sh(f'guest() {{ touch "$HOME/stage"; }}; interrupts_delta {out} 0 -- true', env)
    assert run.returncode != 0
    assert "went down" in run.stderr


def test_interrupts_delta_returns_the_commands_status(env: dict[str, str], tmp_path: Path) -> None:
    fake_proc(env, PROC, PROC)
    out = tmp_path / "irq.json"
    run = sh(f"guest() {{ return 7; }}; interrupts_delta {out} 0 -- x", env)
    assert run.returncode == 7
    assert json.loads(out.read_text())["LOC"] == {"0": 0}


# ---- cyclictest_run --------------------------------------------------------------------------

CT_ARGS = "-m -p 95 -a 2,3 -t 2 -i 1000 -D 1m -h 50"


def cyclic(env: dict[str, str], tmp_path: Path, flags: str = "", extra: str = ""):
    out = tmp_path / "reports"
    e = {
        **env,
        "EXAMPLE": "14-preempt-rt",
        "GUEST_PROFILE": "lab-ready-r05-rt/rt-unpinned",
        "CYCLICTEST_TIMEOUT": "90",
    }
    run = sh(f"cyclictest_run {flags} {out} {CT_ARGS} {extra}", e)
    return run, out


def cyclictest_call(tmp_path: Path) -> str:
    calls = [line for line in log(tmp_path, "guest.log") if line.startswith("cyclictest ")]
    assert len(calls) == 1
    return calls[0]


def test_cyclictest_run_adds_the_monotonic_clock_json_histfile_and_timeout(
    env: dict[str, str], tmp_path: Path
) -> None:
    run, out = cyclic(env, tmp_path)
    assert run.returncode == 0, run.stderr
    call = cyclictest_call(tmp_path)
    assert "--clock=monotonic" in call
    assert re.search(r"--json=\S+/ct\.json --histfile=\S+/ct\.hist", call)
    guest = log(tmp_path, "guest.log")
    assert any(line.startswith("sudo timeout -k 10 90 cyclictest") for line in guest)
    assert any(line.startswith("timeout -k 10 90 cyclictest") for line in guest)
    reports = sorted(out.glob("*.json"))
    assert [p.name for p in reports] == ["cyclictest-t0.json", "cyclictest-t1.json"]
    env_block = json.loads(reports[0].read_text())["runtime"]["environment"]
    assert env_block["kind"] == "vm"
    assert env_block["guest_profile"] == "lab-ready-r05-rt/rt-unpinned"
    assert "nodename" not in reports[0].read_text()


def test_cyclictest_run_default_clock_leaves_the_clock_alone(
    env: dict[str, str], tmp_path: Path
) -> None:
    run, _ = cyclic(env, tmp_path, "--default-clock")
    assert run.returncode == 0, run.stderr
    call = cyclictest_call(tmp_path)
    assert "--clock" not in call
    assert "--default-clock" not in call
    assert "--json=" in call and "--histfile=" in call


@pytest.mark.parametrize("opt", ["--clock=realtime", "-c0", "--json=x", "--histfile x"])
def test_cyclictest_run_refuses_options_it_owns(
    env: dict[str, str], tmp_path: Path, opt: str
) -> None:
    run, _ = cyclic(env, tmp_path, extra=opt)
    assert run.returncode != 0
    assert "is set by the helper" in run.stderr
    assert log(tmp_path, "guest.log") == []


def test_cyclictest_run_fails_on_a_timeout_a_failed_run_and_a_histogram_overflow(
    env: dict[str, str], tmp_path: Path
) -> None:
    (Path(env["GUEST_BIN"]) / "timeout").write_text("#!/usr/bin/env bash\nexit 124\n")
    run, _ = cyclic(env, tmp_path)
    assert run.returncode != 0
    assert "did not finish within 90 s" in run.stderr
    (Path(env["GUEST_BIN"]) / "timeout").write_text(WRAPPER)
    run, _ = cyclic({**env, "FAKE_CT_EXIT": "3"}, tmp_path)
    assert run.returncode != 0
    assert "failed (status 3)" in run.stderr
    run, _ = cyclic(
        {**env, "FAKE_CT_JSON": str(FIXTURES / "cyclictest" / "overflow.json"),
         "FAKE_CT_HIST": str(FIXTURES / "cyclictest" / "overflow.hist")}, tmp_path)  # fmt: skip
    assert run.returncode != 0
    assert "from-cyclictest failed" in run.stderr
    run, _ = cyclic(env, tmp_path, "--allow-overflow")  # the plain fixture still converts
    assert run.returncode == 0, run.stderr


# ---- thread_cpus -----------------------------------------------------------------------------


def test_thread_cpus_samples_every_task_of_the_process(env: dict[str, str], tmp_path: Path) -> None:
    out = tmp_path / "t.json"
    prog = (
        "python3 -c 'import threading,time\n"
        "ts=[threading.Thread(target=time.sleep,args=(2,)) for _ in range(2)]\n"
        "[t.start() for t in ts]\ntime.sleep(2)' & pid=$!; sleep 0.5;"
    )
    run = sh(
        f"{prog} THREAD_CPUS_SECONDS=0.5 THREAD_CPUS_INTERVAL=0.1 thread_cpus $pid {out};"
        " kill $pid",
        env,
    )
    assert run.returncode == 0, run.stderr
    got = json.loads(out.read_text())
    assert got["samples"] == 5 and got["interval_s"] == 0.1
    assert len(got["threads"]) >= 3  # the main thread and two sleepers
    for t in got["threads"].values():
        assert sum(t["cpus"].values()) == 5
        assert all(re.fullmatch(r"\d+", c) for c in t["cpus"])


def test_thread_cpus_counts_field_39_after_a_comm_with_parentheses(
    env: dict[str, str], tmp_path: Path
) -> None:
    # A sampler fed a fake /proc: the comm holds spaces and a ")"; the CPU is still field 39.
    proc = tmp_path / "proc" / "4242" / "task" / "4243"
    proc.mkdir(parents=True)
    fields = ["S"] + ["0"] * 35 + ["5", "0"]  # fields 3..40: 37th is field 39
    (proc / "stat").write_text("4243 (a) b c) " + " ".join(fields) + "\n")
    script = tmp_path / "run.sh"
    script.write_text(
        '. "' + str(LIB) + '"\n'
        f'sed "s#/proc/#{tmp_path}/proc/#" <<<"$_THREAD_CPUS_SH" >"{tmp_path}/sampler.sh"\n'
        f"sh {tmp_path}/sampler.sh 4242 1 0\n"
    )
    run = subprocess.run(
        ["bash", str(script)],
        capture_output=True,
        text=True,
        env={**os.environ, **env},
        check=False,
    )
    assert run.stdout.split() == ["4243", "5"], run.stderr


def test_thread_cpus_runs_in_the_guest_on_request_and_dies_without_tasks(
    env: dict[str, str], tmp_path: Path
) -> None:
    out = tmp_path / "t.json"
    run = sh(
        "THREAD_CPUS_GUEST=1 THREAD_CPUS_SECONDS=0.2 THREAD_CPUS_INTERVAL=0.1"
        f" thread_cpus $$ {out}",
        env,
    )
    assert run.returncode == 0, run.stderr
    assert "sh -c" in log(tmp_path, "ssh.log")[0]
    run = sh(f"thread_cpus 999999999 {out}", env)
    assert run.returncode != 0
    assert "no tasks" in run.stderr


# ---- vcpupin_record --------------------------------------------------------------------------


def test_vcpupin_record_writes_the_pins_of_the_guarded_domain(
    env: dict[str, str], tmp_path: Path
) -> None:
    out = tmp_path / "pins.json"
    run = sh(f"vcpupin_record {out}", env)
    assert run.returncode == 0, run.stderr
    assert json.loads(out.read_text()) == [{"vcpu": 0, "cpus": "4"}, {"vcpu": 1, "cpus": "6-7"}]
    assert log(tmp_path, "virsh.log") == ["qemu:///system|vcpupin lowlat-target"]


def test_vcpupin_record_refuses_a_domain_outside_the_lab_prefix(
    env: dict[str, str], tmp_path: Path
) -> None:
    out = tmp_path / "pins.json"
    run = sh(f"vcpupin_record {out}", {**env, "TARGET_VM": "ebpf-target"})
    assert run.returncode != 0
    assert "refusing" in run.stderr
    assert log(tmp_path, "virsh.log") == [] and not out.exists()


# ---- static checks ---------------------------------------------------------------------------

HELPERS = (
    "lane_revert guest_noise guest_noise_wait interrupts_delta cyclictest_run thread_cpus "
    "vcpupin_record _quiet_lab_run _lab_target"
).split()


def body(name: str) -> list[str]:
    text = LIB.read_text().splitlines()
    start = next(i for i, line in enumerate(text) if re.match(rf"{name}\(\) [{{(]", line))
    end = next(i for i in range(start + 1, len(text)) if text[i] in ("}", ")"))
    return text[start : end + 1]


def test_no_helper_calls_sudo_outside_a_guest_command_string() -> None:
    sudo_lines = 0
    for name in HELPERS:
        for line in body(name):
            code = line.strip()
            if code.startswith("#") or not re.search(r"\bsudo\b", code):
                continue
            sudo_lines += 1
            assert re.search(r"\b(lab_ssh|guest)\b", code), (
                f"{name}: sudo outside a guest command: {code}"
            )
            assert not code.startswith("sudo"), f"{name}: sudo run on the host: {code}"
    assert sudo_lines >= 2  # cyclictest_run's run and clean-up lines: the check saw something


def test_the_script_is_clean_under_bash_n_and_shellcheck() -> None:
    assert subprocess.run(["bash", "-n", str(LIB)], check=False).returncode == 0
    uvx = shutil.which("shellcheck") or None
    cmd = (
        [uvx, "-x", str(LIB)]
        if uvx
        else ["uvx", "--from", "shellcheck-py", "shellcheck", "-x", str(LIB)]
    )
    if not uvx and not shutil.which("uvx"):
        pytest.skip("neither shellcheck nor uvx is available")
    run = subprocess.run(cmd, capture_output=True, text=True, check=False)
    assert run.returncode == 0, run.stdout + run.stderr
