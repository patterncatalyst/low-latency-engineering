"""Ch11 wiring skeleton: run n asyncio tasks to completion and count them."""

import asyncio


async def _one(index: int) -> int:
    await asyncio.sleep(0)
    return index


async def run_tasks(n: int) -> int:
    """Start n tasks, wait for all of them, return how many finished."""
    async with asyncio.TaskGroup() as group:
        tasks = [group.create_task(_one(i)) for i in range(n)]
    return len(tasks)
