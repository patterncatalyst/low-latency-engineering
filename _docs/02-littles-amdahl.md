---
title: "Modelling with Little's Law and Amdahl's Law"
order: 2
part: "Understanding & Measuring Latency"
description: "Two laws predict a latency system before you measure it. Little's Law counts the parcels in flight between scanner and diverter; Amdahl's Law bounds what more workers can buy. Both are checked against runs in C++, Java and Python, including where Python threads fall below 1x."
duration: 50 minutes
---

## Learning objectives

By the end of this chapter you can:

- Apply `L = lambda x W` to a consumer and to the scan-to-divert budget.
- Sample `L` from a running consumer and compare it with `lambda x W-bar`, where `W-bar` is a labelled modelling input.
- Measure a serial fraction `s`, predict the speedup `1 / (s + (1 - s) / N)` and compare it with the speedup measured at N = 1, 2 and 4.
- Build a barrier-phased workload so the serial part is strictly serial.
- Explain why CPU-bound Python threads under the GIL do not speed up and processes do.

## Why this matters

Two questions come before any measurement. How much work is in the system at once? How many workers does a deadline need?

The belt carries a parcel from scanner to diverter in 480 ms: 1.2 m at 2.5 m/s. At 1,000 parcels per second, the parcels in flight number `1000/s x 0.48 s = 480`, predicted from two parameters with no run. The second law answers the capacity question: a batch with a share of it behind one lock, and N workers, give a speedup you can compute before buying cores.

Both laws take a time-average or a time fraction as an input and predict something else. No report here carries a mean as a latency; the laws' inputs sit in a separate `model` block.

The code is in `examples/02-littles-amdahl/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

Every measured number in this chapter carries one profile: bare-metal host, Intel Core i7-11800H, 16 logical CPUs, Fedora 44 kernel 7.2.11-200.fc44 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`.

## Diagram

{% include excalidraw.html file="02-littles-law" alt="The line simulator feeds a consumer band at 1000 parcels/s; the band holds a queue of L parcels and a handler with a variable service time; a sampler counts L and a W-bar box labelled model input takes each parcel's residence time; a result box compares sampled L with lambda x W-bar: C++ +0.2 to +0.6 %, Java +0.7 to +2.0 %." caption="Figure 2.1 — The consumer as a queue. Sampled L matches lambda x W-bar within 0.6 % in C++ and 2.0 % in Java; W-bar is a model input, never a reported latency." %}

## Concept

### Little's Law

For a stable system, the long-run number of items inside equals the arrival rate times the time each item spends inside: `L = lambda x W`. Here `lambda` is parcels per second, `W` is a parcel's residence time from intended emit to handler completion, and `L` counts parcels queued or in service. The law assumes nothing about arrival pattern or service-time distribution, only that nothing is lost inside the system, which is why the run asserts zero drops.

Applied to the belt, it gives the 480 parcels in flight. Applied to a handler, `lambda` times the mean service time is the number of busy workers: the model block reports an offered utilisation of 0.60 from a 600 us service-time parameter. One worker suffices on average, with no slack for the tail Chapter 1 measured.

The check measures `L` and `W` by different mechanisms in one run. `W` is recorded per parcel, so its percentiles are the reported latency. `L` comes from a sampler thread counting parcels in the system at fixed instants, and its time-average is compared with `lambda x W-bar`, where `W-bar` is the time-average of the same per-parcel `W`. `W-bar` is a modelling input, appears only in the `model` block, and is not a latency result. The C++ consumer shows why: `W-bar` is 1.02 to 1.04 ms, p50 is 0.73 to 0.76 ms and p99 is 4.31 to 4.35 ms. The mean is neither the typical parcel nor the tail, yet only the mean ties queue length to rate.

### Amdahl's Law

If a fraction `s` of a one-worker run cannot be parallelised, N workers give

`S(N) = 1 / (s + (1 - s) / N)`

