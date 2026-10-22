"""Parity with the C++ and Java check digit on GS1 known-good values."""

import pytest
from lowlat_bench.check_digit import check_digit, prefixes


def test_known_good_check_digits():
    # GS1 General Specifications example (00) 1 0614141 123456789 7.
    assert check_digit("10614141123456789") == 7
    assert check_digit("00614141000000007") == 4
    assert check_digit("00000000000000000") == 0


def test_prefix_set_matches_cpp_and_java():
    p = prefixes(1024)
    assert p[0] == "00614141000000013"
    assert p[1] == "10614141000007932"
    assert all(len(x) == 17 for x in p)


@pytest.mark.parametrize("bad", ["123", "1061414112345678x", "１0614141123456789"])
def test_rejects_bad_body(bad):
    with pytest.raises(ValueError):
        check_digit(bad)
