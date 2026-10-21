"""The model and the work functions: the arithmetic the verify.sh criteria rest on."""

import pytest
from lowlat_amdahl.model import amdahl_speedup
from lowlat_amdahl.work import CELLS, process_share


def test_one_worker_is_one():
    assert amdahl_speedup(0.1, 1) == pytest.approx(1.0)


def test_ten_percent_serial():
    assert amdahl_speedup(0.1, 2) == pytest.approx(1 / 0.55)
    assert amdahl_speedup(0.1, 4) == pytest.approx(1 / 0.325)
    assert amdahl_speedup(0.1, 10**6) < 10.0  # bounded by 1 / s


def test_table_is_independent_of_how_the_batch_is_split():
    import threading

    def table(workers: int) -> list[int]:
        cell = [0] * CELLS
        lock = threading.Lock()
        for w in range(workers):
            process_share(cell, lock, None, 240, w, workers, 6, 50, 5)
        return cell

    assert table(1) == table(4)