and no number of workers passes `1 / s`. The example measures `s` instead of assuming it: an instrumented one-worker run times every lock section, and `s` is the time inside the lock over the wall time, a ratio of sums over five runs.

A fixed batch of parcels is shared among N workers. Each parcel costs parallel CPU work (`scan_work`), then an addition to a shared sort-plan table under one lock (`update_plan`), the serial part, sized near 10 %.

The formula assumes the serial part runs alone, and a lock does not guarantee that: while one worker holds it, the others can still scan. The workload therefore runs in waves. Each worker scans its parcels, all workers meet at a barrier, every worker commits under the lock, and they meet again. Nobody commits while anyone scans, and nobody scans while anyone commits. That is the structure the formula describes, and it fits a wave-picked sortation plan.

{% include excalidraw.html file="02-amdahl-phases" alt="Three lanes for N = 1, 2 and 4 workers: parallel scan bars shrink as workers are added, a barrier follows, then an amber serial phase of the same width in every lane and a second barrier; a result box lists predicted and measured speedups at N = 4 for C++, Python threads, Python processes and Java." caption="Figure 2.2 — The serial phase does not shrink with N, so the measured speedup at N = 4 (C++ 2.83-2.85x, Java 2.75-2.76x) stays under the Amdahl prediction of about 3.1x; Python threads under the GIL fall below 1x." %}

## How the code works

### The sampler for L

The consumer (`littles.cpp`, `LittlesConsumer.java`) receives the simulator's UDP stream, spins for a drawn service time and marks each parcel done. The sampler counts the parcels due by the belt's schedule minus those done.

{% include codetabs.html langs="C++|Java" %}

```cpp
// Count the parcels in the system at fixed intervals. The interval is 997 us,
// deliberately not a divisor of the 1 ms arrival period: a sampler locked to a
// deterministic arrival stream always sees the same phase (just after an
// arrival) and over-counts by about half a parcel; the drifting phase samples
// every point of the arrival cycle equally, which Little's Law assumes.
// A parcel is in the system when it is due by the schedule
// (arrivals_by) minus done. The sample is taken at the instant the clock is
// read, not at the nominal tick, so a late wake-up cannot skew the pairing.
Sampled sample_in_system(std::stop_token stop, const std::atomic<std::int64_t>& done, std::int64_t t0_ns,
                         const Options& o) {
  Sampled s;
  const std::int64_t end_ns = t0_ns + std::int64_t{o.duration_s} * 1'000'000'000;
  for (std::int64_t tick = t0_ns; tick < end_ns && !stop.stop_requested(); tick += o.sample_us * 1000) {
    if (!sleep_until_ns(tick)) continue;
    const std::int64_t now = monotonic_ns();
    const std::int64_t in_system = lowlat::ch02::arrivals_by(now, t0_ns, o.rate_hz) -
                                   done.load(std::memory_order_acquire);
    s.sum_in_system += in_system;
    s.max_in_system = std::max(s.max_in_system, in_system);
    ++s.samples;
  }
  return s;
}
```

```java
    /**
     * Counts the parcels in the system at fixed intervals: due by the schedule minus done. The
     * interval is 997 us, deliberately not a divisor of the 1 ms arrival period: a sampler locked
     * to a deterministic arrival stream always sees the same phase (just after an arrival) and
     * over-counts by about half a parcel. The sample is taken at the instant the clock is read,
     * not at the nominal tick.
     */
    private static Sampled sample(AtomicLong done, long t0Ns, Options o) {
        Sampled s = new Sampled();
        long endNs = t0Ns + o.durationS() * NS;
        for (long tick = t0Ns; tick < endNs; tick += o.sampleUs() * 1000) {
            long wait = tick - System.nanoTime();
            if (wait > 0) {
                LockSupport.parkNanos(wait);
            }
            long now = System.nanoTime();
            long inSystem = Model.arrivalsBy(now, t0Ns, o.rateHz()) - done.get();
            s.sumInSystem += inSystem;
            s.maxInSystem = Math.max(s.maxInSystem, inSystem);
            s.samples++;
        }
        return s;
    }
```

