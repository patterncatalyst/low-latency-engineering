"""The Python lane under both interpreter builds.

Run under the GIL (default workspace environment) and under the free-threaded build, see the comment
at the top of pyproject.toml. Exactly-once is asserted for the lock in both builds; the shared
itertools.count and the racy claim are only observed (the GIL build keeps them intact in practice,
and the free-threaded build loses claims), except that the free-threaded racy claim must lose some.
"""

import json
import os
import sys
from pathlib import Path

import pytest
from lowlat_sync import gil_enabled, lane, python_build
from lowlat_sync.claims import CountClaim, LockClaim, RacyClaim, claim_for

FREE_THREADED = python_build() == "free-threaded"


def test_python_build_is_one_of_the_two_builds() -> None:
    assert python_build() in {"gil", "free-threaded"}
    if python_build() == "gil":
        assert gil_enabled()


@pytest.mark.skipif(
    os.environ.get("LOWLAT_EXPECT_FREE_THREADED") != "1",
    reason="set LOWLAT_EXPECT_FREE_THREADED=1 when running under python3.14t",
)
def test_free_threaded_build_was_requested() -> None:
    assert sys._is_gil_enabled() is False
    assert gil_enabled() is False
    assert python_build() == "free-threaded"


def test_claim_for_names() -> None:
    assert isinstance(claim_for("lock"), LockClaim)
    assert isinstance(claim_for("lock", racy=True), RacyClaim)
    assert isinstance(claim_for("itertools-count"), CountClaim)
    with pytest.raises(ValueError):
        claim_for("itertools-count", racy=True)
    with pytest.raises(ValueError):
        claim_for("mutex")


def test_lock_claim_is_exactly_once() -> None:
    result = lane.run("lock", threads=4, claims_per_thread=20_000, announce=False)
    assert result.claimed == 80_000
    assert result.lost_or_duplicated == 0


def test_itertools_count_is_observed_not_asserted() -> None:
    result = lane.run("itertools-count", threads=4, claims_per_thread=20_000, announce=False)
    assert result.claimed == 80_000  # every thread made its claims
    assert 0 <= result.lost_or_duplicated < 80_000


def test_racy_claim_loses_claims_without_the_gil() -> None:
    if not FREE_THREADED:
        pytest.skip("under the GIL a lost claim is rare and only observed")
    result = lane.run("lock", racy=True, threads=4, claims_per_thread=50_000, announce=False)
    assert result.lost_or_duplicated >= 1


def test_raw_file_records_the_build_that_ran(tmp_path: Path) -> None:
    result = lane.run("lock", threads=2, claims_per_thread=1_000, announce=False)
    lane.write_raw(result, tmp_path)
    raw = json.loads((tmp_path / lane.RAW_NAME).read_text(encoding="utf-8"))
    assert raw["python_build"] == python_build()
    assert raw["claims"] == 2_000
    assert (tmp_path / lane.SAMPLES_NAME).stat().st_size == 2_000 * 8


@pytest.mark.skipif(
    FREE_THREADED,
    reason="lowlat_measure re-enables the GIL; reports are made in the GIL environment",
)
def test_report_is_made_from_the_raw_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    fixtures = Path(__file__).resolve().parents[3] / "common" / "measure-fixtures"
    monkeypatch.setenv("LOWLAT_PROFILE", str(fixtures / "profile.json"))
    from lowlat_sync.report import build_report

    lane.write_raw(
        lane.run("lock", threads=2, claims_per_thread=1_000, announce=False), tmp_path / "raw"
    )
    report = build_report(tmp_path / "raw", tmp_path / "report.json")
    assert report["count"] == 2_000
    assert report["runtime"]["python_build"] == "gil"
    assert report["runtime"]["counters"]["lost_or_duplicated_claims"] == 0
    assert report["variant"] == "lock"
    assert report["runtime"]["counters"]["racy_claim"] == 0


@pytest.mark.skipif(
    FREE_THREADED,
    reason="lowlat_measure re-enables the GIL; reports are made in the GIL environment",
)
def test_racy_report_keeps_the_variant_and_is_marked(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fixtures = Path(__file__).resolve().parents[3] / "common" / "measure-fixtures"
    monkeypatch.setenv("LOWLAT_PROFILE", str(fixtures / "profile.json"))
    from lowlat_sync.report import build_report

    lane.write_raw(
        lane.run("lock", racy=True, threads=2, claims_per_thread=1_000, announce=False),
        tmp_path / "raw",
    )
    report = build_report(tmp_path / "raw", tmp_path / "report.json")
    assert report["variant"] == "lock"  # a §2 variant name; the marker is the counter
    assert report["runtime"]["counters"]["racy_claim"] == 1
