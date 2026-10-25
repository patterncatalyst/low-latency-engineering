---
title: "Benchmark harnesses: Google Benchmark, pyperf and JMH"
order: 4
part: "Understanding & Measuring Latency"
description: "One check-digit function measured with Google Benchmark, pyperf and JMH: repetitions, forks and processes, warm-up, dead-code elimination, and why the result is a percentile view rather than one number."
duration: 40 minutes
---

## Learning objectives

By the end of this chapter you can:

- Explain what repetitions, worker processes and forks each protect a microbenchmark from.
- Write a Google Benchmark, a pyperf and a JMH benchmark for the same function.
- Keep the optimizer from deleting the work with `benchmark::DoNotOptimize` and `Blackhole`, and recognize a benchmark that timed nothing.
- Read a harness report as a median and percentiles, and say what a percentile across repetitions does and doesn't tell you.
- Relate a nanosecond-scale microbenchmark to the scan-to-divert budget.

## Why this matters

On the sortation line the scanner reads the label, the controller decides, and the diverter fires before the parcel passes it. With the scanner 1.2 m upstream and the belt at 2.5 m/s, the whole decision has 480 ms. Part of that decision is validating the SSCC-18 barcode: the GS1 mod-10 check digit over the 17-digit body. The check digit is a few dozen arithmetic operations. Before anyone argues about whether it fits the budget, someone has to time it, and timing something this small is where measurements go wrong.

Under load, a latency is timed per parcel from the belt's schedule and recorded into a histogram. A microbenchmark is a different instrument. It runs a function in a loop, so the compiler, the JIT, the interpreter and the CPU frequency all get a vote. Each harness in this chapter exists to cancel one of those votes: Google Benchmark for C++, JMH for the JVM and pyperf for CPython. Latency is a distribution, and a harness that reports one number has already discarded the distribution, so part of the work here is getting it back out of each tool.

The code is in `examples/04-benchmark-harnesses/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="04-three-harnesses" alt="A check-digit workload fans out to three lanes: Google Benchmark (C++, DoNotOptimize, 30 repetitions) to median and p99, where p99 is the slowest repetition, pyperf (Python, 6 processes, 3 warm-ups each) to median and p99 of 24 values, and JMH SampleTime (Java, 3 forks, warm-up, Blackhole) to p50, p99 and p99.9." caption="Figure 4.1: The same check-digit workload in three harnesses. Each repeats and warms up, and each is read as percentiles rather than a single number." %}

## Concept

A microbenchmark has four enemies, and each harness handles them differently.

**One run is one sample of the machine.** Frequency scaling, a neighbouring process, a cold cache or an unlucky memory layout shift a result by more than the effect being measured. The answer is repetition at the right level. Google Benchmark repeats the whole timed loop (`Repetitions`). pyperf starts fresh worker processes, so each gets its own address-space layout and hash seed. JMH starts fresh JVMs (forks), so each gets its own JIT history. Repeating inside one process or JVM can't reveal variation that lives in the process itself.

**Early iterations aren't representative.** A JVM interprets, then compiles with C1, then with C2. CPython specializes hot bytecode after a few executions. JMH and pyperf both run warm-up iterations first and discard them from the result. A native function has no JIT to warm. Google Benchmark's optional warm-up (`MinWarmUpTime`) isn't set here; each repetition runs for a minimum time instead.

**The optimizer removes work nobody observes.** A pure function whose result is unused has no observable effect, and a compiler is allowed to delete it. The benchmark then times an empty loop and reports a flattering, meaningless number. A harness can't prevent this. It supplies tools (`benchmark::DoNotOptimize`, `benchmark::ClobberMemory`, `Blackhole.consume`) and the benchmark author has to use them.

**One number isn't a result.** Each harness leads with something other than a percentile, and the defaults are the ones to distrust. Google Benchmark's aggregates print a mean first, and pyperf prints `mean +- std dev`. This book never quotes a mean latency, and this chapter doesn't: it reads the median and the tail percentiles that each tool can produce.

Two precision points matter before any number appears. First, Google Benchmark times a loop of iterations and keeps only the per-repetition result. The `p99` statistic in this example is computed across 30 repetitions, so it is the slowest repetition. It measures run-to-run spread. It isn't per-call tail latency, and it can't show a stalled call. Second, JMH `SampleTime` mode does time individual invocations, so its p99 and p99.9 are tail percentiles, with one adjustment: each invocation here checks 1,024 prefixes, because reading the clock around a call of a few nanoseconds would mostly measure the clock. The percentile is therefore over batches, reported per check digit.

## How the code works

The workload is the same in all three languages: the check digit of a fixed set of 1,024 17-digit prefixes, built identically in each. The three implementations agree, and that is tested first by GoogleTest, JUnit and pytest, because a benchmark of a function that is wrong in one language would compare nothing.

### The benchmark definitions

From `cpp/check_digit_bench.cpp`, `benchmarks-py/src/lowlat_bench/bench_check_digit.py` and `java/src/main/java/io/patterncatalyst/lowlat/bench/CheckDigitBenchmark.java`:

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
void BM_CheckDigit_Guarded(benchmark::State& state) {
  // Built at run time and escaped, so the compiler knows neither the values nor the size.
  std::vector<std::string> prefixes = lowlat::bench::make_prefixes(kPrefixCount);
  benchmark::DoNotOptimize(prefixes.data());
  std::size_t i = 0;
  for (auto _ : state) {
    int digit = check_digit(prefixes[i++ & (kPrefixCount - 1)]);
    benchmark::DoNotOptimize(digit);  // non-const lvalue: the const& overload is deprecated
    benchmark::ClobberMemory();  // force pending writes out; nothing may be reordered past here
  }
}

void BM_CheckDigit_Eliminated(benchmark::State& state) {
  // Constant input, result thrown away: nothing observable depends on the work.
  for (auto _ : state) {
    (void)check_digit("00614141000000007");
  }
}

}  // namespace

BENCHMARK(BM_CheckDigit_Guarded)
    ->Repetitions(kRepetitions)
    ->MinTime(0.1)
    ->ComputeStatistics("p99", p99);
BENCHMARK(BM_CheckDigit_Eliminated)
    ->Repetitions(kRepetitions)
    ->MinTime(0.1)
    ->ComputeStatistics("p99", p99);
```

