---
title: "Latency vs bandwidth: latency is a distribution"
order: 1
part: "Understanding & Measuring Latency"
description: "Equal throughput can hide a 100x difference in median latency, and one slow parcel in a hundred moves p99 by an order of magnitude while the median stays put. Measure the distribution, never one number."
duration: 45 minutes
---

## Learning objectives

By the end of this chapter you can:

- Explain why throughput and latency answer different questions, using a per-parcel and a batch-of-32 consumer at the same 1 kHz.
- Read p50, p90, p99, p99.9 and max from a report, and say what each one is for.
- Build a bimodal workload with a calibrated busy loop and show that the median stays in the fast mode while p99 lands in the slow mode.
- Tie the scan-to-divert budget to a tail percentile instead of the median.
- Check a claim within one run, because a median on an untuned host moves between runs.

## Why this matters

A parcel passes the barcode scanner and the controller has until the parcel reaches the diverter to pick a lane. The belt does not wait: at the line's speed the budget is `1.2 m / 2.5 m/s = 480 ms`, minus encoder jitter and actuation time. A parcel whose decision arrives after the diverter has fired goes down the wrong lane. A controller that is fast for most parcels and slow for a few is a controller that mis-sorts those few.

That makes "how fast is it?" incomplete in two ways. A design can raise the parcels handled per second while making each parcel wait longer. A handler can also be fast for 99 parcels and slow for the hundredth, and any one summary number then describes neither group.

The code is in `examples/01-latency-distribution/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="01-batch-vs-per-parcel" alt="Two lanes of parcels arriving at 1 kHz: the per-parcel lane handles each parcel on arrival, with p50 74-186 us; the batch lane gathers parcels 1 to 32 into one handling step, and an amber arrow marks the first parcel's ~31 ms wait, with p50 15.2-16.1 ms." caption="Figure 1.1 — Batching leaves throughput unchanged but moves the p50 from 74-186 us to 15.2-16.1 ms, because the first parcel waits for 31 others." %}

## Concept

**Latency** is the time one parcel spends between its intended emission and the moment the consumer finishes handling it. **Bandwidth**, or throughput, is how many parcels per second the consumer completes. They are separate quantities, and a design choice can move one without touching the other.

Batching is the standard example. A consumer that collects 32 parcels and handles them together amortises per-call overhead, which is why batching is the usual throughput optimisation. At 1 kHz the 32nd parcel arrives 31 ms after the first. The first parcel therefore waits 31 ms before any handling starts. The batch variant completes parcels at the same rate as the per-parcel variant, yet the typical parcel is about 100 times later.

The second effect is a bimodal workload. One parcel in 100 is a scanner no-read, the barcode could not be decoded, and the controller runs a slower re-lookup that takes about 2 ms. The other 99 take the fast path. The median sits inside the large fast population. The slow path delays every parcel that arrives behind it while the core is busy, so p99 sits in the slow one.

{% include excalidraw.html file="01-bimodal-tail" alt="Parcels 98 to 104 in a row, with parcel 100 drawn wide as an amber ~2 ms slow path that holds the core and parcel 101 queued behind it; p50 points to a fast-mode box (p50 94-190 us) and p99 to a slow-mode box (p99 2.5-6.3 ms), and a ghost box says one summary number describes neither group." caption="Figure 1.2 — The median stays in the fast mode while p99 lands in the slow mode, among the slow parcel and those queued behind it. One summary number describes neither group." %}

### Percentiles

Each report carries a distribution, summarised by five points:

| Point | Meaning | What it answers |
|---|---|---|
| p50 | half the parcels were faster | the typical parcel |
| p90 | 9 in 10 were faster | the shoulder of the distribution |
| p99 | 99 in 100 were faster | the tail that one parcel in a hundred reaches |
| p99.9 | 999 in 1,000 were faster | the rare outliers |
| max | the slowest parcel | the worst case in this run |

A run of 10,000 parcels puts only 100 parcels above p99, 10 above p99.9 and exactly one at the max. The deeper the percentile, the fewer samples stand behind it, so the max is a single observation. Chapter 3 returns to how many samples a percentile needs.

### Why the report never carries a mean

A mean collapses a distribution into one value. In the bimodal workload it would fall between the two modes, describe neither group, and move whenever the slow fraction moved. Every report in this book therefore holds percentiles and a maximum. A time-average appears only in Chapter 2, labelled as a modelling input for Little's Law.

### The budget is a tail requirement

The scan-to-divert deadline applies to every parcel. A median well inside the budget says nothing about the parcels past it. The requirement has the form "p99.9 of scan-to-divert is below the deadline minus margin", and the percentile is set by how many mis-sorts the operation tolerates. At 1 kHz, one parcel in 1,000 is one mis-sort per second. The median is a health indicator and a poor requirement.

## How the code works

Each language has one executable with three variants selected by `--variant`: `per-parcel`, `batch-32` and `bimodal-1pct`. The consumer binds a UDP socket, receives a `ParcelEvent`, handles it according to the variant, and records `done - intended_emit` for each parcel. The simulator stamps `intended_emit_ns` with the scheduled emission time, so a late send does not hide a late handling.

### Why the consumers copy the receive loop

The shared `line-consumer` has no hook between "received" and "done", and `common/` is not edited from a chapter example. Each language therefore copies the minimal receive loop (bound UDP socket, parse, sequence tracking, `done_ns - intended_emit_ns`) and adds the handling policy. The lane lookup reuses the common code where it is public: `line::lane_for` in C++, and `lowlat_consumer.handle` and `GapTracker` in Python. Java has its own copy because the common `Lanes` class is package-private.

### The handlers

The handler is the part that differs between variants. The listings below are the dispatch inside each receive loop: `examples/01-latency-distribution/cpp/src/latdist.cpp`, `latdist-py/src/lowlat_latdist/cli.py` and `java/src/main/java/io/patterncatalyst/lowlat/latdist/Latdist.java`.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
      if (o.policy == Policy::batch) {
        pending.push_back({ev.intended_emit_ns(), ev.barcode()});
        if (pending.size() >= o.batch) flush();
      } else {
        lane_sink += line::lane_for(ev.barcode());
        if (o.policy == Policy::bimodal && ev.seq() % o.slow_every == 0) {
          lane_sink += static_cast<unsigned>(spin(slow_iterations));  // the re-lookup: real CPU work
          ++slow_count;
        }
        finish_parcel(ev.intended_emit_ns(), monotonic_ns(), ev.seq());
      }
```

