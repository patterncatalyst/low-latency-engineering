"""Ch12 wiring skeleton: the uvloop event loop next to asyncio's default."""

import asyncio
from collections.abc import Awaitable

import uvloop


def run_on_uvloop[T](main: Awaitable[T]) -> T:
    """Run a coroutine on a uvloop event loop."""

    async def runner() -> T:
        return await main

    return uvloop.run(runner())


def loop_class_name() -> str:
    """Qualified name of the loop class uvloop.run installs (uvloop.Loop)."""

    async def name() -> str:
        loop_class = type(asyncio.get_running_loop())
        return f"{loop_class.__module__}.{loop_class.__qualname__}"

    return run_on_uvloop(name())
