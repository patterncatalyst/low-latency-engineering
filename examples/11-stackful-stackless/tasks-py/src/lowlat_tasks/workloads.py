"""The three Ch11 workloads in Python: OS threads against asyncio tasks.

Nothing here imports `lowlat_measure`, so the same module measures under the GIL build and under the
free-threaded build with the GIL kept off. Samples are int64 nanoseconds in an `array('q')`.
"""

import asyncio
import gc
import logging
import queue
import threading
import time
import tracemalloc
from array import array
from collections.abc import Callable
from dataclasses import dataclass, field

from lowlat_tasks.placement import Gate, ctx_switches
from lowlat_tasks.procinfo import Memory, memory, memory_counters

VARIANTS = ("threads", "asyncio-tasks")
NS = 1_000_000_000


@dataclass
class Run:
    """What one workload measured."""

    samples: array = field(default_factory=lambda: array("q"))
    counters: dict[str, int] = field(default_factory=dict)
    cpus: list[int] = field(default_factory=list)
    voluntary: int = 0
    involuntary: int = 0
    notes: str = ""


def _positive(ns: int) -> int:
    return ns if ns > 0 else 1


# ---- (a) memory per waiting task -----------------------------------------------------------------


def parked_threads(tasks: int, wait_ms: int, *, hold_ms: int = 0, announce: bool = True) -> Run:
    """`tasks` threads each wait on one shared deadline (an Event.wait with a timeout).

    The start gate is a `threading.Barrier(tasks + 1)`: every thread and the coordinator pass it
    together, so the handshake is the barrier itself. Threads float; nothing is pinned.
    """
    gate = Gate(0, hold_ms, announce=announce)
    gate.release()  # no pinned workers here; this prints the markers verify.sh waits for
    barrier = threading.Barrier(tasks + 1)
    woke = array("q", bytes(8 * tasks))
    deadline = [0]  # written by the coordinator before it enters the barrier

    def task(index: int) -> None:
        barrier.wait()
        remaining = (deadline[0] - time.monotonic_ns()) / NS
        threading.Event().wait(max(remaining, 0.0))
        woke[index] = time.monotonic_ns()

    gc.collect()
    before = memory()
    threads = [threading.Thread(target=task, args=(i,)) for i in range(tasks)]
    for t in threads:
        t.start()
    when = time.monotonic_ns() + wait_ms * 1_000_000
    deadline[0] = when
    barrier.wait()  # the gate: all `tasks` threads and the coordinator are here
    time.sleep(wait_ms / 2000)
    parked = memory()
    for t in threads:
        t.join()
    run = Run()
    run.samples = array("q", (_positive(w - when) for w in woke))
    run.counters = {
        "tasks": tasks,
        "tasks_armed": barrier.parties - 1,
    }  # the barrier opened: all arrived
    run.counters.update(memory_counters(before, parked, tasks))
    run.notes = (
        f"parked; model=threads (threading.Thread, Event.wait); wait_ms={wait_ms}; "
        f"stack_size={threading.stack_size()} (0: the platform default)"
    )
    return run


async def _parked_asyncio(
    tasks: int, wait_ms: int, woke: array, out: dict[str, Memory | int]
) -> None:
    loop = asyncio.get_running_loop()
    barrier = asyncio.Barrier(tasks + 1)
    deadline = [0]

    async def waiter(index: int) -> None:
        await barrier.wait()
        await asyncio.sleep(max((deadline[0] - time.monotonic_ns()) / NS, 0.0))
        woke[index] = time.monotonic_ns()

    gc.collect()
    out["before"] = memory()
    out["traced_before"] = tracemalloc.get_traced_memory()[0] if tracemalloc.is_tracing() else 0
    created = [loop.create_task(waiter(i)) for i in range(tasks)]
    when = time.monotonic_ns() + wait_ms * 1_000_000
    deadline[0] = when
    out["when"] = when
    await barrier.wait()  # the gate: all `tasks` tasks and the coordinator are here
    await asyncio.sleep(wait_ms / 2000)
    out["parked"] = memory()
    out["traced_parked"] = tracemalloc.get_traced_memory()[0] if tracemalloc.is_tracing() else 0
    await asyncio.gather(*created)
    out["armed"] = barrier.parties - 1  # the barrier opened: all arrived


