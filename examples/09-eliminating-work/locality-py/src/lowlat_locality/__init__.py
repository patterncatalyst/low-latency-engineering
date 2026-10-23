"""Ch9: eliminating work, Python lane. Wiring only (S4); the lane lands in S5."""

import sys


class Slotted:
    """A parcel record with fixed attribute storage: no per-instance dict."""

    __slots__ = ("barcode", "weight_g")

    def __init__(self, barcode: int, weight_g: int) -> None:
        self.barcode = barcode
        self.weight_g = weight_g


def instance_bytes(obj: object) -> int:
    """Shallow size of an object including its per-instance dict, if it has one."""
    extra = sys.getsizeof(obj.__dict__) if hasattr(obj, "__dict__") else 0
    return sys.getsizeof(obj) + extra
