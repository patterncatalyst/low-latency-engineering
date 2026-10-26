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
    `old_gen_used_bytes` (integer; old-generation bytes in use after a collection at the end of the run, written
    by example 07), `flags` (array of strings, e.g. `-XX:+UseZGC`)
  - `alloc_bytes_per_parcel` (number)
  - `jit`: free-form counts such as `compilations` and `deoptimizations`, keyed by window
    (`{"first-1000": {...}, "steady": {...}}`)
  - `aot`: `cache` (string), `mode` (string), `used` (boolean)
  - `ctx_switches`: `voluntary`, `involuntary` (integers)
  - `alloc_stalls`: `count`, `max_ns` (integers; `jdk.ZAllocationStall` events, written by `JfrPauses`)
  - `placement`: `cpus` (non-empty array of distinct logical CPU numbers the measured threads were pinned
    to), `distinct_cores`, `smt_siblings` (booleans). `distinct_cores: true` with `smt_siblings: true`
    contradicts itself and fails.
  - `hw_counters`: `source` (`perf`, `cachegrind` or `perfnorm`), `ops` (integer, at least 1) and
    `per_op` (event name to count per operation, at least one entry). Never a time-average.
  - `counters`: exact event counts, name to non-negative integer (CAS failures, max retries, torn
    reads, `io_uring_setup` errno). r05 names: `samples`, `overflows` (samples beyond a cyclictest
    histogram's range) and `safepoints`, plus `interrupts`, the one nested member (an object, narrowed from the integer any counter name
    could take before; no committed report used an integer there): row name (`LOC`,
    `RES`, `CAL`, `TLB` or an IRQ name) to logical CPU number to the delta over the run.
  - `python_build`: `gil` or `free-threaded`, for Python lanes.
  - `environment` (r04): where the measured program ran.
    - `kind`: `host`, `vm` or `container`. Required.
    - `guest_profile`: guest snapshot and profile, like `lab-ready-r04/stock-unpinned`. Required for `vm`
      and `container`, forbidden for `host`. From r05 it may instead be an object `{snapshot, profile,
      vcpupin}` (`vcpupin`: optional list of `{vcpu, cpus}`, host CPU lists from `virsh vcpupin`, written
      by the host driver because the guest can't see them).
    - `container`: required for `container`, forbidden for `host` and `vm`. All fields are required:
      `runtime` (`docker`), `image` (exact tag; `:latest` and tagless references fail, and a registry
      port must be followed by `/`), `image_digest` (`sha256:` plus 64 lowercase hex), `network`
      (`host`, `bridge` or `none`), `cpu_quota` (CPUs like `2` or `1.5`, or null), `cpuset` (like `2,3`,
      or null) and `seccomp` (`default` or a profile file name ending in `.json`; `unconfined` fails).
    - `cgroup`: optional. When present, all four keys are required and each may be null when its file
      wasn't readable: `cpu_max`, `cpuset_effective` (strings) and `nr_throttled`, `throttled_usec`
      (non-negative integers from `cpu.stat`).

  No key anywhere inside `runtime` may name a mean or an average. The schema matches the key
  case-insensitively and rejects `mean`, `avg` and `average` as a whole key or as a part of a
  snake_case, kebab-case or camelCase one (`mean_ns`, `pause_mean_ns`, `mean_compile_ns`,
  `avg_ns`, `average_ns`, `meanNs`, `avgNs`) and a trailing `meanns`/`avgns`, so
  `lowlat-report validate` and `check` both fail. Keys such as `meaning` pass. Key order is the
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
- `lowlat-report from-jmh SOURCE OUT_DIR --example ID [--per-parcel VARIANT…]`: convert JMH SampleTime JSON
  (`rawDataHistogram`, run with `-prof gc`) to `java-<variant>.json` reports through the recorder; needs
  `LOWLAT_PROFILE`. `--per-parcel` names variants whose operation is one parcel: their
  `gc.alloc.rate.norm` becomes `runtime.alloc_bytes_per_parcel`.
- `lowlat-report from-gbench SOURCE OUT_DIR --example ID [--toolchain TEXT]`: convert Google Benchmark JSON
  (with `--benchmark_repetitions`) to `cpp-<variant>.json` reports, one sample per repetition.
- `lowlat-report from-cyclictest JSON HISTFILE OUT_DIR --example ID [--variant PREFIX] [--allow-overflow]
  [--guest-profile SNAPSHOT/PROFILE]`: convert cyclictest (rt-tests v2.11) `--json` plus `--histfile` to one
  `<variant>-t<N>.json` report per thread (language `cpp`); needs `LOWLAT_PROFILE`.
  - Percentiles come from the histogram buckets. cyclictest truncates a latency to whole microseconds (whole
    nanoseconds with `-N`), so a bucket value is the bucket's lower edge in ns and the true latency is up to
    1 us higher. The recorder uses five HdrHistogram digits (the kit default is three), which keeps 1 us
    buckets distinct to about 134 ms and adds under 0.002% above 131 us (a `p99` may read 5000031 for a 5000 us
    bucket). `-N` buckets stay distinct only to about 262 us.
  - The average, `sysinfo.nodename`, `sysinfo.realtime` and the raw command line are never written. The
    clock (absent `-c` means `realtime` at v2.11), policy and priority are in `notes`, with the priority
    and policy rules of `process_options` applied (`-p95 --policy=other` runs FIFO 95).
  - A histogram overflow, a `return_code` other than 0, cycles that differ from the histogram, or a JSON
    histogram that differs from the histfile fails the conversion. `--allow-overflow` records each overflowed
    sample at the thread's maximum, so the count equals the cycles, `max` is exact and the tail
    percentiles are upper bounds; `runtime.counters.overflows` and `notes` say so.

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
