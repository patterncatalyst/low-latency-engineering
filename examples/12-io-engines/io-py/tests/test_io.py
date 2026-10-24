import asyncio

from lowlat_io import loop_class_name, run_on_uvloop


def test_uvloop_runs_the_coroutine() -> None:
    async def answer() -> int:
        await asyncio.sleep(0)
        return 42

    assert run_on_uvloop(answer()) == 42


def test_the_running_loop_is_uvloop() -> None:
    assert loop_class_name() == "uvloop.Loop"
