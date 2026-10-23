"""Ch9 Python lane: tracker logic, SSCC packing against the parcel-v1 golden barcodes, record
layout and footprint ordering, sweeps and the counters harness. Deterministic and CI-safe: no
PMU, no timing assertions."""

import json
import sys
from array import array
from pathlib import Path

import pytest
from lowlat_locality import counters, footprint, records, sweep
from lowlat_locality.records import DIVERT_TICKS, EMPTY, IN_FLIGHT, Scan, scan_of
from lowlat_locality.tracker import Tracked, Tracker

GOLDEN = Path(__file__).resolve().parents[4] / "contracts" / "flat" / "parcel-v1"


# --- SSCC packing --------------------------------------------------------------------------------


def test_pack_and_format_round_trip() -> None:
    assert records.pack_sscc("000000000000000042") == 42
    assert records.pack_sscc("999999999999999999") == 999_999_999_999_999_999
    assert records.format_sscc(42) == "000000000000000042"


@pytest.mark.parametrize(
    "bad",
    ["", "1234567", "12345678901234567", "1234567890123456789", "12345678901234567x",
     "+23456789012345678", "-23456789012345678", " 23456789012345678", "1_345678901234567x",
     "١٢٣٤٥٦٧٨٩٠١٢٣٤٥٦٧٨"],
)  # fmt: skip
def test_rejects_anything_but_eighteen_ascii_digits(bad: str) -> None:
    assert records.pack_sscc(bad) is None


def test_golden_barcodes_pack_to_their_digits() -> None:
    checked = 0
    for seed in (1, 42, 2026):
        golden = json.loads((GOLDEN / f"golden-seed{seed}.json").read_text(encoding="utf-8"))
        for record in golden["records"]:
            barcode = record["barcode"]
            assert records.pack_sscc(barcode) == int(barcode)
            assert records.format_sscc(int(barcode)) == barcode
            checked += 1
    assert checked == 24  # 3 seeds x 8 records


def test_seeded_keys_are_distinct_eighteen_digit_values() -> None:
    ks = records.keys(5_000, seed=7)
    assert len(set(ks)) == 5_000
    assert all(len(records.format_sscc(k)) == 18 for k in ks)


# --- tracker logic, both key types ---------------------------------------------------------------


@pytest.fixture(params=["int", "str"])
def tracker(request: pytest.FixtureRequest) -> Tracker:
    return Tracker(request.param)


def scans(n: int, seed: int = 1) -> list[Scan]:
    return [scan_of(k, i) for i, k in enumerate(records.keys(n, seed))]


def test_inserts_updates_and_finds(tracker: Tracker) -> None:
    batch = scans(8)
    assert [tracker.track(s) for s in batch] == [Tracked.INSERTED] * 8
    assert len(tracker) == 8
    assert tracker.track(batch[3]) is Tracked.UPDATED  # same barcode: no second entry
    assert len(tracker) == 8
    assert all(tracker.find_state(s.barcode) == IN_FLIGHT for s in batch)
    assert tracker.find_state("000000000000000001") == EMPTY
    assert tracker.track(Scan(barcode="not-a-barcode")) is Tracked.REJECTED
    assert len(tracker) == 8


def test_rescan_moves_the_due_tick(tracker: Tracker) -> None:
    first = Scan(barcode=records.format_sscc(5), tick=100)
    tracker.track(first)
    assert tracker.sweep_due(100 + DIVERT_TICKS - 1) == 0
    assert tracker.sweep_due(100 + DIVERT_TICKS) == 1
    assert tracker.track(Scan(barcode=first.barcode, tick=5_000)) is Tracked.UPDATED
    assert tracker.sweep_due(100 + DIVERT_TICKS) == 0
    assert tracker.sweep_due(5_000 + DIVERT_TICKS) == 1


def test_erase(tracker: Tracker) -> None:
    batch = scans(4)
    for s in batch:
        tracker.track(s)
    assert tracker.erase(batch[1].barcode)
    assert not tracker.erase(batch[1].barcode)  # already gone
    assert tracker.find_state(batch[1].barcode) == EMPTY
    assert len(tracker) == 3


def test_sweep_counts_only_what_is_due(tracker: Tracker) -> None:
    batch = scans(50)
    for s in batch:
        tracker.track(s)  # scan tick i, due at i + 1200
    assert tracker.sweep_due(DIVERT_TICKS - 1) == 0
    assert tracker.sweep_due(DIVERT_TICKS) == 1
    assert tracker.sweep_due(DIVERT_TICKS + 24) == 25
    assert tracker.sweep_due(1_000_000) == 50
    tracker.erase(batch[0].barcode)
    assert tracker.sweep_due(1_000_000) == 49


def test_expire_erases_what_is_due(tracker: Tracker) -> None:
    batch = scans(50)
    for s in batch:
        tracker.track(s)
    assert tracker.expire(DIVERT_TICKS + 9) == 10
    assert len(tracker) == 40
    assert all(tracker.find_state(s.barcode) == EMPTY for s in batch[:10])
    assert all(tracker.find_state(s.barcode) == IN_FLIGHT for s in batch[10:])
    assert tracker.expire(DIVERT_TICKS + 9) == 0


def test_sliding_window_keeps_the_line_in_flight_count(tracker: Tracker) -> None:
    ring, window = 1_000, 100
    batch = scans(ring, seed=5)
    for s in batch[ring - window :]:
        tracker.track(s)
    for i in range(3 * ring):
        pos = i % ring
        assert tracker.track(batch[pos]) is Tracked.INSERTED
        assert tracker.erase(batch[(pos - window) % ring].barcode)
        assert len(tracker) == window


# --- record layout and footprint -----------------------------------------------------------------


def test_slotted_record_has_no_instance_dict() -> None:
    record = records.make_record(scan_of(7, 0), 7)
    assert not hasattr(record, "__dict__")
    assert records.ParcelRecord.__slots__[0] == "sscc"  # type: ignore[attr-defined]
    assert sys.getsizeof(record) < sys.getsizeof(records.make_dict_record(scan_of(7, 0), 7))


def test_a_dict_per_parcel_costs_more_than_a_slotted_record() -> None:
    result = footprint.measure(2_000)
    tracked = result["tracked_bytes"]
    assert tracked["dict-per-parcel"] > tracked["slots-str"] > tracked["slots-int"]
    record_only = result["record_only_bytes"]
    assert 3 * record_only["dict-per-parcel"] > 5 * record_only["slots-int"]


# --- sweeps --------------------------------------------------------------------------------------


def test_objects_and_columns_agree_on_the_sweep() -> None:
    n = 5_000
    rows = sweep.build_objects(n)
    due, state = sweep.build_columns(n)
    assert isinstance(due, array)
    for tick in (0, 1_199, 1_200, 2_500, 10_000):
        assert sweep.sweep_objects(rows, tick) == sweep.sweep_columns(due, state, tick)
    assert sweep.sweep_columns(due, state, n // 2) == n // 2 - DIVERT_TICKS + 1


# --- counters (exactness only; the effect is a verify.sh observation) -----------------------------


@pytest.mark.parametrize("mode", ["threads", "processes"])
@pytest.mark.parametrize("layout", ["adjacent-counters", "pair-padded"])
def test_every_camera_keeps_its_own_count(mode: str, layout: str) -> None:
    result = counters.run(layout, mode, cpus=None, batches=20, cameras=3)
    assert result["cameras"] == 3
    assert [len(per_camera) for per_camera in result["batch_ns"]] == [20, 20, 20]
    assert result["stride_bytes"] == counters.STRIDE_BYTES[layout]
