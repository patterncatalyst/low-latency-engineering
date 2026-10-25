"""The Python receive path: four tunnel cameras (flat wire, one UDP port each), three ways to wait.

* `asyncio-datagram`: one thread, one event loop, a `DatagramProtocol` per socket
  (`loop.create_datagram_endpoint`; the default selector loop, epoll underneath).
* `blocking-thread`: one thread per socket, each in a blocking `recv`. Under the GIL the threads
  take turns; under the free-threaded build they run in parallel.
* `uvloop`: the same protocols on uvloop's libuv loop (GIL build only; observed).

The standard library has no io_uring, and no mature third-party binding exists: that is the
divergence from C++.

This module imports nothing that re-enables the GIL. A free-threaded run is refused if the GIL is on
at the start or at the end.
"""

import asyncio
import json
import socket
import sys
import threading
import time
from array import array
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from lowlat_io import gil_enabled, python_build, wire
from lowlat_io.placement import Gate, placement_of

CAMERAS = 4
EXAMPLE = "12-io-engines"
VARIANTS = ("asyncio-datagram", "blocking-thread", "uvloop")
RAW_SAMPLES = "samples.bin"
RAW_SIDECAR = "sidecar.json"
_RCVBUF = 4 * 1024 * 1024
_TICK_S = 0.1


@dataclass
class Camera:
    """One camera's socket and sequence accounting; one thread owns it."""

    sock: socket.socket
    expect: int
    highest: int = -1
    received: int = 0

    def observe(self, seq: int) -> bool:
        if seq <= self.highest:
            return False
        self.highest = seq
        self.received += 1
        return True

    @property
    def complete(self) -> bool:
        return self.highest + 1 >= self.expect

    @property
    def lost(self) -> int:
        return max(0, self.expect - self.received)


@dataclass
class Stats:
    """One thread's samples and counters. Nothing here is shared between threads."""

    samples: array = field(default_factory=lambda: array("q"))
    datagrams: int = 0
    malformed: int = 0
    calls: int = 0  # recv calls (blocking-thread) or datagram_received callbacks (asyncio, uvloop)
    lanes: list[int] = field(default_factory=lambda: [0] * wire.LANES)
    start_ns: int = 0
    last_rx_ns: int = 0


