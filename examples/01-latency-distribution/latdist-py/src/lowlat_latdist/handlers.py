"""The three handling policies: the only per-example code in the receive path.

Each is a ``lowlat_consumer.Handler``: called once per new parcel with the event (reused
by the loop, so copy what must outlive the call) and the ``Completion`` to report done.
"""

from __future__ import annotations

import time

from lowlat.line.v1.parcel_pb2 import ParcelEvent
from lowlat_consumer import Completion, lane_for

from lowlat_latdist.work import calibrate, spin

now = time.monotonic_ns


def per_parcel(event: ParcelEvent, complete: Completion) -> None:
    """Handle the parcel on arrival."""
    lane_for(event.barcode)
    complete(event.intended_emit_ns, now())


class Batch:
    """Hold parcels until ``size`` have arrived, then handle and complete them together."""

    def __init__(self, size: int) -> None:
        self.size = size
        self._pending: list[tuple[int, str]] = []  # (intended_emit_ns, barcode)

    def __call__(self, event: ParcelEvent, complete: Completion) -> None:
        self._pending.append((event.intended_emit_ns, event.barcode))
        if len(self._pending) >= self.size:
            self.drain(complete)

    def drain(self, complete: Completion) -> None:
        """Complete what is held; also the loop's end-of-run hook for a partial last batch."""
        for _, barcode in self._pending:
            lane_for(barcode)
        done_ns = now()  # one completion time for the whole batch
        for intended_ns, _ in self._pending:
            complete(intended_ns, done_ns)
        self._pending.clear()

    def notes(self) -> str:
        return f"; batch={self.size}"


class Bimodal:
    """Per-parcel, but one parcel in ``every`` runs the slow path: a busy loop, not a sleep."""

    def __init__(self, every: int, slow_us: int) -> None:
        self.every = every
        self.slow_count = 0
        self.iterations = calibrate(slow_us)
        t0 = now()
        spin(self.iterations)
        self.measured_ns = now() - t0
        print(
            f"calibrated slow path: {self.iterations} iterations = {self.measured_ns / 1e3:.1f} us",
            flush=True,
        )

    def __call__(self, event: ParcelEvent, complete: Completion) -> None:
        lane_for(event.barcode)
        if event.seq % self.every == 0:
            spin(self.iterations)  # the re-lookup: real CPU work, not a sleep
            self.slow_count += 1
        complete(event.intended_emit_ns, now())

    def notes(self) -> str:
        return (
            f"; slow_every={self.every}; slow_parcels={self.slow_count}; "
            f"slow_path_us={self.measured_ns / 1e3:.1f}; busy loop, not sleep"
        )