```python
            if batched:
                pending.append((event.intended_emit_ns, event.barcode))
                if len(pending) >= BATCH:
                    flush()
            else:
                lane_for(event.barcode)
                if args.variant == "bimodal-1pct" and event.seq % SLOW_EVERY == 0:
                    spin(slow_iterations)  # the re-lookup: real CPU work, not a sleep
                    slow_count += 1
                finish([event.intended_emit_ns], now())
```

```java
                if (batched) {
                    pending.add(new Pending(ev.getIntendedEmitNs(), ev.getBarcode()));
                    if (pending.size() >= BATCH) {
                        for (Pending p : pending) {
                            laneSink += lane(p.barcode());
                        }
                        long done = System.nanoTime(); // one completion time for the whole batch
                        for (Pending p : pending) {
                            rec.record(checked(done - p.intendedNs()));
                        }
                        if (doneCount == 0) {
                            firstDone = done;
                        }
                        lastDone = done;
                        doneCount += pending.size();
                        pending.clear();
                    }
                } else {
                    laneSink += lane(ev.getBarcode());
                    if (bimodal && ev.getSeq() % SLOW_EVERY == 0) {
                        laneSink += BusyWork.spin(slowIterations); // the re-lookup: real CPU work
                        slowCount++;
                    }
                    long done = System.nanoTime();
                    rec.record(checked(done - ev.getIntendedEmitNs()));
                    if (doneCount++ == 0) {
                        firstDone = done;
                    }
                    lastDone = done;
                }
```

The per-parcel path is the `else` branch without the slow check: the lane lookup, then one clock read and one recorded latency. The clock is read after the work, so the latency includes the handling.

