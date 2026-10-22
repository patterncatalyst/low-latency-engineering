import pytest
from lowlat_consumer import GapTracker, lane_for


def test_gap_counts_missing():
    t = GapTracker()
    assert all(t.observe(s) for s in (0, 1, 2, 5, 6))
    assert (t.dropped, t.reordered, t.received, t.accounted) == (2, 0, 5, 7)


def test_repeat_is_reordered_not_recorded():
    t = GapTracker()
    for s in (0, 1, 2):
        t.observe(s)
    assert t.observe(2) is False
    assert t.observe(1) is False
    assert (t.dropped, t.reordered, t.received) == (0, 2, 3)


def test_first_seq_nonzero_counts_leading_drops():
    t = GapTracker()
    t.observe(3)
    assert t.dropped == 3


def sscc(serial: int) -> str:
    """Extension 0, prefix 0614141, 9-digit serial, check digit placeholder (not validated)."""
    return f"00614141{serial:09d}0"


@pytest.mark.parametrize(("serial", "lane"), [(0, 0), (7, 7), (8, 0), (13, 5), (999_999_999, 7)])
def test_lane_lookup(serial, lane):
    assert lane_for(sscc(serial)) == lane


def test_lane_rejects_non_sscc():
    with pytest.raises(ValueError):
        lane_for("12345")


@pytest.mark.parametrize(
    "barcode",
    [
        "00614141000000013x",
        "00614141000000013",
        "0061414100000001300",
        "٠٠٦١٤١٤١٠٠٠٠٠٠٠١٣٠",
        "x06141410000000130",
    ],
    ids=["trailing-letter", "17-chars", "19-chars", "non-ascii-digits", "leading-letter"],
)
def test_lane_rejects_malformed_barcodes(barcode):
    with pytest.raises(ValueError):
        lane_for(barcode)


@pytest.mark.parametrize(
    ("barcode", "lane"),  # the same barcodes the C++ Lane.SerialModuloEight test uses
    [
        ("006141410000000134", 5),
        ("006141410000000008", 0),
        ("006141419999999997", 7),
        ("906141410000000070", 7),
    ],
)
def test_lane_matches_cpp_fixtures(barcode, lane):
    assert lane_for(barcode) == lane
