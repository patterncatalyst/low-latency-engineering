# 10-lockfree-waitfree

Chapter 10: waiting, and who has to do it. Ch9 took work out of the in-flight parcel tracker's data; this chapter takes
waiting out of its coordination. Four tunnel cameras claim slots in one log. Two induction stations race for one belt
gap. The diverter reads parcel state while the tracker writes it. Each is a synchronisation question with a blocking, a
lock-free and a wait-free answer, and the guarantee belongs to an operation, not to a structure.

C++ leads each technique, because the topic is what the hardware does. Java and Python follow with the same technique in
their own idiom. Where one has no equivalent, the divergence is the lesson.

## Technique

- **(a) Progress guarantees on a multi-producer claim.** Four producers take the next sequence number of one log.
  `mutex` blocks: a producer that holds the lock and gets descheduled stops the other three. `cas-loop` is lock-free:
  some producer always completes, but one can lose the race again and again. `fetch-add` is wait-free: one
  instruction (`lock xadd` on x86-64) and every producer finishes in one step. On a load-linked/store-conditional machine
  `fetch_add` and `getAndIncrement` are retry loops, so "wait-free" depends on the platform.
  The log makes the point that the guarantee belongs to the operation. Claiming a slot and publishing it are two steps; a
  producer that stalls between them (`--stalled-producer` sleeps 1 ms there) blocks the consumer of a log whose claim is
  wait-free. The claim is monotonic and 64 bits wide, so a number is never reused: there's no ABA to defend against and
  nothing to reclaim. A structure that recycles nodes needs hazard pointers or epochs in C++; the collector does that
  work in Java. C++26's `<hazard_pointer>` and `<rcu>` aren't shipped by GCC 16.2 or Clang 22.1 (the feature macros are
  undefined), so they're prose only.
- **(b) Memory orders in full.** The induction-gap test: each of two stations raises "claiming the gap" (a store) and
  then reads the other's flag (a load). Both reading 0 means both induct into one gap. Release/acquire allows it on
  x86-64, because a store waits in the store buffer while the same core's next load runs; `seq_cst` forbids it, and
  the `seq_cst` store compiles to `xchg`. In Java the same pair is `VarHandle.setRelease`/`getAcquire` against
  `volatile`, tested with jcstress.
- **(c) The read side.** The diverter and the HMI read a parcel-state snapshot while the tracker updates it at 1 MHz.
  `shared-mutex` makes readers and the writer take turns. `seqlock` lets the writer ignore the readers: a reader copies
  the fields and keeps the copy only if the sequence number was even and didn't change. In C++ a seqlock over plain
  fields is a data race, and that's undefined behaviour even when the reader throws the copy away. So the fields are
  `std::atomic_ref<std::uint64_t>` accessed relaxed, with acquire and release fences around them. In Java the idiom is
  `StampedLock.tryOptimisticRead`, the JDK's own seqlock.

Where the code leaves the ordinary idiom, it says why. The busy-spinning consumer and the pinned threads exist to expose
the mechanism; they aren't advice for general code.

## Workload

- **(a) Claim.** Four producer threads x 1,000,000 claims into a 1,048,576-slot log (a ring: a producer never writes
  more than a ring ahead of the consumer), one consumer reading in order, five distinct physical cores. Each producer
  times its own claim (the clock read, the claim, the clock read) into its own HdrHistogram, counts its steps, CAS
  failures and the largest retry count of one claim, and sets `claimed[seq]` in a byte map that only the claimer
  writes. The map is read after `join()`, so the exactly-once check has no race of its own; the consumer checks every
  payload. Voluntary context switches come from `/proc/thread-self/status` before and after the loop.
- **(b) Litmus.** 10,000,000 trials, two threads on distinct cores, a spin barrier per trial. The flags are reset by their
  owners after both threads finish a trial, and each result is written by its own thread into its own array.
- **(c) Read side.** One writer updates an 8-word snapshot (the last word is a checksum) every microsecond, open loop; three
  readers spin on it; 2 s. A snapshot whose checksum doesn't match is torn. The writer's time inside `write()` is the
  distribution.