The batch path only stores `intended_emit_ns` and the barcode. When the 32nd parcel arrives, `flush` runs the lane lookup for all 32 and reads the clock once, so the whole batch shares one completion time. The first parcel's latency is therefore its 31 ms wait plus the handling, which is what Figure 1.1 shows. C++ and Python put the batch completion in a `flush` helper that is also called after the loop, so a partial last batch is still handled. Java repeats the same steps inline, which is why its listing is longer; it runs them again after the loop for the partial batch.

The bimodal path is the per-parcel path plus one test, `seq % 100 == 0`. The sequence number is deterministic, so exactly 100 of 10,000 parcels are slow and every run is comparable. The slow branch calls `spin` before the completion clock is read, so the slow parcel's latency includes its re-lookup, and the parcels that arrive during the spin sit in the socket buffer until the loop returns. Those queued parcels are why more than 1 % of parcels are slow in latency terms.

In C++ and Java the lane lookup result is added to `lane_sink` (`laneSink`) and printed at the end of the run, because an optimiser can remove a lookup whose result nothing reads. CPython runs the call regardless, so Python discards the result.

### The calibrated busy loop

The slow path, in `cpp/src/latdist.cpp`, `latdist-py/src/lowlat_latdist/work.py` and `java/src/main/java/io/patterncatalyst/lowlat/latdist/BusyWork.java`, is a busy CPU loop, not a sleep. A sleep yields the core: the scheduler runs something else, the timer wakes the thread later, and the cost shows up as scheduler noise instead of work. A real re-lookup holds the core, so the parcels behind it queue, and the loop reproduces that.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
std::uint64_t spin(std::uint64_t iterations) noexcept {
  std::uint64_t x = 0x9e3779b97f4a7c15ULL;
  for (std::uint64_t i = 0; i < iterations; ++i) {
    x = x * 6364136223846793005ULL + 1442695040888963407ULL;
    asm volatile("" : "+r"(x));
  }
  return x;
}

// Iterations of spin() that take `target_us`. Double the count until a run lasts at
// least 20 ms (long enough to swamp the clock read), then time five more runs and keep
// the fastest: a run that was preempted on a busy host measures the scheduler, not the loop.
std::uint64_t calibrate(std::int64_t target_us) {
  std::uint64_t n = 1 << 12;
  double best_iter_per_ns = 0;
  for (int extra = 0; extra < 5;) {
    const auto t0 = monotonic_ns();
    (void)spin(n);
    const auto took_ns = monotonic_ns() - t0;
    best_iter_per_ns = std::max(best_iter_per_ns, static_cast<double>(n) / static_cast<double>(took_ns));
    if (took_ns < 20'000'000) n *= 2;
    else ++extra;
  }
  return static_cast<std::uint64_t>(best_iter_per_ns * static_cast<double>(target_us) * 1000.0);
}
```

```python
_MASK = (1 << 64) - 1


def spin(iterations: int) -> int:
    """A dependent multiply-add chain: each step needs the previous result."""
    x = 0x9E3779B97F4A7C15
    for _ in range(iterations):
        x = (x * 6364136223846793005 + 1442695040888963407) & _MASK
    return x


def calibrate(target_us: int) -> int:
    """Iterations of ``spin`` taking ``target_us``.

    Double the count until a run lasts 20 ms, then time five more runs and keep the
    fastest: a run preempted on a busy host measures the scheduler, not the loop.
    """
    n = 1 << 12
    best = 0.0  # iterations per ns
    extra = 0
    while extra < 5:
        t0 = time.monotonic_ns()
        spin(n)
        took = time.monotonic_ns() - t0
        best = max(best, n / took)
        if took < 20_000_000:
            n *= 2
        else:
            extra += 1
    return int(best * target_us * 1000)
