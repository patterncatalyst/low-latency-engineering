"""Line receive loop: receive ``ParcelEvent`` datagrams, record latency from the schedule.

Execution model, stated plainly because it is part of the result:

* One thread, one process, under the GIL (``build.gil_enabled`` in the report says
  whether this interpreter is the GIL or the free-threaded build). There is no
  concurrency to exploit: one socket, one in-order stream.
* Per-datagram Python overhead (``recv_into``, protobuf parse, barcode handling,
  ``monotonic_ns``, histogram record) is on the measured path. It costs microseconds
  and is included in every latency this program reports. That is the point of the
  Python column: it is what the language costs here, not a defect to hide.
* Latency is ``done_ns - intended_emit_ns``: measured from the belt's schedule, so
  time a datagram waited in the socket buffer is included (no coordinated omission).
* The loop does bind, parse, gap tracking and recording. What an example does with each
  parcel is a ``Handler`` callable passed to ``run`` (see ``Completion``), so an example
  supplies only its handling.

Why a blocking socket and not ``asyncio`` or ``selectors``: with a single socket there
is nothing to multiplex. ``asyncio`` would add an event-loop iteration and a callback
dispatch per datagram, which is pure added latency. A blocking ``recv_into`` on a
socket with a short timeout is the shortest path; the timeout is also what makes the
idle timeout and signal-driven shutdown work without a second thread.
"""

import signal
import socket
import time
from collections.abc import Callable
from dataclasses import dataclass
from types import FrameType
from typing import Literal

from lowlat.line.v1.parcel_pb2 import ParcelEvent
from lowlat_measure import Recorder

from lowlat_consumer.gaps import GapTracker
from lowlat_consumer.handle import lane_for

DEFAULT_RCVBUF = 4 * 1024 * 1024
MAX_DATAGRAM = 2048  # a ParcelEvent is ~60 bytes; this is generous
POLL_S = 0.05  # recv timeout slice: bounds signal and idle-timeout latency

_stop = False


class NegativeLatencyError(RuntimeError):
    """The producer and consumer are not on the same CLOCK_MONOTONIC."""


def _on_signal(signum: int, _frame: FrameType | None) -> None:
    global _stop
    _stop = True


def install_signal_handlers() -> None:
    """Make SIGINT and SIGTERM end ``run`` at its next poll; clears an earlier stop."""
    global _stop
    _stop = False
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)


class Completion:
    """Where a handler reports that a parcel is done.

    Calling it records ``done_ns - intended_emit_ns``. A handler may call it inside the
    handler call (per-parcel) or later (a batch keeps ``event.intended_emit_ns`` and
    completes every held parcel when the batch is full). It also keeps the first and last
    done time, from which a handler's caller derives throughput.
    """

    __slots__ = ("_rec", "count", "first_done_ns", "last_done_ns", "seq")

    def __init__(self, rec: Recorder) -> None:
        self._rec = rec
        self.seq = 0  # set by the loop: the parcel being handled, for error messages
        self.count = 0
        self.first_done_ns = 0
        self.last_done_ns = 0

    def __call__(self, intended_emit_ns: int, done_ns: int) -> None:
        latency = done_ns - intended_emit_ns
        if latency < 0:
            raise NegativeLatencyError(
                f"negative latency {latency} ns for seq {self.seq}: producer and consumer "
                "are not on the same CLOCK_MONOTONIC (same host or VM required)"
            )
        self._rec.record(latency)
        if not self.count:
            self.first_done_ns = done_ns
        self.last_done_ns = done_ns
        self.count += 1


type Handler = Callable[[ParcelEvent, Completion], None]
"""The per-parcel hook: called once per new parcel with the (reused, so do not keep it)
event and the ``Completion``. It must complete every parcel, now or later."""

type Drain = Callable[[Completion], None]
"""Optional: called once when the run ends, to complete the parcels a handler still holds."""


@dataclass(frozen=True, slots=True)
class RunResult:
    stopped: Literal["expect", "idle", "signal"]
    completed: int
    first_done_ns: int
    last_done_ns: int


def lane_handler(event: ParcelEvent, complete: Completion) -> None:
    """Example 00's handler: the lane lookup is the work, then done."""
    lane_for(event.barcode)
    complete(event.intended_emit_ns, time.monotonic_ns())


def open_socket(bind: tuple[str, int], rcvbuf: int) -> tuple[socket.socket, int]:
    """Bind the UDP socket; return it with the receive buffer the kernel granted."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        granted = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        sock.bind(bind)
        sock.settimeout(POLL_S)
    except BaseException:
        sock.close()
        raise
    return sock, granted


def run(
    sock: socket.socket,
    rec: Recorder,
    tracker: GapTracker,
    handler: Handler,
    expect: int | None,
    idle_ns: int,
    drain: Drain | None = None,
) -> RunResult:
    """The receive loop: parse, track gaps, call ``handler`` per new parcel.

    Raises NegativeLatencyError; returns on expect, idle timeout or signal, after calling
    ``drain`` and booking the gaps into ``rec``."""
    buf = bytearray(MAX_DATAGRAM)  # reused for every datagram
    view = memoryview(buf)
    event = ParcelEvent()  # reused; ParseFromString clears it
    done = Completion(rec)
    now = time.monotonic_ns
    last_rx_ns = 0
    stopped: Literal["expect", "idle", "signal"] = "signal"
    while not _stop:
        if expect is not None and tracker.accounted >= expect:
            stopped = "expect"
            break
        try:
            n = sock.recv_into(buf)
        except TimeoutError:
            if tracker.received and now() - last_rx_ns >= idle_ns:
                stopped = "idle"
                break
            continue
        # Stamped on receipt, not on completion: a handler may hold parcels for a while.
        last_rx_ns = now()
        event.ParseFromString(view[:n])
        if not tracker.observe(event.seq):
            continue
        done.seq = event.seq
        handler(event, done)
    if drain is not None:
        drain(done)
    rec.add_dropped(tracker.dropped)
    return RunResult(stopped, done.count, done.first_done_ns, done.last_done_ns)
