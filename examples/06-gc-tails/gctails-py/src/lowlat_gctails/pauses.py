"""Collector pauses from ``gc.callbacks``, recorded off the parcel path.

CPython calls every registered callback twice per collection, ``"start"`` and ``"stop"``, on the
thread that triggered it. The callback here does the least that can be done there: read the
monotonic clock and store into buffers allocated before the run. Nothing is formatted, appended
to a growing list or turned into a histogram sample while parcels are arriving; that happens in
:meth:`GcPauseLog.durations_ns` after the run.

The pause is the whole collection: CPython's collector is stop-the-world for the thread that runs
it (and, under the GIL, for every other thread).
"""

import gc
import time
from array import array
from collections.abc import Iterator
from dataclasses import dataclass
from types import TracebackType
from typing import Self

DEFAULT_CAPACITY = 65_536


@dataclass(frozen=True, slots=True)
class Collection:
    generation: int
    duration_ns: int
    collected: int


class GcPauseLog:
    """Context manager that records every collection in its window.

    A run that outlasts ``capacity`` collections keeps counting but stops storing; ``overflow``
    says how many were not stored.
    """

    def __init__(self, capacity: int = DEFAULT_CAPACITY) -> None:
        self._capacity = capacity
        self._generation = array("b", bytes(capacity))
        self._duration_ns = array("q", bytes(8 * capacity))
        self._collected = array("q", bytes(8 * capacity))
        self._started_ns = 0
        self._count = 0

    def __call__(self, phase: str, info: dict[str, int]) -> None:
        if phase == "start":
            self._started_ns = time.monotonic_ns()
            return
        i = self._count
        self._count = i + 1
        if i < self._capacity:
            self._duration_ns[i] = time.monotonic_ns() - self._started_ns
            self._generation[i] = info["generation"]
            self._collected[i] = info["collected"]

    def __enter__(self) -> Self:
        gc.callbacks.append(self)
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        gc.callbacks.remove(self)

    @property
    def count(self) -> int:
        """Collections seen in the window."""
        return self._count

    @property
    def overflow(self) -> int:
        """Collections seen but not stored."""
        return max(0, self._count - self._capacity)

    def collections(self) -> Iterator[Collection]:
        for i in range(min(self._count, self._capacity)):
            yield Collection(self._generation[i], self._duration_ns[i], self._collected[i])

    def generation_counts(self) -> tuple[int, int, int]:
        """Collections of generation 0, 1 and 2 (counted from the callbacks)."""
        counts = [0, 0, 0]
        for c in self.collections():
            counts[c.generation] += 1
        return counts[0], counts[1], counts[2]
