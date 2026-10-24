"""`sync-py measure` (any build, no lowlat_measure) and `sync-py report` (GIL environment)."""

import argparse
import sys
from pathlib import Path

from lowlat_sync import python_build
from lowlat_sync.placement import parse_cpus, require_gil_off_if_free_threaded


def _measure(args: argparse.Namespace) -> int:
    from lowlat_sync import lane

    require_gil_off_if_free_threaded()
    cpus = parse_cpus(args.cpus)[: args.threads] if args.cpus else None
    if cpus is not None and len(cpus) < args.threads:
        print(f"sync-py: --cpus needs {args.threads} CPUs", file=sys.stderr)
        return 2
    result = lane.run(
        args.variant,
        racy=args.racy_claim,
        threads=args.threads,
        claims_per_thread=args.claims_per_thread,
        cpus=cpus,
        hold_ms=args.hold_ms,
    )
    require_gil_off_if_free_threaded()
    lane.write_raw(result, Path(args.out))
    print(
        f"claim {args.variant}{' (racy)' if args.racy_claim else ''} [{python_build()}]: "
        f"{result.claimed} claims, lost or duplicated {result.lost_or_duplicated}, "
        f"voluntary ctx switches {result.voluntary}, GIL at end {result.gil_at_end}"
    )
    return 0


def _report(args: argparse.Namespace) -> int:
    from lowlat_sync.report import build_report

    report = build_report(Path(args.raw), Path(args.out))
    p = report["percentiles"]
    print(
        f"{report['variant']} [{report['runtime']['python_build']}]: count {report['count']}, "
        f"p50 {p['p50']} ns, p99 {p['p99']} ns, p99.9 {p['p99_9']} ns, max {p['max']} ns"
    )
    print(f"report: {args.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="sync-py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    m = sub.add_parser("measure", help="claim sequence numbers from threads; write raw samples")
    m.add_argument("--variant", choices=["lock", "itertools-count"], required=True)
    m.add_argument("--racy-claim", action="store_true", help="drop the lock of --variant lock")
    m.add_argument("--threads", type=int, default=4)
    m.add_argument("--claims-per-thread", type=int, default=100_000)
    m.add_argument("--cpus", default="", help="CPUs to pin the threads to (distinct cores)")
    m.add_argument(
        "--hold-ms", type=int, default=0, help="hold after placement-ready, for a script's check"
    )
    m.add_argument("--out", required=True, help="directory for raw.json and samples.bin")
    m.set_defaults(func=_measure)
    r = sub.add_parser("report", help="raw samples to a lowlat-report/1 file (GIL environment)")
    r.add_argument("raw", help="directory written by `measure`")
    r.add_argument("--out", required=True)
    r.set_defaults(func=_report)
    args = parser.parse_args(argv)
    return args.func(args)
