"""Receive ``ParcelEvent`` datagrams and handle them per-parcel, in batches, or bimodally.

The common ``lowlat_consumer`` loop binds, parses, tracks gaps and records latency; this
module supplies only the handler (``lowlat_latdist.handlers``). Variants:

* ``per-parcel``    handle each parcel on arrival.
* ``batch-32``      hold 32 parcels, then handle them together; one done time per batch.
* ``bimodal-1pct``  per-parcel, but ``seq % 100 == 0`` runs a ~2 ms busy loop.
"""

import argparse
from collections.abc import Sequence

from lowlat_consumer import GapTracker, Handler, install_signal_handlers, open_socket, run
from lowlat_consumer.cli import build_parser as build_consumer_parser
from lowlat_consumer.cli import parse_hostport
from lowlat_measure import Recorder
from lowlat_measure.recorder import require_profile
from lowlat_measure.table import format_rows

from lowlat_latdist.handlers import Batch, Bimodal, per_parcel

VARIANTS = ("per-parcel", "batch-32", "bimodal-1pct")
BATCH = 32
SLOW_EVERY = 100


def build_parser() -> argparse.ArgumentParser:
    """The common consumer's flags, with this example's defaults and ``--slow-us``."""
    p = build_consumer_parser(variants=VARIANTS)
    p.prog = "latdist-py"
    p.description = __doc__
    p.set_defaults(
        bind=parse_hostport("127.0.0.1:47210"),
        example="01-latency-distribution",
        variant="per-parcel",
    )
    p.add_argument(
        "--slow-us", type=int, default=2000, help="target slow-path duration (bimodal-1pct)"
    )
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    install_signal_handlers()
    if not require_profile("latdist-py"):
        return 2

    policy: Handler | Batch | Bimodal
    match args.variant:
        case "batch-32":
            policy = Batch(BATCH)
        case "bimodal-1pct":
            policy = Bimodal(SLOW_EVERY, args.slow_us)
        case _:
            policy = per_parcel
    drain = policy.drain if isinstance(policy, Batch) else None

    sock, _granted = open_socket(args.bind, args.rcvbuf)
    rec = Recorder(args.example, args.variant)
    tracker = GapTracker()
    with sock:
        host, port = args.bind
        print(f"latdist-py: variant {args.variant} on {host}:{port}", flush=True)
        result = run(
            sock, rec, tracker, policy, args.expect, args.idle_timeout_ms * 1_000_000, drain
        )

    print(f"received {tracker.received} dropped {tracker.dropped} (stopped: {result.stopped})")
    span = result.last_done_ns - result.first_done_ns
    notes = (
        f"throughput_mhz={result.completed * 1_000_000_000_000 // span}; done_span_ns={span}; "
        f"reordered={tracker.reordered}; single thread, GIL"
    )
    if isinstance(policy, Batch | Bimodal):
        notes += policy.notes()
    report = rec.write_report(args.report, notes) if args.report else rec.build_report(notes)
    print(format_rows([report]))
    return 0
