"""The in-flight parcel tracker, barcode to parcel state, on a dict of slotted records."""

from enum import StrEnum
from typing import Literal

from lowlat_locality.records import (
    DIVERT_TICKS,
    EMPTY,
    IN_FLIGHT,
    ParcelRecord,
    Scan,
    make_record,
    pack_sscc,
)


class Tracked(StrEnum):
    INSERTED = "inserted"
    UPDATED = "updated"
    REJECTED = "rejected"


class Tracker:
    """Barcode to :class:`ParcelRecord`, keyed by the packed ``int`` or by the barcode ``str``.

    The int key is a smaller object than the 18-character str and hashes faster; both are one object
    per key, which is why the Python lane compares bytes per tracked parcel and not layouts.
    """

    def __init__(self, key_by: Literal["int", "str"] = "int") -> None:
        self._by_int = key_by == "int"
        self._rows: dict[int | str, ParcelRecord] = {}

    def _key(self, barcode: str) -> tuple[int, int | str] | None:
        sscc = pack_sscc(barcode)
        if sscc is None:
            return None
        return sscc, (sscc if self._by_int else barcode)

    def track(self, scan: Scan) -> Tracked:
        keyed = self._key(scan.barcode)
        if keyed is None:
            return Tracked.REJECTED
        sscc, key = keyed
        record = self._rows.get(key)
        if record is None:
            self._rows[key] = make_record(scan, sscc)
            return Tracked.INSERTED
        record.due_tick = scan.tick + DIVERT_TICKS
        record.scan_tick = scan.tick
        record.confidence_permille = scan.confidence_permille
        return Tracked.UPDATED

    def erase(self, barcode: str) -> bool:
        keyed = self._key(barcode)
        return keyed is not None and self._rows.pop(keyed[1], None) is not None

    def find_state(self, barcode: str) -> int:
        keyed = self._key(barcode)
        record = None if keyed is None else self._rows.get(keyed[1])
        return EMPTY if record is None else record.state

    def sweep_due(self, tick: int) -> int:
        """In-flight parcels due at ``tick`` or earlier (read-only)."""
        return sum(1 for r in self._rows.values() if r.state == IN_FLIGHT and r.due_tick <= tick)

    def expire(self, tick: int) -> int:
        """Erase the parcels due at ``tick`` or earlier; returns how many."""
        due = [k for k, r in self._rows.items() if r.state == IN_FLIGHT and r.due_tick <= tick]
        for key in due:
            del self._rows[key]
        return len(due)

    def __len__(self) -> int:
        return len(self._rows)
