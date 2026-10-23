"""Decode the golden files of ``contracts/flat/parcel-v1`` and print them as JSON.

The output has the shape of ``golden-seedN.json`` (``records`` only): 16 and 32-bit fields are
numbers, 64-bit fields decimal strings. ``verify.sh`` compares it with the C++ and Java tools and
with the committed JSON.
"""

import json
from pathlib import Path
from typing import Any

from lowlat_consumer import flat


def describe(parcel: flat.ParcelV1) -> dict[str, Any]:
    """One record in the golden JSON's field order and number formats."""
    return {
        "schema_id": parcel.schema_id,
        "version": parcel.version,
        "weight_g": parcel.weight_g,
        "seq": str(parcel.seq),
        "intended_emit_ns": str(parcel.intended_emit_ns),
        "actual_emit_ns": str(parcel.actual_emit_ns),
        "encoder_tick": str(parcel.encoder_tick),
        "length_mm": parcel.length_mm,
        "width_mm": parcel.width_mm,
        "height_mm": parcel.height_mm,
        "scan_confidence_permille": parcel.scan_confidence_permille,
        "barcode": parcel.barcode,
    }


def dump(path: Path) -> str:
    """The records of a file of back-to-back parcel-v1 records, as JSON text.

    Raises ``flat.FlatError`` for a bad record and ``ValueError`` when the file is not a whole
    number of records.
    """
    data = memoryview(path.read_bytes())
    if len(data) % flat.SIZE:
        raise ValueError(f"{len(data)} bytes is not a whole number of {flat.SIZE}-byte records")
    records = [
        describe(flat.decode_datagram(data[at : at + flat.SIZE]))
        for at in range(0, len(data), flat.SIZE)
    ]
    return json.dumps({"records": records}, indent=2)
