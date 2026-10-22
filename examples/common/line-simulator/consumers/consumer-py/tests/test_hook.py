"""The handler hook: parcels the handler holds are completed later, and drain flushes the rest."""

import socket
import time
from pathlib import Path

import pytest
from lowlat.line.v1.parcel_pb2 import ParcelEvent
from lowlat_consumer import Completion, GapTracker, run
from lowlat_measure import Recorder

PROFILE = Path(__file__).resolve().parents[5] / "common/measure-fixtures/profile.json"
BARCODE = "006141410000000008"


@pytest.fixture(autouse=True)
def _profile(monkeypatch):
    monkeypatch.setenv("LOWLAT_PROFILE", str(PROFILE))


def _send(port: int, seqs: list[int]) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as tx:
        for seq in seqs:
            event = ParcelEvent(seq=seq, intended_emit_ns=time.monotonic_ns(), barcode=BARCODE)
            tx.sendto(event.SerializeToString(), ("127.0.0.1", port))


def _run(seqs: list[int], handler, drain, expect: int):
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("127.0.0.1", 0))
    rx.settimeout(0.05)
    with rx:
        _send(rx.getsockname()[1], seqs)
        rec = Recorder("hook-test", "hook")
        tracker = GapTracker()
        result = run(rx, rec, tracker, handler, expect, 1_000_000_000, drain)
    return rec, tracker, result


def test_per_parcel_handler_completes_inside_the_call():
    def handler(event: ParcelEvent, complete: Completion) -> None:
        complete(event.intended_emit_ns, time.monotonic_ns())

    rec, tracker, result = _run([0, 1, 2], handler, None, expect=3)
    assert result.stopped == "expect"
    assert result.completed == 3
    assert result.first_done_ns <= result.last_done_ns
    assert rec.build_report("t")["count"] == 3
    assert tracker.dropped == 0


def test_deferred_completion_and_drain():
    held: list[int] = []

    def handler(event: ParcelEvent, complete: Completion) -> None:
        held.append(event.intended_emit_ns)
        if len(held) == 2:
            drain(complete)

    def drain(complete: Completion) -> None:
        done_ns = time.monotonic_ns()
        for intended in held:
            complete(intended, done_ns)
        held.clear()

    rec, _, result = _run([0, 1, 2], handler, drain, expect=3)  # 2 completed in-loop, 1 by drain
    assert result.completed == 3
    assert rec.build_report("t")["count"] == 3


def test_gaps_are_booked_as_dropped():
    def handler(event: ParcelEvent, complete: Completion) -> None:
        complete(event.intended_emit_ns, time.monotonic_ns())

    rec, tracker, result = _run([0, 3], handler, None, expect=4)
    assert tracker.dropped == 2
    assert result.completed == 2
    assert rec.build_report("t")["dropped"] == 2
