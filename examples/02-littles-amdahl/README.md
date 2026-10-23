# 02-littles-amdahl: Little's Law and Amdahl's Law on the line

Two laws that predict a latency system before you measure it, each checked against a run.
Both are modelling tools: a time-average or a time fraction goes in as a labelled input in the
report's `model` block, and a prediction comes out. A latency is never reported as a mean.

```
./verify.sh                 # build, run both experiments in three languages, assert, write reports
ALLOW_BUSY=1 ./verify.sh    # measure although a lab VM is running (noisy; labelled by the profile)
SKIP_BUILD=1 ./verify.sh    # reuse existing builds
```

Reports land in `results/latest/` (or `$RESULTS_DIR`), each with the machine profile.

## A. Little's Law on the line: L = lambda x W

`cpp/src/littles.cpp` and `java/.../LittlesConsumer.java` are consumers of the reference
line-simulator (1 kHz, 10 s). Handling takes a variable service time: exponential, mean 600 us,
capped at 10x the mean, drawn from a seeded generator and spent busy-waiting on the monotonic
clock (CPU work whose length varies, not a sleep that would add timer slack).

- **W per parcel** is `done - intended_emit_ns`, recorded with the measurement kit (variant
  `littles-law`). Its p50/p99/p99.9 are the reported latency.
- **L by sampling**: every 997 us a sampler thread counts the parcels in the system: due by the
  belt's schedule (`arrivals_by`) minus parcels done.
- **`model` block**: `lambda_per_s`, `L_sampled_time_average`, `W_mean_seconds_modelling_input`
  (the one allowed mean), `predicted_L = lambda x W`, `relative_error`, and the warehouse framing.

Criterion: sampled L within 5 % of lambda x W-bar, in C++ and in Java (the managed runtime obeys
the same law), with `count = 10000` and `dropped = 0` (a lost parcel would break the law's
premise).

**Why 997 us, not 1000.** The arrivals are deterministic, one every 1 ms. A sampler on a 1 ms
tick sees the same phase of the arrival cycle every time, just after an arrival, and over-counts
by about half a parcel; a 1 ms sampler did exactly that during development. A period that isn't a divisor of the arrival period lets the phase drift through the
whole cycle, which is the sampling Little's Law assumes.

**The warehouse framing.** The scan-to-divert budget is 480 ms (1.2 m of belt at 2.5 m/s). The
parcels in flight between scanner and diverter at 1 kHz are lambda x W = 1000/s x 0.48 s = **480
parcels**. The same law tells you how many parcels the diverter logic is holding when a slow path
stretches W. verify.sh prints it from the report.

## B. Amdahl's Law: a sort-plan table behind one lock

A fixed batch of parcels (3,200 in C++ and Java, 1,200 in Python) is shared among N workers. Each parcel costs CPU work that
parallelises (`scan_work`), then updates a shared sort-plan table under **one lock** (`update_plan`):
the serial fraction, sized to about 10 %.

- **Measured, not assumed.** An instrumented N = 1 run times every lock section;
  `s = time inside the lock / wall time`, as a ratio of sums over 5 runs.
- **Prediction.** With serial fraction s and parallel fraction p = 1 - s,
  `S(N) = 1 / ((1 - p) + p / N) = 1 / (s + (1 - s) / N)`; S can never exceed 1 / s.
