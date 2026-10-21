"""Receive ``ParcelEvent`` datagrams and handle them per-parcel, in batches, or bimodally.

The common ``line-consumer-py`` has no hook between "received" and "done", so this
copies its minimal receive loop (blocking socket, reused buffer, GapTracker) and adds
the handling policy. Variants:

* ``per-parcel``    handle each parcel on arrival.
* ``batch-32``      hold 32 parcels, then handle them together; one done time per batch.
* ``bimodal-1pct``  per-parcel, but ``seq % 100 == 0`` runs a ~2 ms busy loop.
"""

from __future__ import annotations

import argparse
import signal
import socket
import sys
import time
from collections.abc import Sequence

from lowlat.line.v1.parcel_pb2 import ParcelEvent
from lowlat_consumer.gaps import GapTracker
from lowlat_consumer.handle import lane_for
from lowlat_measure import Recorder
from lowlat_measure.recorder import load_profile
from lowlat_measure.table import format_rows

from lowlat_latdist.work import calibrate, spin

VARIANTS = ("per-parcel", "batch-32", "bimodal-1pct")
BATCH = 32
SLOW_EVERY = 100

_stop = False


def _on_signal(_signum: int, _frame: object) -> None:
    global _stop
    _stop = True


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="latdist-py", description=__doc__)
    p.add_argument("--variant", choices=VARIANTS, default="per-parcel")
    p.add_argument("--bind", default="127.0.0.1:47210", metavar="HOST:PORT")
    p.add_argument("--expect", type=int)
    p.add_argument("--idle-timeout-ms", type=int, default=2000)
    p.add_argument("--slow-us", type=int, default=2000)
    p.add_argument("--report")
    p.add_argument("--example", default="01-latency-distribution")
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    try:
        load_profile()
    except RuntimeError as exc:
        print(f"latdist-py: {exc}", file=sys.stderr)
        return 2

    now = time.monotonic_ns
    slow_iterations = slow_measured_ns = 0
    if args.variant == "bimodal-1pct":
        slow_iterations = calibrate(args.slow_us)
        t0 = now()
        spin(slow_iterations)
        slow_measured_ns = now() - t0
        print(
            f"calibrated slow path: {slow_iterations} iterations = {slow_measured_ns / 1e3:.1f} us"
        )

    host, _, port = args.bind.rpartition(":")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    sock.bind((host, int(port)))
    sock.settimeout(0.05)
    print(f"latdist-py: variant {args.variant} on {args.bind}", flush=True)

    rec = Recorder(args.example, args.variant)
    tracker = GapTracker()
    idle_ns = args.idle_timeout_ms * 1_000_000
    batched = args.variant == "batch-32"
    pending: list[tuple[int, str]] = []
    first_done = last_done = last_rx = done_count = slow_count = booked_dropped = 0
    buf = bytearray(2048)
    view = memoryview(buf)
    event = ParcelEvent()

    def finish(intended: list[int], done_ns: int) -> None:
        nonlocal first_done, last_done, done_count
        for ts in intended:
            latency = done_ns - ts
            if latency < 0:
                raise RuntimeError(f"negative latency {latency} ns: not one CLOCK_MONOTONIC")
            rec.record(latency)
        if not done_count:
            first_done = done_ns
        last_done = done_ns
        done_count += len(intended)

    def flush() -> None:
        for _, barcode in pending:
            lane_for(barcode)
        finish([ts for ts, _ in pending], now())  # one completion time for the whole batch
        pending.clear()

    stopped = "signal"
    with sock:
        while not _stop:
            if args.expect is not None and tracker.accounted >= args.expect:
                stopped = "expect"
                break
            try:
                n = sock.recv_into(buf)
            except TimeoutError:
                if last_rx and now() - last_rx >= idle_ns:
                    stopped = "idle"
                    break
                continue
            last_rx = now()
            event.ParseFromString(view[:n])
            if not tracker.observe(event.seq):
                continue
            if batched:
                pending.append((event.intended_emit_ns, event.barcode))
                if len(pending) >= BATCH:
                    flush()
            else:
                lane_for(event.barcode)
                if args.variant == "bimodal-1pct" and event.seq % SLOW_EVERY == 0:
                    spin(slow_iterations)  # the re-lookup: real CPU work, not a sleep
                    slow_count += 1
                finish([event.intended_emit_ns], now())
            rec.add_dropped(tracker.dropped - booked_dropped)
            booked_dropped = tracker.dropped
    if pending:
        flush()  # a partial last batch still gets handled

    print(f"received {tracker.received} dropped {tracker.dropped} (stopped: {stopped})")
    span = last_done - first_done
    notes = (
        f"throughput_mhz={done_count * 1_000_000_000_000 // span}; done_span_ns={span}; "
        f"reordered={tracker.reordered}; single thread, GIL"
    )
    if batched:
        notes += f"; batch={BATCH}"
    if args.variant == "bimodal-1pct":
        notes += (
            f"; slow_every={SLOW_EVERY}; slow_parcels={slow_count}; "
            f"slow_path_us={slow_measured_ns / 1e3:.1f}; busy loop, not sleep"
        )
    report = rec.write_report(args.report, notes) if args.report else rec.build_report(notes)
    print(format_rows([report]))
    return 0