```

```java
    /** Written by every {@link #spin}; the volatile store makes the loop's result observable to the JIT. */
    private static volatile long sink;

    private BusyWork() {
    }

    /** A dependent multiply-add chain: each step needs the previous result. */
    static long spin(long iterations) {
        long x = 0x9E3779B97F4A7C15L;
        for (long i = 0; i < iterations; i++) {
            x = x * 6364136223846793005L + 1442695040888963407L;
        }
        sink = x;
        return x;
    }

    /**
     * Iterations of {@link #spin} that take {@code targetUs}. Doubles the count until a run lasts
     * 20 ms, then times eight more runs and keeps the fastest: the early runs are interpreted or
     * C1-compiled (the JIT's C2 code is faster), and a run preempted on a busy host measures the
     * scheduler, not the loop.
     */
    static long calibrate(long targetUs) {
        long n = 1 << 12;
        double best = 0; // iterations per ns
        for (int extra = 0; extra < 8;) {
            long t0 = System.nanoTime();
            spin(n);
            long tookNs = System.nanoTime() - t0;
            best = Math.max(best, (double) n / tookNs);
            if (tookNs < 20_000_000L) {
                n *= 2;
            } else {
                extra++;
            }
        }
        return (long) (best * targetUs * 1000);
    }
```

`spin` is a dependent multiply-add chain. Each step needs the previous result, so the CPU cannot vectorise it and the compiler cannot fold it into a closed form.

Keeping the result observable differs by language, and that is the one place the three diverge. C++ uses an empty `asm volatile("" : "+r"(x))` statement, which tells the compiler the register is read and modified, so the loop must run. Java writes the final value to a `volatile` field, which the JIT must honour. Python needs neither, because the interpreter runs every iteration; the `& _MASK` mask keeps the integer at 64 bits so each step costs the same.

`calibrate` finds the iteration count that takes `target_us`. It doubles `n` until one run lasts 20 ms, long enough that the two clock reads are negligible, then times further runs and keeps the highest iterations-per-nanosecond rate. The best rate is kept because a preempted run measures the scheduler, and the fastest run is closest to the loop's own speed. Java takes eight extra runs where C++ and Python take five, because its first runs are interpreted or compiled by the C1 compiler and the optimised C2 code is faster. The result is multiplied by the target in nanoseconds to give the iteration count.

After calibration the program times the loop once and writes the result to the report's `notes` as `slow_path_us`. That measured value, not the 2,000 us target, is what the verification compares against. Two values are fixed: the 2,000 us default of `--slow-us` and the one-in-100 constant `SLOW_EVERY`. A real no-read rate varies; the example teaches the shape.

## Measure

Run the example from the repository root:

```bash
examples/01-latency-distribution/verify.sh
```

It builds all three consumers, runs each of the three variants at 1 kHz for 10 s (10,000 parcels), writes nine reports and asserts the criteria. `examples/01-latency-distribution/README.md` lists the flags and the environment variables, including `ALLOW_BUSY=1` for a loaded host.

All numbers below come from the committed runs `r01-run1..3` in `examples/01-latency-distribution/results/`. Profile: bare-metal host, Intel Core i7-11800H, 16 logical CPUs, Fedora 44 kernel 7.2.11-200.fc44 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`. Ranges are the minimum and maximum across the three runs and the three languages.

### A. Equal throughput, different median

Processed throughput stays at about 1,000 parcels per second in every variant: per-parcel runs measure 1,000.1 to 1,003.3 per second and batch-32 runs 1,003.1 to 1,004.1. The C++ and Python batch figures are about 0.3 % above their per-parcel ones because the first completion falls 31 ms into the run, which shortens the measured span; the criterion allows 1 %.

| Variant | p50 across runs and languages |
|---|---|
| per-parcel | 74 to 186 us |
| batch-32 | 15.2 to 16.1 ms |

The batch median is about 100 times the per-parcel median. The batch p99 is 31.2 ms in all nine batch runs, the fill wait plus handling. Throughput asks at what rate parcels leave; the median asks when each parcel leaves. Batching answers the first well and the second badly.

### B. One parcel in a hundred

In the bimodal runs the calibrated slow path measured 2.0 to 2.1 ms (`slow_path_us` 1,999.6 to 2,107.0). The medians stayed in the fast mode, 94 to 190 us. The tail did not: p99 was 2.5 to 6.3 ms, and 2.9 to 5.0 % of bimodal parcels took 1 ms or more, although only 1 % ran the slow path. The extra parcels arrived during a 2 ms spin and waited behind it.

The C++ bimodal rows of `r01-run1`, as printed by `verify.log`, show the shape:

