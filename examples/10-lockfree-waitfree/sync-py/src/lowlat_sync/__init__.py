"""Ch10: lock-free and wait-free, Python lane (the divergence).

CPython publishes no atomics API, so this lane has no memory-order test and no seqlock. What it can
show is the claim step: a `threading.Lock`, a shared `itertools.count`, and an unsynchronised
`counter += 1`, under the GIL build and under the free-threaded build. Measure with
`lowlat_sync.lane` (it imports nothing that re-enables the GIL) and convert the raw samples to a
`lowlat-report/1` report with `lowlat_sync.report` in the GIL workspace environment.
"""

import sys
import sysconfig


def python_build() -> str:
    """`free-threaded` for the free-threaded build, else `gil` (runtime.python_build).

    The build comes from the interpreter's configuration, not from the live GIL state: an
    extension that does not declare free-threading support re-enables the GIL at import time in a
    free-threaded interpreter, which `gil_enabled` reports separately.
    """
    return "free-threaded" if sysconfig.get_config_var("Py_GIL_DISABLED") else "gil"


def gil_enabled() -> bool:
    """Whether the GIL is on right now (False only for a free-threaded build that kept it off)."""
    return sys._is_gil_enabled()
