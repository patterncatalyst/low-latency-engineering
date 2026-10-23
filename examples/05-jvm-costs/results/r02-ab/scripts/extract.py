#!/usr/bin/env python3
"""Build ab.csv from the raw A/B reports (which are not committed).

usage: extract.py AB1_OUT_DIR AB2_OUT_DIR > ab.csv
  AB1_OUT_DIR  holds 05-jvm-costs-{old,new}-N/ and 00-prerequisites-{old,new}-N/
  AB2_OUT_DIR  holds {old,new}-N/ (java warmed lane only)
Every value is read from the report's own percentiles block (ns) and the
profile's load.load1; nothing is typed in.
"""

import csv
import json
import re
import sys
from pathlib import Path

COLS = "set pair tree lane variant window p50_ns p99_ns p999_ns load1".split()


def rows_for(run: Path, set_, pair, tree, lane):
    for f in sorted(run.glob("*.json")):
        if f.name in (
            "profile.json",
            "time-to-ready.json",
            "alloc-per-op.json",
            "jmh-alloc.json",
            "gbench-alloc.json",
        ):
            continue
        d = json.loads(f.read_text())
        if "percentiles" not in d:
            continue
        stem = f.stem
        m = re.match(r"(.+?)-(first-\d+|steady)$", stem)
        variant, window = (m.group(1), m.group(2)) if m else (stem, "run")
        p = d["percentiles"]
        load1 = json.loads((run / "profile.json").read_text())["load"]["load1"]
        yield [set_, pair, tree, lane, variant, window, p["p50"], p["p99"], p["p99_9"], load1]


def main(ab1: Path, ab2: Path):
    w = csv.writer(sys.stdout, lineterminator="\n")
    w.writerow(COLS)
    out = []
    for run in sorted(ab1.iterdir()):
        m = re.fullmatch(r"(05-jvm-costs|00-prerequisites)-(old|new)-(\d+)", run.name)
        if m and run.is_dir():
            lane = m.group(1)[:2]
            out += rows_for(run, "ab1", int(m.group(3)), m.group(2), lane)
    for run in sorted(ab2.iterdir()):
        m = re.fullmatch(r"(old|new)-(\d+)", run.name)
        if m and run.is_dir():
            out += rows_for(run, "ab2", int(m.group(2)), m.group(1), "05")
    out.sort(key=lambda r: (r[0], r[3], r[1], r[2] != "old", r[4], r[5]))
    w.writerows(out)


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
