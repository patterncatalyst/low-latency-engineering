"""``flat-py``: the Python lane of Ch8 and the golden-bytes tool.

* ``dump FILE``        decode a file of parcel-v1 records and print them as JSON
* ``decode``           ``unpack_from`` over a ``memoryview`` against ``ParseFromString``:
                       per-call percentiles (reports) and allocations per parcel

JMH and Google Benchmark JSON are converted by ``lowlat-report from-jmh`` and ``from-gbench``.
"""

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path

from lowlat_consumer import flat
from lowlat_consumer.cli import positive_int
from lowlat_measure.recorder import require_profile
from lowlat_measure.table import format_rows

from lowlat_flat import decode, golden


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="flat-py",
        description="Ch8 flat-record tools: golden dump, decode lane",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    dump = sub.add_parser("dump", help="decode a file of parcel-v1 records, print JSON")
    dump.add_argument("file", type=Path)

    compare = sub.add_parser("decode", help="unpack_from vs ParseFromString")
    compare.add_argument("--out", type=Path, required=True, help="directory for the reports")
    compare.add_argument(
        "--parcels", type=positive_int, default=1024, help="distinct parcels (default 1024)"
    )
    compare.add_argument(
        "--rounds", type=positive_int, default=200, help="passes over the parcels (default 200)"
    )
    return parser


def run_decode(out: Path, parcels: int, rounds: int) -> int:
    if not require_profile("flat-py"):
        return 2
    out.mkdir(parents=True, exist_ok=True)
    paths = decode.decoders(parcels)
    for fn in paths.values():
        fn(0)  # first-call setup is not counted as per-parcel allocation
    observed = {name: decode.observe_allocations(fn, parcels) for name, fn in paths.items()}
    reports = []
    for name, fn in paths.items():
        recorder = decode.time_decodes(fn, name, parcels, rounds)
        notes = (
            f"per-call time of decode plus reading every field, {parcels * rounds} calls; "
            "two perf_counter_ns reads are inside each sample; "
            f"python {sys.version.split()[0]}; observed, not asserted"
        )
        reports.append(recorder.write_report(out / f"python-{name}.json", notes))
    (out / "python-allocations.json").write_text(
        json.dumps(observed, indent=2) + "\n", encoding="utf-8"
    )
    print(format_rows(reports))
    for name, counts in observed.items():
        print(
            f"{name}: {counts['blocks_per_parcel']:.1f} blocks and "
            f"{counts['new_int_objects_per_parcel']:.1f} new int objects per parcel "
            f"({counts['fields_per_parcel']} fields read)"
        )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    match args.command:
        case "dump":
            try:
                print(golden.dump(args.file))
            except (flat.FlatError, ValueError, OSError) as exc:
                print(f"flat-py: {exc}", file=sys.stderr)
                return 1
            return 0
        case "decode":
            return run_decode(args.out, args.parcels, args.rounds)
    return 2
