"""Python line consumer for the parcel-line simulator.

``loop.run`` is the receive loop; an example supplies a per-parcel ``Handler``. ``flat`` reads
the ``parcel-v1`` flat record (``contracts/flat/parcel-v1``).
"""

from lowlat_consumer.gaps import GapTracker
from lowlat_consumer.handle import lane_for
from lowlat_consumer.loop import (
    Completion,
    Drain,
    Handler,
    NegativeLatencyError,
    RunResult,
    WindowedRecorders,
    install_signal_handlers,
    open_socket,
    run,
)

__all__ = [
    "Completion",
    "Drain",
    "GapTracker",
    "Handler",
    "NegativeLatencyError",
    "RunResult",
    "WindowedRecorders",
    "install_signal_handlers",
    "lane_for",
    "open_socket",
    "run",
]
