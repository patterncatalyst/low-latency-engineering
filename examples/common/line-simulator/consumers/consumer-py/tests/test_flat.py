"""The flat parcel-v1 reader decodes the bytes the C++ header wrote (contracts/flat/parcel-v1)."""

import json
from pathlib import Path

import pytest
from lowlat_consumer import flat

GOLDEN = Path(__file__).resolve().parents[6] / "contracts" / "flat" / "parcel-v1"
SEEDS = (1, 42, 2026)


def test_struct_is_the_documented_layout():
    assert flat.RECORD.size == flat.SIZE == 80
    assert flat.RECORD.format == "<HHIQqqQIIII18s6x"


@pytest.mark.parametrize("seed", SEEDS)
def test_golden_bytes_decode_to_their_json(seed):
    data = (GOLDEN / f"golden-seed{seed}.bin").read_bytes()
    doc = json.loads((GOLDEN / f"golden-seed{seed}.json").read_text(encoding="utf-8"))
    assert len(data) == doc["count"] * doc["record_size"]
    view = memoryview(data)
    for i, expect in enumerate(doc["records"]):
        p = flat.decode(view[i * flat.SIZE : (i + 1) * flat.SIZE])
        assert p.schema_id == expect["schema_id"]
        assert p.version == expect["version"]
        assert p.weight_g == expect["weight_g"]
        assert p.seq == int(expect["seq"])
        assert p.intended_emit_ns == int(expect["intended_emit_ns"])
        assert p.actual_emit_ns == int(expect["actual_emit_ns"])
        assert p.encoder_tick == int(expect["encoder_tick"])
        assert p.length_mm == expect["length_mm"]
        assert p.width_mm == expect["width_mm"]
        assert p.height_mm == expect["height_mm"]
        assert p.scan_confidence_permille == expect["scan_confidence_permille"]
        assert p.barcode == expect["barcode"]
        # encoding the decoded record gives the golden bytes back
        assert flat.encode(p) == data[i * flat.SIZE : (i + 1) * flat.SIZE]


def test_decode_rejects_wrong_size_schema_and_version():
    good = flat.encode(
        flat.ParcelV1(1, 2, 3, 4, 5, 6, 7, 8, 9, "006141410000000008"),
    )
    assert flat.decode(good).seq == 2
    with pytest.raises(flat.FlatError, match="80 bytes"):
        flat.decode(good[:79])
    with pytest.raises(flat.FlatError, match="schema_id"):
        flat.decode(b"\x02\x00" + good[2:])
    with pytest.raises(flat.FlatError, match="version"):
        flat.decode(good[:2] + b"\x02\x00" + good[4:])


def test_header_bytes_are_little_endian():
    raw = flat.encode(flat.ParcelV1(0x04030201, 0, 0, 0, 0, 0, 0, 0, 0, "0" * 18))
    assert raw[:4] == b"\x01\x00\x01\x00"
    assert raw[4:8] == b"\x01\x02\x03\x04"
    assert raw[74:] == b"\x00" * 6
