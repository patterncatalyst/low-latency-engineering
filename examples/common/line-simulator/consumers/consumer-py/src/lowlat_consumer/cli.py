"""Line consumer: receive ``ParcelEvent`` datagrams, record latency from the schedule.

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

Why a blocking socket and not ``asyncio`` or ``selectors``: with a single socket there
is nothing to multiplex. ``asyncio`` would add an event-loop iteration and a callback
dispatch per datagram, which is pure added latency. A blocking ``recv_into`` on a
socket with a short timeout is the shortest path; the timeout is also what makes the
idle timeout and signal-driven shutdown work without a second thread.
"""

from __future__ import annotations

import argparse
import signal
import socket
import sys
import time
from collections.abc import Sequence
from types import FrameType

from lowlat.line.v1.parcel_pb2 import ParcelEvent
from lowlat_measure import Recorder
from lowlat_measure.recorder import load_profile
from lowlat_measure.table import format_rows

from lowlat_consumer.gaps import GapTracker
from lowlat_consumer.handle import lane_for

DEFAULT_BIND = "127.0.0.1:47000"
DEFAULT_RCVBUF = 4 * 1024 * 1024
DEFAULT_IDLE_MS = 2000
MAX_DATAGRAM = 2048  # a ParcelEvent is ~60 bytes; this is generous
POLL_S = 0.05  # recv timeout slice: bounds signal and idle-timeout latency

_stop = False


class NegativeLatencyError(RuntimeError):
    """The producer and consumer are not on the same CLOCK_MONOTONIC."""


def _on_signal(signum: int, _frame: FrameType | None) -> None:
    global _stop
    _stop = True


def parse_hostport(text: str) -> tuple[str, int]:
    host, sep, port = text.rpartition(":")
    if not sep or not host or not port.isdigit():
        raise argparse.ArgumentTypeError(f"expected HOST:PORT, got {text!r}")
    return host, int(port)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="line-consumer-py",
        description="Receive ParcelEvent datagrams and record latency against the schedule.",
    )
    p.add_argument(
        "--bind",
        type=parse_hostport,
        default=parse_hostport(DEFAULT_BIND),
        metavar="HOST:PORT",
        help=f"UDP address to bind (default {DEFAULT_BIND})",
    )
    p.add_argument(
        "--rcvbuf",
        type=int,
        default=DEFAULT_RCVBUF,
        metavar="BYTES",
        help="SO_RCVBUF request; the kernel may grant less (default 4 MiB)",
    )
    p.add_argument(
        "--expect",
        type=int,
        default=None,
        metavar="N",
        help="stop after N datagrams (received + dropped)",
    )
    p.add_argument(
        "--idle-timeout-ms",
        type=int,
        default=DEFAULT_IDLE_MS,
        metavar="MS",
        help="stop after MS with nothing received, once the first arrived",
    )
    p.add_argument(
        "--report",
        metavar="FILE",
        help="write the lowlat-report/1 JSON here (needs LOWLAT_PROFILE)",
    )
    p.add_argument("--example", default="00-line-consumer", help="report example name")
    p.add_argument("--variant", default="baseline", help="report variant name")
    return p


def open_socket(bind: tuple[str, int], rcvbuf: int) -> tuple[socket.socket, int]:
    """Bind the UDP socket; return it with the receive buffer the kernel granted."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    granted = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    sock.bind(bind)
    sock.settimeout(POLL_S)
    return sock, granted


def run(
    sock: socket.socket, rec: Recorder, tracker: GapTracker, expect: int | None, idle_ns: int
) -> None:
    """The receive loop. Raises NegativeLatencyError; returns on expect/idle/signal."""
    buf = bytearray(MAX_DATAGRAM)  # reused for every datagram
    view = memoryview(buf)
    event = ParcelEvent()  # reused; ParseFromString clears it
    now = time.monotonic_ns
    last_rx_ns = 0
    while not _stop:
        try:
            n = sock.recv_into(buf)
        except TimeoutError:
            if tracker.received and now() - last_rx_ns >= idle_ns:
                return
            continue
        event.ParseFromString(view[:n])
        if not tracker.observe(event.seq):
            continue
        lane_for(event.barcode)
        done_ns = now()
        last_rx_ns = done_ns
        latency = done_ns - event.intended_emit_ns
        if latency < 0:
            raise NegativeLatencyError(
                f"negative latency {latency} ns for seq {event.seq}: producer and consumer "
                "are not on the same CLOCK_MONOTONIC (same host or VM required)"
            )
        rec.record(latency)
        if expect is not None and tracker.accounted >= expect:
            return


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    global _stop
    _stop = False
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)

    try:
        load_profile()  # fail before the run, not after it
    except RuntimeError as exc:
        print(f"line-consumer-py: {exc}", file=sys.stderr)
        return 2

    sock, granted = open_socket(args.bind, args.rcvbuf)
    host, port = args.bind
    print(
        f"line-consumer-py: bound {host}:{port}, SO_RCVBUF requested {args.rcvbuf} "
        f"granted {granted} (Linux reports double the set value; capped by "
        "net.core.rmem_max)",
        flush=True,
    )

    rec = Recorder(args.example, args.variant)
    tracker = GapTracker()
    try:
        with sock:
            run(sock, rec, tracker, args.expect, args.idle_timeout_ms * 1_000_000)
    except NegativeLatencyError as exc:
        print(f"line-consumer-py: ABORT: {exc}", file=sys.stderr)
        return 2

    rec.add_dropped(tracker.dropped)
    print(
        f"line-consumer-py: received {tracker.received} dropped {tracker.dropped} "
        f"reordered {tracker.reordered}",
        flush=True,
    )
    notes = (
        f"reordered={tracker.reordered}; rcvbuf_requested={args.rcvbuf}; "
        f"rcvbuf_granted={granted}; single thread, GIL"
    )
    report = rec.write_report(args.report, notes) if args.report else rec.build_report(notes)
    print(format_rows([report]))
    return 0
