# Measurement kit specification

One kit per language, one report format, so a number recorded in C++, Python or
Java can be decoded, re-derived and compared by the same tool.

| Language | Directory | Built on |
|---|---|---|
| C++ | `common/measure-cpp/` (CMake target `lowlat::measure`) | HdrHistogram_c |
| Python | `common/measure-py/` (package `lowlat_measure`, CLI `lowlat-report`) | `hdrhistogram` (import `hdrh`) |
| Java | `common/measure-java/` (artifact `measure-java`, package `io.patterncatalyst.lowlat.measure`) | HdrHistogram (Java) |

Versions come from `versions.env` / `_plans/dependency-pins.md`.

## Histogram

- Unit: nanoseconds.
- Range: lowest discernible value 1, highest trackable value 3,600,000,000,000
  (one hour), 3 significant digits. All three kits use exactly these parameters,
  so encoded histograms are interchangeable.
- Recording uses the library's own calls. Never hand-rolled percentile code.
  - plain: C `hdr_record_value`, Java `recordValue`, Python `record_value`
  - coordinated-omission correction: C `hdr_record_corrected_value`, Java
    `recordValueWithExpectedInterval`, Python `record_corrected_value`
  - Java multi-threaded recording uses `Recorder` / `SingleWriterRecorder` and
    `getIntervalHistogram`; post-hoc correction uses
    `copyCorrectedForCoordinatedOmission`.
  - Inline and post-hoc correction produce the same total count, but a
    percentile can differ by one bucket: the post-hoc copy back-fills from
    bucketed values, not from the original samples. Compare them as
    "equivalent or adjacent bucket", never as identical.

## Recorder API (idiomatic per language, same shape)

- construct with `example` (e.g. `"03-coordinated-omission"`) and `variant`
  (e.g. `"intended-time"`)
- `record(latency_ns)`
- `record_corrected(latency_ns, expected_interval_ns)`
- `add_dropped(n)` — parcels that never arrived (sequence gaps)
- `write_report(path, notes=None, model=None, runtime=None)` — writes one JSON report (below) and returns it;
  `notes` is an optional free-text string (run conditions, buffer sizes); `model` is an
  optional JSON object written as the report's `model` block; `runtime` is an optional JSON
  object written as the report's `runtime` block. All three keys are omitted when absent
  (and `notes` when empty, `model` and `runtime` when empty). Signatures per kit:
  - Java: `Report writeReport(Path path, String notes, Map<String, Object> model, Map<String, Object> runtime)`
    (pass `null` to omit any; the 3-, 2- and 1-argument overloads remain)
  - C++: `nlohmann::json write_report(const std::filesystem::path& path, std::string_view notes = {},
    const std::optional<nlohmann::json>& model = std::nullopt,
    const std::optional<nlohmann::json>& runtime = std::nullopt) const`; `report(notes, model, runtime)`
    builds the document without writing it
  - Python: `write_report(path: str | Path, notes: str | None = None, model: Mapping[str, Any] | None = None, *, language=..., build=..., runtime: Mapping[str, Any] | None = None) -> dict`;
    `build_report(notes=None, model=None, *, language=..., build=..., runtime=None)` builds the document without writing it
- `print_summary()` — one aligned table line to stdout: example, language,
  variant, count, dropped, p50, p90, p99, p99.9, max, in microseconds with 1
  decimal. **Never a mean.**

## Report (JSON)

Must validate against `contracts/measurement/latency-report.schema.json`.

- `schema` = `"lowlat-report/1"`, `example`, `language` (`cpp`/`python`/`java`),
  `variant`, `unit` = `"ns"`, `count` (total recorded count, including
  correction back-fill), `dropped`
- `percentiles`: `p50`, `p90`, `p99`, `p99_9` from the library's
  value-at-percentile for 50, 90, 99, 99.9; `max` from the library's max. Integers.
  The ports define the rank differently: C 0.12.1 and Python 0.10.8 round
  `p·N/100` half up, Java 2.2.2 rounds it up (`ceil`). Dense data lands in the
  same bucket either way; a sparse tail can differ by one bucket. Each kit keeps
  its library's convention, and `lowlat-report check` recomputes a report with
  the convention of the language that wrote it.
- `hdr_histogram`: the library's **compressed V2 encoding, base64** (the
  `HISTFAAA…` form). C `hdr_log_encode`; Python `encode()`; Java
  `encodeIntoCompressedByteBuffer` + `Base64`. Each kit must decode the other
  two's output.
- `build`: `compiler` (C++: `__VERSION__`/`__clang_version__` and standard;
  Java: `Runtime.version()` + `java.vm.name`; Python: `sys.version`) and
  `gil_enabled` (Python `sys._is_gil_enabled()`; `null` in C++ and Java). Optional
  `flags` (C++ build type and flags; Java: the JVM input arguments from
  `RuntimeMXBean.getInputArguments()` joined by single spaces, e.g.
  `-XX:+UseZGC -Xmx1g`, omitted when the JVM was started without any, `JAVA_TOOL_OPTIONS`
  included).
