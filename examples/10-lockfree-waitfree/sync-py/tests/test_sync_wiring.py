"""Wiring: imports, an exactly-once lock claim, and the interpreter build that was asked for."""

import os
import sys

import pytest
from lowlat_sync import claim_all, python_build


def test_lock_claim_is_exactly_once() -> None:
    claimed = claim_all(threads=4, per_thread=2_000)
    assert sorted(claimed) == list(range(8_000))


def test_python_build_matches_the_interpreter() -> None:
    assert python_build() == ("gil" if sys._is_gil_enabled() else "free-threaded")


@pytest.mark.skipif(
    os.environ.get("LOWLAT_EXPECT_FREE_THREADED") != "1",
    reason="set LOWLAT_EXPECT_FREE_THREADED=1 when running under python3.14t",
)
def test_free_threaded_build_was_requested() -> None:
    assert sys._is_gil_enabled() is False
    assert python_build() == "free-threaded"
