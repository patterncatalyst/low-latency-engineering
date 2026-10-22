"""Reader for the flat ``parcel-v1`` record (``contracts/flat/parcel-v1``).

The layout is the one in ``parcel_v1.hpp``: 80 bytes, little-endian, ``schema_id`` and
``version`` first, then the ``ParcelEvent`` fields at fixed offsets. ``struct.Struct`` over a
``memoryview`` decodes it without an intermediate copy of the datagram; the only allocation
is the tuple ``unpack_from`` returns (and the ``ParcelV1`` built from it).

Divergence from the other languages, and the point of the Python lane: there is no flyweight
view here. A CPython object per field is the representation, so "zero-copy" means "no copy of
the bytes", not "no allocation".
"""

import struct
from dataclasses import dataclass
from typing import Final

SCHEMA_ID: Final = 1  # lowlat.line.v1.ParcelEvent
VERSION: Final = 1
SIZE: Final = 80

# < = little-endian with no implicit padding (the record has none: every byte is named).
#  H schema_id | H version | I weight_g | Q seq | q intended_emit_ns | q actual_emit_ns
#  Q encoder_tick | I length_mm | I width_mm | I height_mm | I scan_confidence_permille
#  18s barcode | 6x reserved
RECORD: Final = struct.Struct("<HHIQqqQIIII18s6x")

assert RECORD.size == SIZE


class FlatError(ValueError):
    """The bytes are not a parcel-v1 record."""


@dataclass(frozen=True, slots=True)
class ParcelV1:
    weight_g: int
    seq: int
    intended_emit_ns: int
    actual_emit_ns: int
    encoder_tick: int
    length_mm: int
    width_mm: int
    height_mm: int
    scan_confidence_permille: int
    barcode: str
    schema_id: int = SCHEMA_ID
    version: int = VERSION


def decode(data: bytes | bytearray | memoryview, offset: int = 0) -> ParcelV1:
    """Decode one record at ``offset``; raises ``FlatError`` on a wrong size, schema or version."""
    if len(data) - offset != SIZE:
        raise FlatError(f"parcel-v1 is {SIZE} bytes, got {len(data) - offset}")
    (
        schema_id,
        version,
        weight_g,
        seq,
        intended,
        actual,
        tick,
        length,
        width,
        height,
        conf,
        barcode,
    ) = RECORD.unpack_from(data, offset)
    if schema_id != SCHEMA_ID:
        raise FlatError(f"not parcel-v1: schema_id {schema_id}")
    if version != VERSION:
        raise FlatError(f"unsupported parcel-v1 version {version}")
    return ParcelV1(
        weight_g=weight_g,
        seq=seq,
        intended_emit_ns=intended,
        actual_emit_ns=actual,
        encoder_tick=tick,
        length_mm=length,
        width_mm=width,
        height_mm=height,
        scan_confidence_permille=conf,
        barcode=barcode.decode("ascii"),
        schema_id=schema_id,
        version=version,
    )


def encode(p: ParcelV1) -> bytes:
    """The record as wire bytes; the header constants are always written and reserved is zero."""
    return RECORD.pack(
        SCHEMA_ID,
        VERSION,
        p.weight_g,
        p.seq,
        p.intended_emit_ns,
        p.actual_emit_ns,
        p.encoder_tick,
        p.length_mm,
        p.width_mm,
        p.height_mm,
        p.scan_confidence_permille,
        p.barcode.encode("ascii"),
    )
