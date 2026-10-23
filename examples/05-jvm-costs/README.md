# 05-jvm-costs

Chapter 5: what the JVM charges per parcel, and how to stop paying it on the first one.
A light in-flight parcel tracker sits on the scan-to-divert path (480 ms budget: 1.2 m
at 2.5 m/s). Its `decide(ParcelEvent)` runs in Java on JMH and on the line, and in C++
beside it. The chapter measures three costs of a managed runtime: heap bytes per
decision, the warm-up tail of the first parcels, and process start. Each has a
mechanism that removes it: escape analysis, an in-process warm-up replay, and the Leyden
AOT cache.

## Technique

- **Allocation.** Every `new` is a bump of the thread's TLAB pointer, so the cost is not
  the allocation but the bytes it adds to the next young collection. C2's escape analysis
  removes an allocation that never leaves the compiled method (scalar replacement: the
  object's fields live in registers). JMH's `-prof gc` reads the exact count
  (`gc.alloc.rate.norm`, bytes per operation), so the effect is a counter, not a timing.
- **Warm-up.** Bytecode runs interpreted, then C1 (tier 1 without profiling, tiers 2 and 3 with it), then C2
  (tier 4); an assumption that breaks sends compiled code back to the interpreter
  (deoptimization). A JVM that binds its socket at once pays this on the first parcels of
  the line. Replaying synthetic parcels through the same classes before the bind moves the
  cost off the belt.
- **AOT cache.** JDK 25's ahead-of-time cache (JEP 483 class loading and linking, JEP 514
  one-step creation, JEP 515 method profiles) records a training run and reuses it at
  start. Under G1 the archive also holds heap objects; on JDK 25 other collectors lose
  that part until JEP 516 (JDK 26), which is why this chapter measures the cache under G1.
  `-XX:AOTMode=on` makes a cache the JVM cannot use a startup failure, never a silent
  fallback.
- **C++ contrast.** No JIT, no warm-up: a value on the stack costs nothing, `new` per
  parcel costs a call into the allocator, and a `std::pmr::monotonic_buffer_resource`
  turns that call into a pointer bump. The first window of the C++ consumer differs from
  the steady one only by page faults and cold caches.

## Workload

`Tracker.decide(ParcelEvent)` (`tracker.hpp` in C++):

- lane 0 (exception) when the scan confidence is under 900 permille;
- lane 7 (oversize chute) when the longest side exceeds 1,000 mm or the weight 30 kg;
- otherwise lane 1 to 6 by 1 kg weight class;
- a `DivertDecision(lane, deadlineTick)` record: the encoder tick plus 1,200 (1.2 m at
  1,000 pulses per metre).

`Tracker.onParcel` adds the state: a barcode-keyed `HashMap` of the parcels between the
scanner and the diverter, expired by encoder tick (about 480 in flight at 1 kHz).

The line runs are the common simulator at 1 kHz for 20 s (20,000 parcels) on UDP port
47250, through the common receive path (`LineReceiver` in Java, `consume_with` in C++);
the tracker is the handler. Latency is `done - intended_emit`, as in every chapter.

## Variants

Defects carry the `--` prefix in the text; report variant names have no prefix.

| Variant | What it is | Lane |
|---|---|---|
| `escaping` | JMH: the decision is stored in a field, so it stays on the heap | Java |
| `scalar-replaced` | JMH: the decision is read and dropped in the loop, so C2 removes it | Java |
| `--no-escape-analysis` | JMH: `scalar-replaced` in a fork with `-XX:-DoEscapeAnalysis` | Java |
| `--unwarmed` | line run, bind at once: the JIT warms on the first parcels (the r01 behaviour) | Java |
| `warmed` | line run, `--warm-up 20000`: replay 20,000 synthetic parcels in-process before the bind | Java |
| `aot-cache` | line run with `-XX:AOTCache=… -XX:AOTMode=on`, trained for 3 s first | Java |
| value | Google Benchmark: the `Decision` is a stack value | C++ |
| `--allocating` | Google Benchmark: the `Decision` behind `std::make_unique` | C++ |
| pmr | Google Benchmark, observed: same heap object from a `monotonic_buffer_resource` | C++ |
| `tracker` | line run of the C++ consumer, first-window / steady split | C++ |

