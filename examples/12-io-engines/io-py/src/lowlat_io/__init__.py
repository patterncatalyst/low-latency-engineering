"""Ch12: I/O engines, Python lane (asyncio, a blocking thread per socket, uvloop).

There is no io_uring in the standard library, and no mature binding: the lane compares what the
language offers (the asyncio selector loop, one blocking thread per socket, and uvloop's libuv
loop). `lowlat_io.receive` measures; it imports nothing that re-enables the GIL (no
`lowlat_measure`, and `uvloop` only inside the one function that needs it), so a free-threaded
interpreter keeps the GIL off.
The raw samples and a sidecar are converted to a `lowlat-report/1` report by `lowlat-report
from-samples` in the GIL workspace environment.
"""

import asyncio
import sys
import sysconfig
from collections.abc import Awaitable


def python_build() -> str:
    """`free-threaded` for the free-threaded build, else `gil` (runtime.python_build).

    The build comes from the interpreter's configuration, not from the live GIL state: an extension
    that does not declare free-threading support re-enables the GIL when it is imported.
    """
    return "free-threaded" if sysconfig.get_config_var("Py_GIL_DISABLED") else "gil"


def gil_enabled() -> bool:
    """Whether the GIL is on right now (False only for a free-threaded build that kept it off)."""
    return sys._is_gil_enabled()


def run_on_uvloop[T](main: Awaitable[T]) -> T:
    """Run a coroutine on a uvloop event loop (imports uvloop here, never at module import)."""
    import uvloop

    async def runner() -> T:
        return await main

    return uvloop.run(runner())


def loop_class_name() -> str:
    """Qualified name of the loop class uvloop.run installs (uvloop.Loop)."""

    async def name() -> str:
        loop_class = type(asyncio.get_running_loop())
        return f"{loop_class.__module__}.{loop_class.__qualname__}"

    return run_on_uvloop(name())
