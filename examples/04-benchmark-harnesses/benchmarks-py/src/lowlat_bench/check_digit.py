"""SSCC-18 GS1 mod-10 check digit: the same algorithm as the C++ and Java examples.

Weights 3,1,3,1,... from the rightmost of the 17 digits; the check digit brings the
weighted sum up to a multiple of ten.
"""

from itertools import cycle

BODY_DIGITS = 17
PREFIX_COUNT = 1024  # size of the prefix set the benchmarks share


def check_digit(digits17: str) -> int:
    """Check digit of a 17-digit SSCC body; ValueError unless exactly 17 ASCII digits."""
    if len(digits17) != BODY_DIGITS or not (digits17.isascii() and digits17.isdigit()):
        raise ValueError(f"SSCC body must be 17 digits, got {digits17!r}")
    total = sum(int(c) * w for c, w in zip(reversed(digits17), cycle((3, 1)), strict=False))
    return (10 - total % 10) % 10


def prefixes(n: int) -> list[str]:
    """The fixed prefix set shared by all three languages.

    Prefix i = extension (i % 10), company prefix 0614141, serial (i * 7919 + 13) % 10^9
    zero-padded to nine digits.
    """
    return [f"{i % 10}0614141{(i * 7919 + 13) % 1_000_000_000:09d}" for i in range(n)]