- **Line.** Four simulator instances at 2.5 kHz x 20 s each (four tunnel cameras, 200,000 parcels) to UDP 47300-47303
  (`mutex`, `blocking-queue`) and 47304-47307 (`fetch-add`, `agrona-mpsc`). One receive thread per camera publishes into
  the multi-producer hand-off; one tracker thread reads it, decides the lane and sends the divert command on a separate
  UDP socket to the diverter. The command path shares no queue with the data path: a flood of scans can't sit ahead of a
  command. The line simulator and the shared consumers are unchanged. The example runs four instances of the
  simulator instead.

Placement is unprivileged `sched_setaffinity` on our own benchmark threads (`pthread_setaffinity_np`, OpenHFT
`Affinity.setAffinity`, `os.sched_setaffinity`) on CPUs from `distinct_cores` in `examples/_lib/lib.sh`: one logical CPU per
physical core, chosen from sysfs topology. `verify.sh` asks for six cores and drops the first, so the pinned threads
start at the second physical core, leaving CPU 0 out as example 09 does. All three
languages receive the same list through `--cpus`. It's an experiment control, and it doesn't isolate the cores from the
scheduler or the timer tick; isolation is Part 5. Every run records `runtime.placement`, and `verify.sh`
checks each pinned thread's last CPU in `/proc/<pid>/task/<tid>/stat` while the run holds at its start gate.

The start gate has two lines of handshake, printed by the C++, Java and Python gates alike. Each pinned thread pins
itself and waits. The coordinator prints one `pinned pid=P tid=T cpu=C role=R` line per thread and `placement-ready`,
and holds for 500 ms (`--hold-ms`) while `verify.sh` checks the pins in `/proc`. It then prints `released` and lets the
threads go. The line run starts its simulators on `released`, not on a bound port: the receivers bind before the hold
ends, and simulators started at that point would have parcels waiting in the socket buffer for the rest of the hold,
which shows up as a start-up stall in the percentiles. (`verify.sh` still waits for the ports too.)

## Variants

| Language | Variant | What it is |
|---|---|---|
| C++, Java | `mutex` | `std::mutex` / `ReentrantLock` around a counter (blocking) |
| C++, Java | `cas-loop` | `compare_exchange_weak` / `AtomicLong.compareAndSet` in a loop (lock-free) |
| C++, Java | `fetch-add` | `fetch_add` / `getAndIncrement` (wait-free on x86-64) |
| C++, Java | `--stalled-producer` | the producer that claims the middle sequence sleeps 1 ms before it publishes |
| C++ | `release-acquire`, `seq-cst` | the induction-gap test with each order; also the per-store cost (Google Benchmark) |
| Java | `release-acquire`, `seq-cst` | per-store cost of `setRelease` against `setVolatile` (JMH, observed); the litmus test itself is jcstress |
| C++ | `shared-mutex`, `seqlock` | `std::shared_mutex` against the `atomic_ref` seqlock |
| Java | `rw-lock`, `stamped-lock` | `ReentrantReadWriteLock` against `StampedLock.tryOptimisticRead` |
| C++ line | `mutex`, `fetch-add` | the claim in the hand-off between cameras and tracker |
| Java line | `blocking-queue`, `agrona-mpsc` | `ArrayBlockingQueue` against Agrona's `ManyToOneConcurrentArrayQueue` |
| Python | `lock`, `itertools-count` | `threading.Lock` against `next()` on one shared `itertools.count` |
| Python | `--racy-claim` | the lock removed: `seq = n; n += 1`. The report's variant stays `lock`; its `racy_claim` counter is 1 (0 in every other report) |

### C++

`SequenceClaim` is a concept over three small classes (`claim.hpp`); the multi-producer log (`claim_log.hpp`) is a ring of
slots, each a stamp and a payload, published with a release store and read with an acquire load. Threads are
`std::jthread`s, started together through `std::barrier`; the litmus test is in `litmus.hpp`; the seqlock and the
shared-mutex cell are in `seqlock.hpp`. The store-cost benchmark (`store_bench.cpp`) stores to an atomic with external
linkage: a local atomic that nothing reads is deleted by clang at `-O2`, and the loops measure nothing. `lockfree-test` runs the exactly-once, torn-read and forbidden-outcome checks, and runs
under ThreadSanitizer too (see below).

### Java

