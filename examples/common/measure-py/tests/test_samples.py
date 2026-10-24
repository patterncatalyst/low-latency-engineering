"""``lowlat-report from-samples``: raw int64 samples from a process that never imports the kit."""

import json
import random
import sys
from array import array
from pathlib import Path

import pytest
from lowlat_measure import Recorder
from lowlat_measure.cli import main

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


def test_from_samples_defaults_the_build_to_this_interpreter(
    lowlat_profile: Path, tmp_path: Path
) -> None:
    side = {k: v for k, v in SIDE.items() if k != "build"} | {"count": 3, "gil_enabled": False}
    raw, sidecar = _write(tmp_path, [1000, 2000, 3000], side)
    out = tmp_path / "o.json"
    assert main(["from-samples", str(raw), str(sidecar), str(out)]) == 0
    build = json.loads(out.read_text(encoding="utf-8"))["build"]
    assert build == {"compiler": sys.version, "gil_enabled": False}


@pytest.mark.parametrize(
    ("samples", "side", "needle"),
    [
        ([1000, 2000], {**SIDE, "count": 3}, "count 3"),
        ([1000, -5], {**SIDE, "count": 2}, "negative"),
        ([1000], {k: v for k, v in SIDE.items() if k != "variant"} | {"count": 1}, "variant"),
        ([1000], {**SIDE, "count": 1, "mean_ns": 4}, "unknown keys"),
        (
            [1000],
            {**SIDE, "count": 1, "gil_enabled": False, "runtime": {"python_build": "gil"}},
            "python_build",
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
    assert needle in capsys.readouterr().err
    assert not out.exists()


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
