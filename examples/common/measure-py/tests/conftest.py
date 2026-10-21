"""Shared fixtures: the golden report is written once per session."""

from __future__ import annotations

from pathlib import Path

import pytest
from lowlat_measure import Recorder

FIXTURES = Path(__file__).resolve().parents[2] / "measure-fixtures"


@pytest.fixture(scope="session")
def golden_report() -> Path:
    """Write python-golden.json (dataset i*1000, i=1..10000) and return its path."""
    mp = pytest.MonkeyPatch()
    mp.setenv("LOWLAT_PROFILE", str(FIXTURES / "profile.json"))
    try:
        rec = Recorder("measure-fixtures", "golden")
        for i in range(1, 10_001):
            rec.record(i * 1000)
        out = FIXTURES / "python-golden.json"
        rec.write_report(out)
    finally:
        mp.undo()
    return out
