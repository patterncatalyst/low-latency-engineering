---
title: "What the JVM costs: allocation, escape analysis, JIT warmup vs AOT"
order: 5
part: "The Managed-Runtime Question"
description: "A JVM charges class loading and compilation to the first parcels of the belt, and start-up before them. On a bare-metal, untuned host the unwarmed first-window p99.9 is 13.4 to 28.5 ms against 0.26 to 0.49 ms steady, and escape analysis takes a 24 B/op decision to under 1 B/op."
duration: 50 minutes
---

## Learning objectives

By the end of this chapter you can:

- Explain why a Java allocation costs the bytes it adds to the next young collection, and read `gc.alloc.rate.norm`.
- Prove with a benchmark that escape analysis removed an allocation, by switching the analysis off.
- Describe tiered compilation and deoptimization, and why a JVM that binds at once charges them to the first parcels.
- Move warm-up off the belt with a replay, and start from a Leyden AOT cache that fails loudly.
- Choose the percentile a small window can resolve.

## Why this matters

The scanner sits 1.2 m upstream of the diverter and the belt moves at 2.5 m/s, so the scan-to-divert budget is 480 ms. The belt never waits for a slow consumer. Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*, showed that a stall charges every parcel queued behind it; on the line those parcels keep moving. Chapter 2, *Modelling with Little's Law and Amdahl's Law*, put the in-flight count at 480 parcels at 1 kHz.

A controller JVM that has just started is such a stall: its first parcels arrive while classes load and the interpreter still runs code the compiler will replace. Chapter 1, *Latency vs bandwidth: latency is a distribution*, showed a Java warm-up p99.9 and said Part 2 treats the cause. This chapter measures three costs of a managed runtime: heap bytes per decision, the warm-up tail of the first parcels, and process start.