Python has no counterpart here: Little's Law runs on the C++ and Java consumers, and the Python program covers Amdahl's Law.

`done` is an atomic counter the receive loop increments after each parcel's service time. `arrivals_by` converts the clock into the number of parcels the schedule has released, in integer arithmetic. The difference is the instantaneous `L`. The sample is taken when the clock is read, not at the nominal tick, so a late wake-up cannot pair a stale instant with a fresh count.

Arrivals are deterministic, one every 1 ms, so a sampler on a 1 ms tick sees the same phase each time, just after an arrival, and over-counts by about half a parcel. The 997 us interval does not divide the arrival period, so the phase drifts through the whole cycle. The origin `t0` comes from the first parcel seen, since parcel `seq` is due at `t0 + seq / lambda`.

The service time is drawn from an exponential distribution whose mean is a configured model parameter, 600 us (`--service-mean-us`), capped at ten times that, from a generator seeded with 7. It is spent busy-waiting on the monotonic clock, because a sleep would add timer slack to every parcel. That departs from the idiomatic blocking wait, confined to `serve`.

### The model block

After the run, the consumer reduces both measurements and writes them next to the latency report.

{% include codetabs.html langs="C++|Java" %}

```cpp
  // --- the model block: the only place a mean appears ---------------------
  const double lambda = static_cast<double>(o.rate_hz);
  const double w_mean_s = static_cast<double>(handler.w_sum_ns() / received) / 1e9;
  const double l_sampled = static_cast<double>(sampled.sum_in_system) / static_cast<double>(sampled.samples);
  const double l_predicted = lowlat::ch02::littles_L(lambda, w_mean_s);
  const double rel_err = (l_sampled - l_predicted) / l_predicted;
  const double belt_m = o.belt_mps * o.budget_ms / 1000.0;
  const nlohmann::json model = {
      {"law", "Little: L = lambda * W"},
      {"lambda_per_s", lambda},
      {"L_sampled_time_average", l_sampled},
      {"W_mean_seconds_modelling_input", w_mean_s},
      {"predicted_L", l_predicted},
      {"relative_error", rel_err},
      {"samples", sampled.samples},
      {"sample_interval_us", o.sample_us},
      {"max_in_system", sampled.max_in_system},
      {"service_mean_us", o.service_mean_us},
      {"offered_utilisation", lambda * o.service_mean_us / 1e6},
```

```java
        // --- the model block: the only place a mean appears ---------------------------------
        double lambda = o.rateHz();
        double wMeanS = service.wSumNs / received / 1e9;
        double lSampled = (double) s.sumInSystem / s.samples;
        double lPredicted = Model.littlesL(lambda, wMeanS);
        double relErr = (lSampled - lPredicted) / lPredicted;
        double inFlight = Model.littlesL(lambda, o.budgetMs() / 1000.0);
        double beltM = o.beltMps() * o.budgetMs() / 1000.0;

        Map<String, Object> model = new LinkedHashMap<>();
        model.put("law", "Little: L = lambda * W");
        model.put("lambda_per_s", lambda);
        model.put("L_sampled_time_average", lSampled);
        model.put("W_mean_seconds_modelling_input", wMeanS);
        model.put("predicted_L", lPredicted);
        model.put("relative_error", relErr);
        model.put("samples", s.samples);
        model.put("sample_interval_us", o.sampleUs());
        model.put("max_in_system", s.maxInSystem);
        model.put("service_mean_us", o.serviceMeanUs());
        model.put("offered_utilisation", lambda * o.serviceMeanUs() / 1e6);
```

`w_sum_ns` accumulates every `W`, and its comment states the rule: it feeds the model block only. The block holds `lambda_per_s`, the sampled `L`, `W_mean_seconds_modelling_input`, the prediction and the relative error. The field name carries the label. The warehouse sub-block gives the 480 parcels in flight from the same `littles_L`, with the budget in place of the mean.

