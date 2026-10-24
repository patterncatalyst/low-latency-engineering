"""Ch13: the CPU counts Python reports, and the one to size a pool from.

``os.cpu_count()`` is the number of CPUs the system has. ``os.process_cpu_count()`` (3.13+) is the
number this process may use: it follows the affinity mask, so a ``--cpuset-cpus`` shows in it, but a
CFS quota (``--cpus``) does not, because a quota limits time, not the set of CPUs.
``len(os.sched_getaffinity(0))`` is the same mask counted directly. All three are exact counts that
the kernel or the interpreter reports.
"""

import os
import sys
import sysconfig

SCHEMA = "lowlat-place-probe/1"
EXAMPLE = "13-where-code-runs"


def cpu_counts() -> dict[str, int | None]:
    """System CPUs, CPUs usable by this process, and the size of the affinity mask."""
    return {
        "cpu_count": os.cpu_count(),
        "process_cpu_count": os.process_cpu_count(),
        "affinity_count": len(os.sched_getaffinity(0)),
    }


def probe() -> dict[str, object]:
    """The probe document the lane scripts collect (lowlat-place-probe/1)."""
    return {
        "schema": SCHEMA,
        "example": EXAMPLE,
        "language": "python",
        "python": {
            **cpu_counts(),
            "version": sys.version.split()[0],
            "gil_enabled": sys._is_gil_enabled(),
            "free_threaded_build": bool(sysconfig.get_config_var("Py_GIL_DISABLED")),
        },
    }
