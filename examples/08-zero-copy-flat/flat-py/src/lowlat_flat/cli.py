"""``flat-py``: the Python lane of Ch8 and the golden-bytes tool.

* ``dump FILE``        decode a file of parcel-v1 records and print them as JSON
* ``decode``           ``unpack_from`` over a ``memoryview`` against ``ParseFromString``:
                       per-call percentiles (reports) and allocations per parcel
* ``jmh-to-report``, ``gbench-to-report``
                       convert the JMH and Google Benchmark JSON into lowlat reports
"""

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path

from lowlat_consumer import flat
from lowlat_measure.recorder import require_profile
from lowlat_measure.table import format_rows

from lowlat_flat import decode, golden, harness_report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="flat-py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    dump = sub.add_parser("dump", help="decode a file of parcel-v1 records, print JSON")
    dump.add_argument("file", type=Path)

    compare = sub.add_parser("decode", help="unpack_from vs ParseFromString")
    compare.add_argument("--out", type=Path, required=True, help="directory for the reports")
    compare.add_argument(
        "--parcels", type=int, default=1024, help="distinct parcels (default 1024)"
    )
    compare.add_argument(
        "--rounds", type=int, default=200, help="passes over the parcels (default 200)"
    )

    for name, what in (("jmh-to-report", "JMH"), ("gbench-to-report", "Google Benchmark")):
        convert = sub.add_parser(name, help=f"{what} JSON to lowlat reports")
        convert.add_argument("source", type=Path)
        convert.add_argument("out", type=Path, help="directory for the reports")
    return parser


def run_decode(out: Path, parcels: int, rounds: int) -> int:
    if not require_profile("flat-py"):
        return 2
    out.mkdir(parents=True, exist_ok=True)
    paths = decode.decoders(parcels)
    observed = {name: decode.observe_allocations(fn, parcels) for name, fn in paths.items()}
    reports = []
    for name, fn in paths.items():
        fn(0)  # first call outside the samples
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
        case "jmh-to-report" | "gbench-to-report":
            convert = (
                harness_report.from_jmh
                if args.command == "jmh-to-report"
                else harness_report.from_gbench
            )
            for path in convert(args.source, args.out):
                print(path)
            return 0
    return 2