`SequenceClaim` is a sealed interface with `Locked`, `CasLoop` and `FetchAdd`; `ClaimLog` publishes with
`AtomicLongArray.setRelease`. The padded counters use class inheritance for their padding, as the common `Completion`
does, because `@Contended` is JDK-internal and needs `-XX:-RestrictContended`. Pinning uses OpenHFT
`Affinity.setAffinity(cpu)` rather than `AffinityLock`: the lock picks a CPU from its own inventory, and the harness has
already chosen the list (from the second physical core up) that the C++ and Python lanes use too. The claim run does a discarded warm-up pass on the same code first, so a JIT
compilation's safepoint isn't counted as a context switch of the claim being measured; the line run warms the same way
with synthetic parcels on ephemeral ports. Agrona 2.7 reaches `Unsafe` through `jdk.internal.misc`, which needs
`--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED`; `verify.sh` passes it.

The per-store benchmark (`StoreBenchmark`, JMH) runs with `-XX:LoopUnrollLimit=1`. With C2's default unrolling the
volatile store looked like 1.2 ns, because C2 kept one fence for four unrolled stores (`mem_inst_retired.lock_loads:u`
read 0.25 per store). Unrolling off, the counter reads 1.00 per store and the volatile store costs about 4 ns, the
same instruction cost as C++'s `xchg`.

The litmus tests are two jcstress classes, `StoreBufferVolatile` (`0, 0` is `FORBIDDEN`) and `StoreBufferAcquireRelease`
(`0, 0` is `ACCEPTABLE_INTERESTING`). `verify.sh` runs them in quick mode with `-t 'io.patterncatalyst.lowlat.lockfree.StoreBuffer.*'`
and passes `-jvmArgsPrepend --enable-native-access=ALL-UNNAMED`. It keeps the `RUN RESULTS` text, scrubbed, as
`java-jcstress-summary.txt`; the HTML report and `jcstress-results-*.bin.gz` stay out of the tree (ignored). Never call
the runner with `-h`. JMH and jcstress-core need different jopt-simple versions, the module manages 5.0.4, and the
help formatter fails with a `NoSuchMethodError`; running tests is unaffected. jcstress isn't a CI gate, because it takes
tens of seconds and the allowed outcome is nondeterministic. CI runs the deterministic tests only (exactly-once, no
torn snapshot, `seq-cst` forbids `0, 0` in C++ at 200,000 trials).

### Python

CPython has no public atomics API, and under the GIL its threads don't run in parallel. So the lane is the claim only, with no
memory-order test and no seqlock. It runs under two builds, recorded as `runtime.python_build`: the default GIL build
and the free-threaded `3.14.8+freethreaded` (a user-local `uv python install 3.14t`). The same code shows the
difference. A lost claim is rare under the GIL (the interpreter switches threads every 5 ms, `sys.getswitchinterval()`) and
by the thousand without it. `itertools.count` isn't documented as thread-safe, and the free-threading howto says threads sharing an iterator may
see duplicate or missing elements. The lane reports what it saw and asserts nothing.

The measuring process mustn't import `lowlat_measure`. Its `pyhdrh` extension doesn't declare free-threading support, so
importing it turns the GIL back on, and the run would measure a free-threaded interpreter that has a GIL.
`sync-py measure` imports nothing from it and refuses to run, or to finish, with the GIL on in a free-threaded
build. It writes raw samples; `sync-py report` converts them to a `lowlat-report/1` file in the GIL workspace
environment and takes `runtime.python_build` from the raw file, not from itself. Appendix E keeps the full
free-threading treatment.

## Layout

| Path | Contents |
|---|---|
| `cpp/` | library `lowlat::lockfree`; executables `lockfree-bench` (`claim`, `litmus`, `seqlock`), `lockfree-line`, `lockfree-store-bench`; `lockfree-test` |
| `java/` | Maven module `lockfree-waitfree-java`: `benchmarks.jar` (JMH main class, tools via `-cp ... Main`) and `lockfree-waitfree-java-1.0.0-SNAPSHOT-jcstress.jar` |
| `sync-py/` | Python package `lowlat_sync`, console script `sync-py`, uv workspace member `lowlat-sync` |
| `verify.sh` | runs everything and asserts the criteria |

## Run

```bash
examples/10-lockfree-waitfree/verify.sh
```

Environment (from `examples/_lib/lib.sh`): `ALLOW_BUSY=1`, `SKIP_BUILD=1`, `RESULTS_DIR`, `LOWLAT_BUILD`; also
`SKIP_JCSTRESS=1` and `RECHECK=results/<run-id>` (evaluate the criteria on committed reports; the placement checks need a
live run). A full run takes about 4 minutes, a clean build included, and the jcstress step uses every CPU.

