"""Convert JMH and Google Benchmark output to ``lowlat-report/1`` reports.

``from_jmh``: JMH SampleTime keeps the sampled times as ``rawDataHistogram`` (value, count)
pairs per fork and iteration; they are loaded into the lowlat recorder, so percentiles come from
HdrHistogram like every other report. The ``gc`` profiler's ``gc.alloc.rate.norm`` (bytes
allocated per operation) becomes ``runtime.alloc_bytes_per_parcel`` for the benchmarks named in
``per_parcel``, where an operation is one parcel, and a note for the others, where an operation is
a sweep or a clock read.

``from_gbench``: Google Benchmark JSON run with repetitions; one sample per repetition, the time of
one iteration (``ops_per_iteration`` operations), so a sub-nanosecond-per-record decode keeps its
resolution.

The converters began in Ch8 (``08-zero-copy-flat``) and moved here so that every later chapter
converts its JMH and Google Benchmark runs the same way.
"""

import json
import re
from collections.abc import Collection
from pathlib import Path
from typing import Any

from lowlat_measure.recorder import Recorder

ALLOC_METRIC = "gc.alloc.rate.norm"  # JMH gc profiler, bytes allocated per operation
DEFAULT_TOOLCHAIN = "C++23 release preset (clang)"
_UNIT_NS = {"ns/op": 1.0, "us/op": 1e3, "ms/op": 1e6, "s/op": 1e9}


def kebab(name: str) -> str:
    """``protobufDecode`` or ``ProtobufDecode`` -> ``protobuf-decode``."""
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "-", name).lower()


def variant_of(benchmark: str) -> str:
    """``...DecodeBenchmark.protobufDecode`` -> ``protobuf-decode``."""
    return kebab(benchmark.rsplit(".", 1)[1])


def from_jmh(
    source: Path, out_dir: Path, *, example: str, per_parcel: Collection[str] = ()
) -> list[Path]:
    """Write ``java-<variant>.json`` per JMH benchmark; return the paths.

    ``per_parcel`` names the variants whose operation is one parcel: their allocation rate is
    reported as ``runtime.alloc_bytes_per_parcel``.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for bench in json.loads(source.read_text(encoding="utf-8")):
        variant = variant_of(bench["benchmark"])
        metric = bench["primaryMetric"]
        unit = _UNIT_NS[metric["scoreUnit"]]
        recorder = Recorder(example, variant)
        for fork in metric["rawDataHistogram"]:
            for iteration in fork:
                for value, count in iteration:
                    recorder.record(max(0, round(value * unit)), int(count))
        alloc = bench.get("secondaryMetrics", {}).get(ALLOC_METRIC, {}).get("score")
        notes = (
            f"JMH SampleTime, {bench['forks']} forks x {bench['measurementIterations']} iterations "
            f"of {bench['measurementTime']}; "
            "samples are invocations divided by @OperationsPerInvocation, rounded to whole ns"
        )
        runtime: dict[str, Any] = {}
        if alloc is not None and variant in per_parcel:
            runtime["alloc_bytes_per_parcel"] = alloc
        elif alloc is not None:
            notes += f"; gc.alloc.rate.norm {alloc:.3f} B/op"
        build = {
            "compiler": f"Java {bench['jdkVersion']} {bench['vmName']} {bench['vmVersion']}; "
            f"JMH {bench['jmhVersion']}",
            "gil_enabled": None,
            "flags": " ".join([*bench.get("jvmArgs", []), *bench.get("vmArgs", [])]) or None,
        }
        if build["flags"] is None:
            del build["flags"]
        path = out_dir / f"java-{variant}.json"
        recorder.write_report(path, notes, language="java", build=build, runtime=runtime or None)
        written.append(path)
    return written


def from_gbench(
    source: Path, out_dir: Path, *, example: str, toolchain: str = DEFAULT_TOOLCHAIN
) -> list[Path]:
    """Write ``cpp-<variant>.json`` per Google Benchmark benchmark; return the paths."""
    out_dir.mkdir(parents=True, exist_ok=True)
    data = json.loads(source.read_text(encoding="utf-8"))
    samples: dict[str, list[float]] = {}
    ops: dict[str, int] = {}
    iterations: dict[str, int] = {}
    for run in data["benchmarks"]:
        if run.get("run_type") != "iteration":
            continue
        variant = kebab(run["run_name"].split("/")[0].removeprefix("BM_"))
        samples.setdefault(variant, []).append(
            run["real_time"] * _UNIT_NS[f"{run['time_unit']}/op"]
        )
        ops[variant] = int(run.get("ops_per_iteration", 1))
        iterations[variant] = int(run["iterations"])
    context = data["context"]
    build = {
        "compiler": f"Google Benchmark {context.get('library_version', 'unknown')}; {toolchain}",
        "gil_enabled": None,
        "flags": f"library_build_type={context.get('library_build_type')}",
    }
    written = []
    for variant, values in samples.items():
        recorder = Recorder(example, variant)
        for value in values:
            recorder.record(max(0, round(value)))
        path = out_dir / f"cpp-{variant}.json"
        recorder.write_report(
            path,
            f"Google Benchmark: {len(values)} repetitions, one sample per repetition; "
            f"each sample is a repetition's mean real time per iteration, taken over "
            f"{iterations[variant]} iterations, one iteration = {ops[variant]} operation(s), "
            "rounded to whole ns. Per-iteration samples are not exposed by the harness.",
            language="cpp",
            build=build,
        )
        written.append(path)
    return written
