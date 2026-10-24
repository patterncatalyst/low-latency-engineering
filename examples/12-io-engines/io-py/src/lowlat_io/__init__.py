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
    """Name of the loop class uvloop.run installs."""

    async def name() -> str:
        return type(asyncio.get_running_loop()).__module__

    return run_on_uvloop(name())
