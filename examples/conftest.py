"""Shared pytest fixtures for every Python package under examples/ (this is the rootdir)."""

from pathlib import Path

import pytest

MEASURE_FIXTURES = Path(__file__).resolve().parent / "common" / "measure-fixtures"


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--regen-golden",
        action="store_true",
        default=False,
        help="rewrite the committed common/measure-fixtures/python-golden.json "
        "(tests otherwise write it to a temporary directory)",
    )


@pytest.fixture
def lowlat_profile(monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point LOWLAT_PROFILE at the shared machine-profile fixture; return its path."""
    path = MEASURE_FIXTURES / "profile.json"
    monkeypatch.setenv("LOWLAT_PROFILE", str(path))
    return path
