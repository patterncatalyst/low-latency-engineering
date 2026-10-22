"""Command line of the line consumer (the receive loop is in ``loop``)."""

import argparse
import sys
from collections.abc import Sequence

from lowlat_measure import Recorder
from lowlat_measure.recorder import require_profile
from lowlat_measure.table import format_rows

from lowlat_consumer.gaps import GapTracker
from lowlat_consumer.loop import (
    DEFAULT_RCVBUF,
    NegativeLatencyError,
    install_signal_handlers,
    lane_handler,
    open_socket,
    run,
)

DEFAULT_BIND = "127.0.0.1:47000"
DEFAULT_IDLE_MS = 2000


def parse_hostport(text: str) -> tuple[str, int]:
    host, sep, port = text.rpartition(":")
    if not sep or not host or not port.isdigit():
        raise argparse.ArgumentTypeError(f"expected HOST:PORT, got {text!r}")
    return host, int(port)


def positive_int(text: str) -> int:
    """argparse type: an integer greater than zero."""
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected an integer, got {text!r}") from None
    if value <= 0:
        raise argparse.ArgumentTypeError(f"must be > 0, got {value}")
    return value


def build_parser(variants: Sequence[str] | None = None) -> argparse.ArgumentParser:
    """The consumer's flags; ``variants`` restricts ``--variant`` to a fixed set."""
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
        type=positive_int,
        default=DEFAULT_RCVBUF,
        metavar="BYTES",
        help="SO_RCVBUF request; the kernel may grant less (default 4 MiB)",
    )
    p.add_argument(
        "--expect",
        type=positive_int,
        default=None,
        metavar="N",
        help="stop after N datagrams (received + dropped)",
    )
    p.add_argument(
        "--idle-timeout-ms",
        type=positive_int,
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
    p.add_argument("--variant", default="baseline", choices=variants, help="report variant name")
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    install_signal_handlers()

    if not require_profile("line-consumer-py"):  # fail before the run, not after it
        return 2

    sock, granted = open_socket(args.bind, args.rcvbuf)
    rec = Recorder(args.example, args.variant)
    tracker = GapTracker()
    try:
        with sock:
            host, port = args.bind
            print(
                f"line-consumer-py: bound {host}:{port}, SO_RCVBUF requested {args.rcvbuf} "
                f"granted {granted} (Linux reports double the set value; capped by "
                "net.core.rmem_max)",
                flush=True,
            )
            run(sock, rec, tracker, lane_handler, args.expect, args.idle_timeout_ms * 1_000_000)
    except NegativeLatencyError as exc:
        print(f"line-consumer-py: ABORT: {exc}", file=sys.stderr)
        return 2

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