def parked_asyncio(
    tasks: int, wait_ms: int, *, cpu: int = -1, hold_ms: int = 0, announce: bool = True
) -> Run:
    """`tasks` asyncio tasks each wait on one shared deadline.

    Two passes. The first, untraced, reads RSS and the kernel's figures like the thread run. The
    second runs under `tracemalloc` and reads the bytes the tasks keep allocated in Python's
    allocators: the figure is "measured by tracemalloc" (it counts blocks from Python's own
    allocators and nothing taken outside them), not an exact byte count.
    """
    gate = Gate(1, hold_ms, announce=announce)
    run = Run()
    state: dict[str, Memory | int] = {}
    woke = array("q", bytes(8 * tasks))
    error: list[BaseException] = []

    def worker() -> None:
        try:
            gate.worker_ready(cpu, "event-loop")
            asyncio.run(_parked_asyncio(tasks, wait_ms, woke, state))
        except BaseException as exc:  # reported by the coordinator after join()
            error.append(exc)

    thread = threading.Thread(target=worker, name="event-loop")
    thread.start()
    gate.release()
    thread.join()
    if error:
        raise RuntimeError("the event-loop thread failed") from error[0]
    before, parked, when = state["before"], state["parked"], state["when"]
    assert isinstance(before, Memory) and isinstance(parked, Memory) and isinstance(when, int)
    run.samples = array("q", (_positive(w - when) for w in woke))
    run.counters = {"tasks": tasks, "tasks_armed": int(state["armed"])}
    run.counters.update(memory_counters(before, parked, tasks))

    # The traced pass runs the same workload; it only adds the allocation records.
    traced: dict[str, Memory | int] = {}
    traced_woke = array("q", bytes(8 * tasks))
    tracemalloc.start()
    try:
        asyncio.run(_parked_asyncio(tasks, wait_ms, traced_woke, traced))
    finally:
        tracemalloc.stop()
    grew = max(0, int(traced["traced_parked"]) - int(traced["traced_before"]))
    run.counters["tracemalloc_delta_bytes"] = grew
    run.counters["tracemalloc_bytes_per_task"] = grew // tasks
    run.cpus = [c for c in gate_cpus(cpu)]
    run.notes = (
        f"parked; model=asyncio-tasks; wait_ms={wait_ms}; "
        "tracemalloc_bytes_per_task is measured by "
        "tracemalloc in a second, traced pass (blocks from Python's allocators only)"
    )
    return run


def gate_cpus(cpu: int) -> list[int]:
    return [cpu] if cpu >= 0 else []


# ---- (b) hand-off --------------------------------------------------------------------------------


