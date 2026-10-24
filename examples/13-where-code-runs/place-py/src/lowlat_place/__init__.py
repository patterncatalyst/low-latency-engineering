"""Ch13 wiring skeleton: the CPU counts Python reports."""

import os


def cpu_counts() -> dict[str, int | None]:
    """System CPUs (os.cpu_count) and CPUs usable by this process (os.process_cpu_count)."""
    return {"cpu_count": os.cpu_count(), "process_cpu_count": os.process_cpu_count()}
