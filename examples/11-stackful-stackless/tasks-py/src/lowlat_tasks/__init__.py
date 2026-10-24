"""Ch11: stackful and stackless tasks, Python lane.

Python has no standard-library stackful coroutine, so the comparison is OS threads against asyncio
tasks (stackless: a coroutine's frame lives on the heap). greenlet and gevent are third-party
stackful coroutines and are named in the chapter, not measured. The measuring modules import
nothing that re-enables the GIL (no `lowlat_measure`); `lowlat-report from-samples` converts what
they write.
"""

import sys
import sysconfig

EXAMPLE = "11-stackful-stackless"


def python_build() -> str:
    """`free-threaded` for the free-threaded build, else `gil` (runtime.python_build).

    The build comes from the interpreter's configuration, not from the live GIL state: an extension
    that does not declare free-threading support re-enables the GIL at import time in a
    free-threaded interpreter, which `gil_enabled` reports separately.
    """
    return "free-threaded" if sysconfig.get_config_var("Py_GIL_DISABLED") else "gil"


def gil_enabled() -> bool:
    """Whether the GIL is on right now (False only for a free-threaded build that kept it off)."""
    return sys._is_gil_enabled()
