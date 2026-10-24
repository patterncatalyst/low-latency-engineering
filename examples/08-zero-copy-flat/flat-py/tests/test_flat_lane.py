"""The Python lane: golden bytes, the two decode paths and what each allocates."""

import base64
import json
import zlib
from pathlib import Path

import pytest
from lowlat_flat import cli, decode, golden, harness_report
from lowlat_measure import decode as decode_histogram
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


def _differs_only_in_compression(a: dict, b: dict) -> bool:
    """True when two reports are equal apart from the compressed histogram bytes, and the decoded
    histograms are equal (zlib output varies with the zlib version; the data does not)."""
    if {**a, "hdr_histogram": None} != {**b, "hdr_histogram": None}:
        return False
    ha, hb = decode_histogram(a["hdr_histogram"]), decode_histogram(b["hdr_histogram"])
    return ha.get_total_count() == hb.get_total_count() and list(ha.counts) == list(hb.counts)


def _recompress(encoded: str, level: int) -> str:
    """Re-encode an HdrHistogram V2 compressed string with zlib at another level."""
    raw = base64.b64decode(encoded)
    cookie, payload = raw[:4], zlib.decompress(raw[8:])
    body = zlib.compress(payload, level)
    return base64.b64encode(cookie + len(body).to_bytes(4, "big") + body).decode("ascii")


def test_compression_only_differences_are_recognised() -> None:
    old = json.loads((RESULTS / "r02-run1" / "jmh").glob("*.json").__next__().read_text("utf-8"))
    new = None
    for level in (1, 9, 6):
        candidate = {**old, "hdr_histogram": _recompress(old["hdr_histogram"], level)}
        if candidate["hdr_histogram"] != old["hdr_histogram"]:
            new = candidate
            break
    assert new is not None, "no zlib level changed the bytes"
    assert _differs_only_in_compression(new, old)
    assert not _differs_only_in_compression({**new, "count": old["count"] + 1}, old)


RESULTS = Path(__file__).resolve().parents[2] / "results"

# The committed r02 reports were compressed by zlib-ng (the Fedora system Python). Another zlib
# (the uv-managed build ships stock zlib) writes different bytes for the same histogram, so byte
# identity is asserted only under zlib-ng; the decoded histograms must match under any zlib.
COMMITTED_ZLIB = "1.3.1.zlib-ng"


def _is_zlib_ng() -> bool:
    return "zlib-ng" in zlib.ZLIB_RUNTIME_VERSION


def _check_report(name: str, new: bytes, old: bytes, differed: list[str]) -> None:
    """Decoded histograms and every other field must match; the bytes must match under zlib-ng."""
    if new == old:
        return
    assert _differs_only_in_compression(json.loads(new), json.loads(old)), (
        f"{name}: content differs"
    )
    assert not _is_zlib_ng(), f"{name}: bytes differ under zlib-ng {zlib.ZLIB_RUNTIME_VERSION}"
    differed.append(name)


def _skip_if_only_compression_differs(differed: list[str]) -> None:
    if differed:
        pytest.skip(
            f"byte identity needs zlib-ng; running zlib {zlib.ZLIB_RUNTIME_VERSION}, "
            f"committed with {COMMITTED_ZLIB} (decoded histograms and every other field "
            f"matched in {len(differed)} reports)"
        )


@pytest.mark.parametrize("run", ["r02-run1", "r02-run2", "r02-run3"])
def test_lowlat_report_converters_regenerate_the_committed_reports_byte_for_byte(
    run: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``lowlat-report from-jmh`` and ``from-gbench`` reproduce Ch8's committed reports exactly."""
    committed = RESULTS / run
    monkeypatch.setenv("LOWLAT_PROFILE", str(committed / "profile.json"))
    jmh_out, cpp_out = tmp_path / "jmh", tmp_path / "cpp"
    assert (
        lowlat_report(
            [
                *("from-jmh", str(committed / "jmh.json"), str(jmh_out)),
                *("--example", harness_report.EXAMPLE),
                *(a for v in sorted(harness_report.PER_PARCEL) for a in ("--per-parcel", v)),
            ]
        )
        == 0
    )
    assert (
        lowlat_report(
            [
                *("from-gbench", str(committed / "cpp" / "gbench.json"), str(cpp_out)),
                *("--example", harness_report.EXAMPLE),
            ]
        )
        == 0
    )
    pairs = [(jmh_out, committed / "jmh"), (cpp_out, committed / "cpp")]
    differed: list[str] = []
    for regenerated, original in pairs:
        names = sorted(p.name for p in regenerated.glob("*.json"))
        assert names == sorted(p.name for p in original.glob("*-*.json") if p.name != "gbench.json")
        assert names, original
        for name in names:
            _check_report(
                name, (regenerated / name).read_bytes(), (original / name).read_bytes(), differed
            )
    _skip_if_only_compression_differs(differed)


def test_harness_report_wrapper_keeps_the_old_import_working(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    committed = RESULTS / "r02-run1"
    monkeypatch.setenv("LOWLAT_PROFILE", str(committed / "profile.json"))
    differed: list[str] = []
    for path in harness_report.from_jmh(committed / "jmh.json", tmp_path):
        _check_report(
            path.name, path.read_bytes(), (committed / "jmh" / path.name).read_bytes(), differed
        )
    for path in harness_report.from_gbench(committed / "cpp" / "gbench.json", tmp_path):
        _check_report(
            path.name, path.read_bytes(), (committed / "cpp" / path.name).read_bytes(), differed
        )
    _skip_if_only_compression_differs(differed)