```python
from lowlat_bench.check_digit import PREFIX_COUNT, check_digit, prefixes

PREFIXES = prefixes(PREFIX_COUNT)


def check_all() -> None:
    for p in PREFIXES:
        check_digit(p)


if __name__ == "__main__":
    runner = pyperf.Runner()
    runner.metadata["description"] = f"SSCC-18 check digit over {PREFIX_COUNT} prefixes"
    # inner_loops: each call checks len(PREFIXES) prefixes, so pyperf reports time per check.
    runner.bench_func("check_digit", check_all, inner_loops=len(PREFIXES))
```

```java
@BenchmarkMode(Mode.SampleTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Warmup(iterations = 3, time = 200, timeUnit = TimeUnit.MILLISECONDS)
@Measurement(iterations = 5, time = 300, timeUnit = TimeUnit.MILLISECONDS)
@Fork(3)
@State(Scope.Thread)
public class CheckDigitBenchmark {

    static final int BATCH = 1024;
    private static final String CONSTANT_PREFIX = "00614141000000007";

    // Non-final: the JIT cannot treat the contents as constants.
    private String[] prefixes;

    @Setup
    public void setup() {
        prefixes = CheckDigit.prefixes(BATCH);
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public void guarded(Blackhole bh) {
        for (String prefix : prefixes) {
            bh.consume(CheckDigit.of(prefix));
        }
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    @SuppressWarnings("unused") // the discarded result is the point
    public void eliminated() {
        for (int i = 0; i < BATCH; i++) {
            int digit = CheckDigit.of(CONSTANT_PREFIX);
        }
    }
}
```

**C++.** The Google Benchmark loop `for (auto _ : state)` is the timed region; the library decides how many iterations fit in each repetition. The guarded variant protects the work from both ends. The prefixes are built at run time and `DoNotOptimize(prefixes.data())` makes the pointer opaque, so the compiler can't fold the input to a constant. The index `i++ & (kPrefixCount - 1)` walks 1,024 prefixes with a mask rather than a modulo, which keeps the loop body to the work being measured. `DoNotOptimize(digit)` tells the compiler the result is consumed. The variable is a non-const lvalue because current Google Benchmark deprecates the `const&` overload. `ClobberMemory()` then stops writes from being reordered past that point. The eliminated variant does the opposite: a constant string, a result cast to `void`. `check_digit` is a header-only `constexpr` function so the optimizer can see through it, and with a constant argument and no use, it folds the call away. `Repetitions(30)` produces 30 independent timed runs, `MinTime(0.1)` gives each at least 0.1 s, and `ComputeStatistics("p99", p99)` adds a custom aggregate computed over those 30 values by nearest rank. With 30 samples, rank `ceil(0.99 * 30)` is 30, the worst repetition.