def open_socket(port: int) -> socket.socket:
    """A non-blocking UDP socket on 127.0.0.1:`port` (0 picks one), SO_REUSEPORT set."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, _RCVBUF)
    sock.bind(("127.0.0.1", port))
    sock.setblocking(False)
    return sock


def handle(data: bytes, cam: Camera, stats: Stats) -> None:
    """Decode, sequence-check, decide (the lane lookup), record latency from the intended time."""
    now = time.monotonic_ns()
    stats.datagrams += 1
    stats.last_rx_ns = now
    if not wire.valid(data):
        stats.malformed += 1
        return
    seq, intended = wire.seq_and_intended(data)
    if not cam.observe(seq):
        return
    stats.lanes[wire.lane(data)] += 1
    done = time.monotonic_ns()
    stats.samples.append(max(1, done - intended))


class _CameraProtocol(asyncio.DatagramProtocol):
    def __init__(self, cam: Camera, stats: Stats) -> None:
        self._cam = cam
        self._stats = stats

    def datagram_received(self, data: bytes, addr: object) -> None:
        self._stats.calls += 1
        handle(data, self._cam, self._stats)


async def _serve(cams: list[Camera], stats: Stats, idle_ms: int) -> None:
    loop = asyncio.get_running_loop()
    transports = []
    for cam in cams:
        transport, _ = await loop.create_datagram_endpoint(
            lambda cam=cam: _CameraProtocol(cam, stats), sock=cam.sock
        )
        transports.append(transport)
    try:
        while not all(cam.complete for cam in cams):
            await asyncio.sleep(_TICK_S)
            if stats.last_rx_ns and time.monotonic_ns() - stats.last_rx_ns > idle_ms * 1_000_000:
                break
    finally:
        for transport in transports:
            transport.close()


def _blocking(cam: Camera, stats: Stats, idle_ms: int) -> None:
    sock = cam.sock
    sock.settimeout(_TICK_S)
    while not cam.complete:
        try:
            data = sock.recv(128)
        except TimeoutError:
            stats.calls += 1
            if stats.last_rx_ns and time.monotonic_ns() - stats.last_rx_ns > idle_ms * 1_000_000:
                return
            continue
        stats.calls += 1
        handle(data, cam, stats)


@dataclass
class Run:
    variant: str
    cameras: list[Camera]
    stats: list[Stats]
    cpus: list[int]
    gil_at_start: bool = True
    gil_at_end: bool = True

    @property
    def parcels(self) -> int:
        return sum(len(s.samples) for s in self.stats)

    @property
    def lost(self) -> int:
        return sum(c.lost for c in self.cameras)

    @property
    def skew_ns(self) -> int:
        starts = [s.start_ns for s in self.stats if s.start_ns]
        return max(starts) - min(starts) if starts else 0


def threads_for(variant: str) -> int:
    if variant == "blocking-thread":
        return CAMERAS
    if variant in VARIANTS:
        return 1
    raise ValueError(f"--variant: {' | '.join(VARIANTS)}")


def run(
    variant: str,
    ports: list[int],
    expect: int,
    *,
    cpus: list[int] | None = None,
    hold_ms: int = 0,
    idle_ms: int = 1500,
    announce: bool = True,
    on_ready: Callable[[list[int]], None] | None = None,
) -> Run:
    """One pass: bind, pin and start the threads, run until every camera is complete or idle.

    `on_ready` gets the bound ports once the threads wait at the start gate (tests send from it).
    """
    threads = threads_for(variant)
    pins = cpus if cpus is not None else [-1] * threads
    gate = Gate(threads, hold_ms, announce=announce)
    start = threading.Barrier(threads)
    bound = threading.Barrier(threads + 1)  # every worker has bound its sockets
    failures: list[BaseException] = []
    # Each worker builds its own cameras and stats and publishes them here;
    # the barrier and the join order the reads.
    owned: list[list[Camera]] = [[] for _ in range(threads)]
    stats_by_thread: list[Stats | None] = [None] * threads

    def worker(index: int) -> None:
        try:
            stats = stats_by_thread[index] = Stats()
            ports_of = ports[index : index + 1] if variant == "blocking-thread" else ports
            cams = owned[index] = [Camera(open_socket(p), expect) for p in ports_of]
            bound.wait()
            gate.worker_ready(pins[index], f"{variant}-{index}")
            start.wait()
            stats.start_ns = time.monotonic_ns()
            if variant == "blocking-thread":
                _blocking(cams[0], stats, idle_ms)
            elif variant == "asyncio-datagram":
                asyncio.run(_serve(cams, stats, idle_ms))
            else:
                import uvloop

                uvloop.run(_serve(cams, stats, idle_ms))
        except BaseException as exc:  # reported by the coordinator after join()
            failures.append(exc)
            bound.abort()
            start.abort()

    pool = [
        threading.Thread(target=worker, args=(i,), name=f"{variant}-{i}") for i in range(threads)
    ]
    gil_at_start = gil_enabled()
    for t in pool:
        t.start()
    try:
        bound.wait()
        if on_ready is not None:  # the sockets are bound; the threads wait at the gate
            on_ready([cam.sock.getsockname()[1] for cams in owned for cam in cams])
        gate.release()
    except threading.BrokenBarrierError:
        pass  # a worker failed before the start; the join below reports it
    for t in pool:
        t.join()
    gil_at_end = gil_enabled()
    cameras = [cam for cams in owned for cam in cams]
    for cam in cameras:
        cam.sock.close()
    if failures:
        raise RuntimeError("a receive thread failed") from failures[0]
    return Run(
        variant,
        cameras,
        [s for s in stats_by_thread if s is not None],
        [c for c in pins if c >= 0],
        gil_at_start=gil_at_start,
        gil_at_end=gil_at_end,
    )


def write_raw(result: Run, out: Path, *, expect: int, idle_ms: int) -> None:
    """Samples (little-endian int64 ns) and the sidecar `lowlat-report from-samples` converts."""
    out.mkdir(parents=True, exist_ok=True)
    with (out / RAW_SAMPLES).open("wb") as fh:
        for stats in result.stats:
            samples = stats.samples
            if sys.byteorder == "big":
                samples = array("q", samples)
                samples.byteswap()
            samples.tofile(fh)
    counters = {
        "parcels": result.parcels,
        "datagrams": sum(s.datagrams for s in result.stats),
        "malformed": sum(s.malformed for s in result.stats),
        "dropped": result.lost,
        "callbacks_or_recv_calls": sum(s.calls for s in result.stats),
        "start_skew_ns": result.skew_ns,
        "threads": len(result.stats),
    }
    runtime: dict[str, object] = {"python_build": python_build(), "counters": counters}
    if result.cpus:
        runtime["placement"] = placement_of(result.cpus)
    sidecar = {
        "example": EXAMPLE,
        "variant": result.variant,
        "count": result.parcels,
        "dropped": result.lost,
        "build": {"compiler": sys.version.replace("\n", " "), "gil_enabled": result.gil_at_end},
        "runtime": runtime,
        "notes": (
            f"receive; cameras={CAMERAS}; expect_per_camera={expect}; flat wire; "
            f"variant={result.variant}; threads={len(result.stats)}; idle_ms={idle_ms}; "
            f"gil_at_start={str(result.gil_at_start).lower()}; "
            f"gil_at_end={str(result.gil_at_end).lower()}; no stdlib io_uring; latency is "
            "time.monotonic_ns at the end of the decide step minus the intended emit time"
        ),
    }
    (out / RAW_SIDECAR).write_text(json.dumps(sidecar, indent=2) + "\n", encoding="utf-8")
