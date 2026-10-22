"""pyperf benchmark: check digit over the fixed prefix set.

Run as a script (pyperf re-launches it in worker processes):

    python bench_check_digit.py -o out.json --processes 6 --values 4 --warmups 3

CPython has no dead-code elimination, so there is no "eliminated" variant here. The
contrast in Python is warm-up: the adaptive specializing interpreter rewrites hot
bytecode after a few executions, so pyperf discards warm-up values and keeps them in
the JSON (``warmups``) where they can be compared with the measured ``values``.
"""

import pyperf

from lowlat_bench.check_digit import PREFIX_COUNT, check_digit, prefixes

PREFIXES = prefixes(PREFIX_COUNT)


def check_all() -> None:
    for p in PREFIXES:
        check_digit(p)


if __name__ == "__main__":
    runner = pyperf.Runner()
    runner.metadata["description"] = f"SSCC-18 check digit over {PREFIX_COUNT} prefixes"
    # inner_loops: each call checks len(PREFIXES) prefixes, so pyperf reports time per check.
    runner.bench_func("check_digit", check_all, inner_loops=len(PREFIXES))