All three kits now take the block the same way: the measurement kit's report call accepts an optional `model`, and the kit writes it beside the percentiles. C++ passes a `nlohmann::json`, Python a dict and Java the map. The kit omits the key when no model is given.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
    latency.write_report(o.report,
                         std::format("received={} dropped={} seed={}; W recorded per parcel as done - "
                                     "intended emit time",
                                     received, dropped, o.seed),
                         model);
```

```python
        report = rec.write_report(
            path,
            f"{opts.reps} repetitions after {opts.warmup} warm-up rounds; wall time of the whole "
            "batch (pool already started); repetitions interleaved across N; "
            f"sync={'phased' if opts.phased else 'free'}",
            model,
        )
```

```java
            latency.writeReport(o.report(), ("received=%d dropped=%d seed=%d; W recorded per parcel as done - "
                    + "intended emit time; JIT not warmed").formatted(received, dropped, o.seed()), model);
```

### The phased worker

The worker (`amdahl.cpp`, `work.py`, `Amdahl.java`) is where the serial part becomes strictly serial. All three languages share the same shape: scan a wave's parcels, wait at the barrier, commit them under the lock, wait again.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
// One worker's share of every wave: parcels base+id, base+id+N, ... (K of
// them). Returns ns spent inside the lock when Timed (the clock is read only
// in the calibration runs).
template <bool Timed>
std::int64_t worker(SortPlan& plan, const Options& o, unsigned id, unsigned n, std::barrier<>& wave) {
  std::int64_t in_lock_ns = 0;
  std::vector<std::uint64_t> weight(o.round_parcels);
  for (std::uint64_t base = 0; base < o.batch; base += std::uint64_t{n} * o.round_parcels) {
    for (std::uint64_t j = 0; j < o.round_parcels; ++j) {  // parallel part
      std::uint64_t w = scan_work(base + id + j * n, o.parallel_iters);
      keep(w);
      weight[j] = w;
    }
    if (o.phased) wave.arrive_and_wait();  // nobody commits while anyone is still scanning
    for (const std::uint64_t w : weight) {  // serial part: one lock section per parcel
      std::scoped_lock guard{plan.lock};
      if constexpr (Timed) {
        const std::int64_t t0 = monotonic_ns();
        update_plan(plan, w, o.lock_iters);
        in_lock_ns += monotonic_ns() - t0;
      } else {
        update_plan(plan, w, o.lock_iters);
      }
    }
    if (o.phased) wave.arrive_and_wait();  // nobody scans the next wave while anyone is still committing
  }
  return in_lock_ns;
}
```

```python
def process_share(
    cell: MutableSequence[int],
    lock: AbstractContextManager[object],
    wave: Meeting | None,
    batch: int,
    worker: int,
    workers: int,
    round_parcels: int,
    parallel_iters: int,
    lock_iters: int,
    *,
    timed: bool = False,
) -> int:
    """One worker's share of every wave; returns ns inside the lock when ``timed``.

    A wave is ``round_parcels`` parcels per worker: scan them all (parallel), meet at the barrier,
    commit them all under the lock (serial), meet again. The barriers make the serial part strictly
    serial, which is what Amdahl's formula assumes; ``wave=None`` runs without them.
    """
    in_lock_ns = 0
    span = workers * round_parcels
    for base in range(0, batch, span):
        weights = [
            scan_work(base + worker + j * workers, parallel_iters) for j in range(round_parcels)
        ]
        if wave is not None:
            wave.wait()  # nobody commits while anyone is still scanning
        for weight in weights:
            with lock:
                if timed:
                    t0 = time.perf_counter_ns()
                    update_plan(cell, weight, lock_iters)
                    in_lock_ns += time.perf_counter_ns() - t0
                else:
                    update_plan(cell, weight, lock_iters)
        if wave is not None:
            wave.wait()  # nobody scans the next wave while anyone is still committing
    return in_lock_ns
```

