"""Sequence-gap accounting for the datagram stream."""

from dataclasses import dataclass


@dataclass(slots=True)
class GapTracker:
    """Tracks ``seq`` and classifies each datagram.

    A jump forward by more than one adds the missing count to ``dropped``.
    A ``seq`` at or below the highest seen is ``reordered`` (or duplicated) and
    must not be recorded a second time. ``accounted`` is received plus dropped,
    which is what ``--expect`` counts. With a ``window``, ``dropped_below_window`` counts
    the dropped parcels numbered below it.
    """

    highest: int = -1
    dropped: int = 0
    reordered: int = 0
    received: int = 0
    dropped_below_window: int = 0
    window: int = 0

    def observe(self, seq: int) -> bool:
        """Account for ``seq``; return True if it is new (in order, to be recorded)."""
        if seq <= self.highest:
            self.reordered += 1
            return False
        first_missing = self.highest + 1
        self.dropped += seq - first_missing
        if first_missing < self.window:
            self.dropped_below_window += min(seq, self.window) - first_missing
        self.highest = seq
        self.received += 1
        return True

    @property
    def accounted(self) -> int:
        return self.received + self.dropped
