"""Builders for the optional ``runtime`` block of a ``lowlat-report/1`` report.

Each function returns a plain dict that fits the schema; ``runtime_block`` combines them into
the value for ``Recorder.write_report(runtime=...)``. Nothing here can carry a mean: the schema
rejects any key named for one, and these builders add none.
"""

import sys
from collections.abc import Iterable, Mapping
from typing import Any, Literal

HwSource = Literal["perf", "cachegrind", "perfnorm"]
PythonBuild = Literal["gil", "free-threaded"]


def placement(cpus: Iterable[int], *, distinct_cores: bool, smt_siblings: bool) -> dict[str, Any]:
    """``runtime.placement``: the logical CPUs the measured threads were pinned to."""
    return {"cpus": list(cpus), "distinct_cores": distinct_cores, "smt_siblings": smt_siblings}


def hw_counters(source: HwSource, ops: int, per_op: Mapping[str, float]) -> dict[str, Any]:
    """``runtime.hw_counters``: counters for the measured region, per operation."""
    return {"source": source, "ops": ops, "per_op": dict(per_op)}


def python_build() -> PythonBuild:
    """``runtime.python_build`` for the running interpreter."""
    return "gil" if sys._is_gil_enabled() else "free-threaded"


def runtime_block(
    *,
    placement: Mapping[str, Any] | None = None,
    hw_counters: Mapping[str, Any] | None = None,
    counters: Mapping[str, int] | None = None,
    python_build: PythonBuild | None = None,
    **other: Any,
) -> dict[str, Any]:
    """A ``runtime`` object from the parts given; omitted parts stay out of the report.

    ``other`` passes through the existing keys (``gc``, ``jit``, ``ctx_switches``, ...).
    """
    block: dict[str, Any] = dict(other)
    if placement:
        block["placement"] = dict(placement)
    if hw_counters:
        block["hw_counters"] = dict(hw_counters)
    if counters:
        block["counters"] = dict(counters)
    if python_build:
        block["python_build"] = python_build
    return block
