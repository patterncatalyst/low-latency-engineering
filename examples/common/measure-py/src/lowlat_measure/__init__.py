"""Latency measurement kit: HdrHistogram recorder, report writer and report checks.

Recording from Python costs on the order of a microsecond per call (interpreter
dispatch plus the histogram's index arithmetic); the test suite measures and prints
the figure for the machine it runs on. That cost is part of what the measured
examples teach: a Python recorder inside a hot path perturbs the path it measures,
so record outside the critical section or batch the values.

Report format and rules: ``examples/common/MEASUREMENT.md``.
"""

from lowlat_measure.recorder import (
    HIGHEST_TRACKABLE_NS,
    LOWEST_DISCERNIBLE_NS,
    SIGNIFICANT_DIGITS,
    Recorder,
    decode,
    new_histogram,
)

__all__ = [
    "HIGHEST_TRACKABLE_NS",
    "LOWEST_DISCERNIBLE_NS",
    "SIGNIFICANT_DIGITS",
    "Recorder",
    "decode",
    "new_histogram",
]
