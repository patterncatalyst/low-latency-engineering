"""Shared pytest fixtures for every Python package under examples/ (this is the rootdir)."""

import importlib.util
import re
from collections.abc import Callable
from pathlib import Path

import pytest

MEASURE_FIXTURES = Path(__file__).resolve().parent / "common" / "measure-fixtures"


def pytest_configure(config: pytest.Config) -> None:
    """Name the fix, not an ImportError per module, when the protobuf modules are absent."""
    try:
        generated = importlib.util.find_spec("lowlat.line.v1.parcel_pb2") is not None
    except ModuleNotFoundError:
        generated = False
    if not generated:
        raise pytest.UsageError(
            "the generated protobuf modules (lowlat.line.v1.parcel_pb2) are missing: run "
            "scripts/gen-python-proto.sh from the repository root, then uv sync --all-packages, "
            "before pytest"
        )


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


@pytest.fixture
def bound_port() -> Callable[[str], int]:
    """Parse the port from a consumer's ``... bound HOST:PORT, ...`` banner.

    Tests bind port 0 so they never clash across runs or workers; the consumer prints the
    port the kernel chose, and the simulator is then pointed at it.
    """

    def parse(banner: str) -> int:
        match = re.search(r"bound \S+:(\d+),", banner)
        assert match, f"no bound port in consumer banner: {banner!r}"
        return int(match.group(1))

    return parse