def _expected_acc(rounds: int, batch: int, warmup_batches: int) -> int:
    return (warmup_batches + rounds // batch) * (batch * (batch + 1) // 2)


def _finish_pingpong(
    run: Run, rounds: int, batch: int, warmup_batches: int, acc: int, served: int, gate: Gate
) -> Run:
    run.counters.update(
        {
            "round_trips": rounds,
            "round_trips_served": served,
            "warmup_round_trips": warmup_batches * batch,
            "payload_mismatch": 0 if acc == _expected_acc(rounds, batch, warmup_batches) else 1,
            "start_skew_ns": gate.start_skew_ns(),
        }
    )
    return run


def pingpong_threads(
    rounds: int,
    batch: int,
    *,
    cpus: list[int] | None = None,
    warmup_batches: int = 20,
    hold_ms: int = 0,
    announce: bool = True,
) -> Run:
    """Two threads pass a turn through a pair of `queue.SimpleQueue`s.

    A sample is a batch's time per round trip.
    """
    pins = cpus if cpus else [-1, -1]
    gate = Gate(2, hold_ms, announce=announce)
    ping: queue.SimpleQueue[int] = queue.SimpleQueue()
    pong: queue.SimpleQueue[int] = queue.SimpleQueue()
    run = Run()
    acc = [0]
    served = [0]
    ctx: list[tuple[int, int]] = [(0, 0), (0, 0)]
    failures: list[BaseException] = []

    def ponger() -> None:
        try:
            gate.worker_ready(pins[1], "pong")
            before = ctx_switches()
            while (value := ping.get()) >= 0:
                served[0] += 1
                pong.put(value + 1)
            after = ctx_switches()
            ctx[1] = (after[0] - before[0], after[1] - before[1])
        except BaseException as exc:
            failures.append(exc)

    def pinger() -> None:
        try:
            gate.worker_ready(pins[0], "ping")
            before = ctx_switches()
            total = 0
            clock = time.perf_counter_ns
            for _ in range(warmup_batches):
                for j in range(batch):
                    ping.put(j)
                    total += pong.get()
            for _ in range(rounds // batch):
                t0 = clock()
                for j in range(batch):
                    ping.put(j)
                    total += pong.get()
                run.samples.append(_positive((clock() - t0) // batch))
            acc[0] = total
            after = ctx_switches()
            ctx[0] = (after[0] - before[0], after[1] - before[1])
        except BaseException as exc:
            failures.append(exc)
        finally:
            ping.put(-1)

    b = threading.Thread(target=ponger, name="pong")
    a = threading.Thread(target=pinger, name="ping")
    b.start()
    a.start()
    gate.release()
    a.join()
    b.join()
    if failures:
        raise RuntimeError("a ping-pong thread failed") from failures[0]
    run.cpus = [c for c in pins if c >= 0]
    run.voluntary = ctx[0][0] + ctx[1][0]
    run.involuntary = ctx[0][1] + ctx[1][1]
    run.counters.update({"ctx_voluntary_a": ctx[0][0], "ctx_voluntary_b": ctx[1][0]})
    run.notes = (
        f"pingpong; model=threads (queue.SimpleQueue); rounds={rounds}; batch={batch}; "
        "sample=batch time / batch"
    )
    return _finish_pingpong(run, rounds, batch, warmup_batches, acc[0], served[0], gate)


class _Token:
    """A one-shot hand-off on an asyncio.Future, re-armed by the side that takes it."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop
        self._future: asyncio.Future[None] = loop.create_future()

    def post(self) -> None:
        self._future.set_result(None)

    async def take(self) -> None:
        await self._future
        self._future = self._loop.create_future()


async def _pingpong_asyncio(
    rounds: int, batch: int, warmup_batches: int, run: Run, out: dict[str, int]
) -> None:
    loop = asyncio.get_running_loop()
    ping, pong = _Token(loop), _Token(loop)
    slot = [0]
    served = [0]

    async def ponger() -> None:
        while True:
            await ping.take()
            if slot[0] < 0:
                return
            slot[0] += 1
            served[0] += 1
            pong.post()

    async def pinger() -> None:
        total = 0
        clock = time.perf_counter_ns
        for _ in range(warmup_batches):
            for j in range(batch):
                slot[0] = j
                ping.post()
                await pong.take()
                total += slot[0]
        for _ in range(rounds // batch):
            t0 = clock()
            for j in range(batch):
                slot[0] = j
                ping.post()
                await pong.take()
                total += slot[0]
            run.samples.append(_positive((clock() - t0) // batch))
        slot[0] = -1
        ping.post()
        out["acc"] = total

    before = ctx_switches()
    b = loop.create_task(ponger())
    await pinger()
    await b
    after = ctx_switches()
    out["served"] = served[0]
    out["voluntary"] = after[0] - before[0]
    out["involuntary"] = after[1] - before[1]


def pingpong_asyncio(
    rounds: int,
    batch: int,
    *,
    cpu: int = -1,
    warmup_batches: int = 20,
    hold_ms: int = 0,
    announce: bool = True,
) -> Run:
    """Two asyncio tasks pass a turn through a pair of `asyncio.Future`s on one loop thread."""
    gate = Gate(1, hold_ms, announce=announce)
    run = Run()
    out: dict[str, int] = {}
    failures: list[BaseException] = []

    def worker() -> None:
        try:
            gate.worker_ready(cpu, "event-loop")
            asyncio.run(_pingpong_asyncio(rounds, batch, warmup_batches, run, out))
        except BaseException as exc:
            failures.append(exc)

    thread = threading.Thread(target=worker, name="event-loop")
    thread.start()
    gate.release()
    thread.join()
    if failures:
        raise RuntimeError("the event-loop thread failed") from failures[0]
    run.cpus = gate_cpus(cpu)
    run.voluntary, run.involuntary = out["voluntary"], out["involuntary"]
    run.notes = (
        f"pingpong; model=asyncio-tasks (asyncio.Future); rounds={rounds}; batch={batch}; "
        "sample=batch time / batch"
    )
    return _finish_pingpong(run, rounds, batch, warmup_batches, out["acc"], out["served"], gate)


# ---- (c) the blocking call -----------------------------------------------------------------------


class _CountSlowCallbacks(logging.Handler):
    """Counts the `Executing <...> took N seconds` warnings of asyncio's debug mode."""

    SLOW_CALLBACK = "Executing "

    def __init__(self) -> None:
        super().__init__(level=logging.WARNING)
        self.count = 0

    def emit(self, record: logging.LogRecord) -> None:
        # CPython 3.14 base_events.py: logger.warning('Executing %s took %.3f seconds', ...)
        if record.name == "asyncio" and record.msg == "Executing %s took %.3f seconds":
            self.count += 1


async def _neighbours(
    tasks: int,
    iterations: int,
    period_ns: int,
    blocking: bool,
    block_ns: int,
    lateness: array,
    late: bytearray,
    epoch: int,
    debug: bool,
) -> None:
    stagger = period_ns // tasks

    async def neighbour(i: int) -> None:
        late[i] = time.monotonic_ns() >= epoch + i * stagger
        for k in range(iterations):
            d = epoch + k * period_ns + i * stagger
            await asyncio.sleep(max((d - time.monotonic_ns()) / NS, 0.0))
            lateness[i * iterations + k] = _positive(time.monotonic_ns() - d)
            # The defect: time.sleep in a coroutine blocks the event loop, so every task waits.
            if blocking and i == 0 and k % 10 == 9:
                time.sleep(block_ns / NS)

    async with asyncio.TaskGroup() as group:
        for i in range(tasks):
            group.create_task(neighbour(i))
        # Debug mode times every callback from here on. It is switched on after the tasks exist, so
        # the step that creates all of them (longer than the threshold) is not counted, and the
        # collector is off so a collection pause does not look like a slow callback.
        if debug:
            gc.collect()
            gc.disable()
            asyncio.get_running_loop().set_debug(True)
    if debug:
        gc.enable()


def neighbours_asyncio(
    tasks: int,
    iterations: int,
    period_us: int,
    *,
    blocking: bool = False,
    block_us: int = 2000,
    debug: bool = False,
    slow_callback_ms: float = 1.0,
    cpu: int = -1,
    hold_ms: int = 0,
    announce: bool = True,
) -> Run:
    """`tasks` asyncio tasks wake every period, staggered across it; with `blocking`, task 0 calls
    `time.sleep` once every tenth iteration. With `debug`, the loop runs in asyncio debug mode with
    `slow_callback_duration` at `slow_callback_ms`, and the warnings it logs are counted."""
    gate = Gate(1, hold_ms, announce=announce)
    run = Run()
    lateness = array("q", [1]) * (tasks * iterations)
    late = bytearray(tasks)
    counter = _CountSlowCallbacks()
    failures: list[BaseException] = []

    def worker() -> None:
        try:
            gate.worker_ready(cpu, "event-loop")
            epoch = time.monotonic_ns() + 500_000_000
            with asyncio.Runner(debug=False) as runner:
                runner.get_loop().slow_callback_duration = slow_callback_ms / 1000
                runner.run(
                    _neighbours(
                        tasks,
                        iterations,
                        period_us * 1000,
                        blocking,
                        block_us * 1000,
                        lateness,
                        late,
                        epoch,
                        debug,
                    )
                )
        except BaseException as exc:
            failures.append(exc)

    logger = logging.getLogger("asyncio")
    logger.addHandler(counter)
    try:
        thread = threading.Thread(target=worker, name="event-loop")
        thread.start()
        gate.release()
        thread.join()
    finally:
        logger.removeHandler(counter)
    if failures:
        raise RuntimeError("the event-loop thread failed") from failures[0]
    run.samples = lateness
    run.cpus = gate_cpus(cpu)
    run.counters = {
        "tasks": tasks,
        "iterations": iterations,
        "late_starts": sum(late),
        "blocking_calls": iterations // 10 if blocking else 0,
        "blocking_call_us": block_us if blocking else 0,
        "debug_mode": int(debug),
        "slow_callback_ms_x1000": int(slow_callback_ms * 1000) if debug else 0,
        "slow_callback_warnings": counter.count,
    }
    run.notes = (
        f"neighbours; model=asyncio-tasks; tasks={tasks}; iterations={iterations}; "
        f"period_us={period_us}; "
        f"blocking_call={str(blocking).lower()}; debug={str(debug).lower()}; "
        "sample=wake lateness against the task's deadline; "
        "asyncio's epoll timeout has 1 ms resolution"
    )
    return run


WORKLOADS: dict[str, Callable[..., Run]] = {
    "parked-threads": parked_threads,
    "parked-asyncio-tasks": parked_asyncio,
    "pingpong-threads": pingpong_threads,
    "pingpong-asyncio-tasks": pingpong_asyncio,
    "neighbours-asyncio-tasks": neighbours_asyncio,
}
