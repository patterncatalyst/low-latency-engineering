"""Wiring: the package imports and a slotted record is smaller than a dict-backed one."""

from lowlat_locality import Slotted, instance_bytes


class Dicted:
    def __init__(self, barcode: int, weight_g: int) -> None:
        self.barcode = barcode
        self.weight_g = weight_g


def test_slots_beat_a_dict_per_instance() -> None:
    assert instance_bytes(Slotted(1, 2)) < instance_bytes(Dicted(1, 2))
