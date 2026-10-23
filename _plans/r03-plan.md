---
title: "r03 plan: accelerating code"
render_with_liquid: false
description: "Relay plan for r03: Part 3, Ch9–10 (eliminating work: allocation, cache locality, false sharing; lock-free and wait-free synchronization) on the in-flight parcel tracker, in C++, Python and Java. Step status is kept current so a fresh session can resume."
---

Planned by Opus on 2026-10-23 on `release/r03` (cut from main at `9b0339f`). Status column is updated as steps land. Open questions in §6 are answered in S1 before execution.

## 0. Facts that shape the plan (host read-only probes 2026-10-23; S0 re-checks and pins)

- **Host PMU, unprivileged:** `perf_event_paranoid` 2 (unchanged, never changed). `perf stat -e cycles:u,instructions:u,L1-dcache-load-misses:u,LLC-load-misses:u,machine_clears.memory_ordering:u` counts user space of our own processes. The cross-core snoop event `ocr.demand_rfo.l3_hit.snoop_hitm:u` exists but is microarchitecture-specific: it is observed only, and asserted criteria use the generic `L1-dcache-load-misses:u`. S0 (2026-10-23): `perf stat --control fifo:` with `-D -1` and JMH `-prof perfnorm` with `:u` events work at paranoid 2; `perf c2c record` is refused ("Failure to open any events for recording") and is not used: cross-core transfer is observed with `perf stat` user-space events.
- **`perf --version` prints the full host kernel build:** recorded as major.minor (`7.2`) only, by the `profile.sh` rule; `validate.py host-ids` catches a slip.
- **valgrind 3.27.1** (system package, already installed, recorded not pinned): cachegrind gives deterministic simulated D1/LL miss counts for the C++ lanes, an independent cross-check from the hardware counters and an exact counter for asserts.
- **Cache geometry (properties, not the part):** 64-byte line, L1d 48 KiB per core, L2 1.25 MiB per core, L3 24 MiB shared; 8 cores, 16 threads (SMT). Line-scale in-flight table (4,800 parcels at 10 kHz x 480 ms, Ch2) fits L2 in every layout; a hub-wide table of 1,000,000 parcels does not fit L3 as a node map (~130 MB estimated) and roughly fits L3 as an open-addressing map (~15 MB estimated). S5 confirms the sizes with counters and JOL/`sizeof`.
- **abseil 20250512.1** (held, protobuf's tested pin, Apache-2.0) is already installed in `~/.cache/lowlat/prefix` with `absl/container/flat_hash_map.h`: the C++ open-addressing map is an established library, not hand-rolled, and adds no dependency.
- **Java libraries already pinned:** Agrona 2.7.0 (`Long2LongHashMap`, `ManyToOneConcurrentArrayQueue`), JOL 0.17, OpenHFT Affinity 2026.2 (via `chronicle-bom`), JMH 1.37. New candidate: OpenJDK jcstress (Q4).
- **JDK idioms in 25:** `LongAdder` (striped cells, padded internally), `StampedLock.tryOptimisticRead` (the JDK's seqlock), `VarHandle` access modes, `Thread.onSpinWait()`. `@jdk.internal.vm.annotation.Contended` is internal (needs `--add-exports` and `-XX:-RestrictContended`): shown in prose as the non-idiomatic route, not used.
- **C++:** C++23 code only (`std::atomic_ref`, `std::hardware_destructive_interference_size`, `std::barrier`/`std::latch`, `std::jthread`). C++26 `<hazard_pointer>`/`<rcu>` are status only (S0: neither GCC 16.2.1 nor Clang 22.1.8 with libstdc++ ships them; feature macros undefined).
- **CPython:** host 3.14.8 (GIL). uv offers `cpython-3.14.8+freethreaded` as a download; Q3 = yes: pinned in S0 (`_plans/dependency-pins.md`, r03 pins) as a user-local uv download (no system package), and the Python lanes run under both builds. No public atomics API in 3.14.
- **Shared code not to touch:** `examples/common/line-simulator/**` and the three consumers. r03 changes to the kit are additive (schema fields, `lib.sh` helpers, the converter move). If any step must change the shared receive path, examples 00–08 are re-measured, as r02 S13 did.
- **Release rule:** merged PR + `r03.x` tag + notes-only GitHub release; no tarball (CLAUDE.md).

## 1. Approach

C++ leads each technique, because Part 3 is about what the hardware does. Java and Python follow as the same technique in their idiom. Where a technique has no clean equivalent, the divergence is the lesson:

- Python cannot place an object or pad a field.
- Python under the GIL has no parallel threads to false-share or race; the free-threaded build does, and the same code shows it.
- Java's collector stands in for hazard pointers.
- On x86, `getAndAdd` is wait-free because of the instruction it compiles to.

Code tabs use the include default order, `C++|Python|Java`.

**One arc on the scan-to-divert path** (480 ms budget, 1.2 m at 2.5 m/s), around the in-flight parcel tracker (barcode -> parcel state):

- Ch9 removes work from the tracker's data: the lookup map (allocation and pointer chasing), the record layout the per-tick sweep touches (hot/cold split), and the per-camera counters threads write (false sharing).
- Ch10 removes waiting from the tracker's coordination: many scan-tunnel cameras claiming slots in one log (mutex, CAS loop, fetch-add), the ordering two induction stations need to claim one belt gap (memory-order test), and the diverter reading parcel state while the tracker writes it (shared mutex against seqlock).

Each technique is measured twice:

- in a microbenchmark at saturation, where the mechanism shows;
- on the line, where the budget is the question.

The finding to expect is that at line rates most of these differences fit the budget many times over. They matter at hub scale and at saturation. The chapter says so with numbers.

**Criteria**, carried over from r01/r02:

- **Mechanism counters first:** exact allocation counts, cachegrind misses (deterministic), counts of exactly-once claims and torn reads, forbidden litmus outcomes. Then hardware counters, then latency.
- **Latency criteria** compare only within one `verify.sh` run. Variants alternate (A B A B A B) and are judged on the median of three alternations.
- **Tails and ratios only.** p50 is never compared across runs (host 1 kHz consumer p50 drifts run to run).
- **Margins:** every asserted bound clears by at least 2x in all three calibration runs (S7); exact counters are exempt and labelled "exact". Any margin under 2x is stated in the prose. Any bound change goes to the user.
- **No-regression claims:** a no-regression claim is made only from a committed interleaved A/B worded "no shift detected"; otherwise re-measure.

**Run locations:** host bare metal, untuned (`powersave`, `balanced`), serial, lab VM down (`require_quiet_host`), labelled with the profile (`r03-run1..3`). r03 has no VM measurement. The guest and its snapshots are not touched.

**Thread placement on the host (Q1):** placement is unprivileged `sched_setaffinity` (C++ `pthread_setaffinity_np`, Java OpenHFT `AffinityLock`, Python `os.sched_setaffinity`). It picks distinct physical cores (or an SMT pair for the observed sibling variant) from `/sys/devices/system/cpu/*/topology` as an experiment control. It is recorded in `runtime.placement`, and the prose says it is not isolation.

**Rejected:**
- Hand-rolled C++ hash map: abseil `flat_hash_map` is pinned already.
- `std::flat_map` as the fast map: it is sorted, O(n) insert, the wrong structure.
- Boost.Lockfree or moodycamel as a new C++ dependency: the claim primitive is the lesson, and the libraries are named in prose.
- `@Contended` in code: JDK-internal; `LongAdder` and explicit padding are the idioms.
- Changing the line simulator to emit multi-camera reads: the shared workload is re-measured on any change, so Ch10 runs four simulator instances instead.
- A VM lane: placement and counters on the host answer the question; isolation is Part 5.
- Python false sharing as an asserted criterion: interpreter cost hides it, so it is observed only.
- jcstress in CI as a gate: long and nondeterministic for the allowed outcome; CI runs only deterministic tests.
- Committing raw cachegrind or jcstress HTML: large; summaries only.
- Asserting the vendor HITM event: not portable.

## 2. Per chapter

### Ch9 — `examples/09-eliminating-work/` (host)

- **Technique:**
  - (a) Data-structure allocation and pointer chasing on the barcode lookup: node-based map against open addressing on a packed 64-bit SSCC key.
  - (b) Hot/cold split of the parcel record for the per-tick due sweep: a fat record against hot columns.
  - (c) False sharing of per-camera counters: adjacent against padded to a 128-byte false-sharing range, plus a 64-byte padding variant that tests Ch7's adjacent-line prefetcher claim.
- **Workload:**
  - Tracker `track(scan)` (insert or update by barcode), `expire(tick)` (erase diverted), `sweep_due(tick)`.
  - Two working sets: line tracker 4,800 in flight (Ch2) and hub tracker 1,000,000 preloaded (seeded, shuffled insertion so slot order is not allocation order, as Ch8).
  - Five scan-tunnel cameras (one thread each) bump their own read and no-read counters; a telemetry reader samples them off-path.
  - Line run: 10 kHz x 20 s (200,000 parcels) against the preloaded hub tracker, UDP 47290 (`node-map`) and 47291 (`flat-map`).
  - SSCC packing (`std::from_chars`, `Long.parseLong`, `int()`) is checked against the barcodes in `contracts/flat/parcel-v1` golden JSON in all three languages.
- **C++:**
  - Maps: `node-map` (`std::unordered_map<std::string, ParcelState>`, idiomatic; the 18-digit key exceeds libstdc++'s 15-character small-string buffer, so each insert allocates twice: node and string) against `flat-map` (`absl::flat_hash_map<std::uint64_t, std::uint32_t>` slot index plus columns, `reserve`d).
  - Records: `--fat-record` (one roughly 80-byte struct, everything about the parcel) against `hot-cold` (`std::vector<std::uint64_t>` ticks plus `std::vector<std::uint8_t>` state; cold fields in their own vector).
  - Counters: `--adjacent-counters` (`std::array<std::atomic<std::uint64_t>, 5>`, single writer each, relaxed load plus store, no RMW) against `pair-padded` (`alignas(2 * std::hardware_destructive_interference_size)`), observed `--line-padded` (64 B) and `--smt-siblings`.
  - Allocation count via the replaced global `operator new` (Ch5 pattern). Latency per sampled lookup into HdrHistogram via `measure-cpp`. Cachegrind run of the hub lookup and the sweep on a reduced iteration count.
- **Java:**
  - JMH `-prof gc` B/op for insert/erase: `node-map` (`HashMap<String, ParcelState>`) against `flat-map` (Agrona `Long2LongHashMap` key -> slot, primitive `long[]`/`byte[]` columns).
  - JMH SampleTime for hub lookups and the sweep (`--fat-record` = `ParcelRecord[]` of objects, `hot-cold` = primitive arrays; the difference from Ch8's `MemorySegment` table is said in one line).
  - Counters: `--adjacent-counters` (`AtomicLongArray`, index i, `getPlain`/`setRelease`) against `pair-padded` (index i x 16), and `long-adder` (JDK idiom, observed; it is a different shape: a contended sum, not per-camera values).
  - Standalone harness for the counter threads (placement via `AffinityLock`). Perf counters through `perfnorm` with `:u` events (S0: works at paranoid 2).
- **Python** (the divergence):
  - `tracemalloc` bytes per tracked parcel: `--dict-per-parcel` against `@dataclass(slots=True)` keyed by `str`, and keyed by `int`.
  - Sweep of a list of objects against an `array('Q')` column (observed: every element read still makes an int object; the lever in Python is fewer objects, not layout).
  - False sharing between processes through `multiprocessing.shared_memory` (`--adjacent-counters` against `pair-padded`, observed; threads under the GIL never write in parallel, so there is nothing to false-share).
- **Measured:**
  - allocations or bytes per insert;
  - hub and line lookup p50/p99/p99.9;
  - misses per lookup and per slot (perf `:u`, cachegrind);
  - sweep p50/p99/p99.9;
  - per-batch increment latency (1,000 increments per sample) and L1 misses per increment per placement;
  - line end-to-end p50/p99/p99.9 per variant with the hub table loaded;
  - receive-thread `alloc_bytes_per_parcel` (Java) and allocations per parcel (C++).
- **Asserts** (provisional bounds; S7 confirms each margin is at least 2x):
  1. (exact) C++ `node-map` at least 2 allocations per insert and `flat-map` 0 after `reserve`; JMH `node-map` insert at least 64 B/op and `flat-map` at most 1 B/op; Python `--dict-per-parcel` bytes per parcel at least 2x `slots` (exact for CPython 3.14.8).
  2. Hub lookups, same run: `node-map` p50 at least 2x `flat-map` p50 (C++, Java); cachegrind LL read misses per lookup `node-map` at least 2x `flat-map` (exact, deterministic). Line-scale ratio observed (expected near 1: it fits L2).
  3. Hub sweep, same run: `--fat-record` p50 at least 2x `hot-cold` p50 (C++, Java); cachegrind D1 read misses per slot `--fat-record` at least 4x `hot-cold` (exact; byte ratio about 9x).
  4. Counters, placement on distinct physical cores asserted from `/proc/<pid>/task/<tid>/stat`: `--adjacent-counters` per-batch p50 at least 3x `pair-padded` (median of 3 alternations, C++ and Java); `L1-dcache-load-misses:u` per increment `--adjacent-counters` at least 10x `pair-padded` (C++).
  5. Line, C++: allocations per parcel on the receive thread from the tracker (exact): `node-map` at least 1, `flat-map` 0.
  6. Every report: count, `dropped=0`, `check`, `build.flags` (Java), `runtime.placement` where pinned.
- **Observed:** `--line-padded` against `pair-padded` (does the adjacent-line prefetcher matter on this host; Ch7's claim), `--smt-siblings` (siblings share L1: expected no penalty), `long-adder`, the vendor snoop-hit event, line end-to-end percentiles ("both fit 480 ms by orders of magnitude"), Java line `alloc_bytes_per_parcel` (decode dominates), Python sweep and process counters.
- **Figures:** 9.1 `09-working-set`; 9.2 `09-node-vs-flat-map`; 9.3 `09-hot-cold-split`; 9.4 `09-false-sharing`.

### Ch10 — `examples/10-lockfree-waitfree/` (host)

- **Technique:**
  - (a) Progress guarantees on a multi-producer claim: blocking (`mutex`), lock-free (`cas-loop`), wait-free claim step (`fetch-add`). The guarantee belongs to an operation, not to a structure: a producer stalled between claim and publish blocks the consumer of a fetch-add log. ABA avoided by monotonic 64-bit sequences; reclamation (hazard pointers, epochs) in prose; in Java the collector does it.
  - (b) Memory orders in full: the induction-gap test (two induction stations each raise "claiming the gap", then read the other's flag; both reading 0 means both induct into one gap). Release/acquire allows it on x86 (store buffer); `seq_cst` forbids it. Mapping to Java `VarHandle` modes.
  - (c) Read side: the diverter and HMI read a parcel-state snapshot while the tracker writes it: `shared-mutex` against `seqlock`.
- **Workload:**
  - (a) Four camera threads x 1,000,000 claims each into a 1M-slot log, one tracker consumer; distinct physical cores.
  - (b) 10,000,000 trials, two threads on distinct cores, spin barrier per trial.
  - (c) One writer at 1 MHz updates, three readers spinning; snapshot carries a checksum field.
  - Line: four simulator instances at 2.5 kHz x 20 s each (four tunnel cameras, 200,000 parcels total) to UDP 47300–47303 (`mutex`/`blocking-queue`) and 47304–47307 (`fetch-add`/`agrona-mpsc`). One receive thread per camera publishes into the MPSC hand-off; the tracker thread decides; divert commands go on the separate command channel, never the data queue. No simulator change.
- **C++:**
  - (a) `std::mutex`, `compare_exchange_weak` loop with a thread-local retry counter, `fetch_add`; `std::barrier` start; per-thread HdrHistogram per claim; per-thread voluntary context switches from `/proc/thread-self/status` before and after.
  - `--stalled-producer`: one producer sleeps 1 ms between claim and publish at a fixed sequence.
  - (b) `std::atomic<int>` with `memory_order_release`/`acquire` against `seq_cst`; per-store cost observed (Google Benchmark: `seq_cst` store compiles to `xchg`).
  - (c) `std::shared_mutex` against a seqlock: even/odd sequence, fields through `std::atomic_ref` relaxed with acquire/release fences. The prose says why a plain-field seqlock is a data race in C++.
- **Java:**
  - (a) `ReentrantLock`, `AtomicLong.compareAndSet` loop, `getAndIncrement` (one `lock xadd` on x86; on an LL/SC machine it is a loop, so "wait-free" depends on the platform).
  - (b) jcstress tests with `@Outcome(id = "0, 0", expect = ACCEPTABLE_INTERESTING)` for `setRelease`/`getAcquire` and `FORBIDDEN` for volatile (Q4).
  - (c) `ReentrantReadWriteLock` against `StampedLock.tryOptimisticRead` (the JDK's seqlock: idiomatic).
  - Line: `blocking-queue` (`ArrayBlockingQueue`) against `agrona-mpsc` (`ManyToOneConcurrentArrayQueue`, the library's CAS-claim MPSC).
- **Python** (the divergence), run under both builds (`gil`, `free-threaded`, recorded in `runtime.python_build` from `sys._is_gil_enabled()`): (a) `threading.Lock` against `next()` on a shared `itertools.count`, plus an unsynchronised `counter += 1` claim (`--racy-claim`). Exactly-once asserted for `lock` in both builds; `itertools-count` exactly-once is observed and reported, not asserted, in both builds (S0: not documented thread-safe; the 3.14 free-threading howto, Iterators, says threads sharing an iterator may see duplicate or missing elements); `--racy-claim` lost claims observed under the GIL and asserted at least 1 under free threading (exact). Claim tail observed against `sys.getswitchinterval()` (5 ms) under the GIL, and with real parallel contention under free threading. Ch9's thread-based false-sharing counters also run under the free-threaded build (observed: interpreter cost per increment may still hide the line transfer). No memory-order lane and no seqlock lane (no public atomics API in 3.14). Appendix E keeps the full free-threading treatment; Ch10 links to it.
- **Measured:**
  - claim p50/p99/p99.9 per variant;
  - CAS failures total and the largest retry count in one claim;
  - steps per claim;
  - producer voluntary context switches;
  - consumer's largest wait at the stalled sequence;
  - litmus outcome counts;
  - per-store cost;
  - writer update p50/p99/p99.9 and reader retries;
  - torn snapshots;
  - line end-to-end p50/p99/p99.9 per variant.
- **Asserts** (provisional; S7):
  1. (exact) every synchronised variant (Python: `lock` only; `itertools-count` is observed), every language and Python build: each sequence 0..N-1 claimed exactly once (bitmap). Python `--racy-claim` under free threading: lost or duplicated claims at least 1 (exact; it demonstrates the race).
  2. (exact) `fetch-add` steps per claim = 1; `cas-loop` failed CAS at least 1 in total (contention present); `mutex` producers' voluntary context switches at least 100, against `fetch-add` at most 10 (calibrated).
  3. Claim p99.9, same run, median of 3 alternations: `mutex` at least 3x `fetch-add` (C++, Java). `cas-loop` against `fetch-add` observed: lock-free is not "faster", and wait-free bounds steps, not time.
  4. `--stalled-producer` (1 ms sleep): the consumer's wait at that sequence is at least 0.5 ms in the `fetch-add` log. The sleep guarantees at least 1 ms, so the margin is 2x by construction.
  5. (exact) Litmus: C++ `seq-cst` both-zero = 0 and Java volatile `0, 0` = 0 (forbidden by the model); C++ `release-acquire` and Java acquire/release both-zero at least 1 (expected thousands per 10M; S7 records the margin).
  6. (exact) Seqlock: torn snapshots 0 in every variant. Writer p99.9 `seqlock` at most 1/3 of `shared-mutex` (same run, C++; Java `stamped-lock` against `rw-lock`).
  7. Line: count 200,000, `dropped=0` per camera, `check`; end-to-end percentiles observed (expected no difference at 2.5 kHz per camera: an uncontended lock costs nanoseconds).
  8. Every report: count, `dropped=0`, `check`, `build.flags`, `runtime.placement`.
- **Observed:** `cas-loop` tails, per-store `seq_cst` cost, reader retries, Python claim tail against the switch interval, line percentiles.
- **Figures:** 10.1 `10-progress-guarantees`; 10.2 `10-store-buffer`; 10.3 `10-seqlock`; 10.4 `10-stalled-producer` (optional).

## 3. Steps

Executor is Sonnet unless the row says MAIN. Opus validates each step with `lgtm-idiomatic-review` (code steps) and `lgtm-professional-voice` (prose steps). Findings are fixed in the same step, not deferred. One checkpoint commit per step (scopes `r03.x`, `demo-09`, `demo-10`, `§9`, `§10`). Host runs are serial with the lab VM down.

| id | What | Files | Dep | Runs on | Status |
|---|---|---|---|---|---|
| S0 | Upstream survey + exact pins, licences, date, holds: jcstress (Central latest, licence), Agrona (2.7.0 still latest?), JOL, Affinity via `chronicle-bom`, abseil `flat_hash_map` from the held pin; record (not pin) valgrind and perf major.minor; probe `perf stat --control fifo:` with `-D -1`, JMH `-prof perfnorm` with `:u` events, `perf c2c record` at paranoid 2, generic event availability; C++26 `<hazard_pointer>`/`<rcu>` in GCC 16 / Clang 22 (status); `sys._is_gil_enabled()` on 3.14.8; pin `cpython-3.14.8+freethreaded` (uv, user-local) and record whether `itertools.count.__next__` is documented thread-safe in the free-threaded build | `_plans/dependency-pins.md` ("r03 pins"), `versions.env` (only if a tarball is added) | – | host (read-only) | done |
| S1 | Record answers to Q1–Q9; iteration-plan status (r02 complete, merged #4, tag `r02.x`; r03 in progress); commit this plan | `_plans/iteration-plan.md`, this file, `CLAUDE.md` only if Q1 changes a rule | answers | MAIN | done |
| S2 | Report contract, additive in `lowlat-report/1`: `runtime.placement` {`cpus`, `distinct_cores`, `smt_siblings`}, `runtime.hw_counters` {`source` (`perf`, `cachegrind`, `perfnorm`), `ops`, `per_op` {event: number}}, `runtime.counters` {name: integer} (CAS failures, max retries, torn reads, litmus outcomes); `noMean` covers all; `check` validates; fixtures (pass and planted fail); C++ and Java writers fill `placement` | `contracts/measurement/latency-report.schema.json`, `contracts/measurement/examples/` (schema fixtures, pass and planted fail), `measure-py`, `measure-cpp`, `measure-java`, `measure-fixtures/` (writer goldens `cpp-placement.json`, `java-placement.json`) | S0 | host | done |
| S3 | `profile.sh`: `cpu.caches` (L1d/L2/L3 size, line size from sysfs), `cpu.topology` (core id per logical CPU), `tools.perf` (`7.2`), `tools.valgrind`. `lib.sh`: `distinct_cores N`, `smt_pair`, `assert_placement PID TID CPU`, `perf_region OUT -- CMD` (FIFO-controlled `perf stat -x,` writing `hw_counters`), `cachegrind_run OUT -- CMD` (summary only, scrubbed), `interleave N VARIANTS...`. Promote `harness_report.py` (`from_jmh`/`from_gbench`) from 08 into `lowlat_measure` as `lowlat-report from-jmh`/`from-gbench`; 08 `verify.sh` re-pointed; identity test regenerates 08's committed `r02-run1` JMH reports byte-identical; `RECHECK` on 08 `r02-run1..3` passes. `.gitignore`: `cachegrind.out.*`, `jcstress-results/` | `scripts/profile.sh`, `examples/_lib/lib.sh`, `examples/common/measure-py/**`, `examples/08-zero-copy-flat/{verify.sh,flat-py}`, `.gitignore` | S2 | host | done |
| S4 | Build wiring: modules `09-eliminating-work` (Java `*-java` with JMH, Agrona, Affinity, JOL), `10-lockfree-waitfree` (JMH, Agrona, Affinity, jcstress per Q4) in `examples/pom.xml`; `dependencyConvergence` passes without a disabled rule; `-Xlint:all -Werror` kept; C++ targets `lowlat::eliminating_work`, `lowlat::lockfree` linking `absl::flat_hash_map` from the prefix; uv packages `lowlat-locality` (`09-*/locality-py`), `lowlat-sync` (`10-*/sync-py`); one wiring test each | `examples/pom.xml`, `examples/09-*/java/pom.xml`, `examples/10-*/java/pom.xml`, `examples/09-*/cpp/CMakeLists.txt`, `examples/10-*/cpp/CMakeLists.txt`, `*-py/pyproject.toml` | S0, S2 | host | done |
| S5 | Example 09 (C++, Java, Python) + `verify.sh` (criteria §2 Ch9) + README (technique, workload, expected effect, observation surfaces: terminal output, Grafana "no panel by design" (Part 7), licences) | `examples/09-eliminating-work/**` | S3, S4 | host | todo |
| S6 | Example 10 (C++, Java, Python) + `verify.sh` + README; jcstress summary to text | `examples/10-lockfree-waitfree/**` | S3, S4 | host | built; dry run misses 2 provisional bounds (S7 calibrates) |
| S7 | Calibration gate: 3 quiet dry runs of 09 and 10 into `results/latest` (uncommitted); margin table per asserted criterion; every bound clears at least 2x (exact counters exempt and labelled); tuned parameters (batch size, trial counts, hub size) into READMEs; any bound change or sub-2x margin goes to the user and is recorded in Follow-ups | READMEs, this file's Follow-ups | S5, S6 | host (MAIN) | todo |
| S8 | Host measurement `r03-run{1,2,3}` for 09 and 10, serial, VM down, load1 at most 2 at start, one recorded commit; `verify.log` through `scrub-host-ids.py --filter`. 00–08 not re-measured unless a step touched the shared receive path (then re-measure all, as r02 S13); otherwise `lowlat-report check` over every committed report and record "no re-measure needed" with the diff stat of `examples/common/` | `examples/09-*/results/r03-run*/`, `examples/10-*/results/r03-run*/` | S7 | host (MAIN) | todo |
| S9 | Figures 9.1–9.4, 10.1–10.3 (+10.4), r01 visual grammar, S8 ranges only; `_plans/r03-figures.md` value table completed | `_plans/r03-figures.md`, `diagrams/09-*.py`, `diagrams/10-*.py`, `assets/diagrams/`, `_data/diagrams.yml` | S8 | host | todo |
| S10 | Ch9 prose from `_plans/r03-chapters.md` | `_docs/09-eliminating-work.md`, `_plans/r03-chapters.md` | S9 | – | todo |
| S11 | Ch10 prose | `_docs/10-lockfree-waitfree.md` | S9 | – | todo |
| S12 | Wiring: `_example_pages/09`, `10`; outline links Ch9/Ch10; forward links in Ch5, Ch6, Ch7, Ch8, 07 README become links to the shipped chapters (`relative_url`), no number changes; reconciliation 09.x and 10.x plus runs rows; iteration-plan status | listed files, `_plans/reconciliation-plan.md` | S10, S11 | – | todo |
| S13 | CI + `validate.py`: `java-flags` covers `results/r0[2-9]-*` and chapters 5–10; new checks: every report with `runtime.hw_counters` names a `source`, every pinned report has `runtime.placement.cpus`, no `cachegrind.out.*` or jcstress HTML tracked, `tools.perf`/`tools.valgrind` in profiles are major.minor; `--self-test` planted case for each; CI builds and unit-tests 09/10 (deterministic tests only: exactly-once, seqlock torn-read 0, litmus `seq-cst` 0 at a small trial count); ruff over the new packages | `scripts/validate.py`, `.github/workflows/ci.yml` | S4, S12 | CI | todo |
| S14 | Idiom + voice review: `lgtm-idiomatic-review` on 09, 10 and kit diffs; `lgtm-professional-voice` (pattern scan **and** the house-voice rubric: Geewax model, `scan.sh --stats`) on `_docs/09-10`, READMEs, `_plans/r03-*`; fix findings now | all r03 files | S13 | host (MAIN + executors) | todo |
| S14b | House-voice pass over the shipped prose (user request 2026-10-23; fix now): Ch0–8 (`_docs/00-*`–`08-*`, incl. the outline), example READMEs 00–08, `_data/diagrams.yml` captions, site chrome (rule 14 sweep). Captions `Figure N.x — …` become `Figure N.x: …` in chapters and `_data/diagrams.yml`; contractions where the sentence allows; cadence and triads per rule 15; example-first openings. Prose only: no number, code block, command, identifier, recorded output or verification footer data changes, so no re-measure | `_docs/0[0-8]-*.md`, `examples/0[0-8]-*/README.md`, `_data/diagrams.yml`, site chrome | S13 | – (executors split per lgtm-professional-voice) | todo |
| S15 | Re-measure: any S14 change to measured code or a `verify.sh` invalidates S8; re-run `r03-run1..3` and re-quote chapters, figures and reconciliation. Only where a "no regression" claim is made instead: committed interleaved A/B worded "no shift detected". Otherwise "no re-measure needed" with the diff stat | results, chapters, figures, reconciliation | S14 | host (MAIN) | todo |
| S16 | (after S14b) Opus validation: every quoted number recomputed from committed files; §4 criteria; Jekyll in `ruby:4.0`; `validate.py` + `--self-test`; `wordcount.sh`; figures regenerate byte-identically; host-ids clean | – | S15 | host (MAIN) | todo |
| S17 | Ship: PR `release/r03` -> main, `ci-ok` green, squash-merge (user OK), delete branch, tag `r03.x`, notes-only GitHub release; no tarball | – | S16 | GitHub (MAIN) | todo |

## 4. Acceptance criteria

- **S0:** every new dependency has exact version, licence, source and date; no ranges, `LATEST` or EA; each probe result recorded (works, or fallback chosen); perf and valgrind recorded as major.minor; C++26 status recorded with the compiler versions.
- **S1:** §6 answers in Follow-ups with date; `iteration-plan.md` shows r02 complete and r03 in progress.
- **S2:** a report with `runtime.placement`, `hw_counters` and `counters` passes `check`; one with `runtime.counters.mean_retries` fails; all committed r01/r02 reports still pass `check`.
- **S3:**
  - `profile.sh | jq .tools.perf` prints `"7.2"`;
  - `distinct_cores 4` prints four CPUs with four distinct `core_id`s;
  - `perf_region` on a test binary writes `hw_counters` with nonzero `L1-dcache-load-misses` and excludes the code outside the region (a planted loop outside it does not move the count);
  - the 08 identity test passes and `RECHECK=results/r02-run{1,2,3}` on 08 exits 0;
  - `python3 scripts/validate.py` passes.
- **S4:** `mvn -B -f examples/pom.xml verify` passes with the enforcer and `-Werror`; C++ and uv builds pass; `ctest` passes; `ruff check` and `ruff format --check` pass on the new packages.
- **S5/S6:** each `verify.sh` exits 0 on the host and asserts its §2 criteria; variant names only from §2 (`validate.py variant-names`); placement verified per pinned thread; READMEs state technique, workload, expected effect, observation surfaces and licences.
- **S7:** margin table committed in Follow-ups; every asserted bound clears at least 2x in all 3 dry runs, or a recorded user decision; exact counters labelled.
- **S8:**
  - every report passes `check` and carries `profile.virt` `none`, `loadavg` and (pinned runs) `runtime.placement`;
  - every `verify.log` ends with all criteria passing;
  - `validate.py host-ids` passes;
  - committed r03 results are at most 20 MB;
  - "no re-measure needed" or the 00–08 re-measure is recorded.
- **S9:** at least 2 `_data/diagrams.yml` entries each for Ch9 and Ch10; every SVG/`.excalidraw` parses and regenerates byte-identically; every number is a parameter or an S8 range.
- **S10/S11:**
  - 1,900–2,500 words (`wordcount.sh`);
  - `part: "Accelerating Code"`;
  - full spine;
  - every number traceable to a committed file and profile-labelled;
  - no mean;
  - p50 compared only within a run;
  - sub-2x margins stated;
  - `listings` and `codetabs` pass;
  - no trading domain;
  - nothing ported from a reference;
  - house voice from the first draft (lgtm-professional-voice "House voice", Geewax model): `scan.sh --tier ban` 0 and `scan.sh --stats` shows no em dash, no `stiff` flag (most negations and "it is" forms contracted) and no `uniform sentence length` flag; every `check triads` candidate read and either a real list or rewritten; sections open on a concrete thing in the line before the abstraction.
- **S12:** examples page lists 00–10; reconciliation has one row per asserted and observed claim with run evidence; forward links resolve.
- **S13:** `ci-ok` green on the PR; each new check fails on its planted case and passes on the tree.
- **S14:** both scanners 0 ban-tier after triage; idiom findings fixed or the non-idiomatic construct justified in prose; `scan.sh --stats` on r03 prose clean of em dashes and `stiff`/`uniform` flags, triad candidates triaged.
- **S14b:** `scan.sh --tier ban` 0 on Ch0–8, READMEs 00–08 and `_data/diagrams.yml`; `scan.sh --stats` before/after table committed in Follow-ups with no em dash and no `stiff` flag left; `git diff` shows no change inside code blocks, inline code, commands, numbers or recorded output (a script compares the numbers in each changed paragraph before and after); `validate.py` (incl. diagram captions vs `_data/diagrams.yml`), Jekyll build and `wordcount.sh` still pass (each chapter stays 1,900–2,500 words).
- **S15:** quoted numbers match the final committed runs; any A/B is committed and worded "no shift detected".
- **S16:** every criterion above holds; Jekyll builds with 0 warnings.
- **S17:** PR squash-merged, tag `r03.x`, notes-only release published, branch deleted.

## 5. Risks

| Risk | Detection |
|---|---|
| Threads land on SMT siblings or the same CPU, hiding false sharing or contention | `assert_placement` from `/proc/<pid>/task/<tid>/stat` field 39 per thread; `runtime.placement` in each report; `--smt-siblings` kept as the observed contrast |
| `perf --version` or tool output leaks the host kernel build or home paths | profile records `7.2`; `scrub_results` on exit; `validate.py host-ids` in CI |
| Vendor-specific PMU event missing or renamed | asserts use generic `L1-dcache-load-misses:u`; vendor event observed only; S0 probe |
| `perf stat --control` or JMH `perfnorm` refused at paranoid 2 | S0 probe; fallback whole-process `perf stat` on a process that does only the measured region, or counters observed only; never change paranoid. S0: both work; `perf c2c` refused, not used by any chapter |
| Setup work (building a 1M table) pollutes counters | FIFO-controlled region; cachegrind with `CACHEGRIND_FUNCTION` (per-function costs of the measured function; cachegrind has no `--toggle-collect`); S3 planted-loop test |
| Cachegrind too slow on 1M x many lookups | reduced, fixed iteration count with a seeded key sequence; deterministic counts compared per op |
| Powersave drift between variants | variants interleaved (A B A B A B) in one `verify.sh`, median of 3; no cross-run p50 |
| A ratio clears its bound with under 2x margin | S7 gate; bound or parameter change goes to the user; the prose states the margin |
| Litmus allowed outcome not observed (threads not concurrent) | distinct cores, spin barrier per trial, 10M trials; S7 records counts; the `seq-cst` 0 criterion is exact regardless |
| jcstress run time or output size | quick mode with a named test, text summary committed, HTML ignored |
| C++ seqlock written as a data race (UB) | fields via `std::atomic_ref`; `sanitize` preset with TSan on the unit test; idiom review |
| Exactly-once check itself races | bitmap written once per claim by the claimer, checked after `join` (happens-before) |
| Overlap with Ch7 (SPSC, padding) and Ch8 (flat table) | boundaries in `r03-chapters.md`; checked at S16 |
| Shared receive path changed by accident, invalidating 00–08 numbers | `git diff --stat main -- examples/common/line-simulator` empty at S8; otherwise re-measure 00–08 |
| Converter move changes 08 results | identity test on committed JMH JSON; `RECHECK` 08 r02 runs |
| Four simulator instances drop at 2.5 kHz each | `dropped=0` per camera; emit lateness in the logs |
| Hub table memory (1M node map ~130 MB per variant, two JVMs, C++) | sizes in README; run variants serially; RSS observed |
| Host accidentally changed | `lib.sh` never calls sudo; `profile.sh` diff before and after S8; placement is unprivileged |
| Results bloat | `.gitignore` for cachegrind and jcstress outputs; S8 size check |
| New Python scripts fail CI ruff | `ruff check`/`format --check` run in S4–S6 before commit |

## 6. Open questions (answered in S1)

1. **Host thread placement.** r02 recorded "no thread pinning on the host". False sharing, the litmus test and claim contention need threads on known distinct physical cores. Recommendation: allow unprivileged `sched_setaffinity` on the host as an experiment control (no isolation claim, no system change), recorded in `runtime.placement`, the prose saying so. The alternative is unpinned runs with placement only observed (flaky effect, weaker criteria). **Yours to decide**: it revises an r02 decision.
2. **Hub-scale working set.** 1,000,000 parcels in flight (a whole hub, matching Ch8's sweep) against the line's 4,800. Recommendation: yes, both, with the line-scale result taught as "fits L2, layout barely matters".
3. **Python free-threaded build.** Downloading `cpython-3.14.8+freethreaded` through uv (user-local, like the r02 SDKMAN JDK upgrade) would let Ch10 show real races and contention in Python. Recommendation was no; the user chose yes (Follow-ups).
4. **jcstress.** New Java dependency (OpenJDK, GPL-2.0 with Classpath exception, same family as JMH) for the Java litmus test, against a hand-rolled `VarHandle` harness. Recommendation: jcstress (the established tool).
5. **Converter promotion.** Move `harness_report.py` from 08 into `lowlat_measure`, touching 08's `verify.sh` with an identity test and `RECHECK` (no re-measure), against duplicating it in 09/10. Recommendation: promote.
6. **Hardware counters in asserts.** Recommendation: assert cachegrind counts (deterministic, exact) and the generic L1-miss ratio for false sharing; all other perf counters observed.
7. **Ch10 scope.** Three parts (claim and progress, memory orders, seqlock) in 2,500 words. Recommendation: all three; if the word budget fails at S11, the seqlock part becomes observed with a shorter section, which is a user decision at that point.
8. **Ch10 line run** with four simulator instances as four tunnel cameras (no simulator change). Recommendation: yes.
9. **Slugs.** `09-eliminating-work`, `10-lockfree-waitfree` (permalinks `/docs/09-eliminating-work/`, `/docs/10-lockfree-waitfree/`). Recommendation: accept.

## Follow-ups

| Item | Decision |
|---|---|
| Q1 host thread placement (2026-10-23, user) | Allowed: unprivileged per-thread `sched_setaffinity` of our own benchmark threads on the host, as an experiment control, recorded in `runtime.placement` and asserted per thread; prose says it is not isolation. Revises r02's "no host thread pinning" for r03 onward; no system setting changes |
| Q2 hub-scale working set | Accepted: 1,000,000 hub tracker and the 4,800 line tracker |
| Q3 free-threaded Python (2026-10-23, user) | Yes: `cpython-3.14.8+freethreaded` via a user-local uv download, pinned in S0; Ch10 Python claim lane and Ch9 thread counters run under both builds (§2 Ch10 Python) |
| Q4 jcstress | Accepted: OpenJDK jcstress, pinned in S0 with licence; verify.sh only, not a CI gate |
| Q5 converter promotion | Accepted: promote `harness_report.py` into `lowlat_measure` with the 08 identity test and `RECHECK` |
| Q6 hardware counters in asserts | Accepted: cachegrind counts and generic L1-miss ratio asserted; other counters observed |
| Q7 Ch10 scope | Accepted: all three parts within 2,500 words; overflow goes back to the user at S11 |
| Q8 Ch10 line run | Accepted: four simulator instances, no simulator change |
| Q9 slugs | Accepted: `09-eliminating-work`, `10-lockfree-waitfree` |
| S6 note, free-threaded lane (2026-10-23, S4 validation) | Under `python3.14t`, importing `pyhdrh` (through `lowlat_measure`) re-enables the GIL with a RuntimeWarning. The free-threaded lane must not import `lowlat_measure` in the measured process, or must verify `sys._is_gil_enabled()` is False after its imports and fail otherwise. |
| S6 note, jcstress runs (2026-10-23, S4 validation) | Pass `-jvmArgsPrepend --enable-native-access=ALL-UNNAMED`; scrub the summary (JNA's warning prints an absolute jar path); never call `-h`. |
