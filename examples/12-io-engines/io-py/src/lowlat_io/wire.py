"""The flat `parcel-v1` record (contracts/flat/parcel-v1): 80 bytes, little-endian.

The receive lane needs three fields, read at fixed offsets without building an object per record.
"""

import struct

SIZE = 80
LANES = 8
_SCHEMA_ID = 1
_VERSION = 1
_HEADER = struct.Struct("<HH")
_SEQ_INTENDED = struct.Struct("<Qq")  # seq at offset 8, intended_emit_ns at offset 16
_BARCODE = slice(56, 74)
_SERIAL = slice(64, 73)  # barcode digits 8..16: the 9-digit serial; digit 17 is the check digit
_RECORD = struct.Struct("<HHIQqqQIIII18s6x")


def valid(data: bytes) -> bool:
    """True for an 80-byte version-1 record."""
    return len(data) == SIZE and _HEADER.unpack_from(data) == (_SCHEMA_ID, _VERSION)


def seq_and_intended(data: bytes) -> tuple[int, int]:
    """(seq, intended_emit_ns) of a valid record."""
    return _SEQ_INTENDED.unpack_from(data, 8)


def lane(data: bytes) -> int:
    """The lane for the record's SSCC-18: its 9-digit serial modulo 8.

    Raises ValueError when the barcode is not 18 ASCII digits.
    """
    if not data[_BARCODE].isdigit():
        raise ValueError("SSCC-18 must be digits only")
    return int(data[_SERIAL]) % LANES


def encode(seq: int, intended_emit_ns: int, barcode: str = "003400001234567890") -> bytes:
    """A record for tests and the warm-up feeder."""
    return _RECORD.pack(
        _SCHEMA_ID,
        _VERSION,
        0,
        seq,
        intended_emit_ns,
        intended_emit_ns,
        0,
        0,
        0,
        0,
        1000,
        barcode.encode("ascii"),
    )
