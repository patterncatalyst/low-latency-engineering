"""``locality-py``: the Python lane of Ch9.

* ``footprint``       bytes per tracked parcel: dict per parcel against slotted dataclasses (JSON)
* ``sweep``           the due sweep over a list of objects (``fat-record``) or arrays (``hot-cold``)
* ``counters``        five camera counters in shared memory or threads; raw batch times (JSON)
* ``counters-report`` turns that raw JSON into latency reports

``counters`` imports no HdrHistogram code, so it can run in a free-threaded interpreter with the
GIL still off; ``counters-report`` runs in the normal one.
"""

import argparse
import json
import os
import sys
import threading
import time
from collections.abc import Sequence
from pathlib import Path


def _positive(text: str) -> int:
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return value


def _cpus(text: str) -> list[int]:
    return [int(c) for c in text.split(",")]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="locality-py", description="Ch9 Python lane")
    sub = parser.add_subparsers(dest="command", required=True)

    fp = sub.add_parser("footprint", help="bytes per tracked parcel by record shape")
    fp.add_argument("--parcels", type=_positive, default=100_000)
    fp.add_argument("--out", type=Path, required=True)
    fp.set_defaults(func=run_footprint)

    sw = sub.add_parser("sweep", help="due sweep: list of objects against array columns")
    sw.add_argument("--variant", choices=("fat-record", "hot-cold"))
    for variant in ("fat-record", "hot-cold"):  # --fat-record is a spelling of --variant fat-record
        sw.add_argument(f"--{variant}", dest="variant", action="store_const", const=variant)
    sw.add_argument("--size", type=_positive, default=1_000_000)
    sw.add_argument("--samples", type=_positive, default=20)
    sw.add_argument("--cpu", type=int)
    sw.add_argument("--hold-ms", type=int, default=0)
    sw.add_argument("--out", type=Path, required=True)
    sw.set_defaults(func=run_sweep)

    ct = sub.add_parser("counters", help="five camera counters; writes raw batch times as JSON")
    ct.add_argument("--layout", choices=("adjacent-counters", "pair-padded", "line-padded"))
    for layout in ("adjacent-counters", "line-padded"):  # spellings of --layout NAME
        ct.add_argument(f"--{layout}", dest="layout", action="store_const", const=layout)
    ct.add_argument("--mode", choices=("processes", "threads"), default="processes")
    ct.add_argument("--cpus", type=_cpus, help="one CPU per camera, comma separated")
    ct.add_argument("--batches", type=_positive, default=3_000)
    ct.add_argument("--hold-ms", type=int, default=0)
    ct.add_argument("--out", type=Path, required=True, help="raw result JSON")
    ct.set_defaults(func=run_counters)

    cr = sub.add_parser("counters-report", help="raw counters JSON to a latency report")
    cr.add_argument("raw", type=Path)
    cr.add_argument("--out", type=Path, required=True)
    cr.add_argument("--example", default="09-eliminating-work")
    cr.set_defaults(func=run_counters_report)
    return parser


def run_footprint(args: argparse.Namespace) -> int:
    from lowlat_locality import footprint

    result = footprint.measure(args.parcels)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    for shape, per in result["tracked_bytes_per_parcel"].items():
        print(f"{shape:<16} {per:8.1f} bytes per tracked parcel")
    print(f"footprint: {args.out}")
    return 0


def run_sweep(args: argparse.Namespace) -> int:
    from lowlat_measure import runtime
    from lowlat_measure.recorder import Recorder, require_profile

    from lowlat_locality import counters, sweep

    if args.variant is None:
        print("sweep: --variant fat-record|hot-cold is required", file=sys.stderr)
        return 2
    if not require_profile("locality-py"):
        return 2
    if args.cpu is not None:
        os.sched_setaffinity(0, {args.cpu})
    samples = sweep.time_sweeps(args.variant, args.size, args.samples)
    if args.cpu is not None:
        pid, tid = os.getpid(), threading.get_native_id()
        counters.announce_placement(pid, tid, args.cpu, "bench")
        time.sleep(args.hold_ms / 1000)
    recorder = Recorder("09-eliminating-work", f"hub-sweep-{args.variant}")
    for ns in samples:
        recorder.record(ns)
    block = runtime.runtime_block(
        pinned=runtime.placement([args.cpu], distinct_cores=True, smt_siblings=False)
        if args.cpu is not None
        else None,
        event_counts={"slots": args.size, "sweeps": args.samples},
        build=runtime.python_build(),
    )
    notes = (
        f"op=hub-sweep; one sample = one sweep over {args.size} slots, "
        f"python {sys.version.split()[0]}; "
        "iterating the columns still creates an int per element; observed, not asserted"
    )
    recorder.write_report(args.out, notes, runtime=block)
    recorder.print_summary()
    print(f"report: {args.out}")
    return 0


def run_counters(args: argparse.Namespace) -> int:
    from lowlat_locality import counters

    if args.layout is None:
        print("counters: --layout adjacent-counters|pair-padded|line-padded", file=sys.stderr)
        return 2
    cpus = args.cpus
    if cpus is not None and len(cpus) != counters.CAMERAS:
        print(f"counters: --cpus needs {counters.CAMERAS} CPUs", file=sys.stderr)
        return 2
    result = counters.run(args.layout, args.mode, cpus, args.batches, args.hold_ms)
    args.out.write_text(json.dumps(result) + "\n", encoding="utf-8")
    print(
        f"counters: {args.layout} {args.mode} python {result['python']} "
        f"gil_enabled={result['gil_enabled']}; raw: {args.out}"
    )
    return 0


def run_counters_report(args: argparse.Namespace) -> int:
    from lowlat_measure import runtime
    from lowlat_measure.recorder import Recorder, require_profile

    if not require_profile("locality-py"):
        return 2
    raw = json.loads(args.raw.read_text(encoding="utf-8"))
    recorder = Recorder(args.example, f"counters-{raw['layout']}")
    for per_camera in raw["batch_ns"]:
        for ns in per_camera:
            recorder.record(ns)
    pinned = None
    if all(cpu is not None for cpu in raw["cpus"]):
        pinned = runtime.placement(raw["cpus"], distinct_cores=True, smt_siblings=False)
    block = runtime.runtime_block(
        pinned=pinned,
        event_counts={
            "cameras": raw["cameras"],
            "batch_size": raw["batch_size"],
            "batches_per_camera": raw["batches"],
            "increments": raw["cameras"] * raw["batches"] * raw["batch_size"],
            "stride_bytes": raw["stride_bytes"],
        },
        build="gil" if raw["gil_enabled"] else "free-threaded",
    )
    notes = (
        f"op=counters; one sample = one batch of {raw['batch_size']} increments by one camera; "
        f"mode={raw['mode']}; python {raw['python']} gil_enabled={raw['gil_enabled']}; "
        "each camera owns its cells; observed, not asserted"
    )
    # The raw run may come from the other interpreter (verify.sh runs the free-threaded lane under
    # the free-threaded binary and this report step under the normal one), so the build identity
    # is the measuring interpreter's, carried in the raw JSON, never this process's.
    build = {"compiler": raw["compiler"], "gil_enabled": raw["gil_enabled"]}
    recorder.write_report(args.out, notes, build=build, runtime=block)
    recorder.print_summary()
    print(f"report: {args.out}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
