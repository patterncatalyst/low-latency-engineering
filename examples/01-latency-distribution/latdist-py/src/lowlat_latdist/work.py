"""The slow "re-lookup" path: real CPU work calibrated to a target duration."""

import time

_MASK = (1 << 64) - 1


def spin(iterations: int) -> int:
    """A dependent multiply-add chain: each step needs the previous result."""
    x = 0x9E3779B97F4A7C15
    for _ in range(iterations):
        x = (x * 6364136223846793005 + 1442695040888963407) & _MASK
    return x


def calibrate(target_us: int) -> int:
    """Iterations of ``spin`` taking ``target_us``.

    Double the count until a run lasts 20 ms, then time five more runs and keep the
    fastest: a run preempted on a busy host measures the scheduler, not the loop.
    """
    n = 1 << 12
    best = 0.0  # iterations per ns
    extra = 0
    while extra < 5:
        t0 = time.monotonic_ns()
        spin(n)
        took = time.monotonic_ns() - t0
        best = max(best, n / took)
        if took < 20_000_000:
            n *= 2
        else:
            extra += 1
    return int(best * target_us * 1000)
