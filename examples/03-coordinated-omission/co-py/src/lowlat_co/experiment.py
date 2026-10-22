"""One stall, measured three ways.

The receive phase records ``receipt-time`` and ``intended-time`` from the same datagrams;
the closed-loop phase records one request stream plain and through ``record_corrected``.
Single thread under the GIL: the per-datagram interpreter cost is part of every number.
"""

import socket
import time
from collections.abc import Callable
from dataclasses import dataclass, field

from lowlat.line.v1.parcel_pb2 import ParcelEvent
from lowlat_consumer.gaps import GapTracker
from lowlat_consumer.handle import lane_for
from lowlat_measure import Recorder

EXAMPLE = "03-coordinated-omission"
EXPECTED_INTERVAL_NS = 1_000_000  # the closed-loop client's 1 ms request interval

# Probe variant -> (clock name for the report notes, the clock).
CLOCKS: dict[str, tuple[str, Callable[[], int]]] = {
    "clock-read": ("time.monotonic_ns", time.monotonic_ns),
    "clock-read-perf_counter_ns": ("time.perf_counter_ns", time.perf_counter_ns),
}


@dataclass
class Recorders:
    """The four recorders of one run. Variant names carry the suffix, e.g. ``-control``."""

    suffix: str = ""
    receipt_time: Recorder = field(init=False)
    intended_time: Recorder = field(init=False)
    closed_loop_corrected: Recorder = field(init=False)
    closed_loop_naive: Recorder = field(init=False)

    def __post_init__(self) -> None:
        self.receipt_time = Recorder(EXAMPLE, "receipt-time" + self.suffix)
        self.intended_time = Recorder(EXAMPLE, "intended-time" + self.suffix)
        self.closed_loop_corrected = Recorder(EXAMPLE, "closed-loop-corrected" + self.suffix)
        self.closed_loop_naive = Recorder(EXAMPLE, "closed-loop-naive" + self.suffix)


def stall(ms: int) -> None:
    """The stall: a blocking sleep, which models a GC pause, a page fault or a lock convoy.

    It is the one place in this example where sleeping is the right tool.
    """
    time.sleep(ms / 1000)


def receive(
    sock: socket.socket,
    rec: Recorders,
    *,
    expect: int,
    stall_ms: int,
    stall_seq: int,
    idle_ns: int = 2_000_000_000,
) -> int:
    """Receive ``expect`` parcels; return how many never arrived."""
    sock.settimeout(0.1)  # bounds the idle check
    buf = bytearray(2048)
    view = memoryview(buf)
    event = ParcelEvent()
    tracker = GapTracker()
    now = time.monotonic_ns
    last_rx_ns = 0
    while tracker.accounted < expect:
        try:
            n = sock.recv_into(buf)
        except TimeoutError:
            if tracker.received and now() - last_rx_ns >= idle_ns:
                break
            continue
        # Just dequeued: this is where a service-side timer starts its clock, however
        # long the parcel waited in the socket buffer.
        dequeued_ns = now()
        last_rx_ns = dequeued_ns
        event.ParseFromString(view[:n])
        if not tracker.observe(event.seq):
            continue
        lane_for(event.barcode)
        if stall_ms and event.seq == stall_seq:
            stall(stall_ms)
        done_ns = now()
        rec.receipt_time.record(done_ns - dequeued_ns)
        rec.intended_time.record(done_ns - event.intended_emit_ns)
    rec.receipt_time.add_dropped(tracker.dropped)
    rec.intended_time.add_dropped(tracker.dropped)
    return tracker.dropped


def closed_loop(rec: Recorders, requests: int, *, stall_ms: int, stall_seq: int) -> None:
    """``requests`` closed-loop requests, one per interval.

    Each starts, handles one parcel, finishes, and only then is the next issued; request
    ``stall_seq`` stalls. The latency goes in plain and through ``record_corrected``.
    """
    barcode = "006141410000000134"
    now = time.monotonic_ns
    for i in range(requests):
        start_ns = now()
        lane_for(barcode)
        if stall_ms and i == stall_seq:
            stall(stall_ms)
        latency_ns = now() - start_ns
        rec.closed_loop_naive.record(latency_ns)
        rec.closed_loop_corrected.record_corrected(latency_ns, EXPECTED_INTERVAL_NS)

        # Closed loop: the next request is issued only now. Nothing queues behind the
        # stall, so nothing is measured as having waited.
        wait_ns = start_ns + EXPECTED_INTERVAL_NS - now()
        if wait_ns > 0:
            time.sleep(wait_ns / 1e9)


def clock_probe(calls: int) -> dict[str, Recorder]:
    """Cost of one clock read: two back-to-back reads, the difference recorded."""
    out: dict[str, Recorder] = {}
    for variant, (_, clock) in CLOCKS.items():
        rec = Recorder(EXAMPLE, variant)
        record = rec.record
        for _ in range(calls):
            a = clock()
            b = clock()
            record(b - a)
        out[variant] = rec
    return out
