"""Bytes per tracked parcel by record shape, counted with ``tracemalloc`` (exact per CPython build).

Three shapes hold the same parcels:

* ``dict-per-parcel``: a ``dict[str, ...]`` record per parcel, keyed by the barcode ``str``
  (the first-draft shape);
* ``slots-str``: a ``@dataclass(slots=True)`` record keyed by the barcode ``str``;
* ``slots-int``: the same record keyed by the packed SSCC ``int``.

``tracemalloc`` reports the bytes still allocated after the table is built, so it counts the
key, the record and its attribute values, and the dict entry: what a tracked parcel keeps alive.
"""

import gc
import sys
import tracemalloc
from collections.abc import Callable
from typing import Any

from lowlat_locality.records import (
    format_sscc,
    keys,
    make_dict_record,
    make_record,
    pack_sscc,
    scan_of,
)

SHAPES = ("dict-per-parcel", "slots-str", "slots-int")


def _retained_bytes(build: Callable[[], Any]) -> int:
    """Bytes still allocated after ``build()`` returns its result (kept alive until measured)."""
    gc.collect()
    tracemalloc.start()
    try:
        before = tracemalloc.get_traced_memory()[0]
        result = build()
        after = tracemalloc.get_traced_memory()[0]
        del result
    finally:
        tracemalloc.stop()
    return after - before


def measure(parcels: int) -> dict[str, Any]:
    """Bytes retained by ``parcels`` tracked parcels in each shape, and by the records alone."""
    sscc_keys = keys(parcels)

    def table(shape: str) -> dict[Any, Any]:
        out: dict[Any, Any] = {}
        for i, sscc in enumerate(sscc_keys):
            scan = scan_of(sscc, i)
            if shape == "dict-per-parcel":
                out[scan.barcode] = make_dict_record(scan, pack_sscc(scan.barcode) or 0)
            elif shape == "slots-str":
                out[scan.barcode] = make_record(scan, pack_sscc(scan.barcode) or 0)
            else:
                out[sscc] = make_record(scan, sscc)
        return out

    def records(shape: str) -> list[Any]:
        make = make_dict_record if shape == "dict-per-parcel" else make_record
        return [make(scan_of(sscc, i), sscc) for i, sscc in enumerate(sscc_keys)]

    tracked = {shape: _retained_bytes(lambda shape=shape: table(shape)) for shape in SHAPES}
    record_only = {
        shape: _retained_bytes(lambda shape=shape: records(shape))
        for shape in ("dict-per-parcel", "slots-int")
    }
    return {
        "python": sys.version.split()[0],
        "gil_enabled": sys._is_gil_enabled(),
        "parcels": parcels,
        "tracked_bytes": tracked,
        "record_only_bytes": record_only,
        "tracked_bytes_per_parcel": {k: v / parcels for k, v in tracked.items()},
        "example_barcode": format_sscc(sscc_keys[0]),
    }
