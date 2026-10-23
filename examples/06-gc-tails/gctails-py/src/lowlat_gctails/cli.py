"""Receive ``ParcelEvent`` datagrams and track them on a heap with a large live set.

The common ``lowlat_consumer`` loop binds, parses, tracks gaps and records latency; this module
supplies the tracker and measures the collector. Variants:

* ``cyclic-garbage``  each parcel's scan history is a reference cycle: only the cyclic collector
  frees it, and by then it sits in the oldest generation.
* ``frozen``          no cycles, and ``gc.freeze()`` after setup moves the live set out of the
  collector's reach.

CPython 3.14.8 has the generational collector again (3.14.0 to 3.14.4 shipped an incremental one
that 3.14.5 reverted), so a collection of the oldest generation, "generation 2", walks every
tracked object that is not frozen.
"""

import argparse
import gc
import platform
import sys
import time
from collections.abc import Sequence
from pathlib import Path

from lowlat.line.v1.parcel_pb2 import ParcelEvent
from lowlat_consumer import (
    Completion,
    GapTracker,
    NegativeLatencyError,
    install_signal_handlers,
    open_socket,
    run,
)
from lowlat_consumer.cli import build_parser as build_consumer_parser
from lowlat_consumer.cli import parse_hostport, positive_int
from lowlat_measure import Recorder
from lowlat_measure.recorder import require_profile
from lowlat_measure.table import format_rows

from lowlat_gctails.pauses import GcPauseLog
from lowlat_gctails.tracker import Settings, Tracker

VARIANTS = ("cyclic-garbage", "frozen")
DEFAULT_WARMUP = 30_000
MIN_PYTHON = (3, 14, 5)  # 3.14.0 to 3.14.4 shipped the incremental collector, reverted in 3.14.5


def build_parser() -> argparse.ArgumentParser:
    """The common consumer's flags, with this example's defaults and the workload size."""
    defaults = Settings()
    p = build_consumer_parser(variants=VARIANTS)
    p.prog = "gc-tails-py"
    p.description = __doc__
    p.set_defaults(
        bind=parse_hostport("127.0.0.1:47261"),
        example="06-gc-tails",
        variant="cyclic-garbage",
    )
    p.add_argument("--rate", type=positive_int, default=defaults.rate, help="parcels per second")
    p.add_argument(
        "--live-entries",
        type=positive_int,
        default=defaults.live_entries,
        help="manifest entries in the live set",
    )
    p.add_argument(
        "--entry-bytes",
        type=positive_int,
        default=defaults.entry_bytes,
        help="label bytes per manifest entry",
    )
    p.add_argument(
        "--in-flight-ms",
        type=positive_int,
        default=defaults.in_flight_ms,
        help="time between scanner and diverter",
    )
    p.add_argument(
        "--samples",
        type=positive_int,
        default=defaults.samples,
        help="scan samples built per parcel",
    )
    p.add_argument(
        "--warm-up",
        dest="warmup",
        type=positive_int,
        default=DEFAULT_WARMUP,
        help="synthetic parcels run before the bind",
    )
    return p


def settings_from(args: argparse.Namespace) -> Settings:
    return Settings(
        rate=args.rate,
        live_entries=args.live_entries,
        entry_bytes=args.entry_bytes,
        in_flight_ms=args.in_flight_ms,
        samples=args.samples,
    )


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    install_signal_handlers()
    if not require_profile("gc-tails-py"):
        return 2
    if sys.version_info < MIN_PYTHON:
        need = ".".join(map(str, MIN_PYTHON))
        print(
            f"gc-tails-py: CPython {platform.python_version()} has the incremental collector; "
            f"the generational one this example measures needs {need} or later",
            file=sys.stderr,
        )
        return 2

    frozen = args.variant == "frozen"
    tracker = Tracker(settings_from(args), cyclic=not frozen)
    tracker.populate()
    tracker.warm_up(args.warmup)
    gc.collect()  # the setup's garbage is not the run's
    if frozen:
        gc.freeze()  # everything alive now is permanent: later collections never walk it

    def on_parcel(event: ParcelEvent, complete: Completion) -> None:
        tracker.track(event.barcode, event.seq)
        complete(event.intended_emit_ns, time.monotonic_ns())

    sock, granted = open_socket(args.bind, args.rcvbuf)
    rec = Recorder(args.example, args.variant)
    gaps = GapTracker()
    try:
        with sock, GcPauseLog() as pauses:
            host, port = sock.getsockname()  # the real port when --bind used port 0
            print(f"gc-tails-py: variant {args.variant} on {host}:{port}", flush=True)
            result = run(sock, rec, gaps, on_parcel, args.expect, args.idle_timeout_ms * 1_000_000)
    except NegativeLatencyError as exc:
        print(f"gc-tails-py: ABORT: {exc}", file=sys.stderr)
        return 2

    gen0, gen1, gen2 = pauses.generation_counts()
    print(
        f"received {gaps.received} dropped {gaps.dropped} (stopped: {result.stopped}); "
        f"collections {gen0}/{gen1}/{gen2} (gen 0/1/2)"
    )
    notes = (
        f"gen2_collections={gen2}; collections_gen0={gen0}; collections_gen1={gen1}; "
        f"gc_callbacks_unstored={pauses.overflow}; frozen_objects={gc.get_freeze_count()}; "
        f"gc_thresholds={list(gc.get_threshold())}; live_entries={args.live_entries}; "
        f"samples_per_parcel={args.samples}; cpython={platform.python_version()} generational; "
        f"rcvbuf_granted={granted}; reordered={gaps.reordered}; single thread, "
        + ("GIL" if sys._is_gil_enabled() else "free-threaded, GIL off")
    )
    runtime = {
        "gc": {
            "name": "CPython generational cycle collector",
            "flags": ["gc.freeze()"] if frozen else [],
        }
    }
    report = (
        rec.write_report(args.report, notes, runtime=runtime)
        if args.report
        else rec.build_report(notes, runtime=runtime)
    )

    # The pauses become a latency distribution here, after the run.
    pause_rec = Recorder(args.example, f"{args.variant}-gc-pause")
    for collection in pauses.collections():
        pause_rec.record(max(1, collection.duration_ns))
    pause_notes = f"gc.callbacks pauses, ns; gen2_collections={gen2}; collections={pauses.count}"
    pause_report = (
        pause_rec.write_report(_sibling(args.report, "-gc-pause"), pause_notes, runtime=runtime)
        if args.report
        else pause_rec.build_report(pause_notes, runtime=runtime)
    )
    print(format_rows([report, pause_report]))
    return 0


def _sibling(report: str, suffix: str) -> Path:
    """``dir/run.json`` with suffix ``-gc-pause`` is ``dir/run-gc-pause.json``."""
    base = Path(report)
    return base.with_name(f"{base.stem}{suffix}{base.suffix}")
