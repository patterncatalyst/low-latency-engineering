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

## Recorder API (idiomatic per language, same shape)

- construct with `example` (e.g. `"03-coordinated-omission"`) and `variant`
  (e.g. `"intended-time"`)
- `record(latency_ns)`
- `record_corrected(latency_ns, expected_interval_ns)`
- `add_dropped(n)` — parcels that never arrived (sequence gaps)
- `write_report(path)` — writes one JSON report (below) and returns it
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
- `hdr_histogram`: the library's **compressed V2 encoding, base64** (the
  `HISTFAAA…` form). C `hdr_log_encode`; Python `encode()`; Java
  `encodeIntoCompressedByteBuffer` + `Base64`. Each kit must decode the other
  two's output.
- `build`: `compiler` (C++: `__VERSION__`/`__clang_version__` and standard;
  Java: `Runtime.version()` + `java.vm.name`; Python: `sys.version`) and
  `gil_enabled` (Python `sys._is_gil_enabled()`; `null` in C++ and Java). Optional
  `flags` (C++ build type and flags).
- `profile`: the JSON file named by the environment variable `LOWLAT_PROFILE`
  (written by `scripts/profile.sh --out FILE`), embedded verbatim. The kits never
  probe the machine themselves. If `LOWLAT_PROFILE` is unset, fail with a clear
  message: a number without a profile is not publishable.
- Optional `model`: the only place a time-average may appear (Little's law,
  Amdahl's law; Ch2). Optional `notes`.
- JSON is written with the language's established library: nlohmann/json,
  Jackson 3 (`tools.jackson`), stdlib `json`.

## Shared fixtures

Each kit's tests write a golden report from one fixed dataset to
`common/measure-fixtures/<language>-golden.json`, with `LOWLAT_PROFILE` pointing
at `common/measure-fixtures/profile.json` (a committed sample profile):

- dataset: values 1,000 ns to 10,000,000 ns, i.e. `i * 1000` for i = 1..10,000,
  recorded plain; variant `"golden"`, example `"measure-fixtures"`.

`lowlat-report check common/measure-fixtures/*-golden.json` decodes every
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
  (`values_are_equivalent`); when given reports from several languages for the
  same example and variant, also assert they agree with each other. Exit
  non-zero on any mismatch.