| p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|
| 153.7 us | 171.1 us | 4,382.7 us | 6,045.7 us | 6,664.2 us |

p50 and p90 differ by 17 us, p90 and p99 by more than 4 ms. p99.9 and max extend past the slow-path length because of queueing.

The Java runs show a second tail effect. Their notes record `JIT not warmed: first parcels included`, and per-parcel p99.9 reaches 8.6 to 22.3 ms in `java-per-parcel` while C++ stays below 0.5 ms. Part 2 treats that runtime cause; here p99.9 exposed it and p50 did not.

### The median itself moved

The per-parcel median is not a constant of the code. On this untuned host it changed between runs of the same binary: C++ per-parcel p50 was 157 us in `r01-run1`, 74 us in `r01-run2` and 80 us in `r01-run3`. Nothing in the program or the stream changed between those runs. The host runs governor `powersave` and tuned profile `balanced`, so the kernel chooses CPU frequency and idle state at run time. The median shifted by a factor of two; the data do not isolate which setting caused it, because the reports record no frequency or idle-state counters. Part 5 covers tuning the frequency governor and idle states as versioned configuration, and measures its effect.

That variation decides how a check is written. A check that requires the bimodal median to stay under twice the per-parcel median of a separate run fails on this host: the live `r01-run2` was evaluated that way, and its `verify.log` records the failure ("got 158335, need < 147838"), because the C++ per-parcel run landed at 74 us and the bimodal run at 158 us. Both medians were in the fast mode, far below the 2 ms slow path; the check compared two measurements taken at different times on an untuned host.

`verify.sh` therefore compares within one run: the bimodal p50 must be under a quarter of the same run's measured `slow_path_us`, so the median falls in the fast mode. `RECHECK=results/<run-id>` re-evaluates a committed run without running anything, and `recheck.log` in each of `r01-run1..3` records all 12 criteria passing, including the C++ bimodal check in `r01-run2` that had failed.

## Cross-check

Each criterion in `verify.sh` pairs the percentiles with an independent measurement. Throughput comes from the span between the first and last completion timestamps, not from the latency percentiles. The slow-path duration comes from timing the calibrated loop directly, not from the latency histogram. Agreement across three languages in all three runs shows the effect belongs to the handling policy and not to one runtime.

## What you learned

- Throughput and latency are separate. Batching 32 parcels at 1 kHz left throughput within 1 % and moved the median from 74 to 186 us up to 15.2 to 16.1 ms.
- A mixed workload has no single latency. With one slow parcel in 100, p50 stayed at 94 to 190 us and p99 reached 2.5 to 6.3 ms, and 2.9 to 5.0 % of parcels took 1 ms or more because of queueing behind the slow ones.
- Report p50, p90, p99, p99.9 and max, never a mean, and tie the scan-to-divert requirement to a tail percentile.
- Simulate a slow path with a calibrated busy loop, not a sleep, so the parcels behind it queue as they would behind real work. Keep the loop's result observable so the optimiser does not remove it.
- A median is not stable on an untuned host. Compare quantities within one run, and record the governor and tuned profile with every number.

Chapter 2 models these effects with Little's Law and Amdahl's Law.

## For deeper coverage

- Enberg, *Latency* (Manning), as further reading.
- Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*, in Part 1: how many samples a percentile needs and how a slow consumer hides its own slow samples.
- Chapter 2 in Part 1: Little's Law and Amdahl's Law as modelling inputs.
- Chapter 5 in Part 2: the JIT warm-up tail seen in the Java runs.
- Part 5: the CPU governor, idle states and tuned profiles behind the median's movement.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` runs all nine consumer runs and asserts `count` 10,000, `dropped` 0 and a passing `lowlat-report check` for every report, and, for each of C++, Python and Java: per-parcel and batch-32 throughput within 1 %; batch-32 p50 at least 10x per-parcel p50; bimodal-1pct p99 at least 20x its own p50; bimodal-1pct p50 under a quarter of the same run's measured slow path. `RECHECK` evaluated these criteria on the committed reports of `r01-run1..3`, and all 12 held in each run (`recheck.log`). The live runs used the earlier cross-run median check, which failed in `r01-run2` as described above.*