```java
    /**
     * One worker's share of every wave: parcels base+id, base+id+N, ... (K of them). Returns ns
     * inside the lock when timed.
     */
    private static long worker(SortPlan plan, Options o, int id, int n, boolean timed, CyclicBarrier wave) {
        long inLockNs = 0;
        long[] weight = new long[(int) o.roundParcels()];
        for (long base = 0; base < o.batch(); base += n * o.roundParcels()) {
            for (int j = 0; j < weight.length; j++) { // parallel part
                weight[j] = scanWork(base + id + (long) j * n, o.parallelIters());
            }
            if (o.phased()) {
                meet(wave); // nobody commits while anyone is still scanning
            }
            for (long w : weight) { // serial part: one lock section per parcel
                synchronized (plan) {
                    if (timed) {
                        long t0 = System.nanoTime();
                        plan.update(w, o.lockIters());
                        inLockNs += System.nanoTime() - t0;
                    } else {
                        plan.update(w, o.lockIters());
                    }
                }
            }
            if (o.phased()) {
                meet(wave); // nobody scans the next wave while anyone is still committing
            }
        }
        return inLockNs;
    }
```

Worker `id` handles parcels `base + id`, `base + id + N`, and so on, so the workers cover the batch without overlap. Scanned weights go into a local array, which decouples the phases. The first barrier keeps any worker from committing while another scans, and the second keeps the next scan from overlapping a commit. With `phased` off both waits vanish, which is the free-running variant discussed below.

The lock is the idiomatic one in each language. C++ takes a `std::scoped_lock` on a `std::mutex` and waits on `std::barrier`. Java uses a `synchronized` block, the idiomatic critical section for a short non-blocking update, and `CyclicBarrier`; the workers are platform threads because the work is CPU-bound, and virtual threads exist for blocking I/O. Python uses `with lock` and a `threading` or `multiprocessing` barrier.

Two details are specific to this experiment. In C++, `keep(w)` is an empty `asm volatile` that pins the scan result: `scan_work` has no side effects and its result is used only inside the lock, so without `keep` the optimiser may sink the call into the locked region and count parallel work as serial. This is the `DoNotOptimize` idiom of Chapter 4, which application code does not need. And `Timed` (the `timed` flag elsewhere) reads the clock inside the lock only in calibration runs, so timing calls do not enlarge the measured section.

### The serial fraction and the speedup

The driver measures `s` first, then runs the repetitions.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
  // Serial fraction s = time inside the lock / wall time, at N = 1. Ratio of sums
  // over the calibration runs.
  std::int64_t lock_total = 0, wall_total = 0;
  for (int i = 0; i < o.calibration_runs; ++i) {
    const Run r = run_batch<true>(plan, o, 1);
    lock_total += r.in_lock_ns;
    wall_total += r.wall_ns;
  }
  const double s = static_cast<double>(lock_total) / static_cast<double>(wall_total);
  std::println("amdahl-cpp: batch {} parcels, serial fraction s = {:.4f} (time in lock / wall, N=1, {} instrumented runs); "
               "ideal limit 1/s = {:.2f}x",
               o.batch, s, o.calibration_runs, 1.0 / s);
```

```python
        lock_total = wall_total = 0
        for _ in range(opts.calibration_runs):
            wall, in_lock = bench.run(1, timed=True)
            wall_total += wall
            lock_total += in_lock
        s = lock_total / wall_total
        print(
            f"amdahl-py[{mode}]: batch {opts.batch} parcels, serial fraction s = {s:.4f} "
            f"(time in lock / wall, N=1, {opts.calibration_runs} instrumented runs); "
            f"ideal limit 1/s = {1 / s:.2f}x"
        )
```

```java
        // Serial fraction s = time inside the lock / wall time, at N = 1: ratio of sums.
        long lockTotal = 0;
        long wallTotal = 0;
        for (int i = 0; i < o.calibrationRuns(); i++) {
            Run r = runBatch(plan, o, 1, true);
            lockTotal += r.inLockNs();
            wallTotal += r.wallNs();
        }
        double s = (double) lockTotal / wallTotal;
        System.out.printf("amdahl-java: batch %d parcels, serial fraction s = %.4f (time in lock / wall, N=1, "
                + "%d instrumented runs); ideal limit 1/s = %.2fx%n", o.batch(), s, o.calibrationRuns(), 1.0 / s);
