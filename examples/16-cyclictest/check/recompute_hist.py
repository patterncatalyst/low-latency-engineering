#!/usr/bin/env python3
"""Recompute a cyclictest report's percentiles from the raw ``--histfile``, without the kit.

    recompute_hist.py HISTFILE[.gz] REPORT.json [THREAD]

``HISTFILE`` is what ``cyclictest --histfile`` wrote (``verify.sh`` keeps it gzipped).
``REPORT.json`` is the ``lowlat-report/1`` that ``lowlat-report from-cyclictest`` made from it.
``THREAD`` (default 0) is the measurement thread's column in the histogram. The script reads
only the histogram and the report's ``percentiles`` and ``count``, computes p50, p90, p99,
p99.9 and max itself, and exits 0 when all five match exactly, 1 when any differs, 2 on a
usage or input error. It prints one JSON object with both sets of numbers.

The arithmetic, written out so it can be checked by hand:

* A bucket row is ``INDEX COUNT [COUNT ...]``; INDEX is the latency in whole microseconds
  (nanoseconds with ``-N``), the first count is thread 0. Samples beyond the ``-h`` range are
  not in any row; ``# Histogram Overflows:`` counts them and ``# Max Latencies:`` holds the
  largest value. They are placed at that maximum, as the converter's ``--allow-overflow``
  does (a run without overflow has none).
* The sample at rank ``max(1, int(p / 100 * N + 0.5))`` (round half up, as HdrHistogram's C
  and Python ports do) is the first bucket whose running count reaches the rank. The value is
  the bucket's lower edge in ns.
* The report keeps the values in an HdrHistogram with five significant digits, which reports
  the highest value equivalent to the one recorded: for a recorded value ``v`` the range
  ``[lo, lo + w - 1]`` with ``w = 2 ** max(0, v.bit_length() - 18)`` and ``lo = v - v % w``.
  Below 262,144 ns ``w`` is 1, so the figure is exact; above it the figure is the top of a
  bucket at most 0.002% wide.
"""

from __future__ import annotations

import gzip
import json
import re
import sys
from pathlib import Path

PERCENTILES = {"p50": 50.0, "p90": 90.0, "p99": 99.0, "p99_9": 99.9}
SIGNIFICANT_BITS = 18  # 2 ** 18 sub-buckets cover five significant digits
ROW = re.compile(r"^\d+(\s|$)")


def read_text(path: Path) -> str:
    if path.suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8").read()
    return path.read_text(encoding="utf-8")


def parse(text: str, thread: int = 0) -> tuple[dict[int, int], int, int]:
    """(bucket -> count, overflow count, largest latency) of one thread."""
    buckets: dict[int, int] = {}
    overflows = peak = 0
    for line in text.splitlines():
        if line.startswith("#"):
            label, _, rest = line[1:].partition(":")
            values = rest.split()
            if label.strip() == "Histogram Overflows" and len(values) > thread:
                overflows = int(values[thread])
            elif label.strip() == "Max Latencies" and len(values) > thread:
                peak = int(values[thread])
        elif ROW.match(line):
            fields = line.split()
            if len(fields) <= thread + 1:
                raise ValueError(f"row '{line}' has no count for thread {thread}")
            count = int(fields[thread + 1])
            if count:
                buckets[int(fields[0])] = count
    if not buckets:
        raise ValueError("the histogram holds no samples")
    return buckets, overflows, peak


def equivalent_top(value_ns: int) -> int:
    """The highest value a five-digit HdrHistogram treats as equal to ``value_ns``."""
    width = 1 << max(0, value_ns.bit_length() - SIGNIFICANT_BITS)
    return value_ns - value_ns % width + width - 1


def percentiles(text: str, unit_ns: int, thread: int = 0) -> dict[str, int]:
    buckets, overflows, peak = parse(text, thread)
    rows = sorted(buckets.items())
    if overflows:
        if peak <= rows[-1][0]:
            raise ValueError("the histogram overflowed but its maximum is inside the buckets")
        rows.append((peak, overflows))
    total = sum(count for _, count in rows)
    out: dict[str, int] = {"count": total}
    for key, p in PERCENTILES.items():
        rank = max(1, int(p / 100 * total + 0.5))
        running = 0
        for bucket, count in rows:
            running += count
            if running >= rank:
                out[key] = equivalent_top(bucket * unit_ns)
                break
    out["max"] = equivalent_top(rows[-1][0] * unit_ns)
    return out


def unit_of(report: dict) -> int:
    """Nanoseconds per bucket, from the report's notes ("histogram buckets of 1 us")."""
    match = re.search(r"buckets of 1 (us|ns)", str(report.get("notes", "")))
    return 1 if match and match.group(1) == "ns" else 1000


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    try:
        report = json.loads(Path(argv[2]).read_text(encoding="utf-8"))
        mine = percentiles(
            read_text(Path(argv[1])), unit_of(report), int(argv[3]) if len(argv) == 4 else 0
        )
    except (OSError, ValueError, KeyError) as exc:
        print(f"recompute_hist: {exc}", file=sys.stderr)
        return 2
    theirs = {k: report["percentiles"].get(k) for k in (*PERCENTILES, "max")}
    theirs["count"] = report.get("count")
    print(json.dumps({"recomputed": mine, "report": theirs}, sort_keys=True))
    return 0 if mine == theirs else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
