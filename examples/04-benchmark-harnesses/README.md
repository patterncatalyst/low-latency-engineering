# 04-benchmark-harnesses

Chapter 4 example: three benchmark harnesses on one small function, and what each does
to keep the measurement valid. The function is the GS1 mod-10 check digit of an SSCC-18
(the same algorithm as `common/line-simulator`), run over a fixed set of 1,024 17-digit
prefixes that all three languages build identically.

| Language | Harness | What it shows |
|---|---|---|
| C++ | Google Benchmark v1.10.0 | `Guarded` vs `Eliminated`: a pure function with a constant input and a discarded result is folded away |
| Java | JMH 1.37, `Mode.SampleTime` | `guarded` (state input, `Blackhole`) vs `eliminated` (local, dropped): C2 removes dead code |
| Python | pyperf 2.10.0 | CPython has no dead-code elimination, so the contrast is warm-up: pyperf keeps its warm-up values next to the measured ones |

## Run

```
examples/04-benchmark-harnesses/verify.sh          # ALLOW_BUSY=1 on a busy host
```

`verify.sh` builds, runs the parity tests, runs the three harnesses, converts their
samples to `lowlat-report/1` files, checks them, and exits non-zero unless:

- C++: the eliminated median is at least 10x lower than the guarded median;
- Java: the eliminated p50 is at least 10x lower than the guarded p50, and the JMH output
  includes p0.99 and p0.999;
- Python: the pyperf JSON holds at least 20 values from at least 3 worker processes.

An eliminated loop can time as 0.000 ns, so the divisor is floored at 0.01 ns. The ratio
is then a lower bound, not a measurement of how fast nothing is.

Raw harness output (`gbench.json`, `jmh.json`, `pyperf.json`), console text, the
machine profile and the `report-*.json` files land in `results/latest/`.

## Files

| Path | Purpose |
|---|---|
| `cpp/check_digit.hpp` | header-only check digit (inlinable, so the optimizer can see through it) |
| `cpp/check_digit_bench.cpp` | the two benchmarks, 30 repetitions, `ComputeStatistics("p99", ...)` |
| `cpp/check_digit_test.cpp` | GoogleTest parity against `lowlat::line::sscc_check_digit` |
| `java/pom.xml`, `java/src/...` | JMH archetype layout: `jmh-generator-annprocess`, shade plugin, `target/benchmarks.jar` |
| `benchmarks-py/` | uv workspace member: `check_digit.py`, `bench_check_digit.py` (pyperf), `to_report.py` (harness JSON to lowlat report), tests |
| `verify.sh` | build, test, run, convert, check, assert |

Build only: `cmake --preset release && cmake --build --preset release --target check-digit-bench`
(from `examples/`), `mvn -f examples/04-benchmark-harnesses/java/pom.xml package`,
`uv sync --package lowlat-bench-harnesses`.

## What each harness reports by default

None of them leads with a percentile.

- **Google Benchmark** prints one line per repetition and then aggregates: mean, median,
  stddev, cv. The mean comes first and is the wrong number to quote. The benchmark adds a
  custom `p99` statistic with `ComputeStatistics`. It is computed across the 30 repetitions
  (nearest rank), so with 30 samples it is the worst repetition: a view of run-to-run
  spread, not of per-call tail latency. Google Benchmark times a loop of iterations and does
  not keep per-iteration times, so the lowlat report holds one sample per repetition.
- **JMH SampleTime** times individual invocations and prints p0.00, p0.50, p0.90, p0.95,
  p0.99, p0.999, p0.9999 and p1.00 beside a mean score. The percentiles are the result.
  Each invocation checks 1,024 prefixes (`@OperationsPerInvocation`), because SampleTime
  reads the clock around every invocation and a call of a few nanoseconds would mostly
  measure the clock. The JSON carries `rawDataHistogram`, (value, count) pairs in ns per
  operation, which the converter loads into the lowlat histogram.
- **pyperf** prints `mean +- std dev`. `pyperf stats` gives the median, MAD and the 0th to
  100th percentiles; `verify.sh` prints that view. The JSON holds every measured value of
  every worker process and, per run, the warm-up values.

