"""co-experiment-py run|probe: Ch3 coordinated omission. See the example README."""

from __future__ import annotations

import argparse
import socket
import sys
from collections.abc import Sequence
from pathlib import Path

from lowlat_consumer.cli import parse_hostport
from lowlat_measure import Recorder
from lowlat_measure.recorder import load_profile
from lowlat_measure.table import format_rows

from lowlat_co import experiment


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="co-experiment-py", description=__doc__)
    sub = p.add_subparsers(dest="mode", required=True)
    run = sub.add_parser("run", help="UDP phase from the simulator, then the closed-loop phase")
    run.add_argument("--bind", type=parse_hostport, default=("127.0.0.1", 47232), metavar="H:P")
    run.add_argument("--expect", type=int, default=10_000)
    run.add_argument("--stall-ms", type=int, default=200)
    run.add_argument("--stall-seq", type=int, default=5_000)
    run.add_argument("--suffix", default="")
    run.add_argument("--out", type=Path, required=True)
    probe = sub.add_parser("probe", help="cost of one clock read")
    probe.add_argument("--calls", type=int, default=1_000_000)
    probe.add_argument("--out", type=Path, default=Path("."))
    return p


def emit(rec: Recorder, out: Path, notes: str) -> None:
    report = rec.write_report(out / f"python-{rec.variant}.json", notes)
    print(format_rows([report]))


def do_run(args: argparse.Namespace) -> None:
    rec = experiment.Recorders(args.suffix)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
        sock.bind(args.bind)
        print(f"listening on {args.bind[0]}:{args.bind[1]}", flush=True)
        dropped = experiment.receive(
            sock, rec, expect=args.expect, stall_ms=args.stall_ms, stall_seq=args.stall_seq
        )
    experiment.closed_loop(rec, args.expect, stall_ms=args.stall_ms, stall_seq=args.stall_seq)
    notes = (
        f"stall_ms={args.stall_ms} stall_seq={args.stall_seq} dropped={dropped}; "
        "the stall is a blocking sleep; single thread, GIL"
    )
    emit(rec.receipt_time, args.out, notes)
    emit(rec.intended_time, args.out, notes)
    emit(rec.closed_loop_corrected, args.out, notes + "; record_corrected, expected interval 1 ms")
    emit(rec.closed_loop_naive, args.out, notes)


def do_probe(args: argparse.Namespace) -> None:
    what = {
        "clock-read": "time.monotonic_ns",
        "clock-read-perf_counter_ns": "time.perf_counter_ns",
    }
    for variant, rec in experiment.clock_probe(args.calls).items():
        notes = f"{args.calls} back-to-back pairs of {what[variant]}; value = second - first"
        emit(rec, args.out, notes)


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        load_profile()  # fail before the run, not after it
    except RuntimeError as exc:
        print(f"co-experiment-py: {exc}", file=sys.stderr)
        return 2
    args.out.mkdir(parents=True, exist_ok=True)
    {"run": do_run, "probe": do_probe}[args.mode](args)
    return 0
