"""Ch10: lock-free and wait-free, Python lane. Wiring only (S4); the lane lands in S6."""

import sys
import sysconfig
import threading


def python_build() -> str:
    """`free-threaded` for the free-threaded build, else `gil` (runtime.python_build).

    The build comes from the interpreter's configuration, not from the live GIL state: an
    extension that does not declare free-threading support re-enables the GIL at import time in a
    free-threaded interpreter, which `gil_enabled` reports separately.
    """
    return "free-threaded" if sysconfig.get_config_var("Py_GIL_DISABLED") else "gil"


def gil_enabled() -> bool:
    """Whether the GIL is on right now (False only for a free-threaded build that kept it off)."""
    return sys._is_gil_enabled()


def claim_all(threads: int, per_thread: int) -> list[int]:
    """Claim sequences under a lock from several threads; returns every claimed sequence."""
    lock = threading.Lock()
    next_seq = 0
    claimed: list[list[int]] = [[] for _ in range(threads)]

    def worker(slot: int) -> None:
        nonlocal next_seq
        for _ in range(per_thread):
            with lock:
                seq = next_seq
                next_seq += 1
            claimed[slot].append(seq)

    pool = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
    for t in pool:
        t.start()
    for t in pool:
        t.join()
    return [seq for part in claimed for seq in part]
