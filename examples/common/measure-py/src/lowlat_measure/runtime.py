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
    """``runtime.hw_counters``: counters for the measured region, per operation.

    Raises ``ValueError`` when ``ops`` is below 1.
    """
    if ops < 1:
        raise ValueError(f"ops must be positive: {ops}")
    return {"source": source, "ops": ops, "per_op": dict(per_op)}


def python_build() -> PythonBuild:
    """``runtime.python_build`` for the running interpreter.

    Reports whether the GIL is on now (``sys._is_gil_enabled()``): a free-threaded interpreter
    that re-enabled the GIL, for example by importing this package's HdrHistogram extension,
    reports "gil". The build itself is sysconfig's ``Py_GIL_DISABLED``, which
    ``lowlat_sync.python_build`` reads.
    """
    return "gil" if sys._is_gil_enabled() else "free-threaded"


def runtime_block(
    *,
    pinned: Mapping[str, Any] | None = None,
    hw: Mapping[str, Any] | None = None,
    event_counts: Mapping[str, int] | None = None,
    build: PythonBuild | None = None,
    **other: Any,
) -> dict[str, Any]:
    """A ``runtime`` object from the parts given; omitted parts stay out of the report.

    ``pinned`` is a :func:`placement`, ``hw`` a :func:`hw_counters`, ``event_counts`` the
    ``counters`` map and ``build`` a :func:`python_build` value. ``other`` passes through the
    existing keys (``gc``, ``jit``, ``ctx_switches``, ...).
    """
    block: dict[str, Any] = dict(other)
    if pinned:
        block["placement"] = dict(pinned)
    if hw:
        block["hw_counters"] = dict(hw)
    if event_counts:
        block["counters"] = dict(event_counts)
    if build:
        block["python_build"] = build
    return block