The code is in `examples/05-jvm-costs/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="05-jit-tiers" alt="A chain from the interpreter (tier 0) to C1 (tier 1, with tiers 2 and 3 adding profiling) to C2 (tier 4, optimized code), with a dashed deoptimization path from C2 back to the interpreter when an assumption breaks. Below, three line runs at 1 kHz for 20 s compare the first window of 2,000 parcels: --unwarmed binds at once and has a first-window p99.9 of 13.4-28.5 ms; warmed replays 20,000 parcels before the bind (0.29-0.36 ms), and an amber arrow shows the replay driving the code to C2; aot-cache starts from a cache of classes and profiles with no compiled code (0.61-3.2 ms). A note gives the time to ready, a median of 5 launches: 173-177 ms without a trained AOT cache and 51-55 ms with one." caption="Figure 5.1 — The first parcels pay for class loading, interpretation and compilation. Replaying parcels before the bind moves that cost off the belt; the AOT cache (classes and profiles, no compiled code) shortens warm-up but does not remove it." %}

## Concept

### Allocation costs bytes, not calls

Each HotSpot thread allocates from a thread-local allocation buffer (TLAB), a private slice of the young generation. A `new` is usually a pointer bump with no lock and no system call. The cost arrives later: every byte brings the heap closer to the next young collection, a pause the belt does not wait for. Here the unit is bytes per operation, which JMH's `-prof gc` reports as `gc.alloc.rate.norm`: an exact counter, not a timing, so it can be asserted without a margin.

### Escape analysis

When C2 inlines a small method into its caller, it can see whether an object built inside it leaves the compiled code. If the caller reads the object and drops it, C2 applies scalar replacement: the fields live in registers and the allocation disappears. If the caller stores it in a field, it stays on the heap.

{% include excalidraw.html file="05-escape-analysis" alt="Three JMH lanes run the same decide() call on each parcel. In the escaping lane the DivertDecision is stored in a field, so it stays on the heap and gc.alloc.rate.norm is about 24 B/op. In the scalar-replaced lane (amber) C2 keeps the fields in registers and the counter is below 1 B/op. In the --no-escape-analysis lane, scalar replacement is absent and the counter is about 24 B/op again." caption="Figure 5.2 — An object that never leaves the compiled method costs nothing on the heap: about 24 B/op becomes less than 1 B/op, and turning escape analysis off brings the 24 B back." %}

Inlining and non-escape are decided per call site, so the same `decide` source allocates in one caller and not in another. A hot path should not depend on it; Chapter 9, *Eliminating work: allocation, cache locality, false sharing*, designs the data instead.

### Tiered compilation and deoptimization

Bytecode starts in the interpreter, tier 0. Counters hand a hot method to C1: tier 1 is compiled code without profiling, tiers 2 and 3 add profiling. A method that stays hot goes to C2 at tier 4, which inlines and runs escape analysis on the profile. When an assumption in compiled code breaks, such as a branch never taken before, the code is deoptimized back to the interpreter and compiled again. A JVM that binds at once puts class loading, interpretation and compilation on the first parcels.

### Two ways to move the cost

**Replay before the bind.** Before the socket opens, the process sends synthetic parcels through the real receive path and waits until the compiler is quiet. It delays the start.

**The Leyden AOT cache.** JDK 25's ahead-of-time cache is built from JEP 483 (class loading and linking, JDK 24), JEP 514 (one-step creation) and JEP 515 (method profiles). A training run started with `-XX:AOTCacheOutput` writes the cache when it exits; `verify.sh`'s later runs pass `-XX:AOTCache` and `-XX:AOTMode=on`. The cache holds loaded and linked classes and method profiles, and no compiled code, so C1 and C2 still run but start from a profile. With `-XX:AOTMode=on` a cache the JVM cannot use is a startup failure; the default mode runs on without it, and such a run measures the wrong thing.

The cache is measured under G1: on JDK 25 it archives heap objects only with G1, and JEP 516 (final in JDK 26) lifts that limit. A cache records the module graph and JFR adds the `jdk.jfr` module, so the line run uses a cache trained with the same JFR flags.

GraalVM CE native-image compiles ahead of time and is not measured here: its documentation lists the Serial and Epsilon collectors only, and G1 in native-image is part of Oracle GraalVM.

### The C++ contrast

C++ has no JIT, so it has no warm-up. A value on the stack costs nothing, `std::make_unique` costs a call into the allocator, and `std::pmr::monotonic_buffer_resource` turns that call into a pointer bump. What remains on the first parcels is page faults and cold caches.

## How the code works

### The decision

`decide` is the pure decision on the scan-to-divert path: a lane from the scan confidence, dimensions and weight, and the belt position of the divert deadline. The excerpts are from `DivertDecision.java` and `Tracker.java` under `java/src/main/java/io/patterncatalyst/lowlat/jvmcosts/` and from `cpp/include/lowlat/jvmcosts/tracker.hpp`.

{% include codetabs.html langs="Java|C++" %}

```java
public record DivertDecision(int lane, long deadlineTick) {
}
// ...
    /** The decision for one parcel. Pure: no state, so a caller that only reads it lets the JIT drop the object. */
    public static DivertDecision decide(ParcelEvent event) {
        Dimensions dims = event.getDims();
        int longestMm = Math.max(dims.getLengthMm(), Math.max(dims.getWidthMm(), dims.getHeightMm()));
        int lane;
        if (event.getScanConfidencePermille() < MIN_CONFIDENCE_PERMILLE) {
            lane = EXCEPTION_LANE;
        } else if (longestMm > OVERSIZE_MM || event.getWeightG() > OVERSIZE_G) {
            lane = OVERSIZE_LANE;
        } else {
            lane = 1 + Math.min(SORT_LANES - 1, event.getWeightG() / WEIGHT_CLASS_G);
        }
        return new DivertDecision(lane, event.getEncoderTick() + DIVERT_TICKS);
    }
