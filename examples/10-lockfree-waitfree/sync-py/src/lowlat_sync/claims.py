"""Three ways to hand out the next sequence number to several threads.

The point of the lane is what each costs and what each guarantees, not speed:

* `LockClaim`: `threading.Lock` around a counter. Exactly once in both builds.
* `CountClaim`: `next()` on one shared `itertools.count`. Exactly once under the GIL in practice.
  CPython documents no thread safety for it, and the free-threading howto says threads sharing
  an iterator may see duplicate or missing elements, so the lane reports what it saw and asserts
  nothing.
* `RacyClaim`: `value = n; n += 1` with no synchronisation at all. Under the GIL a thread switch
  between the read and the write can lose a claim, though the interpreter rarely switches there;
  without the GIL threads run the read-modify-write in parallel and lose claims by the thousand.
"""

import itertools
import threading
from typing import Protocol


class Claim(Protocol):
    def claim(self) -> int:
        """The next sequence number."""
        ...


class LockClaim:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._next = 0

    def claim(self) -> int:
        with self._lock:
            seq = self._next
            self._next += 1
            return seq


class CountClaim:
    def __init__(self) -> None:
        self._count = itertools.count()

    def claim(self) -> int:
        return next(self._count)


class RacyClaim:
    def __init__(self) -> None:
        self._next = 0

    def claim(self) -> int:
        seq = self._next
        self._next += 1
        return seq


def claim_for(variant: str, *, racy: bool = False) -> Claim:
    """The claim for `--variant`; `racy` replaces the lock of `lock` by nothing (`--racy-claim`)."""
    if variant == "lock":
        return RacyClaim() if racy else LockClaim()
    if racy:
        raise ValueError("--racy-claim drops the lock of --variant lock")
    if variant == "itertools-count":
        return CountClaim()
    raise ValueError("--variant: lock | itertools-count")