**Python.** There is no eliminated variant, because CPython doesn't remove the call: the interpreter can't prove `check_digit` has no side effect, so it executes it. `bench_func` hands the function to pyperf's runner, which controls processes, warm-up and values through the command line (the next section shows the flags). `inner_loops=len(PREFIXES)` tells pyperf that one call performs 1,024 checks, so every reported figure is time per check digit. Python's contrast is therefore warm-up, which pyperf records next to the measured values.

**Java.** `Mode.SampleTime` samples individual invocations and builds a histogram. `@Warmup` and `@Measurement` set 3 discarded and 5 measured iterations, and `@Fork(3)` runs the whole thing in three fresh JVMs. `@State(Scope.Thread)` with a `@Setup` method builds the prefixes once per thread, and the comment on the field matters: a non-final field isn't a JIT constant. `guarded` passes every result to `Blackhole.consume`, which JMH implements so the JIT must assume the value escapes. `eliminated` computes a digit into a local that nothing reads, from a constant, and C2 deletes the loop body. `@OperationsPerInvocation(BATCH)` divides the invocation time by 1,024, which is why the report is in nanoseconds per check digit.

Where the languages diverge, the divergence is the point. C++ and Java can both eliminate dead code, and each supplies a sink. Python can't, so it needs no sink and needs warm-up handling instead. The three sinks aren't equivalent, and they aren't a contest.

### The harness invocations

Three separate commands from `verify.sh`, each copied verbatim:

```bash
"$(cpp_bin check-digit-bench)" --benchmark_out="$OUT/gbench.json" \
  --benchmark_out_format=json >"$OUT/gbench.console.txt" 2>&1

java -jar "$HERE/java/target/benchmarks.jar" -rf json -rff "$OUT/jmh.json" >"$OUT/jmh.console.txt" 2>&1

pyrun python "$HERE/benchmarks-py/src/lowlat_bench/bench_check_digit.py" \
  -o "$OUT/pyperf.json" --processes 6 --values 4 --warmups 3 >"$OUT/pyperf.console.txt" 2>&1
```

The C++ binary takes its repetition count from the source, so the command only chooses where the JSON goes. The JMH jar is a shaded build with the annotation-processor output, and its fork and iteration counts also come from the annotations. pyperf takes everything on the command line: 6 worker processes, 4 measured values per process and 3 warm-up values each, which gives 24 measured values. The script then reads percentiles out of each JSON instead of trusting the console summary, which is where the mean is printed.

## Measure

Run the example from the repository root:

```bash
examples/04-benchmark-harnesses/verify.sh
```

Set `ALLOW_BUSY=1` on a host that is running other work, and accept noisier numbers. The script builds, runs the parity tests, runs the three harnesses and fails unless the effects below appear.

