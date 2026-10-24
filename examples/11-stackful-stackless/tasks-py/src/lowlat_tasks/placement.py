"""Thread placement for the Python lane: `os.sched_setaffinity` on our own threads.

Adapted from example 10.

An experiment control, not isolation; it needs no privilege and changes nothing on the host. The
start of a pinned run follows the protocol of the C++ and Java lanes: every worker pins itself and
waits, the coordinating thread prints one `pinned pid=P tid=T cpu=C role=R` line per thread and
`placement-ready`, holds, prints `released` and lets them go together, so a script can check each
thread's CPU in /proc and start its load on `released`.
"""

import os
import sys
import sysconfig
import threading
import time
from pathlib import Path

_SYS_CPU = Path("/sys/devices/system/cpu")


def parse_cpus(text: str) -> list[int]:
    try:
        cpus = [int(part) for part in text.split(",")]
    except ValueError as exc:
        raise ValueError(f"--cpus: {text!r} is not a list of CPU numbers") from exc
    if not cpus or min(cpus) < 0:
        raise ValueError(f"--cpus: {text!r} is not a list of CPU numbers")
    return cpus


def current_cpu() -> int:
    """The CPU the calling thread last ran on (field 39 of /proc/thread-self/stat)."""
    stat = Path("/proc/thread-self/stat").read_text(encoding="ascii")
    return int(stat.rpartition(")")[2].split()[36])


def ctx_switches() -> tuple[int, int]:
    """The calling thread's voluntary and involuntary context switches so far."""
    voluntary = involuntary = 0
    for line in Path("/proc/thread-self/status").read_text(encoding="ascii").splitlines():
        if line.startswith("voluntary_ctxt_switches:"):
            voluntary = int(line.split()[1])
        elif line.startswith("nonvoluntary_ctxt_switches:"):
            involuntary = int(line.split()[1])
    return voluntary, involuntary


def _core_of(cpu: int) -> tuple[str, str]:
    topology = _SYS_CPU / f"cpu{cpu}" / "topology"

    def read(name: str, fallback: str) -> str:
        try:
            return (topology / name).read_text(encoding="ascii").strip()
        except OSError:
            return fallback

    return read("physical_package_id", "0"), read("core_id", str(cpu))


def placement_of(cpus: list[int]) -> dict[str, object]:
    """`runtime.placement` for pinned `cpus`: distinct physical cores, SMT siblings, from sysfs."""
    cores = [_core_of(cpu) for cpu in cpus]
    siblings = len(set(cores)) < len(cores)
    return {"cpus": cpus, "distinct_cores": not siblings, "smt_siblings": siblings}


class Gate:
    """The start of a pinned run: workers call `worker_ready`, the coordinator calls `release`.

    Each worker stamps CLOCK_MONOTONIC as it leaves the gate; `start_skew_ns` is the stamps' spread.
    """

    def __init__(self, workers: int, hold_ms: int = 0, *, announce: bool = True) -> None:
        self._barrier = threading.Barrier(workers + 1)
        self._hold_ms = hold_ms
        self._announce = announce
        self._lock = threading.Lock()
        self._lines: list[str] = []
        self._left: list[int] = []

    def worker_ready(self, cpu: int, role: str) -> None:
        try:
            if cpu >= 0:
                os.sched_setaffinity(0, {cpu})  # pid 0: the calling thread
                if (on := current_cpu()) != cpu:
                    raise RuntimeError(f"pinned to CPU {cpu} but running on CPU {on}")
            if cpu >= 0:
                with self._lock:
                    self._lines.append(
                        f"pinned pid={os.getpid()} tid={threading.get_native_id()} "
                        f"cpu={current_cpu()} role={role}"
                    )
        except BaseException:
            self._barrier.abort()
            raise
        self._barrier.wait()
        self._barrier.wait()
        stamp = time.monotonic_ns()
        with self._lock:
            self._left.append(stamp)

    def start_skew_ns(self) -> int:
        """Latest minus earliest worker stamp after the release (0 for fewer than two workers)."""
        with self._lock:
            return max(self._left) - min(self._left) if len(self._left) > 1 else 0

    def release(self) -> None:
        self._barrier.wait()
        if self._announce:
            with self._lock:
                for line in self._lines:
                    print(line)
            print("placement-ready", flush=True)
        time.sleep(self._hold_ms / 1000)
        if self._announce:
            print("released", flush=True)
        self._barrier.wait()


def free_threaded_build() -> bool:
    return bool(sysconfig.get_config_var("Py_GIL_DISABLED"))


def require_gil_off_if_free_threaded() -> None:
    """Exit when a free-threaded interpreter has the GIL back on (an import re-enabled it)."""
    if free_threaded_build() and sys._is_gil_enabled():
        raise SystemExit(
            "this free-threaded interpreter re-enabled the GIL (an extension does not support it)"
        )
