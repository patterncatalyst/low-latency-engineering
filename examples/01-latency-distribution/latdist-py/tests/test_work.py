import time

from lowlat_latdist.work import calibrate, spin


def test_spin_is_deterministic_and_not_constant():
    assert spin(1000) == spin(1000)
    assert spin(1000) != spin(1001)


def test_calibrate_hits_the_target_within_a_factor_of_two():
    n = calibrate(2000)
    t0 = time.monotonic_ns()
    spin(n)
    took_us = (time.monotonic_ns() - t0) / 1000
    assert 1000 < took_us < 4000
