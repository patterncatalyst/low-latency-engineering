"""``lowlat-report``: validate, show and check latency reports.

The JSON Schema is the single copy in ``contracts/measurement/``. It is found via the
``LOWLAT_SCHEMA`` environment variable, defaulting to the path inside this repository
computed from the package location (valid for the editable workspace install).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

from lowlat_measure.recorder import decode, percentiles_of
from lowlat_measure.table import format_rows

SCHEMA_ENV = "LOWLAT_SCHEMA"
_REPO_ROOT = Path(__file__).resolve().parents[5]
DEFAULT_SCHEMA = _REPO_ROOT / "contracts" / "measurement" / "latency-report.schema.json"


def schema_path() -> Path:
    return Path(os.environ.get(SCHEMA_ENV) or DEFAULT_SCHEMA)


def _validator() -> Draft202012Validator:
    path = schema_path()
    if not path.is_file():
        raise FileNotFoundError(f"schema not found at {path}; set {SCHEMA_ENV} to its location")
    return Draft202012Validator(json.loads(path.read_text(encoding="utf-8")))


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _schema_errors(validator: Draft202012Validator, report: dict[str, Any]) -> list[str]:
    return [
        f"{'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}"
        for e in sorted(validator.iter_errors(report), key=lambda e: list(e.absolute_path))
    ]


def _load_valid(paths: list[Path], validator: Draft202012Validator) -> tuple[list[dict], int]:
    reports, failures = [], 0
    for path in paths:
        try:
            report = _load(path)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"FAIL {path}: {exc}", file=sys.stderr)
            failures += 1
            continue
        errors = _schema_errors(validator, report)
        for err in errors:
            print(f"FAIL {path}: {err}", file=sys.stderr)
        if errors:
            failures += 1
        else:
            reports.append({"_path": path, **report})
    return reports, failures


def cmd_validate(args: argparse.Namespace) -> int:
    reports, failures = _load_valid(args.files, _validator())
    for r in reports:
        print(f"ok   {r['_path']}")
    return 1 if failures else 0


def cmd_show(args: argparse.Namespace) -> int:
    reports, failures = _load_valid(args.files, _validator())
    if reports:
        print(format_rows(reports, header=True))
    return 1 if failures else 0


def _check_one(report: dict[str, Any]) -> list[str]:
    """Recompute percentiles from the histogram; compare within equivalent values."""
    hist = decode(report["hdr_histogram"])
    problems = []
    if hist.get_total_count() != report["count"]:
        problems.append(f"count: emitted {report['count']}, histogram {hist.get_total_count()}")
    recomputed = percentiles_of(hist, report["language"])
    for key, value in recomputed.items():
        emitted = report["percentiles"][key]
        if not hist.values_are_equivalent(emitted, value):
            problems.append(f"{key}: emitted {emitted}, recomputed {value}")
    return problems


def cmd_check(args: argparse.Namespace) -> int:
    reports, failures = _load_valid(args.files, _validator())
    for r in reports:
        problems = _check_one(r)
        for p in problems:
            print(f"FAIL {r['_path']}: {p}", file=sys.stderr)
        failures += bool(problems)
        if not problems:
            print(f"ok   {r['_path']}")

    # Different languages measuring the same workload are expected to differ;
    # only reports recorded from one fixed dataset (the shared goldens) must agree.
    if not args.same_dataset:
        return 1 if failures else 0

    groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in reports:
        groups[(r["example"], r["variant"])].append(r)
    for (example, variant), group in groups.items():
        if len(group) < 2:
            continue
        group_ok = True
        ref = group[0]
        ref_hist = decode(ref["hdr_histogram"])
        ref_p = percentiles_of(ref_hist)
        for other in group[1:]:
            mismatches = []
            for key, value in percentiles_of(decode(other["hdr_histogram"])).items():
                if not ref_hist.values_are_equivalent(ref_p[key], value):
                    mismatches.append(
                        f"{key}: {ref['language']} {ref_p[key]} vs {other['language']} {value}"
                    )
            for m in mismatches:
                print(f"FAIL cross-language {example}/{variant}: {m}", file=sys.stderr)
            failures += bool(mismatches)
            group_ok = group_ok and not mismatches
        if group_ok:
            langs = ", ".join(g["language"] for g in group)
            print(f"ok   cross-language {example}/{variant}: {langs}")
    return 1 if failures else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lowlat-report", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name, func, text in (
        ("validate", cmd_validate, "schema-validate each report"),
        ("show", cmd_show, "print an aligned percentile table in microseconds"),
        ("check", cmd_check, "validate and recompute percentiles from each histogram"),
    ):
        p = sub.add_parser(name, help=text, description=text)
        p.add_argument("files", nargs="+", type=Path, metavar="FILE")
        if name == "check":
            p.add_argument(
                "--same-dataset",
                action="store_true",
                help="also require reports sharing example and variant to agree across "
                "languages (only for reports recorded from one fixed dataset)",
            )
        p.set_defaults(func=func)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