```

`s` is a ratio of sums across five runs, so one noisy run does not dominate. Repetitions are interleaved across N, 1, 2, 4, 1, 2, 4 and so on, so a change in background load lands on every N alike. The measured speedup is the ratio of p50 wall times read from the histogram. Every repetition compares the table's checksum with the one-worker table; the updates are additions, so the result must not depend on N, and a mismatch would mean a lost update.

Python runs the program under two executors. `ThreadPoolExecutor` with `threading.Lock` runs threads of one interpreter. `ProcessPoolExecutor` with `multiprocessing.Lock` and a shared `multiprocessing.Array` runs one interpreter per worker. The prediction covers only the lock; the GIL is not in the model, which is the point of running both.

## Measure

Run the example from the repository root:

```bash
examples/02-littles-amdahl/verify.sh
```

The script builds the programs, runs both experiments, asserts the criteria and writes the reports. `ALLOW_BUSY=1` measures although a lab VM is running; `SKIP_BUILD=1` reuses builds.

The 1-minute load average at the start was 0.17 to 0.35. Ranges are across the three runs, `r02-run1` to `r02-run3`.

### A. Little's Law

Each consumer received 10,000 parcels at 1,000 per second over 10 s with none dropped. The sampler took 10,031 samples.

| Consumer | Sampled L | W-bar (model input) | Error of L vs lambda x W-bar | Max in system |
|---|---|---|---|---|
| C++ | 1.021 to 1.045 | 1.015 to 1.043 ms | +0.2 to +0.6 % | 11 |
| Java | 1.096 to 1.109 | 1.078 to 1.092 ms | +0.7 to +2.0 % | 21 to 23 |

Both sit inside the 5 % criterion. Offered load is 0.60 of one worker, so the queue is usually short and occasionally holds a burst. Java's error is larger and its tail longer: its p99.9 for `W` is 16.9 to 18.7 ms against 8.4 ms in C++. The Java run does not warm the JIT first; one untested hypothesis is that compilation and collection pauses stretch a burst's residence.

The report's warehouse sub-block gives the same 480 parcels in flight on 1.20 m of belt. A slow path that stretches `W` grows that count in proportion.

### B. Amdahl's Law

| | s | 1/s | N = 2 predicted / measured | N = 4 predicted / measured |
|---|---|---|---|---|
| C++ | 0.095 | 10.5x | 1.83x / 1.77 to 1.78x | 3.11x / 2.83 to 2.85x |
| Java | 0.099 | 10.1x | 1.82x / 1.76x | 3.09x / 2.75 to 2.76x |
| Python processes | 0.104 to 0.105 | 9.5 to 9.6x | 1.81x / 1.73 to 1.80x | 3.04 to 3.05x / 2.92 to 2.94x |
| Python threads | 0.099 to 0.100 | 10.0 to 10.1x | 1.82x / 0.96 to 0.98x | 3.08x / 0.52 to 0.69x |

The N = 1 wall p50 for C++ was 78.4 to 78.7 ms and for Java 78.9 to 79.1 ms. At N = 4 it fell to 27.6 to 27.7 ms in C++ and 28.6 to 28.8 ms in Java.

The C++ and Java speedups at N = 4 sit 9 to 11 % under the prediction (C++ -8.5 to -9.1 %, Java -10.7 to -11.0 %), inside the 15 % criterion. For sizing, the formula is optimistic: a worker count taken from `S(N)` under-provisions by about a tenth.

Two costs are candidates. Each wave ends when the slowest worker reaches the barrier, and the contended lock moves the table's cache lines between cores. The formula has no term for either, and these runs did not isolate how much of the gap they explain. A further hypothesis is frequency: the governor is `powersave` on a host that boosts to 4.6 GHz, and the effective clock (user cycles over task-clock from `perf stat`) was 4.33 to 4.34 GHz for C++, 4.35 to 4.36 for Java and 3.82 to 3.90 for Python. Those figures cover each whole process: they show the cores ran above the 2.30 GHz base clock, not whether the clock fell as more cores woke at N = 4. The workers were not pinned, so scheduler placement is a third unmeasured candidate.

Python threads stay near 1x at N = 2 and fall to 0.52 to 0.69x at N = 4. The CPU-bound loop holds the GIL (`build.gil_enabled` is `true` in the reports, CPython 3.14.8), so the interpreter runs one thread at a time. The fall below 1x is consistent with each barrier and lock hand-off also paying a GIL hand-off, a hypothesis the run does not isolate. Processes track the prediction, 2.92 to 2.94x against a predicted 3.04 to 3.05x. The gap between the predicted 3.08x for threads and the measured 0.52 to 0.69x is the GIL, which Amdahl's Law does not know about. Free-threaded CPython is Appendix E.

### An observation: the free-running lock

`--sync free` removes the barriers in C++ and Java and changes nothing else. The same work ran at 3.56 to 3.60x at N = 4 in C++ and 3.52 to 3.57x in Java, over the predicted 3.08 to 3.11x, with 10 repetitions per N. Lock sections can then overlap other workers' scanning; the runs are consistent with that account and do not test it. The bound for a free-running lock is not Amdahl's curve but `min(N, 1/s)`: fine-grained locking buys back part of what Amdahl charges, and cannot pass `1/s`.

## Cross-check

For Little's Law, `L` and `W` come from a sampler thread and a per-parcel clock read, so agreement within a few per cent confirms both. For Amdahl's Law, every repetition at every N reproduces the one-worker checksum, so the speedups compare equal work, and `perf stat -e cycles:u,task-clock` gives the effective GHz independently of the program's clocks. The Python threads run is a negative control: it misses the prediction widely because a mechanism outside the model is active.

## What you learned

- Little's Law sizes work in flight: 480 parcels between scanner and diverter. On the consumer, sampled `L` matched `lambda x W-bar` within +0.3 to +1.6 % in C++ and +2.4 to +3.6 % in Java.
- `W-bar` and the serial fraction are modelling inputs in a labelled `model` block; latencies stay percentiles.
- Amdahl's Law bounds speedup at `1/s`. With `s` near 0.1, N = 4 predicts about 3.1x and the phased runs measured 2.75 to 2.85x in C++ and Java. Size workers from measured speedup, not the formula.
- A free-running lock measured above the formula, 3.52 to 3.60x, with lock sections overlapping other workers' scanning as the likely cause.
- CPU-bound Python threads fall to 0.52 to 0.69x at N = 4 under the GIL; processes reached 2.92 to 2.94x.

Chapter 3 returns to measurement itself: clocks, percentiles and coordinated omission.

## For deeper coverage

- Enberg, *Latency* (Manning), as further reading on latency and its measurement.
- Chapter 1, *Latency vs bandwidth: latency is a distribution*, in Part 1.
- Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*, in Part 1: the clocks behind `W`.
- Chapter 4, *Benchmark harnesses: Google Benchmark, pyperf and JMH*, in Part 1: the idiom behind `keep`.
- Appendix E, *Free-threaded Python vs the GIL*.
- Part 5: the governor behind the effective clock.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts, for the C++ and Java consumers, 10,000 parcels received with none dropped and sampled `L` within 5 % of `lambda x W-bar`. It asserts that the C++ and Java speedups at N = 4 are within 15 % of the prediction, that Python threads stay under 1.3x (the reports record the GIL enabled), that Python processes exceed 2x, and that every N reproduces the one-worker table (the programs exit non-zero on a checksum mismatch). It validates the report files. All of it held on the three runs, `r02-run1` to `r02-run3`.*
