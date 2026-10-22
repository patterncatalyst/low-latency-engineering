"""Amdahl's Law, a modelling tool: it takes a time fraction as input, never a latency."""


def amdahl_speedup(serial_fraction: float, workers: int) -> float:
    """Speedup on ``workers`` workers when ``serial_fraction`` s of the one-worker run is serial.

    With the parallel fraction p = 1 - s:  S(n) = 1 / ((1 - p) + p / n) = 1 / (s + (1 - s) / n),
    bounded above by 1 / s.
    """
    return 1.0 / (serial_fraction + (1.0 - serial_fraction) / workers)
