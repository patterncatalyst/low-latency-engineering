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
EnvKind = Literal["host", "vm", "container"]
NetworkMode = Literal["host", "bridge", "none"]


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


def container(
    *,
    runtime: str,
    image: str,
    image_digest: str,
    network: NetworkMode,
    seccomp: str,
    cpu_quota: str | None = None,
    cpuset: str | None = None,
) -> dict[str, Any]:
    """``runtime.environment.container``; ``cpu_quota`` and ``cpuset`` are None when not set."""
    return {
        "runtime": runtime,
        "image": image,
        "image_digest": image_digest,
        "network": network,
        "cpu_quota": cpu_quota,
        "cpuset": cpuset,
        "seccomp": seccomp,
    }


def cgroup(
    *,
    cpu_max: str | None = None,
    cpuset_effective: str | None = None,
    nr_throttled: int | None = None,
    throttled_usec: int | None = None,
) -> dict[str, Any]:
    """``runtime.environment.cgroup``: cgroup v2 facts read after the run (None becomes null)."""
    return {
        "cpu_max": cpu_max,
        "cpuset_effective": cpuset_effective,
        "nr_throttled": nr_throttled,
        "throttled_usec": throttled_usec,
    }


def environment(
    kind: EnvKind,
    *,
    guest_profile: str | None = None,
    container: Mapping[str, Any] | None = None,
    cgroup: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """``runtime.environment``: where the measured program ran.

    The schema requires ``guest_profile`` (snapshot/profile, for example
    ``lab-ready-r04/stock-unpinned``) for vm and container and ``container`` for container;
    ``lowlat-report check`` enforces both, so this builder does not. Parts left None stay out.
    """
    env: dict[str, Any] = {"kind": kind}
    if guest_profile is not None:
        env["guest_profile"] = guest_profile
    if container is not None:
        env["container"] = dict(container)
    if cgroup is not None:
        env["cgroup"] = dict(cgroup)
    return env


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
    env: Mapping[str, Any] | None = None,
    **other: Any,
) -> dict[str, Any]:
    """A ``runtime`` object from the parts given; omitted parts stay out of the report.

    ``pinned`` is a :func:`placement`, ``hw`` a :func:`hw_counters`, ``event_counts`` the
    ``counters`` map, ``build`` a :func:`python_build` value and ``env`` an :func:`environment`.
    ``other`` passes through the existing keys (``gc``, ``jit``, ``ctx_switches``, ...).
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
    if env:
        block["environment"] = dict(env)
    return block
