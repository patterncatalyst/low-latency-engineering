"""The Python lane: golden bytes, the two decode paths and what each allocates."""

import json
from pathlib import Path

import pytest
from lowlat_flat import cli, decode, golden, harness_report
from lowlat_measure.cli import main as lowlat_report

CONTRACT = Path(__file__).resolve().parents[4] / "contracts" / "flat" / "parcel-v1"


@pytest.mark.parametrize("seed", [1, 42, 2026])
def test_dump_matches_the_committed_json(seed: int) -> None:
    expect = json.loads((CONTRACT / f"golden-seed{seed}.json").read_text(encoding="utf-8"))
    dumped = json.loads(golden.dump(CONTRACT / f"golden-seed{seed}.bin"))
    assert dumped["records"] == expect["records"]


def test_dump_rejects_a_partial_record(tmp_path: Path) -> None:
    short = tmp_path / "short.bin"
    short.write_bytes(b"\x01\x00\x01\x00" + bytes(10))
    assert cli.main(["dump", str(short)]) == 1


def test_both_paths_read_the_same_values() -> None:
    paths = decode.decoders(64)
    for i in range(64):
        schema_id, version, *numbers, barcode = paths[decode.UNPACK_FROM](i)
        assert (schema_id, version) == (1, 1)
        parsed = paths[decode.PARSE_FROM_STRING](i)
        assert tuple(numbers) == parsed[:-1]
        assert barcode.decode("ascii") == parsed[-1]


def test_every_numeric_field_read_makes_an_int_object_on_both_paths() -> None:
    # The Python divergence: a flat record is not a view. Reading a field creates an int, so
    # "zero-copy" saves the byte copy, not the allocation.
    for name, fn in decode.decoders(1024).items():
        counts = decode.observe_allocations(fn, 1024)
        assert counts["new_int_objects_per_parcel"] >= 6, (name, counts)
        assert counts["blocks_per_parcel"] >= counts["new_int_objects_per_parcel"], (name, counts)


@pytest.mark.usefixtures("lowlat_profile")
def test_decode_command_writes_checked_reports(tmp_path: Path) -> None:
    assert cli.main(["decode", "--out", str(tmp_path), "--parcels", "64", "--rounds", "5"]) == 0
    reports = sorted(tmp_path.glob("python-*-*.json"))
    assert [p.stem for p in reports] == ["python-parse-from-string", "python-unpack-from"]
    assert lowlat_report(["check", *map(str, reports)]) == 0
    observed = json.loads((tmp_path / "python-allocations.json").read_text(encoding="utf-8"))
    assert set(observed) == set(decode.VARIANTS)


def test_variant_names_are_kebab_case_of_the_method() -> None:
    assert harness_report.variant_of("a.b.DecodeBenchmark.protobufDecode") == "protobuf-decode"
    assert harness_report.variant_of("a.b.DecodeBenchmark.flatFfm") == "flat-ffm"
    assert harness_report.variant_of("a.b.ClockBenchmark.downcallCritical") == "downcall-critical"
    assert harness_report.variant_of("a.b.ClockBenchmark.nanoTime") == "nano-time"


@pytest.mark.usefixtures("lowlat_profile")
def test_jmh_conversion_keeps_percentiles_and_per_parcel_allocation(tmp_path: Path) -> None:
    jmh = [
        {
            "benchmark": "io.x.DecodeBenchmark.flatFfm",
            "forks": 2,
            "measurementIterations": 5,
            "measurementTime": "500 ms",
            "jdkVersion": "25.0.5",
            "vmName": "OpenJDK 64-Bit Server VM",
            "vmVersion": "25.0.5+8-LTS",
            "jmhVersion": "1.37",
            "jvmArgs": ["--enable-native-access=ALL-UNNAMED"],
            "primaryMetric": {
                "scoreUnit": "ns/op",
                "rawDataHistogram": [[[[16.0, 90], [17.0, 9], [52.0, 1]]]],
            },
            "secondaryMetrics": {"gc.alloc.rate.norm": {"score": 0.001}},
        }
    ]
    source = tmp_path / "jmh.json"
    source.write_text(json.dumps(jmh), encoding="utf-8")
    (path,) = harness_report.from_jmh(source, tmp_path / "out")
    report = json.loads(path.read_text(encoding="utf-8"))
    assert report["variant"] == "flat-ffm"
    assert report["count"] == 100
    assert report["percentiles"]["p50"] == 16
    assert report["runtime"]["alloc_bytes_per_parcel"] == 0.001
    assert report["build"]["flags"] == "--enable-native-access=ALL-UNNAMED"
    assert lowlat_report(["check", str(path)]) == 0


@pytest.mark.usefixtures("lowlat_profile")
def test_gbench_conversion_has_one_sample_per_repetition(tmp_path: Path) -> None:
    runs = [
        {
            "run_name": "BM_DecodeBitCast/min_time:0.100/repeats:30",
            "run_type": "iteration",
            "real_time": 8800.0 + i,
            "time_unit": "ns",
            "iterations": 50000,
            "ops_per_iteration": 1024,
        }
        for i in range(30)
    ]
    runs.append(
        {
            "run_name": "BM_DecodeBitCast/x",
            "run_type": "aggregate",
            "real_time": 1.0,
            "time_unit": "ns",
        }
    )
    source = tmp_path / "gbench.json"
    source.write_text(
        json.dumps({"context": {"library_version": "1.10.0"}, "benchmarks": runs}), encoding="utf-8"
    )
    (path,) = harness_report.from_gbench(source, tmp_path / "out")
    report = json.loads(path.read_text(encoding="utf-8"))
    assert path.name == "cpp-decode-bit-cast.json"
    assert report["count"] == 30
    assert report["language"] == "cpp"
    assert "mean real time per iteration, taken over 50000 iterations" in report["notes"]
    assert lowlat_report(["check", str(path)]) == 0
