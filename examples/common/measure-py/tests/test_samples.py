"""``lowlat-report from-samples``: raw int64 samples from a process that never imports the kit."""

import json
import random
from array import array
from pathlib import Path

import pytest
from lowlat_measure import Recorder
from lowlat_measure.cli import main
from lowlat_measure.samples import read_samples

SIDE = {
    "example": "11-stackful-stackless",
    "variant": "threads-ft",
    "count": 5000,
    "dropped": 3,
    "notes": "free-threaded process, raw samples",
    "build": {"compiler": "CPython 3.14.8 free-threading build", "gil_enabled": False},
    "runtime": {"python_build": "free-threaded"},
}


def _samples(n: int = 5000) -> list[int]:
    rng = random.Random(7)
    return [int(rng.lognormvariate(11, 1.2)) + 1 for _ in range(n)] + [900_000_000]


def _write(tmp_path: Path, samples: list[int], side: dict) -> tuple[Path, Path]:
    raw, sidecar = tmp_path / "s.i64", tmp_path / "s.json"
    with raw.open("wb") as f:
        array("q", samples).tofile(f)
    sidecar.write_text(json.dumps(side), encoding="utf-8")
    return raw, sidecar


def test_from_samples_is_identical_to_the_recorder(lowlat_profile: Path, tmp_path: Path) -> None:
    samples = _samples()
    side = {**SIDE, "count": len(samples)}
    raw, sidecar = _write(tmp_path, samples, side)
    out = tmp_path / "converted.json"
    assert main(["from-samples", str(raw), str(sidecar), str(out)]) == 0

    rec = Recorder(side["example"], side["variant"])
    for ns in samples:
        rec.record(ns)
    rec.add_dropped(side["dropped"])
    direct = rec.build_report(side["notes"], build=side["build"], runtime=side["runtime"])

    converted = json.loads(out.read_text(encoding="utf-8"))
    assert converted["percentiles"] == direct["percentiles"]
    assert converted["hdr_histogram"] == direct["hdr_histogram"]
    assert converted == direct
    assert converted["build"]["gil_enabled"] is False
    assert converted["runtime"]["python_build"] == "free-threaded"
    assert main(["check", str(out)]) == 0


def _without(key: str, **extra: object) -> dict:
    return {k: v for k, v in SIDE.items() if k != key} | extra


def _bad_build(**build: object) -> dict:
    return {**SIDE, "count": 1, "build": {**SIDE["build"], **build}}


