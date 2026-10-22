"""The in-flight parcel tracker with a heap that looks like a shift in progress (Python lane).

The same three lifetimes as the Java lane, sized for CPython, which can build tens of thousands
of objects per second on the receive thread, not hundreds of thousands:

* the shift manifest is a ring of entries, full before the first parcel and overwritten one entry
  per parcel, so the live set is constant;
* the in-flight table holds each parcel from the scanner to the diverter (an ``OrderedDict`` whose
  eldest entry leaves when the belt is full);
* the scan history is built per parcel and dies with it.

The only difference between the two variants is whether the history is a reference cycle. A cycle
(the parcel lists its samples and each sample points back at the parcel) cannot be freed by
reference counting: it waits for the cyclic collector, and by the time the parcel leaves the belt
the cycle has been promoted to the oldest generation, so only a full collection (which walks the
whole live set) can free it. Without the back-pointer, refcounting frees the parcel the moment the
table drops it and the collector has nothing to do.
"""

from collections import OrderedDict
from dataclasses import dataclass, field

from lowlat_consumer import lane_for

SAMPLE_BYTES = 256

# Stage names are shared strings: a manifest entry holds references, not copies.
STAGES = ("scan", "dimension", "checkweigh", "label")


@dataclass(frozen=True, slots=True)
class Settings:
    rate: int = 10_000
    live_entries: int = 400_000
    entry_bytes: int = 256
    in_flight_ms: int = 480
    samples: int = 6

    @property
    def in_flight_parcels(self) -> int:
        return max(1, self.rate * self.in_flight_ms // 1000)


@dataclass(slots=True)
class ManifestEntry:
    """A manifest line: what the shift knows about one parcel."""

    barcode: str
    seq: int
    lane: int
    label: bytes
    stages: tuple[str, ...]


@dataclass(slots=True)
class ScanSample:
    """One raw sensor read; ``parent`` is set only when the history is made cyclic."""

    at_ns: int
    sensor: int
    raw: bytes
    parent: ParcelState | None = None


@dataclass(slots=True)
class ParcelState:
    """A parcel between the scanner and the diverter."""

    seq: int
    lane: int
    samples: list[ScanSample] = field(default_factory=list)


def synthetic_barcode(n: int) -> str:
    """An 18-digit string in the SSCC-18 shape: extension, prefix, 9-digit serial, check digit."""
    return f"{0:08}{n % 1_000_000_000:09}0"


class Tracker:
    """Single-threaded; the receive thread is the only caller after construction."""

    def __init__(self, settings: Settings, *, cyclic: bool) -> None:
        self.settings = settings
        self.cyclic = cyclic
        self._ring: list[ManifestEntry | None] = [None] * settings.live_entries
        self._in_flight: OrderedDict[str, ParcelState] = OrderedDict()
        self._cursor = 0

    def populate(self) -> None:
        """Fill the manifest, so the run starts with the live set a shift in progress has."""
        for i in range(len(self._ring)):
            self._ring[i] = self._entry(synthetic_barcode(i), i, i & 7)

    def track(self, barcode: str, seq: int) -> int:
        """Handle one parcel: lane lookup, scan history, manifest line, in-flight table."""
        lane = lane_for(barcode)
        state = ParcelState(seq, lane)
        samples = [
            ScanSample(seq * 31 + i, i, bytes(SAMPLE_BYTES))  # a fresh buffer per read
            for i in range(self.settings.samples)
        ]
        if self.cyclic:
            for sample in samples:
                sample.parent = state  # state -> samples -> sample -> state
        state.samples = samples
        self._ring[self._cursor % len(self._ring)] = self._entry(barcode, seq, lane)
        self._cursor += 1
        self._in_flight[barcode] = state
        if len(self._in_flight) > self.settings.in_flight_parcels:
            self._in_flight.popitem(last=False)  # diverted: the eldest leaves the belt
        return lane

    def warm_up(self, parcels: int) -> None:
        """Run synthetic parcels through ``track``, so the belt is full when the run starts."""
        for i in range(parcels):
            self.track(synthetic_barcode(i), -1 - i)

    def _entry(self, barcode: str, seq: int, lane: int) -> ManifestEntry:
        return ManifestEntry(barcode, seq, lane, bytes(self.settings.entry_bytes), STAGES)
