import asyncio
import json
import os
import socket
import sys
import threading
import time
from pathlib import Path

import pytest
from lowlat_io import gil_enabled, loop_class_name, python_build, receive, run_on_uvloop, wire
from lowlat_io.placement import parse_cpus

FREE_THREADED = python_build() == "free-threaded"
PER_CAMERA = 300


def test_uvloop_runs_the_coroutine() -> None:
    async def answer() -> int:
        await asyncio.sleep(0)
        return 42

    assert run_on_uvloop(answer()) == 42


def test_the_running_loop_is_uvloop() -> None:
    assert loop_class_name() == "uvloop.Loop"


@pytest.mark.skipif(
    os.environ.get("LOWLAT_EXPECT_FREE_THREADED") != "1",
    reason="set LOWLAT_EXPECT_FREE_THREADED=1 when running under 3.14.9t",
)
def test_free_threaded_build_was_requested() -> None:
    assert sys._is_gil_enabled() is False
    assert gil_enabled() is False
    assert python_build() == "free-threaded"


def test_a_record_round_trips_its_fields() -> None:
    data = wire.encode(42, 1_234_567_890)
    assert len(data) == wire.SIZE
    assert wire.valid(data)
    assert wire.seq_and_intended(data) == (42, 1_234_567_890)


def test_the_lane_is_the_serial_modulo_eight() -> None:
    assert wire.lane(wire.encode(0, 0, "003400001234567890")) == 123456789 % 8
    assert wire.lane(wire.encode(0, 0, "003400000000000000")) == 0


def test_a_short_or_foreign_datagram_is_not_a_parcel() -> None:
    data = wire.encode(1, 1)
    assert not wire.valid(data[:40])
    assert not wire.valid(b"\x09\x00" + data[2:])
    with pytest.raises(ValueError):
        wire.lane(wire.encode(0, 0, "00340000123456789X"))


def test_cpus_parse() -> None:
    assert parse_cpus("1,2,3") == [1, 2, 3]
    with pytest.raises(ValueError):
        parse_cpus("1,x")


def _send(ports: list[int], per_camera: int) -> threading.Thread:
    def feed() -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as out:
            for seq in range(per_camera):
                for port in ports:
                    out.sendto(wire.encode(seq, time.monotonic_ns()), ("127.0.0.1", port))
                if seq % 20 == 19:
                    time.sleep(0.001)  # stay inside the socket buffer

    thread = threading.Thread(target=feed)
    thread.start()
    return thread


@pytest.mark.parametrize("variant", ["asyncio-datagram", "blocking-thread", "uvloop"])
def test_every_variant_decides_every_parcel(variant: str) -> None:
    if variant == "uvloop" and FREE_THREADED:
        pytest.skip("uvloop is measured under the GIL build only")
    senders: list[threading.Thread] = []
    result = receive.run(
        variant,
        [0] * receive.CAMERAS,
        PER_CAMERA,
        idle_ms=1500,
        announce=False,
        on_ready=lambda ports: senders.append(_send(ports, PER_CAMERA)),
    )
    senders[0].join()
    assert result.parcels == PER_CAMERA * receive.CAMERAS
    assert result.lost == 0
    assert sum(s.malformed for s in result.stats) == 0
    assert len(result.stats) == receive.threads_for(variant)
    if FREE_THREADED and variant != "uvloop":
        assert result.gil_at_start is False
        assert result.gil_at_end is False


def test_the_sidecar_has_what_from_samples_needs(tmp_path: Path) -> None:
    senders: list[threading.Thread] = []
    result = receive.run(
        "blocking-thread",
        [0] * receive.CAMERAS,
        50,
        announce=False,
        on_ready=lambda ports: senders.append(_send(ports, 50)),
    )
    senders[0].join()
    receive.write_raw(result, tmp_path, expect=50, idle_ms=1500)
    side = json.loads((tmp_path / receive.RAW_SIDECAR).read_text())
    assert side["count"] == result.parcels == 200
    assert (tmp_path / receive.RAW_SAMPLES).stat().st_size == 8 * side["count"]
    assert side["build"]["gil_enabled"] is (not FREE_THREADED)
    assert side["runtime"]["python_build"] == python_build()
    assert side["runtime"]["counters"]["dropped"] == 0
    assert "free-threading" in side["build"]["compiler"].lower() or not FREE_THREADED