@pytest.mark.parametrize(
    ("samples", "side", "needle"),
    [
        ([1000, 2000], {**SIDE, "count": 3}, "count 3"),
        ([1000, -5], {**SIDE, "count": 2}, "negative"),
        ([1000, 3_600_000_000_001], {**SIDE, "count": 2}, "highest trackable"),
        ([1000], _without("variant", count=1), "variant"),
        ([1000], {**SIDE, "count": 1, "mean_ns": 4}, "unknown keys"),
        # the sidecar must carry what the measured process wrote; the converter never fills it in
        ([1000], _without("build", count=1), "missing build"),
        ([1000], _bad_build(gil_enabled="false"), "gil_enabled must be a boolean"),
        ([1000], _bad_build(gil_enabled=0), "gil_enabled must be a boolean"),
        ([1000], _bad_build(compiler=""), "build.compiler"),
        ([1000], {**SIDE, "count": 1, "build": {"gil_enabled": False}}, "build.compiler"),
        # the schema names every field it rejects, not just the first
        (
            [1000],
            {**SIDE, "count": 1, "example": 7, "notes": 5, "build": {"compiler": "x"}},
            "build.gil_enabled is required",
        ),
        ([1000], {**SIDE, "count": 1, "example": 7}, "sidecar example must be a non-empty string"),
        ([1000], {**SIDE, "count": 1, "gil_enabled": True}, "conflicts"),
        ([1000], {**SIDE, "count": 1, "gil_enabled": "false"}, "gil_enabled must be a boolean"),
        # the GIL came back: free-threaded claimed, gil_enabled true
        ([1000], _bad_build(gil_enabled=True), "GIL came back"),
        (
            [1000],
            {**SIDE, "count": 1, "runtime": {"python_build": "gil"}},
            "python_build is 'gil'",
        ),
        ([1000], {**SIDE, "count": 1, "runtime": [1]}, "runtime must be a JSON object"),
        ([1000], {**SIDE, "count": 1, "runtime": "x"}, "runtime must be a JSON object"),
        ([1000], {**SIDE, "count": True}, "count must be"),
        ([1000], {**SIDE, "count": 1.0}, "count must be"),
        ([1000], {**SIDE, "count": 1, "dropped": True}, "dropped must be"),
        ([1000], {**SIDE, "count": 1, "dropped": -1}, "dropped must be"),
        ([1000], {**SIDE, "count": 1, "dropped": 1.5}, "dropped must be"),
        ([1000], {**SIDE, "count": 1, "notes": 5}, "notes must be"),
        ([1000], {**SIDE, "count": 1, "model": []}, "model must be"),
        ([1000], {**SIDE, "count": 1, "variant": ""}, "variant must be"),
        # the schema is the last gate and nothing is written when it fails
        ([1000], {**SIDE, "count": 1, "language": "cobol"}, "schema"),
        (
            [1000],
            {
                **SIDE,
                "count": 1,
                "runtime": {"python_build": "free-threaded", "environment": {"kind": "vm"}},
            },
            "schema",
        ),
        ([], {**SIDE, "count": 0}, "at least 1"),
        ([1000], {**SIDE, "count": 1, "runtime": {}}, "python_build"),
        ([1000], {**SIDE, "count": 1, "runtime": {"python_build": "nogil"}}, "python_build"),
        (
            [1000],
            _bad_build(compiler="CPython 3.14.8 (GIL build)"),
            "not a free-threading build",
        ),
    ],
)
def test_from_samples_rejects_bad_input(
    lowlat_profile: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    samples: list[int],
    side: dict,
    needle: str,
) -> None:
    raw, sidecar = _write(tmp_path, samples, side)
    out = tmp_path / "o.json"
    assert main(["from-samples", str(raw), str(sidecar), str(out)]) == 1
    err = capsys.readouterr().err
    assert needle in err
    assert "Traceback" not in err
    assert not out.exists()


def test_from_samples_accepts_a_matching_top_level_gil_flag(
    lowlat_profile: Path, tmp_path: Path
) -> None:
    raw, sidecar = _write(tmp_path, [1000], {**SIDE, "count": 1, "gil_enabled": False})
    assert main(["from-samples", str(raw), str(sidecar), str(tmp_path / "o.json")]) == 0


def test_from_samples_accepts_the_gil_build_with_the_gil_on(
    lowlat_profile: Path, tmp_path: Path
) -> None:
    side = {**SIDE, "count": 1, "build": {"compiler": "CPython", "gil_enabled": True}}
    side["runtime"] = {"python_build": "gil"}
    raw, sidecar = _write(tmp_path, [1000], side)
    assert main(["from-samples", str(raw), str(sidecar), str(tmp_path / "o.json")]) == 0


def test_read_samples_is_typed_as_an_int_array(tmp_path: Path) -> None:
    raw, _ = _write(tmp_path, [1, 2, 3], {**SIDE, "count": 3})
    assert read_samples(raw).tolist() == [1, 2, 3]


def test_from_samples_rejects_a_torn_file(
    lowlat_profile: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    raw, sidecar = _write(tmp_path, [1000], {**SIDE, "count": 1})
    raw.write_bytes(raw.read_bytes() + b"\x01\x02")
    assert main(["from-samples", str(raw), str(sidecar), str(tmp_path / "o.json")]) == 1
    assert "whole number" in capsys.readouterr().err


def test_from_samples_needs_a_profile(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.delenv("LOWLAT_PROFILE", raising=False)
    raw, sidecar = _write(tmp_path, [1000], {**SIDE, "count": 1})
    assert main(["from-samples", str(raw), str(sidecar), str(tmp_path / "o.json")]) == 2
    assert "LOWLAT_PROFILE" in capsys.readouterr().err