The Python lane under each build, by hand, from `examples/`:

```bash
# GIL build (the default workspace environment)
uv run sync-py measure --variant lock --cpus 1,2,3,4 --out /tmp/claim-gil
uv run sync-py report /tmp/claim-gil --out /tmp/python-gil-lock.json

# free-threaded build: a separate environment, .venv-ft (ignored by git)
UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft uv run --python 3.14t --package lowlat-sync \
    sync-py measure --variant lock --racy-claim --cpus 1,2,3,4 --out /tmp/claim-ft
uv run sync-py report /tmp/claim-ft --out /tmp/python-free-threaded-lock-racy-claim.json   # reporting stays in the GIL build

# unit tests under both builds
uv run pytest 10-lockfree-waitfree/sync-py
LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft \
    uv run --python 3.14t --all-packages pytest 10-lockfree-waitfree/sync-py
```

The C++ and Java programs by hand (CPUs from `distinct_cores 6` in `lib.sh`, without the first; `LOWLAT_PROFILE` from `scripts/profile.sh --out`):

```bash
build=examples/build/release/10-lockfree-waitfree/cpp
$build/lockfree-bench claim --variant fetch-add --stalled-producer --cpus 1,2,3,4,5 --report /tmp/fa.json
$build/lockfree-bench litmus --variant seq-cst --trials 10000000 --cpus 1,2 --report /tmp/seqcst.json
java --enable-native-access=ALL-UNNAMED -cp examples/10-lockfree-waitfree/java/target/benchmarks.jar \
    io.patterncatalyst.lowlat.lockfree.Main seqlock --variant stamped-lock --cpus 1,2,3,4 --report /tmp/sl.json
```

Under ThreadSanitizer. The `sanitize` preset is AddressSanitizer plus UndefinedBehaviorSanitizer, which can't be
combined with ThreadSanitizer, so the thread build overrides the preset's list:

```bash
cmake --preset sanitize -B examples/build/tsan -DLOWLAT_SANITIZE=thread
cmake --build examples/build/tsan --target lockfree-test && examples/build/tsan/10-lockfree-waitfree/cpp/lockfree-test
```

ThreadSanitizer doesn't model `std::atomic_thread_fence`, and a scratch seqlock over plain fields wasn't flagged by it.
So the race-freedom of `Seqlock` comes from its atomic accesses, which you can read in the code, not from the
sanitizer's silence.

Reports land in `results/latest/`: `cpp-<variant>-alt<N>.json` and `java-<variant>-alt<N>.json` for the claims (with
`-consumer-wait` beside them), `*-cell-*` for the read side, `cpp-litmus-*`, `*-line-*` (aggregate, `-camera0..3`,
`-divert`), `python/`, the Google Benchmark and JMH conversions under `cpp/` and `java/`, the jcstress summary and the
machine profile.

## Expected effect and criteria

`verify.sh` evaluates every criterion, prints its measured value, bound and margin, and exits non-zero if any failed.
Latency ratios compare variants within one run, alternating A B C A B C A B C and taking the median of the three
per-alternation ratios; a p50 is never compared across runs. Counters marked exact are deterministic. The bounds are
those of the S7 calibration (`_plans/r03-plan.md`, Follow-ups).

1. **Exactly once (exact).** In every synchronised variant, each sequence 0..N-1 is claimed exactly once: C++ and Java
   `mutex`, `cas-loop`, `fetch-add`, Python `lock` in both builds. Python `--racy-claim` under the free-threaded build
   loses or duplicates at least 1.
2. **Steps and contention.** `fetch-add` takes exactly 1 step per claim (exact); `cas-loop` fails at least 1 CAS in
   total (exact count, contention present); voluntary context switches are counted per producer thread: the
   least-switching `mutex` producer has at least 100 and the most-switching `fetch-add` producer at most 10 (median of 3
   runs; `producer_voluntary_ctx_min` and `producer_voluntary_ctx_max` in the report). C++ and Java.
3. **Claim tail.** `mutex` claim p99 is at least 2.5x `fetch-add`'s in C++ and at least 3x in Java, median of 3
   alternations. C++ ran 5.8x to 7.9x across calibration runs, so 2.5x keeps a 2x margin; Java ran 13x to 16x. The p99.9
   ratio is observed, not asserted. `cas-loop` against `fetch-add` is observed: lock-free is not faster, and wait-free bounds steps, not time.
