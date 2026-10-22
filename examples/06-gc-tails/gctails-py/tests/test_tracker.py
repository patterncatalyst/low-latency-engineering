import gc

import pytest
from lowlat_gctails.tracker import Settings, Tracker, synthetic_barcode

SMALL = Settings(rate=1_000, live_entries=500, entry_bytes=32, in_flight_ms=100, samples=4)


@pytest.fixture
def quiet_gc():
    """No automatic collections while a test counts what a manual one frees."""
    gc.collect()
    gc.disable()
    yield
    gc.enable()


def test_synthetic_barcode_has_the_sscc_shape():
    assert len(synthetic_barcode(123_456_789)) == 18
    assert synthetic_barcode(123_456_789) == "000000001234567890"


def test_in_flight_table_is_bounded():
    tracker = Tracker(SMALL, cyclic=False)
    tracker.populate()
    tracker.warm_up(1_000)
    assert len(tracker._in_flight) == SMALL.in_flight_parcels


def test_track_returns_the_common_lane():
    tracker = Tracker(SMALL, cyclic=False)
    assert tracker.track(synthetic_barcode(77), 1) == 77 % 8


def test_cyclic_history_is_only_freed_by_the_collector(quiet_gc):
    tracker = Tracker(SMALL, cyclic=True)
    tracker.warm_up(2_000)  # fills the belt; the parcels that left it are cycles
    assert gc.collect() > 0


def test_acyclic_history_is_freed_by_reference_counting(quiet_gc):
    tracker = Tracker(SMALL, cyclic=False)
    tracker.warm_up(2_000)
    assert gc.collect() == 0