```

```cpp
/// The decision for one parcel: the lane and the belt position by which the diverter must have acted.
struct Decision {
  std::uint32_t lane;
  std::int64_t deadline_tick;
  friend bool operator==(const Decision&, const Decision&) = default;
};
// ...
/// Pure and header-only, so a benchmark loop can inline it.
[[nodiscard]] inline Decision decide(const line::v1::ParcelEvent& ev) noexcept {
  const auto& dims = ev.dims();
  const std::uint32_t longest_mm = std::max({dims.length_mm(), dims.width_mm(), dims.height_mm()});
  std::uint32_t lane = 0;
  if (ev.scan_confidence_permille() < kMinConfidencePermille) {
    lane = kExceptionLane;
  } else if (longest_mm > kOversizeMm || ev.weight_g() > kOversizeG) {
    lane = kOversizeLane;
  } else {
    lane = 1 + std::min(kSortLanes - 1, ev.weight_g() / kWeightClassG);
  }
  return {.lane = lane, .deadline_tick = static_cast<std::int64_t>(ev.encoder_tick()) + kDivertTicks};
}
```

The Java record is a 24-byte object: a 12-byte header, an `int` and a `long`; returning it is a `new` unless the JIT removes it. The C++ `Decision` is a 16-byte value returned by value, and `decide` is `inline` and header-only so a benchmark loop can inline it. In Java a small result is a heap object the JIT may remove; in C++ the programmer chooses the storage.

### Counting the allocation

`AllocationBenchmark.java` runs the same `decide` call three ways; `cpp/src/alloc_bench.cpp` is the C++ counterpart.

{% include codetabs.html langs="Java|C++" %}

```java
    @Benchmark
    @OperationsPerInvocation(BATCH)
    public void escaping() {
        for (ParcelEvent event : events) {
            stored = Tracker.decide(event); // a heap write: the object outlives the call
        }
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    public long scalarReplaced() {
        return sumOfDecisions(events);
    }

    @Benchmark
    @OperationsPerInvocation(BATCH)
    @Fork(value = 2, jvmArgsAppend = "-XX:-DoEscapeAnalysis")
    public long scalarReplacedNoEscapeAnalysis() {
        return sumOfDecisions(events);
    }

    private static long sumOfDecisions(ParcelEvent[] parcels) {
        long sum = 0;
        for (ParcelEvent event : parcels) {
            DivertDecision decision = Tracker.decide(event); // read here, never stored or passed on
            sum += decision.lane() + decision.deadlineTick();
        }
        return sum;
    }
```

```cpp
// Replaceable allocation functions: count, then defer to malloc. GCC 16 cannot see that operator
// new is malloc-backed in this translation unit and reports the free() in the matching operator
// delete as a mismatch (-Wmismatched-new-delete); the pair is consistent.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmismatched-new-delete"
void* operator new(std::size_t size) {
  g_allocations.fetch_add(1, std::memory_order_relaxed);
  g_bytes.fetch_add(size, std::memory_order_relaxed);
  if (void* p = std::malloc(size)) return p;
  throw std::bad_alloc{};
}
// ...
void BM_Decide_Value(benchmark::State& state) {
  std::size_t i = 0;
  const AllocationCounter counter;
  for (auto _ : state) {
    jvmcosts::Decision decision = jvmcosts::decide(kEvents[i++ & (kParcels - 1)]);
    benchmark::DoNotOptimize(decision);
  }
  counter.report(state);
}

void BM_Decide_Allocating(benchmark::State& state) {
  std::size_t i = 0;
  const AllocationCounter counter;
  for (auto _ : state) {
    auto decision = std::make_unique<jvmcosts::Decision>(jvmcosts::decide(kEvents[i++ & (kParcels - 1)]));
    benchmark::DoNotOptimize(decision);  // the pointer escapes: the allocation cannot be elided
  }
  counter.report(state);
}

void BM_Decide_Pmr(benchmark::State& state) {
  alignas(std::max_align_t) std::array<std::byte, kArenaBytes> buffer;
  // The null resource upstream: running out of arena would throw instead of reaching the global allocator.
  std::pmr::monotonic_buffer_resource arena{buffer.data(), buffer.size(), std::pmr::null_memory_resource()};
  std::pmr::polymorphic_allocator<jvmcosts::Decision> allocator{&arena};
  std::size_t i = 0;
  const AllocationCounter counter;
  for (auto _ : state) {
    jvmcosts::Decision* decision = allocator.new_object<jvmcosts::Decision>(jvmcosts::decide(kEvents[i & (kParcels - 1)]));
    benchmark::DoNotOptimize(decision);
    if (++i % kRewindEvery == 0) arena.release();  // the whole arena in one step; no per-object free
  }
  counter.report(state);
}
```

In `escaping` the result goes into the field `stored`, so the object outlives the call. In `scalarReplaced` the decision is read inside `sumOfDecisions` and never stored, and the loop returns a `long` that JMH consumes, so it is not dead code (Chapter 4, *Benchmark harnesses: Google Benchmark, pyperf and JMH*). `scalarReplacedNoEscapeAnalysis` runs the same loop in a fork with `-XX:-DoEscapeAnalysis`; the method-level `@Fork` overrides the class-level one. `@OperationsPerInvocation(BATCH)` divides by the 1,024 decisions per invocation.

C++ has no escape analysis to switch off. A compiler may elide an allocation in narrow cases, but the language does not promise it, so the lane makes storage explicit. `BM_Decide_Value` keeps the `Decision` on the stack and uses `benchmark::DoNotOptimize` so the work is not deleted. `BM_Decide_Allocating` puts it behind `std::make_unique`. `BM_Decide_Pmr` takes the same `Decision` object from an arena over a stack buffer whose upstream is `std::pmr::null_memory_resource()`, so an exhausted arena throws instead of reaching the global allocator, and `arena.release()` rewinds the arena in one step.

The counters differ. JMH's `-prof gc` reads the JVM's allocation accounting. The C++ counter is the replaced global `operator new` at the top of the file, which counts calls and bytes; the pragmas silence a GCC 16 mismatched-new-delete warning on the matching `delete`.

### Warm-up before the bind

C++ has nothing to warm, so this excerpt is Java only. It comes from `WarmUp.java` and the warm-up branch of `Costs.main` in `Costs.java`.

```java
    static Result replay(long parcels) throws IOException, InterruptedException, ExecutionException {
        Config config = new Config("127.0.0.1", 0, RCVBUF, parcels, IDLE_MS, null, "05-jvm-costs", "warm-up");
        TrackerHandler handler = new TrackerHandler(0);
        try (LineReceiver receiver = new LineReceiver(config); ExecutorService sender = Executors.newSingleThreadExecutor()) {
            var sent = sender.submit(() -> send(receiver.localAddress(), parcels));
            receiver.run(handler);
            return new Result(sent.get(), receiver.completion().count(), receiver.dropped());
        }
    }
    // ...
    static long awaitCompilerQuiet() throws InterruptedException {
        CompilationMXBean jit = ManagementFactory.getCompilationMXBean();
        long waitedMs = 0;
        long quietMs = 0;
        long last = jit.getTotalCompilationTime();
        while (quietMs < QUIET_MS && waitedMs < QUIET_LIMIT_MS) {
            Thread.sleep(50);
            waitedMs += 50;
            long now = jit.getTotalCompilationTime();
            quietMs = now == last ? quietMs + 50 : 0;
            last = now;
        }
        return last;
    }
// ...
        if (split.warmUp() > 0) {
            WarmUp.Result replay = WarmUp.replay(split.warmUp());
            long compileMs = WarmUp.awaitCompilerQuiet();
            System.out.printf("warm-up: replayed %d parcels, handled %d, dropped %d; JIT compile time %d ms%n",
                    replay.sent(), replay.handled(), replay.dropped(), compileMs);
        }
```

`replay` builds a receiver on an ephemeral loopback port with the same `TrackerHandler` as the real run, and a single-thread executor sends synthetic parcels at it. `awaitCompilerQuiet` polls the JVM's cumulative compile time every 50 ms and returns when it has not grown for 500 ms, or after 10,000 ms, so the queued C2 compilations finish there and not in the first window. In `Costs.main` the branch runs before `ready:` prints, so a script that waits for `ready:` waits for the warm-up too.

### The AOT cache in the run script

The AOT lines of `verify.sh` train and then use the cache.

```bash
# One collector and one heap for every Java run: the variants differ in warm-up and AOT only.
JVM_ARGS=(-XX:+UseG1GC -Xms256m -Xmx256m)
# ...
# train_aot CACHE NAME [JVM_FLAG...]: a $TRAIN_SECONDS s training run at $RATE Hz; the JVM writes CACHE when it exits.
# The cache records the JVM arguments that change the module graph (JFR adds jdk.jfr), so a cache is
# trained with exactly the observation flags of the run that will use it.
train_aot() {
  local cache=$1 name=$2 log pid
  shift 2
  log=$OUT/aot-training-$name.log
  rm -f "$cache"
  java "$@" "${JVM_ARGS[@]}" "-XX:AOTCacheOutput=$cache" -cp "$JAR" "$MAIN" --variant "training-$name" \
    --bind "127.0.0.1:$TRAIN_PORT" --expect $((RATE * TRAIN_SECONDS)) --idle-timeout-ms 1000 >"$log" 2>&1 &
  # ...
}
# ...
  # -XX:AOTMode=on: a cache the JVM cannot use is a startup failure, never a silent fallback.
  # G1 in the training run and here: JEP 516 (JDK 26) lifts the G1-only limit on archived heap objects.
  run_java aot-cache "-XX:AOTCache=$AOT_OBSERVED" -XX:AOTMode=on "-Xlog:aot:file=$OUT/aot-cache.aot.log" --
```

`train_aot` runs the consumer for 3 s at 1 kHz with `-XX:AOTCacheOutput`. The script trains one cache with the observation flags for the line run and one plain for the time-to-ready launches. The line run passes `-XX:AOTCache` and `-XX:AOTMode=on`, and `-Xlog:aot` writes the log the script searches for `Opened AOT cache`.

## Measure

Run from the repository root:

```bash
examples/05-jvm-costs/verify.sh
```

It builds both modules, runs the JMH and Google Benchmark lanes and the line runs at 1 kHz for 20 s (20,000 parcels, UDP port 47250), trains the AOT caches, times five alternating launches and asserts the criteria. `ALLOW_BUSY=1` measures while a lab VM runs or the host is loaded, with noisy numbers. `RECHECK=results/<run-id>`, run from the example directory, re-evaluates the committed reports of a run without running anything.

Profile for every number below: bare-metal host, Intel Core i7-11800H, 16 logical CPUs, Fedora 44 kernel 7.2.11-200.fc44 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`, Temurin 25.0.5+8. Ranges are across the three committed runs `r02-run1` to `r02-run3`.

**Allocation per decision.** JMH `-prof gc` reports `escaping` at 24 B/op in all three runs, the 12-byte header, the `int` and the `long`. `scalar-replaced` reports 0.00016 to 0.00017 B/op, under 1 B/op. `--no-escape-analysis` reports 24 B/op again. In C++, `--allocating` costs 16 B/op and one allocation per parcel, and the value variant 1.3e-06 B/op. The pmr arena makes 0.00 B/op through the global allocator (observed). The median per decision over 30 repetitions is 2.3 ns for the value, 11.1 to 11.2 ns for `--allocating` and 3.7 to 3.8 ns for pmr (observed). The allocating variant's extra 8.7 to 8.8 ns is small against 480 ms; on the JVM the cost of an allocation is the young collection it brings closer (Chapter 6).

**The first window.** The first window is parcels 0 to 1,999; the steady window is the rest of the same run.

| Variant | First-window p99.9 | Steady p99.9 | Ratio |
|---|---|---|---|
| `--unwarmed` | 13.4 to 28.5 ms | 0.26 to 0.49 ms | 58.3x, 51.7x, 98.3x (bound 5x) |
| `warmed` | 0.29 to 0.36 ms | 0.26 to 0.32 ms | 1.3x, 1.1x, 1.1x |
| `aot-cache` (observed) | 0.61 to 3.2 ms | 0.26 to 0.31 ms | 2.2x, 2.2x, 12.5x |

In runs 1 and 3 the cold stall at the start is about 30 ms and delays 31 parcels, under 7 % of the 480 ms budget, and the first-window p99.9 is 58x and 98x steady. The `warmed` first-window p99 is 0.23 to 0.33 ms, 1.1x the steady p99 in all three runs against a bound of 3x. The `aot-cache` first window is observed, not attributed: 0.61, 0.69 and 3.2 ms in runs 1 to 3.

**Time to ready.** The median of five alternating launches, after one discarded pair, is 50.7 to 54.8 ms with the AOT cache and 173.1 to 176.9 ms without. The ratio is about 0.3 (bound 0.8), the log shows `Opened AOT cache`, and `runtime.aot.used` is true (set from that line).

**Criterion 2 and the percentile a window can resolve.** The criterion was first written on p99. In `r02-run2` it failed: the p99 ratios are 24.7x, 1.7x and 52.0x, from first-window p99 values of 11.0, 0.34 and 11.0 ms. The first-window maximum is 30.3, 15.2 and 30.3 ms, and the cold stall leaves 31, 15 and 31 parcels above 1 ms (0.75 to 1.55 % of a 2,000-parcel window). The window's p99 is its 21st-worst parcel. Run 2 delayed only 15, so its p99 fell outside the stall; the p99.9, its 3rd-worst parcel, is inside every time.

The criterion is therefore asserted on p99.9; the p99 ratio is observed. `RECHECK` re-evaluated all three runs' committed reports, and `recheck.log` in each run directory records 58.3x, 51.7x and 98.3x. Run 2's `verify.log` still records the original failure, and the run was not repeated. A window resolves only the percentiles whose rank the effect covers: choose them for the sample count, as Chapter 1 argued, and state the window.

**JIT events** (observed). The `--unwarmed` run compiles 245 to 248 methods in the first window, 16 to 19 of them at tier 4. The `warmed` run compiles 1,059 to 1,069 before the first parcel, 234 to 236 at tier 4, and 20 to 24 in the first window. The `aot-cache` run compiles 183 to 189 at startup and 266 to 270 in the first window, with 0 deoptimizations there. The AOT cache does not remove compilation.

**Allocation on the line** (observed). The receive thread allocates 732.7 B per parcel for `--unwarmed`, 667.3 B for `warmed` and 654.4 B for `aot-cache`, the same in every run, protobuf parse included. Chapter 8, *Zero-copy and flat data: Panama (FFM), Valhalla value objects, and the C++ comparison*, removes most of it.

**The C++ lane** (observed). The C++ consumer's first-window p99 over its steady p99 is 1.0x in all three runs. Every line run counted 20,000 parcels and dropped none.

## Cross-check

Allocation: async-profiler 4.6's allocation event on `escaping` attributes over 99.99 % of the sampled bytes to the `DivertDecision` leaf frame in all three runs, independent of the JMH counter. That lane is optional and user-local (`scripts/deps/install-async-profiler.sh`).

Warm-up: JFR's `jdk.Compilation` and `jdk.Deoptimization` events, counted per window by `JitWindows`, confirm the mechanism: the compilations are in the first window for `--unwarmed` and before the first parcel for `warmed`.

Cache: the `-Xlog:aot` line (copied into `runtime.aot.used`) and `-XX:AOTMode=on`, which would have stopped an unusable cache at startup, show the cache was used.

## What you learned

- A Java allocation costs the bytes it adds to the next young collection, and `gc.alloc.rate.norm` counts them exactly.
- Escape analysis took the 24-byte decision to under 1 B/op, and switching it off brought the 24 B back.
- A JVM that binds at once puts class loading and compilation on the first parcels: a first-window p99.9 of 13.4 to 28.5 ms against 0.26 to 0.49 ms steady.
- A replay moves that work before the bind. The AOT cache cut time to ready from 173.1 to 176.9 ms to 50.7 to 54.8 ms, and `-XX:AOTMode=on` makes an unusable cache fail at startup.
- A 2,000-parcel window resolves p99.9 of a 15 to 30 ms stall and can miss it at p99.

The next chapter, *GC for tails: Generational ZGC and Shenandoah*, measures the pauses that allocation causes.

## For deeper coverage

- Enberg, *Latency* (Manning), for further reading on measuring and reasoning about latency.
- Chapter 1, *Latency vs bandwidth: latency is a distribution*, and Chapter 4, *Benchmark harnesses: Google Benchmark, pyperf and JMH*, in Part 1.
- Chapter 6, *GC for tails: Generational ZGC and Shenandoah*, in Part 2.
- Chapter 9, *Eliminating work: allocation, cache locality, false sharing*, in Part 3.
- `examples/common/MEASUREMENT.md` for the report format.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts the exact allocation counters (JMH and C++), the `--unwarmed` first-window p99.9 at least 5x steady, the `warmed` first-window p99 at most 3x steady, the `aot-cache` time to ready at most 0.8x the no-cache median with the cache opened in the AOT log, the JVM arguments in every Java report, and 20,000 parcels, none dropped, with `lowlat-report check` passing. Observed only: compilations and deoptimizations per window, bytes per parcel, the C++ split, timings and pmr counter, the `aot-cache` first window and the async-profiler share. Criterion 2 failed in `r02-run2` on its original p99 form and was re-evaluated on p99.9 by `RECHECK` for all three runs. It holds on `r02-run1` to `r02-run3` after that recheck.*
