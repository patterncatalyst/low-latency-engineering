"""Shared fixtures: the golden report is written once per session."""

from pathlib import Path

import pytest
from lowlat_measure import Recorder

FIXTURES = Path(__file__).resolve().parents[2] / "measure-fixtures"


@pytest.fixture(scope="session")
def golden_report(request: pytest.FixtureRequest, tmp_path_factory: pytest.TempPathFactory) -> Path:
    """Write python-golden.json (dataset i*1000, i=1..10000) and return its path.

    The file goes to a temporary directory. ``pytest --regen-golden`` writes the committed
    ``measure-fixtures/python-golden.json`` instead, which the C++ and Java tests read.
    """
    if request.config.getoption("--regen-golden"):
        out = FIXTURES / "python-golden.json"
    else:
        out = tmp_path_factory.mktemp("golden") / "python-golden.json"
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("LOWLAT_PROFILE", str(FIXTURES / "profile.json"))
        rec = Recorder("measure-fixtures", "golden")
        for i in range(1, 10_001):
            rec.record(i * 1000)
        rec.write_report(out)
    return out