Profile for every number below: bare-metal host, an 8-core, 16-thread Intel laptop CPU (SMT on, `intel_pstate`), Fedora 44 kernel 7.2 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`. Ranges span the three committed runs `r02-run1` to `r02-run3`.

**C++, Google Benchmark, 30 repetitions.** The guarded median is 4.73 to 4.74 ns per check digit (4.728, 4.730 and 4.737 ns). The custom p99, which is the slowest repetition, is 4.75 to 4.79 ns, within 0.06 ns of the median in every run. The spread measures stability; the worst call is another question.

**Java, JMH SampleTime, 3 forks.** The guarded p50 is 31 to 32 ns per check digit. The tail widens: p99 is 37 to 38 ns, p99.9 is 42 to 52 ns, and the maximum sampled invocation is 92 to 122 ns per check digit. The shape is a tight body and a maximum 2.9 to 3.8 times the median, which is what a distribution looks like and what a single number hides.

**Python, pyperf, 6 processes x 4 values.** `pyperf stats` reports a median of 1.97 to 2.02 us per check digit over 24 values. The 95th percentile is 2.03 to 2.05 us and the maximum is 2.05 us in every run. Runs 1 and 2 had 5 and 4 of 24 values outside pyperf's outlier band, which is narrow at this spread; run 3 had none. Run 1 spanned 2.00 to 2.05 us, runs 2 and 3 1.95 to 2.05 and 1.96 to 2.05 us. The percentiles show that spread where a one-line summary would not.

**Dead-code elimination.** Figure 4.2 shows both variants.

{% include excalidraw.html file="04-dead-code-elimination" alt="C++ and Java lanes each show a guarded variant (DoNotOptimize, Blackhole.consume) with a measured median (4.73 to 4.74 ns in C++, p50 31 to 32 ns in Java) and an eliminated variant whose result is unused and removed, timing about 0 ns, at least 472x lower in C++ and at least 3,100x lower in Java; the Python lane is a ghost box: CPython does not eliminate the work, and the contrast there is warm-up." caption="Figure 4.2: When the result is unused, the compiler or JIT removes the work and the benchmark times nothing." %}

The eliminated C++ median is a fraction of a nanosecond (1.8e-10 ns in all three runs in `gbench.json`), and the Java eliminated p50 is 0 ns. `verify.sh` floors the divisor at 0.01 ns so the ratio stays finite, so the ratios are lower bounds, not measurements of how fast nothing is: at least 472x in C++ (472x, 473x, 473x) and at least 3,100x in Java (3,100x, 3,200x, 3,200x). A tool that reports 0 ns for a function that does 17 multiplications has told you the benchmark is broken, not that the function is free.

**Python warm-up.** The first warm-up value of the calibration run, with a cold interpreter, was 1,894 to 1,917 ns per check, against a median measured value of 1,974 to 2,023 ns. The warm-up value is 5.6, 4.1 and 4.7 % lower than the median in runs 1 to 3, and below the minimum measured value in every run (2,001, 1,951 and 1,959 ns). That first value is one call of 1,024 checks (`loops=1` in `pyperf.json`), and it shows no cold-start penalty.

**The tuning warning.** In all three runs pyperf warned the result may be unstable and advised `pyperf system tune`. The book never tunes the host: governor, turbo and CPU isolation are system changes, made only inside the lab VM. `verify.sh` keeps the warning and records `pyperf system show` read-only. The numbers above are untuned, so they aren't comparable with numbers from a tuned VM.

**Against the budget.** Even the slowest figure here, about 2 us per check digit in CPython, is microsecond-scale against a 480 ms window, so the check digit isn't where the budget goes. A microbenchmark answers a narrow question, how much does this function cost in isolation, and it can't answer how long a parcel waits under load. That needs a timer that starts at the belt's schedule.

## Cross-check

The conversion step in `verify.sh` is an independent computation of the same percentiles. It reloads the raw samples (the 30 repetitions, JMH's `rawDataHistogram`, the 24 pyperf values) and computes p50, p99 and p99.9 itself. For Java the report p50 is 31, 32 and 32 ns, matching the JMH output of each run. For Python the report p50 is 2,023, 1,973 and 2,009 ns against the `pyperf stats` medians of 2.02, 1.97 and 2.01 us. All three agree: the report takes the lower of the middle two of the 24 values and pyperf averages them, and those two differ by at most 6.2 ns. For C++ the report records whole nanoseconds, so the guarded median shows as 5 where the harness says 4.73 to 4.74.

The first re-run showed why the check is worth having. The converter computed every report's percentiles with one rank convention, and a sparse JMH tail came out one bucket apart: the emitted p99.9 was one bucket below the value recomputed from the decoded histogram. The cause is a rank convention that differs between HdrHistogram ports: the C and Python ports round the percentile's rank half up and the Java port rounds it up, so in a sparse tail the two can land one bucket apart. The converter now computes each report's percentiles with the convention of the language the report is labelled with (commit `26a547c`), and a regression test pins the sparse-tail case. When two tools disagree by one bucket in a sparse tail, suspect a convention difference. The GoogleTest, JUnit and pytest parity tests are the second check, confirming that the three benchmarks time the same arithmetic.

## What you learned

- Repetitions, worker processes and forks each reset a different source of run-to-run variation, and a repeat inside one process can't reveal variation that lives in the process.
- `benchmark::DoNotOptimize`, `ClobberMemory` and `Blackhole.consume` give a result an observable use; without one, C++ and Java timed almost nothing, at least 472x and 3,100x faster than the guarded variant.
- CPython doesn't eliminate the call, so the Python contrast is warm-up, which pyperf records and discards.
- Google Benchmark's p99 here is the slowest of 30 repetitions, a view of spread. JMH SampleTime gives tail percentiles over batches.
- Harnesses print a mean by default. Read the median and the percentiles.
- A nanosecond-scale microbenchmark says what a function costs in isolation, not whether the line meets its 480 ms budget.

## For deeper coverage

- Enberg, *Latency* (Manning), for further reading on measuring and reasoning about latency.
- Chapter 1, *Latency vs bandwidth: latency is a distribution*, for why percentiles replace a single number.
- Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*, for measuring under load rather than in a loop.
- Part 5 (*The OS, Isolation & the Network Edge*), for tuning the system that pyperf warns about, in the lab VM.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` runs the GoogleTest, JUnit and pytest parity tests and asserts that the eliminated C++ median is at least 10x below the guarded one, that the eliminated Java p50 is at least 10x below the guarded p50, that the JMH output carries p0.99 and p0.999, and that the pyperf JSON holds at least 20 values from at least 3 worker processes; it also validates six report files. It held on all three runs, `r02-run1` to `r02-run3`.*