Every Java line run uses the same JVM arguments, `-XX:+UseG1GC -Xms256m -Xmx256m`; the
variants differ only in warm-up and AOT. JFR (with every compilation, threshold 0, and
every deoptimization), the async unified GC and safepoint log, and the JVM arguments come
from `java_flags` in `_lib/lib.sh`.

## Layout

| Path | Contents |
|---|---|
| `java/` | Maven module `jvm-costs-java`: `Tracker`, `Costs` (the consumer), `WarmUp`, `AllocationBenchmark` (JMH), `JitWindows` (JFR per window) |
| `cpp/` | `lowlat::jvm_costs` (`tracker.hpp`), `jvmcosts-consumer`, `jvmcosts-bench` (Google Benchmark), `jvm-costs-test` |
| `verify.sh` | builds, runs everything, asserts the criteria |

`java -jar java/target/benchmarks.jar` runs JMH; the consumer is
`java -cp java/target/benchmarks.jar io.patterncatalyst.lowlat.jvmcosts.Costs`.

## Run

```bash
examples/05-jvm-costs/verify.sh
```

Environment (from `examples/_lib/lib.sh`): `ALLOW_BUSY=1` to measure while a lab VM runs
or the host is loaded (numbers are noisy; also passes `-Djmh.ignoreLock=true`, which lets
a second JMH harness start), `SKIP_BUILD=1`, `RESULTS_DIR`, `LOWLAT_BUILD`. This example
adds `WINDOW=N` (parcels in the first window, default 2000) and
`RECHECK=results/<run-id>`, which re-evaluates committed reports without running anything.

A run takes about four minutes. Reports and logs land in `results/latest/`:

- `java-<variant>.json`, `-first-2000.json`, `-steady.json` for `unwarmed`, `warmed`,
  `aot-cache`; `cpp-tracker*.json`; each with the `build.flags` it ran with and, for Java,
  `runtime.alloc_bytes_per_parcel`, `runtime.gc` and `runtime.jit` (compilations and
  deoptimizations for `startup`, `first-2000` and `steady`); the `aot-cache` reports also
  carry `runtime.aot`;
- `jmh-alloc.json`, `alloc-per-op.json`, `gbench-alloc.json`: the allocation counters;
- `time-to-ready.json`: the ten launches and their medians;
- `*.gc.log`, `aot-cache.aot.log`, `aot-training-*.log`: the logs. `.jfr` recordings and
  the AOT cache files stay in a scratch directory and are never committed.

View the reports with:

```bash
uv run --project examples lowlat-report show examples/05-jvm-costs/results/latest/*.json
```

The reports whose name ends in `-first-2000` or `-steady` split one run at parcel 2,000;
their counts add up to the whole run's.

## Flags of the Java consumer

| Flag | Default | Meaning |
|---|---|---|
| `--variant` | `unwarmed` | report variant name |
| `--bind HOST:PORT` | `127.0.0.1:47250` | UDP address |
| `--expect N` | none | stop after N parcels (received + dropped) |
| `--window N` | none | also report parcels with `seq < N` and the rest apart |
| `--warm-up N` | 0 | replay N synthetic parcels in this JVM before the bind |
| `--report FILE` | none | write the `lowlat-report/1` JSON (needs `LOWLAT_PROFILE`) |
| `--idle-timeout-ms`, `--rcvbuf`, `--example` | common | as in the other Java consumers |

The program prints `ready:` once the socket is bound; the time-to-ready measurement waits
for that line.

## Expected effect and criteria

`verify.sh` evaluates every criterion, prints a line per criterion with the measured value
and the bound, and exits non-zero if any missed:

1. JMH `-prof gc`: `escaping` allocates at least 24 B per decision (a 12-byte header, an
   `int` and a `long`), `scalar-replaced` at most 1 B, `--no-escape-analysis` at least
   24 B again. C++: `--allocating` at least 16 B and one allocation per parcel, value at
   most 1 B.
