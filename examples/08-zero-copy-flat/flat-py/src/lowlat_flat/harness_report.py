"""Ch8 binding of the shared JMH and Google Benchmark converters.

The converters live in ``lowlat_measure.harness`` (``lowlat-report from-jmh`` and
``from-gbench``). This module keeps Ch8's names, example id and per-parcel variants, so
``from lowlat_flat import harness_report`` still works.
"""

from pathlib import Path

from lowlat_measure import harness
from lowlat_measure.harness import kebab, variant_of

__all__ = ["EXAMPLE", "PER_PARCEL", "from_gbench", "from_jmh", "kebab", "variant_of"]

EXAMPLE = "08-zero-copy-flat"
PER_PARCEL = frozenset({"protobuf-decode", "flat-ffm"})  # one operation is one parcel


def from_jmh(source: Path, out_dir: Path) -> list[Path]:
    """``java-<variant>.json`` per JMH benchmark, as ``lowlat-report from-jmh`` writes them."""
    return harness.from_jmh(source, out_dir, example=EXAMPLE, per_parcel=PER_PARCEL)


def from_gbench(source: Path, out_dir: Path) -> list[Path]:
    """``cpp-<variant>.json`` per Google Benchmark benchmark, as ``from-gbench`` writes them."""
    return harness.from_gbench(source, out_dir, example=EXAMPLE)
