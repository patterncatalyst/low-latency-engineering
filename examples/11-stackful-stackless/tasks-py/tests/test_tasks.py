import asyncio

from lowlat_tasks import run_tasks


def test_every_task_finishes() -> None:
    assert asyncio.run(run_tasks(100)) == 100