- **Measurement.** 30 repetitions per N, each repetition's wall time recorded with the kit (variant
  `amdahl-n<N>`), repetitions interleaved across N so a change in background load hits all N alike.
  Measured speedup is the ratio of the p50 wall times (HdrHistogram's p50, not a mean). Every
  repetition checks that the table equals the one-worker table: the updates are additions, so the
  result must not depend on N.
- **Effective GHz**: `perf stat -e cycles:u,task-clock` on the example's own process (no root);
  user cycles over task-clock, stored in `model.effective_ghz`. If `perf_event_paranoid` or the PMU
  prevents it, verify.sh records `unavailable (perf_event_paranoid=N)`.

| Language | Workers | Lock | Why |
|---|---|---|---|
| C++ | `std::jthread` | `std::mutex` | The standard facilities; one critical section needs nothing else. |
| Java | platform threads | `synchronized` | The idiomatic critical section for a short non-blocking update; no tryLock, timeout or condition is needed, and since JDK 24 (JEP 491) it no longer pins virtual threads. `ReentrantLock` would add API surface for nothing. Platform threads because the work is CPU-bound: virtual threads exist for blocking I/O. |
| Python threads | `ThreadPoolExecutor` | `threading.Lock` | Shows the GIL. |
| Python processes | `ProcessPoolExecutor` | `multiprocessing.Lock`, shared `multiprocessing.Array` | One interpreter per worker; the table is shared memory. |

Criteria: C++ and Java speedup at N = 4 within +-15 % of the prediction; Python threads < 1.3x
(the GIL serialises the CPU-bound bytecode, however many threads); Python processes > 2x.

### Why waves, and what happens without them

Amdahl's formula assumes the serial part runs alone. A lock doesn't guarantee that: while one
worker is in the lock section the others can be in their parallel part, so the two overlap and the
run beats the formula. The workload therefore runs in **waves**: each worker scans its 160
parcels (60 in Python), all workers meet at a barrier (`std::barrier`, `CyclicBarrier`, `threading.Barrier` /
`multiprocessing.Barrier`), then every worker commits its updates under the lock, and they
meet again. That's the strictly serial structure the formula describes, and it's a fair model of
a wave-picked sortation plan whose next wave depends on the committed table.

`--sync free` (C++ and Java) removes the barriers. verify.sh runs it as an observation, not a
criterion: the same work then lands at 3.5 to 3.6x at N = 4 (r02-run1..3, 3.51 to 3.59x) against a predicted 3.1x, because
the lock sections overlap the other workers' scanning. The bound for a free-running
lock isn't Amdahl's curve but `min(N, 1 / s)`. The lesson for the code: fine-grained locking
buys back part of what Amdahl charges, and it still can't pass 1 / s.

Under phased synchronisation the measured speedup sits under the prediction at N = 4: 8.6 to
9.0 % in C++ and 11.0 to 11.3 % in Java (r02-run1..3): contended lock hand-off, cache-line movement of the shared table and the barriers
are costs the formula doesn't have. Amdahl is an upper bound that is already generous.

### What the Python pair shows

Threads stay under 1x (0.47 to 0.50x at N = 4 in r02-run1..3; the CPU-bound loop holds the GIL,
`build.gil_enabled` is `true` in the report) because every barrier and lock hand-off also pays
GIL hand-off. Processes track the prediction. The prediction for threads covers only the lock; the
GIL isn't in the model, which is the point of the comparison. Free-threaded Python is Appendix E.

## Files

```
cpp/                  CMake targets littles-consumer, amdahl-cpp, ch02-model-test (auto-discovered)
  include/lowlat/ch02/model.hpp   amdahl_speedup, arrivals_by, littles_L
java/                 Maven module littles-amdahl-java (parent: examples/pom.xml)
  .../ch02/Model.java, LittlesConsumer.java, Amdahl.java
amdahl-py/            uv workspace member lowlat-amdahl (console script amdahl-py)
verify.sh             the criteria above
```

The Java kit takes the `model` block through `writeReport(path, notes, model)`; the C++ and Python kits return the report as a JSON object, and the example adds the block before writing.

Ports: UDP 47220 (C++ consumer) and 47221 (Java consumer).

Run one piece by hand:

```
scripts/profile.sh --out /tmp/profile.json && export LOWLAT_PROFILE=/tmp/profile.json
examples/build/release/02-littles-amdahl/cpp/amdahl-cpp --reps 30 --report-dir /tmp/amdahl
java -cp examples/02-littles-amdahl/java/target/littles-amdahl-java.jar \
     io.patterncatalyst.lowlat.ch02.Amdahl --sync free --report-dir /tmp/amdahl
examples/.venv/bin/amdahl-py --modes processes --report-dir /tmp/amdahl
```

## Verification status

Behavioural. `verify.sh` runs both experiments and exits 0 only when every criterion holds:

- A, C++ and Java: `count = 10000`, `dropped = 0`, and sampled L within 5 % of lambda x W-bar.
- B, C++ and Java: speedup at N = 4 within 15 % of the Amdahl prediction from the measured serial
  fraction.
- B, Python: threads under 1.3x at N = 4, processes over 2x.
- The unit tests (C++ model test, Java JUnit, Python pytest) pass, and the reports pass
  `lowlat-report check`.

All of it held on the quiet-host runs `r02-run1..3` (bare-metal host, governor `powersave`, tuned
`balanced`, kernel 7.2, no pinning or isolation; load average at the start 0.34 to
0.55 on 16 CPUs). The values below are ranges over the three runs.

| Criterion | Result (r02-run1..3) |
|---|---|
| A, C++: L within 5 % of lambda x W-bar | PASS: error +0.28 to +0.51 % (L 1.046 to 1.087 against 1.042 to 1.083) |
| A, Java: L within 5 % of lambda x W-bar | PASS: error +1.31 to +4.27 % (L 1.114 to 1.235 against 1.100 to 1.188); r02-run1 at +4.27 % and r02-run2 at +3.95 % are close to the 5 % bound |
| B, C++ N = 4 within 15 % | PASS: s = 0.0951, predicted 3.11x, measured 2.83 to 2.85x (-8.6 to -9.0 %) |
| B, Java N = 4 within 15 % | PASS: s = 0.0984 to 0.0989, predicted 3.08 to 3.09x, measured 2.74 to 2.75x (-11.0 to -11.3 %) |
| B, Python threads < 1.3x | PASS: 0.47 to 0.50x (GIL enabled) |
| B, Python processes > 2x | PASS: 2.92 to 2.97x |
| Effective GHz (user cycles / task-clock) | C++ 4.34 to 4.35, Java 4.35 to 4.36, Python 3.69 to 3.86 (`perf stat`, no root) |

The W-bar in the Little's Law rows is the labelled modelling input in the report's `model` block.
Reported latencies are percentiles.