2. `--unwarmed`: the first-window p99.9 is at least 5x the steady p99.9 of the same run.
3. `warmed`: the first-window p99 is at most 3x the steady p99 of the same run.
4. `aot-cache`: the median time to ready (JVM launch to a bound socket, five launches
   alternating with the no-cache launches, after one discarded pair that fills the page
   cache) is at most 0.8x the no-cache median, and the AOT log shows the cache opened.
5. Every Java report's `build.flags` carries the JVM arguments the run used, the AOT
   flags for `aot-cache`.
6. Every line run counts 20,000 parcels, drops none, and every report passes
   `lowlat-report check`.

The window is a parameter of criterion 2. The cold cost of an unwarmed JVM is a stall of
about 11 ms at the start, which delays a few dozen parcels: about 1% of a 2,000-parcel
window. The p99 of that window is its 20th-worst parcel, so it sits on the edge of the
stall and lands inside it in some runs and outside it in others (first-window over steady
p99 from 1.7x to 52x across the r02 runs). The p99.9 and the maximum fall inside the stall
every time, so the criterion is asserted on p99.9 and the p99 ratio is printed as observed.
`verify.sh` prints the p99, p99.9 and maximum ratios for every variant.

The AOT cache is trained twice, once with the observation flags (JFR adds the `jdk.jfr`
module, which the cache records, so the line run needs a cache trained with the same
flags) and once without them, for the time-to-ready launches, which start a plain JVM.

### Observed, not asserted

- Compilations and deoptimizations per window (`runtime.jit`): the `warmed` run compiles
  during the replay, before the first parcel; the `--unwarmed` run compiles on the belt.
- Allocated bytes per parcel on the receive thread, protobuf parse included (the number
  Ch8 removes with a flat record).
- The C++ first-window / steady ratio (no JIT).
- The C++ pmr arena: the heap-allocation counter stays at zero.
- The `aot-cache` first-window p99 next to `warmed` and `--unwarmed`.
- With async-profiler 4.6 unpacked under `~/.cache/lowlat` (optional; install it with
  `scripts/deps/install-async-profiler.sh`, user-local and sha256-verified), the allocation
  event's share by leaf frame for the `escaping` benchmark, against JMH's bytes per operation.

## Observation surfaces

JMH `-prof gc` (and `-prof async` when async-profiler is present; `scripts/deps/install-async-profiler.sh`), JFR events
`jdk.Compilation` and `jdk.Deoptimization`, the unified GC log (`-Xlog:gc*,safepoint`),
`-Xlog:aot`, and the `runtime` block of each report. No dashboard panel: Part 7 wires the
off-path telemetry, and there is none by design until then.

## Licences

Every dependency is open source; none sits on a path that needs a paid tier.

| Component | Licence |
|---|---|
| Temurin JDK 25.0.5 (JIT, JFR, AOT cache, G1) | GPL-2.0-only WITH Classpath-exception-2.0 |
| JMH 1.37 (`jmh-core`, annotation processor) | GPL-2.0-only WITH Classpath-exception-2.0 |
| protobuf-java 4.36.2, protobuf C++ 36.2 | BSD-3-Clause |
| HdrHistogram 2.2.2 (Java), HdrHistogram_c 0.12.1 | CC0-1.0 OR BSD-2-Clause |
| Jackson 3.2.4 (`tools.jackson.core:jackson-databind`; reports and `JitWindows`) | Apache-2.0 |
| Google Benchmark 1.10.0 | Apache-2.0 |
| GoogleTest 1.18.0, JUnit 6.1.3 (tests only) | BSD-3-Clause, EPL-2.0 |
| nlohmann/json 3.12.0 | MIT |
| async-profiler 4.6 (optional, observed) | Apache-2.0 |

## Verification status

Unverified until S13: `verify.sh` runs end to end and its reports pass
`lowlat-report check`, but no number is recorded here. The `r02-run1..3` host runs
(bare-metal, untuned, serial, VM down) fill in the measured ranges; a number without its
machine profile (the `profile` block of every report) is not quoted.
