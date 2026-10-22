"""--window: the run is split at parcel N; ownership: a completion made on another thread counts."""

import json
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest
from lowlat.line.v1.parcel_pb2 import ParcelEvent
from lowlat_consumer import Completion, GapTracker, WindowedRecorders, run
from lowlat_measure import Recorder

BARCODE = "006141410000000008"
EXAMPLES = Path(__file__).resolve().parents[5]
SIM = EXAMPLES / "build/release/common/line-simulator/line-simulator"
PORT = 47112

pytestmark = pytest.mark.usefixtures("lowlat_profile")


def _count(rec: Recorder) -> int:
    return int(rec.histogram.get_total_count())


def test_gap_tracker_books_drops_in_their_window():
    t = GapTracker(window=10)
    for s in (0, 1, 4):  # 2 and 3 missing
        t.observe(s)
    assert t.dropped_below_window == 2
    t.observe(14)  # 5..13 missing: 5..9 below the window
    assert (t.dropped, t.dropped_below_window) == (11, 7)
    t.observe(20)
    assert (t.dropped, t.dropped_below_window) == (16, 7)


def test_windowed_recorders_split_by_seq_and_name_the_reports(tmp_path):
    w = WindowedRecorders("ex", "warmed", 3)
    for seq in range(10):
        w.record(seq, 1000 + seq)
    assert (_count(w.first), _count(w.steady)) == (3, 7)
    assert (w.first.variant, w.steady.variant) == ("warmed-first-3", "warmed-steady")
    first, steady = w.write_reports(tmp_path / "run.json", "n")
    assert (first.name, steady.name) == ("run-first-3.json", "run-steady.json")
    assert json.loads(first.read_text(encoding="utf-8"))["variant"] == "warmed-first-3"
    assert json.loads(steady.read_text(encoding="utf-8"))["count"] == 7


def _run(seqs, window, handler):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as rx:
        rx.bind(("127.0.0.1", 0))
        rx.settimeout(0.05)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as tx:
            for seq in seqs:
                event = ParcelEvent(seq=seq, intended_emit_ns=time.monotonic_ns(), barcode=BARCODE)
                tx.sendto(event.SerializeToString(), ("127.0.0.1", rx.getsockname()[1]))
        rec = Recorder("window-test", "w")
        windows = WindowedRecorders("window-test", "w", window)
        tracker = GapTracker(window=window)
        drain = getattr(handler, "drain", None)
        result = run(
            rx, rec, tracker, handler, max(seqs) + 1, 1_000_000_000, drain, windows=windows
        )
    return rec, windows, tracker, result


def test_two_windows_sum_to_the_total_and_drops_are_split():
    def handler(event: ParcelEvent, complete: Completion) -> None:
        complete(event.intended_emit_ns, time.monotonic_ns())

    rec, w, tracker, _ = _run([0, 1, 2, 6, 9], 4, handler)  # 3 missing below 4; 4, 5, 7, 8 above
    assert (_count(w.first), _count(w.steady)) == (3, 2)
    assert _count(w.first) + _count(w.steady) == _count(rec)
    assert (w.first.dropped, w.steady.dropped) == (1, 4)
    assert w.first.dropped + w.steady.dropped == rec.dropped == tracker.dropped


def test_completion_made_on_another_thread_counts_every_parcel():
    done_ids: set[int] = set()
    pending: list[tuple[int, int]] = []

    class Handler:
        def __call__(self, event: ParcelEvent, complete: Completion) -> None:
            pending.append((event.seq, event.intended_emit_ns))

        def drain(self, complete: Completion) -> None:
            def decide() -> None:
                done_ids.add(threading.get_ident())
                for seq, intended in pending:
                    complete(intended, time.monotonic_ns(), seq)

            t = threading.Thread(target=decide)
            t.start()
            t.join()  # the join publishes what the decide thread wrote

    rec, w, _, result = _run(list(range(50)), 20, Handler())
    assert done_ids and threading.get_ident() not in done_ids
    assert result.completed == 50
    assert _count(rec) == 50
    assert (_count(w.first), _count(w.steady)) == (20, 30)


@pytest.mark.skipif(not SIM.is_file(), reason=f"simulator not built: {SIM}")
def test_cli_window_writes_two_reports_summing_to_the_total(tmp_path):
    report = tmp_path / "r.json"
    cmd = [
        sys.executable,
        "-m",
        "lowlat_consumer",
        "--bind",
        f"127.0.0.1:{PORT}",
        "--expect",
        "1000",
        "--window",
        "400",
        "--variant",
        "baseline",
        "--report",
        str(report),
    ]
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True) as consumer:
        try:
            assert consumer.stdout.readline().startswith("line-consumer-py: bound")
            subprocess.run(
                [
                    str(SIM),
                    "--rate",
                    "1000",
                    "--duration",
                    "1",
                    "--quiet",
                    "--dest",
                    f"127.0.0.1:{PORT}",
                ],
                check=True,
                timeout=30,
            )
            out, _ = consumer.communicate(timeout=30)
        finally:
            if consumer.poll() is None:
                consumer.kill()
    assert consumer.returncode == 0, out
    total = json.loads(report.read_text(encoding="utf-8"))["count"]
    first = json.loads((tmp_path / "r-first-400.json").read_text(encoding="utf-8"))
    steady = json.loads((tmp_path / "r-steady.json").read_text(encoding="utf-8"))
    assert (first["count"], steady["count"]) == (400, 600)
    assert first["count"] + steady["count"] == total == 1000
