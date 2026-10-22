import gc

from lowlat_gctails.pauses import GcPauseLog


def test_records_each_collection_with_its_generation():
    with GcPauseLog(capacity=8) as log:
        gc.collect(0)
        gc.collect(1)
        gc.collect(2)
    assert log.count == 3
    assert log.generation_counts() == (1, 1, 1)
    assert all(c.duration_ns > 0 for c in log.collections())


def test_callback_is_removed_on_exit():
    log = GcPauseLog(capacity=2)
    with log:
        assert log in gc.callbacks
    assert log not in gc.callbacks


def test_overflow_counts_what_was_not_stored():
    with GcPauseLog(capacity=2) as log:
        for _ in range(5):
            gc.collect(0)
    assert log.count == 5
    assert log.overflow == 3
    assert len(list(log.collections())) == 2