4. **Stalled producer.** With a 1 ms sleep between claim and publish, the consumer waits at least 0.5 ms at that
   sequence in the `fetch-add` log. The sleep guarantees at least 1 ms, so the 2x margin is by construction.
5. **Litmus (exact).** C++ `seq-cst` and Java `volatile` read `0, 0` zero times (the model forbids it); C++
   `release-acquire` and Java `setRelease`/`getAcquire` read `0, 0` at least once.
6. **Read side.** Torn snapshots 0 in every variant (exact). Writer p99 `seqlock` is at most 1/3 of `shared-mutex`
   (C++), `stamped-lock` at most 1/3 of `rw-lock` (Java), median of 3 alternations; the p99.9 ratio is observed.
7. **Line.** 200,000 parcels counted, `dropped` 0 on every camera, every divert command received, for the four line
   variants. End-to-end percentiles are observed; at 2.5 kHz per camera an uncontended lock costs nanoseconds against a
   budget of hundreds of milliseconds, so no difference is expected.
8. **Reports.** Every report passes `lowlat-report check` with count, `dropped` 0, `build.flags` (C++ and Java) and
   `runtime.placement` (pinned runs) or `runtime.python_build` (Python).

Observed, not asserted: `cas-loop` tails and retry counts, the per-store cost of `seq_cst` against release, reader
retries, the Python claim tail against the 5 ms switch interval, the `itertools-count` and GIL-build racy results, the
line percentiles. `verify.sh` flags any asserted bound that clears with under 2x margin, and the chapter prose repeats it.

## Observation surfaces

| Surface | What it shows |
|---|---|
| Terminal output of `verify.sh` | each criterion's value, bound and margin; the observed items |
| `runtime.counters` in each report | exact counts: claims, steps, CAS failures, retries, lost claims, torn snapshots, litmus outcomes |
| `runtime.placement`, `/proc/<pid>/task/<tid>/stat` | where each pinned thread ran |
| `runtime.ctx_switches` | the producers' voluntary and involuntary context switches |
| jcstress `RUN RESULTS` | outcome counts of the Java litmus tests |
| Google Benchmark, JMH | per-store cost |

Grafana: no panel by design. The evidence here comes from short microbenchmarks and a 20 s line run, and it's exact counts and
distributions in the reports. Live observability of the tracker is Part 7.

## Licences

| Component | Version | Licence | Used for |
|---|---|---|---|
| jcstress | 0.16 | GPL-2.0-only WITH Classpath-exception-2.0 | litmus tests (test-time harness) |
| Agrona | 2.7.0 | Apache-2.0 | `ManyToOneConcurrentArrayQueue` |
| OpenHFT Affinity (chronicle-bom 2026.26) | 2026.2 | Apache-2.0 | thread pinning |
| JMH | 1.37 | GPL-2.0-only WITH Classpath-exception-2.0 | Java benchmarks |
| JNA | 5.19.1 | LGPL-2.1-or-later OR Apache-2.0 | Affinity's native calls (version managed for convergence) |
| jopt-simple | 5.0.4 | MIT | option parsing in JMH and jcstress (version managed for convergence) |
| HdrHistogram | per `versions.env` | BSD-2-Clause / CC0 | latency histograms (C, Java, Python) |
| Google Benchmark | v1.10.0 | Apache-2.0 | C++ per-store cost |
| GoogleTest | v1.18.0 | BSD-3-Clause | C++ tests |
| protobuf | per `versions.env` | BSD-3-Clause | the line's wire format and divert commands |
| nlohmann/json | v3.12.0 | MIT | C++ reports |
| pytest | 9.1.1 | MIT | Python tests |
| Jackson (`jackson-databind`, `jackson-core`) | 3.2.4 (`jackson-annotations` 2.22) | Apache-2.0 | JSON reports in the Java measurement kit |
| slf4j-api | 2.0.17 | MIT | logging facade, pulled in by Affinity |
| Apache Commons Math (`commons-math3`) | 3.6.1 | Apache-2.0 | statistics, pulled in by JMH |
| JUnit | 6.1.3 | EPL-2.0 | Java tests |
| CPython | 3.14.8 and 3.14.8+freethreaded | PSF-2.0 | the Python lanes (GIL and free-threaded builds) |

The GPL-with-Classpath-exception tools are build- and measurement-time only; no hot path links them.

## Verification status

