"""The r01 "handle" step: decode the barcode, look up a lane.

Later chapters replace this with real work; the work is part of the measured latency.
"""

LANES = 8

# SSCC-18 layout (GS1): extension digit (1), company prefix (7), serial reference (9),
# check digit (1). See include/lowlat/line/sscc.hpp in the simulator.
_SERIAL = slice(8, 17)


def lane_for(barcode: str) -> int:
    """Lane 0..7 from the SSCC serial reference modulo 8."""
    if len(barcode) != 18 or not (barcode.isascii() and barcode.isdigit()):
        raise ValueError(f"not an SSCC-18: {barcode!r}")
    return int(barcode[_SERIAL]) % LANES
