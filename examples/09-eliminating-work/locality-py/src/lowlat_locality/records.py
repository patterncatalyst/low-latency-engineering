"""The parcel record and SSCC packing."""

from dataclasses import dataclass

SSCC_DIGITS = 18
EMPTY, IN_FLIGHT, DIVERTED = 0, 1, 2
DIVERT_TICKS = 1200  # 1.2 m at 1000 pulses per metre


def pack_sscc(digits: str) -> int | None:
    """The 18 digits as an int, or None unless the text is exactly 18 ASCII digits.

    ``int()`` accepts signs, spaces, underscores and non-ASCII digits, so the shape is checked
    first.
    """
    if len(digits) != SSCC_DIGITS or not (digits.isascii() and digits.isdecimal()):
        return None
    return int(digits)


def format_sscc(value: int) -> str:
    """The inverse of :func:`pack_sscc`: 18 zero-padded digits."""
    return f"{value:0{SSCC_DIGITS}d}"


@dataclass(slots=True, frozen=True)
class Scan:
    """One scan of one parcel, as the tracker receives it."""

    barcode: str
    seq: int = 0
    tick: int = 0
    weight_g: int = 0
    length_mm: int = 0
    width_mm: int = 0
    height_mm: int = 0
    confidence_permille: int = 0


@dataclass(slots=True)
class ParcelRecord:
    """Everything the tracker knows about a parcel.

    ``slots=True`` removes the per-instance ``__dict__``: the fields live in fixed slots after
    the object header. This is the idiomatic way to make a Python record small; it is the lever,
    because every attribute value is still an object of its own.
    """

    sscc: int
    due_tick: int
    scan_tick: int
    seq: int
    divert_tick: int
    weight_g: int
    length_mm: int
    width_mm: int
    height_mm: int
    confidence_permille: int
    state: int
    lane: int
    destination: str


def make_record(scan: Scan, sscc: int) -> ParcelRecord:
    return ParcelRecord(
        sscc=sscc,
        due_tick=scan.tick + DIVERT_TICKS,
        scan_tick=scan.tick,
        seq=scan.seq,
        divert_tick=0,
        weight_g=scan.weight_g,
        length_mm=scan.length_mm,
        width_mm=scan.width_mm,
        height_mm=scan.height_mm,
        confidence_permille=scan.confidence_permille,
        state=IN_FLIGHT,
        lane=sscc % 8,
        destination="",
    )


def make_dict_record(scan: Scan, sscc: int) -> dict[str, int | str]:
    """The same parcel as a plain dict: the first-draft shape that ``dict-per-parcel`` measures."""
    return {
        "sscc": sscc,
        "due_tick": scan.tick + DIVERT_TICKS,
        "scan_tick": scan.tick,
        "seq": scan.seq,
        "divert_tick": 0,
        "weight_g": scan.weight_g,
        "length_mm": scan.length_mm,
        "width_mm": scan.width_mm,
        "height_mm": scan.height_mm,
        "confidence_permille": scan.confidence_permille,
        "state": IN_FLIGHT,
        "lane": sscc % 8,
        "destination": "",
    }


def keys(n: int, seed: int = 2026) -> list[int]:
    """``n`` distinct SSCC-18 keys (i * odd multiplier mod 10^18), as in the C++ and Java lanes."""
    stride = 1_442_695_040_888_963_407
    return [((i + seed * 0x9E3779B1) * stride) % 10**18 for i in range(n)]


def scan_of(key: int, i: int) -> Scan:
    """Scan number ``i`` for ``key``: encoder tick i, so due ticks spread over the table."""
    return Scan(
        barcode=format_sscc(key),
        seq=i,
        tick=i,
        weight_g=500 + i % 20_000,
        length_mm=150 + i % 1000,
        width_mm=100 + i % 600,
        height_mm=50 + i % 450,
        confidence_permille=950 + i % 51,
    )
