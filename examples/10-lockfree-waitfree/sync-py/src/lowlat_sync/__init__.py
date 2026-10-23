"""Ch10: lock-free and wait-free, Python lane. Wiring only (S4); the lane lands in S6."""

import sys
import threading


def python_build() -> str:
    """`free-threaded` if the GIL is off in this interpreter, else `gil` (runtime.python_build)."""
    return "gil" if sys._is_gil_enabled() else "free-threaded"


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