## The optimizer trap

`BM_CheckDigit_Eliminated` and the Java `eliminated` benchmark time an empty loop: the
check digit is a pure function, nothing reads the result, so the compiler (clang) and the
JIT (C2) remove it. A harness cannot stop that; the benchmark has to give the result a
use. `benchmark::DoNotOptimize`, `ClobberMemory` and `Blackhole` exist for that, and the
`Guarded` and `guarded` variants use them. The inputs matter as much: the guarded variants
read prefixes from a container the compiler cannot see through.

## Python: warm-up, not elimination

CPython does not remove the call. What it does is specialize hot bytecode after a few
executions, which is why pyperf runs warm-up values first, discards them from the result and
records them. For this function the effect is small: pyperf's own output reports
`2^16 (64 outer-loops x 1024 inner-loops)` loop iterations per value, so each value covers 64
calls of the 1,024-prefix function and the interpreter is warm before the first value
finishes. The first warm-up of the calibration run (a cold interpreter) was 1,912 to 1,991 ns
per check digit and the median measured value 1,977 to 1,989 ns across r02-run1..3: 3.0 and 3.3
percent lower in runs 2 and 3, 0.4 percent higher in run 1, and below the minimum measured value in runs 2 and 3 (minimum 1,973 and 1,952 ns, first warm-up 1,929 and 1,912 ns) but not in run 1 (minimum 1,966 ns, first warm-up 1,991 ns). `verify.sh` prints both. A function with a
long first call would show more.

## Host state and the pyperf warning

Numbers here are host bare metal, untuned: governor `powersave`, tuned profile `balanced`,
turbo on (recorded in `profile.json` and in every report). pyperf prints "the benchmark
result may be unstable" and advises `pyperf system tune`. The warning stays.
Tuning the system (governor, turbo, CPU isolation) changes the host, which this repository
does not do; it is taught in Part 5, inside the lab VM. `pyperf system show` is read-only and
its output is saved as `pyperf.system-show.txt`.

## Report conversion

| Harness | Samples in the lowlat report |
|---|---|
| Google Benchmark | 30 per benchmark: real time per iteration of each repetition |
| JMH | every sampled invocation, from `rawDataHistogram` (ns per check digit) |
| pyperf | 24 measured values (6 processes x 4), and the 31 warm-up values (13 from the calibration run, 3 per worker process) as a separate variant |

Reports are whole nanoseconds, the report unit. A value under 0.5 ns is recorded as 0, which
for the eliminated variants is the point. The `lowlat-report show` table prints microseconds
with one decimal and so shows 0.0 for the C++ and Java rows; `verify.sh` also prints the
nanosecond values.

## Verification status

Behavioural. `verify.sh` builds, runs the check-digit parity tests (GoogleTest, JUnit during
`package`, pytest), runs the three harnesses and asserts: the C++ eliminated median is at least
10x lower than the guarded median; the Java eliminated p50 is at least 10x lower than the
guarded p50 and the JMH console and JSON include p0.99 and p0.999; the pyperf JSON holds at
least 20 values from at least 3 worker processes; the six converted reports pass
`lowlat-report check` with the profile embedded.

All of it held on the quiet-host runs `r02-run1..3` (bare-metal host, governor `powersave`,
tuned `balanced`, kernel 7.2.11-200.fc44, untuned; pyperf printed its unstable-system warning).
Ranges over the three runs:

| Harness | Result |
|---|---|
| Google Benchmark (C++) | guarded median 4.73 to 4.76 ns per check digit; eliminated median below 0.5 ns (0 ns in the report); ratio 473 to 476x (divisor floored at 0.01 ns, so a lower bound) |
| JMH SampleTime (Java) | guarded p50 32 ns; eliminated p50 0 ns; ratio 3,200x (floored) |
| pyperf (Python) | 24 values from 6 worker processes; 64 outer loops x 1,024 inner loops per value; report p50 of the measured values 1,977 to 1,988 ns |

## Licences

Google Benchmark: Apache-2.0. JMH: GPL-2.0 with Classpath exception. pyperf: MIT.
Versions are pinned in `_plans/dependency-pins.md`.
