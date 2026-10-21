"""Sequence-gap accounting for the datagram stream."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(slots=True)
class GapTracker:
    """Tracks ``seq`` and classifies each datagram.

    A jump forward by more than one adds the missing count to ``dropped``.
    A ``seq`` at or below the highest seen is ``reordered`` (or duplicated) and
    must not be recorded a second time. ``accounted`` is received plus dropped,
    which is what ``--expect`` counts.
    """

    highest: int = -1
    dropped: int = 0
    reordered: int = 0
    received: int = 0

    def observe(self, seq: int) -> bool:
        """Account for ``seq``; return True if it is new (in order, to be recorded)."""
        if seq <= self.highest:
            self.reordered += 1
            return False
        self.dropped += seq - self.highest - 1
        self.highest = seq
        self.received += 1
        return True

    @property
    def accounted(self) -> int:
        return self.received + self.dropped
