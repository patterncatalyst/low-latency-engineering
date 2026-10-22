"""Convert harness output into ``lowlat-report/1`` reports.

Each harness exposes a different amount of raw data; this module uses what it gives:

* ``gbench``  Google Benchmark JSON run with ``--benchmark_repetitions``: one sample per
              repetition (time per iteration). Repetition-level, not per-iteration.
* ``jmh``     JMH SampleTime JSON: ``rawDataHistogram`` is (value, count) pairs in ns/op
              across forks and iterations, loaded with ``record_value(v, count)``.
* ``pyperf``  pyperf JSON: every measured value (or warm-up value) of every worker process.

Values are rounded to whole nanoseconds, the report unit. A value that rounds to 0 is a
loop the optimizer removed.
"""

import argparse
import json
import sys
from collections import defaultdict
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from lowlat_measure.recorder import Recorder

from lowlat_bench.check_digit import PREFIX_COUNT

EXAMPLE = "04-benchmark-harnesses"
_UNIT_NS = {"ns": 1.0, "us": 1e3, "ms": 1e6, "s": 1e9}  # Google Benchmark time_unit -> ns


def _finish(
    rec: Recorder, out: Path, language: str, build: dict[str, Any], notes: str
) -> dict[str, Any]:
    # The report speaks for `language`, so its percentiles follow that language's
    # HdrHistogram rank convention (Java rounds the rank up); `lowlat-report check`
    # recomputes them the same way.
    return rec.write_report(out, notes, language=language, build=build)


def _ns(value: float) -> int:
    return max(0, round(value))


def from_gbench(src: Path, out_dir: Path) -> list[Path]:
    data = json.loads(src.read_text(encoding="utf-8"))
    ctx = data["context"]
    build = {
        "compiler": f"Google Benchmark {ctx.get("library_version", "unknown")}; "
        "see the C++ report for the compiler",
        "gil_enabled": None,
        "flags": f"library_build_type={ctx.get('library_build_type')}",
    }
    samples: defaultdict[str, list[float]] = defaultdict(list)
    for b in data["benchmarks"]:
        if b.get("run_type") != "iteration":
            continue
        unit = _UNIT_NS[b["time_unit"]]
        samples[b["run_name"].split("/")[0]].append(b["real_time"] * unit)
    written = []
    for name, values in samples.items():
        rec = Recorder(EXAMPLE, name.removeprefix("BM_CheckDigit_").lower())
        for v in values:
            rec.record(_ns(v))
        path = out_dir / f"report-cpp-{rec.variant}.json"
        _finish(
            rec,
            path,
            "cpp",
            build,
            f"Google Benchmark: {len(values)} repetitions, one sample per repetition "
            "(real time per iteration, rounded to whole ns; 0 means the loop was folded away). "
            "Per-iteration samples are not exposed by the harness.",
        )
        written.append(path)
    return written


def from_jmh(src: Path, out_dir: Path) -> list[Path]:
    data = json.loads(src.read_text(encoding="utf-8"))
    written = []
    for b in data:
        build = {
            "compiler": f"Java {b['jdkVersion']} {b['vmName']} {b['vmVersion']}; "
            f"JMH {b['jmhVersion']}",
            "gil_enabled": None,
        }
        rec = Recorder(EXAMPLE, b["benchmark"].rsplit(".", 1)[1])
        for fork in b["primaryMetric"]["rawDataHistogram"]:
            for iteration in fork:
                for value, count in iteration:
                    rec.record(_ns(value), int(count))
        path = out_dir / f"report-java-{rec.variant}.json"
        _finish(
            rec,
            path,
            "java",
            build,
            f"JMH SampleTime, {b['forks']} forks x {b['measurementIterations']} iterations of "
            f"{b['measurementTime']}; samples are invocations of {PREFIX_COUNT} check digits, "
            "reported as ns per check digit (JMH normalises by OperationsPerInvocation) "
            "from the rawDataHistogram, rounded to whole ns.",
        )
        written.append(path)
    return written


def from_pyperf(src: Path, out_dir: Path) -> list[Path]:
    import pyperf

    suite = pyperf.BenchmarkSuite.load(str(src))
    written = []
    for bench in suite.get_benchmarks():
        build = {"compiler": sys.version, "gil_enabled": sys._is_gil_enabled()}
        measured = Recorder(EXAMPLE, f"{bench.get_name()}-measured")
        warm = Recorder(EXAMPLE, f"{bench.get_name()}-warmup")
        for run in bench.get_runs():
            for v in run.values:
                measured.record(_ns(v * 1e9))
            # pyperf stores warm-up values already normalised to one inner loop.
            for _loops, value in run.warmups:
                warm.record(_ns(value * 1e9))
        kinds = ((measured, "measured values"), (warm, "warm-up values (not in the result)"))
        for rec, what in kinds:
            path = out_dir / f"report-python-{rec.variant}.json"
            _finish(
                rec,
                path,
                "python",
                build,
                f"pyperf {what} from {len(bench.get_runs())} runs; each value is the time per "
                "check digit, rounded to whole ns.",
            )
            written.append(path)
    return written


CONVERTERS = {"gbench": from_gbench, "jmh": from_jmh, "pyperf": from_pyperf}


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("harness", choices=sorted(CONVERTERS))
    parser.add_argument("source", type=Path, help="the harness's JSON output")
    parser.add_argument("out_dir", type=Path, help="directory for the report-*.json files")
    args = parser.parse_args(argv)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    convert = CONVERTERS[args.harness]
    for path in convert(args.source, args.out_dir):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
