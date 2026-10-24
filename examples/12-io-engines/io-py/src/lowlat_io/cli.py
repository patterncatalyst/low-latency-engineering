"""`io-py receive`: measure one variant, write raw samples and a sidecar (no lowlat_measure)."""

import argparse
import sys
from pathlib import Path

from lowlat_io import python_build, receive
from lowlat_io.placement import parse_cpus, require_gil_off_if_free_threaded


def _receive(args: argparse.Namespace) -> int:
    if args.variant == "uvloop" and python_build() == "free-threaded":
        print("io-py: uvloop is measured under the GIL build only", file=sys.stderr)
        return 2
    require_gil_off_if_free_threaded()
    threads = receive.threads_for(args.variant)
    cpus = parse_cpus(args.cpus)[:threads] if args.cpus else None
    if cpus is not None and len(cpus) < threads:
        print(f"io-py: --cpus needs {threads} CPUs for {args.variant}", file=sys.stderr)
        return 2
    ports = [args.base_port + i for i in range(receive.CAMERAS)]
    result = receive.run(
        args.variant, ports, args.expect, cpus=cpus, hold_ms=args.hold_ms, idle_ms=args.idle_ms
    )
    require_gil_off_if_free_threaded()
    receive.write_raw(result, Path(args.out), expect=args.expect, idle_ms=args.idle_ms)
    print(
        f"receive: {args.variant} [{python_build()}] parcels {result.parcels} "
        f"dropped {result.lost} "
        f"datagrams {sum(s.datagrams for s in result.stats)} "
        f"calls {sum(s.calls for s in result.stats)} start skew {result.skew_ns} ns "
        f"GIL at end {result.gil_at_end}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="io-py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser(
        "receive", help="receive the cameras' parcels; write raw samples and a sidecar"
    )
    r.add_argument("--variant", choices=receive.VARIANTS, required=True)
    r.add_argument("--base-port", type=int, default=47320)
    r.add_argument("--expect", type=int, default=5_000, help="parcels per camera")
    r.add_argument("--cpus", default="", help="CPUs to pin the threads to (distinct cores)")
    r.add_argument("--hold-ms", type=int, default=0, help="hold after placement-ready")
    r.add_argument("--idle-ms", type=int, default=1500)
    r.add_argument("--out", required=True, help="directory for samples.bin and sidecar.json")
    r.set_defaults(func=_receive)
    args = parser.parse_args(argv)
    return args.func(args)