- `profile`: the JSON file named by the environment variable `LOWLAT_PROFILE`
  (written by `scripts/profile.sh --out FILE`), embedded verbatim. The kits never
  probe the machine themselves. If `LOWLAT_PROFILE` is unset, fail with a clear
  message: a number without a profile is not publishable.
- Optional `model`: the only place a time-average may appear (Little's law,
  Amdahl's law; Ch2). Optional `notes`.
- Optional `runtime` (additive in `lowlat-report/1`; reports without it stay valid): facts
  about the managed runtime and scheduler during the run. All members optional:
  - `gc`: `name` (string), `collectors` (array of strings), `heap_bytes` (integer),
    `flags` (array of strings, e.g. `-XX:+UseZGC`)
  - `alloc_bytes_per_parcel` (number)
  - `jit`: free-form counts such as `compilations` and `deoptimizations`, keyed by window
    (`{"first-1000": {...}, "steady": {...}}`)
  - `aot`: `cache` (string), `mode` (string), `used` (boolean)
  - `ctx_switches`: `voluntary`, `involuntary` (integers)
  - `alloc_stalls`: `count`, `max_ns` (integers; `jdk.ZAllocationStall` events, written by `JfrPauses`)

  No key anywhere inside `runtime` may be named `mean` or end in `_mean` or `mean_ns`; the
  schema rejects it, so `lowlat-report validate` and `check` both fail. Key order is the
  order above for the typed members; the kits write the object as given, after `model`.
  The Java kit never adds `runtime` on its own: `RuntimeInfo.jvm()` returns a mutable map
  with `gc.collectors` (`GarbageCollectorMXBean` names), `gc.heap_bytes` (`Runtime.maxMemory()`)
  and `gc.flags` (the GC and heap input arguments), which the caller extends with measured
  facts and passes to `writeReport`. (`BuildInfo` records the full argument list in
  `build.flags` automatically; `RuntimeInfo` is the structured, opt-in view.) The name is
  not `Runtime`, to avoid shadowing `java.lang.Runtime`.
- JSON is written with the language's established library: nlohmann/json,
  Jackson 3 (`tools.jackson`), stdlib `json`.

## Shared fixtures

Each kit's tests produce a golden report from one fixed dataset. They write it to a
temporary directory; the committed `common/measure-fixtures/<language>-golden.json` is
rewritten only on request: `LOWLAT_REGEN_GOLDEN=1` for the C++ and Java tests,
`pytest --regen-golden` for Python. Cross-language checks read the committed files. The
tests point `LOWLAT_PROFILE`
at `common/measure-fixtures/profile.json` (a committed sample profile):

- dataset: values 1,000 ns to 10,000,000 ns, i.e. `i * 1000` for i = 1..10,000,
  recorded plain; variant `"golden"`, example `"measure-fixtures"`.

`lowlat-report check --same-dataset common/measure-fixtures/*-golden.json` decodes every
histogram and confirms that all three report the same percentiles, within
HdrHistogram's equivalent-value range.

## Correction test (every kit)

Record 1,000 values of 1 ms, then one value of 1 s with an expected interval of
1 ms through the corrected call:

- corrected total count is exactly 2,000 (1,000 + 1 + 999 back-filled values)
- corrected p99 > 1 ms, while the same data recorded plain has p99 ≈ 1 ms
  (within HdrHistogram's equivalent range of 1,000,000 ns)

## `lowlat-report` (Python CLI, in `measure-py`)

- `lowlat-report validate FILE…`: schema-validate each report
- `lowlat-report show FILE…`: aligned table (µs, 1 decimal), no mean
- `lowlat-report check FILE…`: validate, decode `hdr_histogram`, recompute
  p50/p90/p99/p99.9/max, and assert they match the emitted values
  (`values_are_equivalent`). With `--same-dataset`, also assert that reports
  sharing example and variant agree across languages; use it only for reports
  recorded from one fixed dataset (the goldens), because languages measuring a
  live workload are expected to differ. Exit non-zero on any mismatch.

## Scratch files and JFR (Part 2)

Nothing bulky or machine-specific is committed. `*.jfr` recordings, `.scratch/` directories
and Chronicle Queue data (`examples/*/results/**/queue/`) are git-ignored. `lib.sh`
`java_run` writes the JFR recording to a `mktemp` directory outside the tree (removed on
exit; set `LOWLAT_SCRATCH` to keep it) and the unified GC and safepoint log to
`$OUT/<variant>.gc.log` (committed, small). `jfr_pauses JFR EXAMPLE VARIANT` runs the
`JfrPauses` CLI (shaded `measure-java/target/measure-java-cli.jar`) and writes
`$OUT/java-<variant>-gc-pause.json`: one sample per `jdk.GCPhasePause` event (duration in
ns; nested `GCPhasePauseLevel*` phases are not counted), `runtime.gc` from
`jdk.GCConfiguration` and `runtime.alloc_stalls` from `jdk.ZAllocationStall`.