Behavioural. `verify.sh` asserts the eight criteria above, and all of them held on the host runs `r03-run1..3`
(bare-metal host, untuned: governor `powersave`, tuned `balanced`, clocksource `tsc`, kernel 7.2, Temurin 25.0.5+8,
GCC 16.2, Python 3.14.8 and 3.14.8+freethreaded; lab VM down; commit 20664bd; load average 0.64 to 1.99 at each start).
Threads sat on distinct physical cores other than CPU 0 (jcstress picks its own CPUs), placed with `sched_setaffinity`
and asserted per thread, and the free-threaded runs kept the GIL off from start to end. Ranges over the three runs; a
ratio is the range of each run's median over its 3 alternations, and a p99 in ns is the first alternation.

| Quantity | Range |
|---|---|
| Exactly-once claims, C++ and Java `mutex`, `cas-loop`, `fetch-add`; Python `lock`, GIL and free-threaded (exact) | 0 lost or duplicated in all runs |
| Python `--racy-claim`, free-threaded build, of 400,000 claims (exact count, at least 1 asserted) | 97,002 to 116,017 lost or duplicated; GIL build 0 |
| `fetch-add` steps per claim (exact) | 1 |
| `cas-loop` failed CAS, least contended of 3 runs, C++ / Java | at least 2,711,734 / 3,824,735 |
| `mutex` voluntary switches, least-switching producer, C++ / Java (bound 100) | 5,406 to 9,746 / 47,556 to 61,712 |
| `fetch-add` voluntary switches, most-switching producer, C++ / Java (bound 10) | 1 / 1 to 3 |
| Claim p99, `mutex` / `cas-loop` / `fetch-add`, C++ | 2,633 to 2,985 / 478 to 502 / 400 to 468 ns |
| Claim p99, `mutex` / `cas-loop` / `fetch-add`, Java | 8,187 to 8,383 / 1,409 to 1,837 / 516 to 584 ns |
| Claim p99 ratio, `mutex` / `fetch-add` | C++ 6.10x to 6.45x (bound 2.5x), Java 14.13x to 15.23x (bound 3x) |
| Consumer wait at the stalled sequence (1 ms sleep, bound 0.5 ms) | C++ 1.05 to 1.07 ms, Java 1.11 to 1.14 ms |
| Litmus both-zero: C++ `seq-cst` / Java `volatile` (exact) | 0 / 0 |
| Litmus both-zero: C++ release/acquire of 10,000,000 trials / Java `setRelease`/`getAcquire` jcstress samples | 2,306,475 to 9,888,040 / 85.0 to 98.6 million |
| Torn snapshots, every read-side variant (exact) | 0 in 2.44 to 2.62 billion C++ and 1.22 to 1.30 billion Java reads |
| Writer p99, shared lock / seqlock, C++ | 5,979 to 6,603 / 25 to 32 ns, ratio 205.5x to 231.0x (bound 3x) |
| Writer p99, `rw-lock` / `stamped-lock`, Java | 8,083 to 8,287 / 206 to 234 ns, ratio 34.5x to 37.1x (bound 3x) |
| Line runs, four variants | 200,000 parcels counted, none dropped on any camera, every divert command received |
| Reports | 88 pass `lowlat-report check`; every C++ and Java report carries `build.flags`, every Python report `runtime.python_build`, every pinned run `runtime.placement` |
| Observed: `mutex` over `fetch-add` p99.9 | C++ 5.64x to 5.92x, Java 6.24x to 6.40x |
| Observed: seqlock reader retries | C++ 4,904,289 to 26,715,000, Java 6,125,589 to 6,366,054 |
| Observed: per-store p50, release / `seq_cst` and `setRelease` / `volatile` | 0 / 4 ns and 0 / 4 ns |
| Observed: Python `lock` claim p99, GIL / free-threaded | 664 to 686 ns / 13,007 to 13,367 ns |

Outliers and failures: none. The narrowest margins are the C++ claim p99 ratio (2.44x to 2.58x) and the stalled-producer
wait (2.11x to 2.29x, a margin set by construction since the sleep guarantees at least 1 ms); no asserted bound cleared
with under 2x. The `cas-loop` against `fetch-add` comparison is observed: lock-free is not faster here, and wait-free
bounds steps, not time. End-to-end line percentiles are observed and show no difference between variants, as expected at
2.5 kHz per camera against a 480 ms budget.
