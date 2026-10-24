# 09-eliminating-work

Chapter 9: eliminating work. Take one scan on the sortation line. The in-flight parcel tracker looks the
barcode up, inserts or updates the parcel, and at every encoder tick sweeps for parcels that reached the
diverter. Ch9 removes work from that tracker's data in two places and from its counters in a third: the
lookup map, the record layout the sweep reads, and the counters the scan-tunnel cameras write. C++ leads,
because the chapter is about what the hardware does. Java follows with the same techniques in its idiom.
Python is the divergence.

Expect a plain result. At line rates (4,800 parcels in flight, 10 kHz) most of these differences fit the
480 ms budget many times over. They matter at hub scale, 1,000,000 parcels, and at saturation. The example
measures both and says which is which.

## Technique

- **(a) Allocation and pointer chasing on the lookup.** A node-based map against open addressing on a
  packed 64-bit SSCC key. The 18-digit barcode is longer than libstdc++'s 15-character small-string
  buffer, so a `std::unordered_map<std::string, ...>` insert allocates twice, once for the node and once for
  the key's characters, and a lookup chases bucket, node and key. `absl::flat_hash_map<std::uint64_t,
  std::uint32_t>` maps the packed SSCC to a slot and is `reserve`d once, so an insert allocates nothing.
  Java compares `HashMap<String, ParcelState>` with Agrona's `Long2LongHashMap` over primitive columns.
- **(b) Hot/cold split of the record for the per-tick sweep.** The sweep reads two fields of every
  record: the due tick and the state. In one 80-byte struct (`--fat-record`) it drags the other 71 bytes
  through the cache. In `hot-cold` columns it reads 9 bytes a slot. Java compares an array of `ParcelState`
  objects (ordinary on-heap objects, not Ch8's `MemorySegment` table) with primitive arrays.
- **(c) False sharing of per-camera counters.** Five cameras, one writer thread each, bump their own read
  and no-read counters while a telemetry thread samples them. `--adjacent-counters` puts the five read counters side by side in one 64-byte line and the five no-read
  counters in the next, so every camera shares a line with every other.
  `pair-padded` gives each camera 128 bytes, which is `2 * std::hardware_destructive_interference_size`,
  the range the L2 spatial prefetcher fetches as a pair. `--line-padded` (64 bytes) tests Ch7's claim that one
  line isn't enough. `--smt-siblings` puts two cameras on the two hardware threads of one core, which share an
  L1. In Java the counters sit in one `MemorySegment` from `arena.allocate(size, 128)` (Ch8's idiom), because a
  heap array's alignment can't be controlled and an "adjacent" array would straddle two lines at a different
  place on every run. `long-adder` is the JDK's `LongAdder`: a different shape, one contended sum instead of
  one value per camera.

The padding isn't idiomatic C++ or Java. It's a latency construct, and the comments in `counters.hpp` and
`CameraCounters.java` say why it's there. Everything else is the idiom: standard containers and abseil in
C++, JDK collections, Agrona and `LongAdder` in Java, dataclasses with `slots=True` in Python.

## Workload

- **Tracker.** `track(scan)` inserts or updates by barcode. `erase(barcode)` and `expire(tick)` remove
  parcels, and `sweep_due(tick)` counts the in-flight parcels due at a tick. The due tick is the scan
  tick plus 1,200: 1.2 m at 1,000 pulses per metre.
- **Two working sets.** The line tracker holds 4,800 parcels in flight (Ch2). The hub tracker holds
  1,000,000, preloaded from a seeded family of distinct SSCCs and visited in a shuffled order, so the order of
  lookups isn't the order of allocations (as in Ch8). A node map of 1,000,000 parcels allocates about
  150 MB in C++ and can't fit the 24 MiB L3. `tracker-bench` prints the exact bytes each build allocated.
- **Cameras.** Five camera threads, each pinned to its own physical core, each timing every batch of 1,000
  increments. A telemetry thread, also pinned, samples all counters about once a millisecond, off the
  cameras' path.
- **Line run.** The shared line simulator sends 10 kHz for 20 s, 200,000 parcels, to a consumer holding the
  preloaded hub tracker: UDP 47290 for `node-map`, 47291 for `flat-map`. Each parcel is tracked and the
  oldest preloaded parcel is retired, so the table stays at hub size. The simulator and the consumer library
  aren't modified. The handlers plug into the consumer's `consume_with` and `EventReceiver`.
- **SSCC packing** (`std::from_chars` in C++, `int()` after an ASCII-digit check in Python, and in Java a single loop that
  accepts only the ASCII digits `0` to `9`, because `Long.parseLong` also takes non-ASCII Unicode digits that
  would alias the barcode) is checked against the barcodes in the `contracts/flat/parcel-v1` golden JSON by the unit
  tests in all three languages.

Placement is an experiment control. Each measured thread is pinned to one logical CPU of a distinct
physical core, chosen from sysfs topology by `distinct_cores`; CPU 0 is left alone. The pin is
`pthread_setaffinity_np`, OpenHFT `AffinityLock` or `os.sched_setaffinity`, and `verify.sh` reads where every
thread last ran from `/proc/<pid>/task/<tid>/stat`. The result lands in `runtime.placement`. It isn't
isolation: the scheduler still shares those cores with the rest of the host.

## Variants

| Language | Variant | What it is |
|---|---|---|
| C++, Java | `node-map` | `std::unordered_map<std::string, FatRecord>`; `HashMap<String, ParcelState>` |
| C++, Java | `flat-map` | `absl::flat_hash_map<uint64, uint32>` to a slot plus columns; Agrona `Long2LongHashMap` plus primitive arrays |
| C++, Java | `--fat-record` | one 80-byte struct per parcel; `ParcelState[]` of objects |
| C++, Java | `hot-cold` | `due_tick` and `state` columns, cold fields apart; primitive arrays |
| C++, Java | `--adjacent-counters` | the five read counters in one 64-byte line, the no-read counters in the next |
| C++, Java | `pair-padded` | one camera per 128 bytes |
| C++, Java | `--line-padded` | one camera per 64 bytes (observed) |
| C++, Java | `--smt-siblings` | adjacent layout, two cameras on one core's hardware threads (observed) |
| Java | `long-adder` | one `LongAdder` shared by all cameras (observed) |
| Python | `--dict-per-parcel` | a `dict` record per parcel, the shape a first draft has |
| Python | `slots-str`, `slots-int` | `@dataclass(slots=True)` records keyed by the barcode `str` or by the packed `int` |

A report's variant carries the operation as a prefix: `insert-`, `hub-lookup-`, `line-lookup-`, `hub-sweep-`,
`counters-` or `line-`, as in `hub-lookup-node-map` and `counters-pair-padded`. The defect-named spellings
work as options too: `tracker-bench --fat-record`, `counters-bench --adjacent-counters` and
`locality-py counters --adjacent-counters` are the same as `--variant NAME`.

### C++

`FlatTracker<Table>` is one tracker over either record table, so the sweep and the lookup benchmarks run the
same code. Allocation is counted exactly: `alloc_counter.cpp` replaces the global `operator new` with a
per-thread counter (the Ch5 pattern), and a measured region reads it before and after. Each hub lookup is
timed into an HdrHistogram; each sweep is timed as a whole. `perf stat` counts only the timed loop, through
its `--control` FIFOs. Cachegrind gets the sweep through a single `extern "C"` function
(`CACHEGRIND_FUNCTION`). The node map's hash and key compare run in libstdc++ and libc, outside any one
function, so the lookups are measured by difference instead: a run with 200,000 lookups minus the same run
with one.

The replaced `operator new` is linked into `tracker-bench`, `eliminating-line` and the unit test, and nowhere
else. `counters-bench` uses the standard allocator.

### Java

The JMH benchmarks use SampleTime with the `gc` profiler. `InsertBenchmark` reports bytes per
insert-and-erase pair at line scale. `HubLookupBenchmark` and `HubSweepBenchmark` run on 1,000,000
parcels, and the object table is allocated in a shuffled order so slot order isn't allocation order. Each
method gets its own fork, the benchmark thread is pinned with `AffinityLock`, and the heap is fixed and
pre-touched so no collection starts inside a run. The counters and the line run are standalone harnesses in
`Main` (`counters`, `consume`), because JMH can't give control of five pinned threads. Each camera thread
first runs its whole measured loop, `timeBatches`, on a scratch counter set for 600 ms. That matters more than
it sounds: warming only the inner batch left the outer loop at C1's profiling tier, whose shared profile
counters bounced between the five cores and added L1 misses to the padded layout.
Warmed whole, the loop runs C2 code and compilation stays out of the measured region, which lasts only tens of
milliseconds.

The lookup keys are built once, so their `String` hash codes are cached. On the line a barcode arrives as a
new `String` and pays the hash too, which makes the JMH lookup a conservative measure of the node map.
`perfnorm` with user-space events gives per-lookup hardware counters, observed.

### Python: fewer objects, not tighter ones

Python can't place an object or pad a field. The lever is the number of objects, and the lane measures it.

- `tracemalloc` bytes per tracked parcel for a `dict` per parcel against a `@dataclass(slots=True)` record,
  keyed by `str` and by `int`. Slots remove the per-instance dict, not the integers: every attribute value is
  still an object.
- The due sweep over a list of objects against an `array('Q')` column (observed). Iterating the column still
  creates an `int` for every element.
- False sharing between processes through `multiprocessing.shared_memory` (observed). Shared memory is a
  page-aligned array of 64-bit cells at known offsets, so adjacent and padded layouts exist even in Python.
  Threads under the GIL never write in parallel, so there's nothing to false-share. The free-threaded build
  (`python3.14t`, a user-local uv download) runs the same thread code in parallel, and the lane runs both
  builds. The measured process records raw batch times and never imports `lowlat_measure`, because importing
  the HdrHistogram C extension re-enables the GIL. `counters-report` turns the raw file into reports in the
  normal interpreter.

## Layout of the example

| Path | Contents |
|---|---|
| `cpp/` | headers `sscc.hpp`, `records.hpp`, `keys.hpp`, `tracker.hpp`, `counters.hpp`, `placement.hpp`, `perf_region.hpp`, `alloc_counter.hpp`; executables `tracker-bench`, `counters-bench`, `eliminating-line`, `eliminating-work-test` |
| `java/` | Maven module `eliminating-work-java` (`benchmarks.jar`: JMH main class; tools via `-cp`), package `io.patterncatalyst.lowlat.eliminating` |
| `locality-py/` | Python package `lowlat_locality`, console script `locality-py`, uv workspace member `lowlat-locality` |
| `verify.sh` | runs everything and asserts the criteria |

## Run

```bash
examples/09-eliminating-work/verify.sh
```

A full run takes about nine minutes. The usual switches from `examples/_lib/lib.sh` apply: `ALLOW_BUSY=1`,
`SKIP_BUILD=1`, `RESULTS_DIR`, `LOWLAT_BUILD`, and `RECHECK=results/<run-id>` to re-evaluate committed
reports without running anything. One is specific to this example: `SKIP_CACHEGRIND=1`. The JVM needs a 2 GB heap for the hub tables, and the C++ lookups
need a few hundred MB.

By hand:

```bash
B=examples/build/release/09-eliminating-work/cpp
export LOWLAT_PROFILE=/tmp/profile.json          # scripts/profile.sh --out /tmp/profile.json
$B/tracker-bench --mode lookup --variant flat-map --size 1000000 --cpu 2 --out /tmp/lookup.json
$B/tracker-bench --mode sweep --fat-record --cpu 2 --out /tmp/sweep.json
$B/counters-bench --adjacent-counters --cpus 1,2,3,4,5,6 --out /tmp/counters.json
JAR=examples/09-eliminating-work/java/target/benchmarks.jar
java -jar "$JAR" HubLookupBenchmark -prof gc
java --enable-native-access=ALL-UNNAMED -cp "$JAR" io.patterncatalyst.lowlat.eliminating.Main footprint
uv run --project examples --package lowlat-locality locality-py footprint --out /tmp/footprint.json
```

Reports land in `results/latest/`: `cpp/`, `java/` and `python/` hold one `<operation>-<variant>` report per
run (`.a1` to `.a3` are the three alternations). `cpp/cachegrind/` holds the simulated-cache summaries, and
the raw `java/*/jmh.json`, `python/footprint.json` and the machine profile sit beside them. View them with:

```bash
uv run --project examples lowlat-report show examples/09-eliminating-work/results/latest/cpp/*.json
```

## Expected effect and criteria

`verify.sh` evaluates every criterion, prints its measured value, bound and margin, and exits non-zero if any
failed. Latency criteria compare variants inside one run, alternating A B A B A B and judged on the median of
the three per-alternation ratios. p50 is never compared across runs. Exact counters (allocations, object sizes,
cachegrind misses) are deterministic and labelled so.

1. **Allocation and footprint (exact).** C++ `node-map` makes at least 2 allocations per insert and `flat-map`
   none after `reserve`. JMH `node-map` allocates at least 64 B per insert and `flat-map` at most 1 B. In
   Python the `dict` record object (`sys.getsizeof`) is at least 2x the slotted record, and `--dict-per-parcel`
   holds at least 2x the bytes of `slots-int` per tracked parcel. Against `slots-str` the ratio is observed,
   because the `str` key is a cost both shapes share.
2. **Hub lookups.** Cachegrind last-level read misses per lookup are at least 2x higher for `node-map`
   (exact), and so is `LLC-load-misses:u` per lookup in C++ (median of three). The p50 ratios for C++ and
   Java are observed, and their margins against 2x are printed.
3. **Hub sweep.** `--fat-record` p50 is at least 2x `hot-cold` p50 in C++ and Java, and cachegrind L1 data
   read misses per slot are at least 4x higher for `--fat-record` (exact; the byte ratio is 80:9).
4. **Counters**, on distinct physical cores with the placement asserted per thread. With the single-writer
   store increment, `L1-dcache-load-misses:u` per increment is at least 10x higher for `--adjacent-counters`
   than for `pair-padded`, in C++ and in Java (median of three). With the `fetch_add` increment, C++ per-batch
   p50 is at least 3x. The store-increment batch times and Java's `getAndAdd` times are observed.
5. **Line, C++.** Allocations per parcel on the receive thread, counted around the tracker calls (exact):
   `node-map` at least 1, `flat-map` none.
6. **Reports.** Every report has its count. The line runs have `dropped` = 0. Every report passes
   `lowlat-report check`, Java reports carry `build.flags`, and pinned runs carry `runtime.placement`.

Mechanism counters come first, then hardware counters, then latency. Hardware counters assert only the
generic `LLC-load-misses:u` and `L1-dcache-load-misses:u`. A vendor snoop event is observed and never asserted,
because it isn't portable.

### Counters: the increment is part of the experiment

Each camera counter has one writer, so the store increment is a relaxed load and a relaxed store, with no
read-modify-write (`bump_read`, or `setRelease(get() + 1)` in Java). That keeps the layout apart from the
cost of a `lock`-prefixed instruction. But a store buffer hides part of the coherence traffic from such a loop.
Each core's loads of its own counter are forwarded from its own pending stores, so the layout shows up in the L1
miss counts well before it shows up in the batch time. The same counts as an atomic read-modify-write
(`fetch_add`, `getAndAdd`) can't hide it, and there the batch time shows the effect in C++.

`verify.sh` runs both increments in three alternations and prints both. It asserts the miss counts for the
store increment and the batch time for the C++ `fetch_add` increment; the rest is printed as observed.

### Observed, not asserted

The hub lookup p50 ratios. The store-increment batch times, and Java's `getAndAdd` times. `--line-padded`
against `pair-padded` (does the adjacent-line prefetcher matter here? That's Ch7's claim). `--smt-siblings`: the
siblings share an L1, so line ping-pong is absent, but they also share one core's execution resources.
`long-adder`, line-scale lookups, and the other per-lookup and per-slot hardware counters from `perf` and
`perfnorm`. The build footprint. Line end-to-end percentiles, where both variants fit 480 ms by orders of
magnitude. The Java line's `alloc_bytes_per_parcel`, which the protobuf decode dominates. The JOL footprint. In
Python, the sweep and the process and thread counters on the GIL and free-threaded builds.

## Observation surfaces

| Surface | What it shows |
|---|---|
| Terminal output of `verify.sh` | each criterion with value, bound and margin, then the observed items |
| `lowlat-report show` | percentiles of every report: p50, p90, p99, p99.9, max |
| `runtime.counters` | exact allocation counts and bytes, cameras, increments |
| `runtime.hw_counters` | `perf` and `perfnorm` events per operation; cachegrind misses per operation |
| `runtime.placement` | the CPUs the measured threads were pinned to, distinct cores, SMT siblings |
| JMH `-prof gc` | bytes allocated per insert, collections during a sweep |
| JOL (`Main footprint`) | instance and graph sizes of the Java trackers |
| Grafana | no panel by design: the tracker is measured off the live path here, and low-overhead observability is Part 7 |

## Licences

| Component | Version | Licence | Used for |
|---|---|---|---|
| Agrona | 2.7.0 | Apache-2.0 | primitive-keyed map |
| OpenHFT Affinity (chronicle-bom 2026.26) | 2026.2 | Apache-2.0 | thread pinning |
| abseil-cpp | 20250512.1 | Apache-2.0 | `absl::flat_hash_map` |
| JMH | 1.37 | GPL-2.0-only WITH Classpath-exception-2.0 | Java benchmarks |
| JOL | 0.17 | GPL-2.0-only WITH Classpath-exception-2.0 | object layout and footprint |
| JNA and jna-platform (via Affinity) | 5.19.1 | LGPL-2.1-or-later OR Apache-2.0 | native calls behind thread pinning |
| slf4j-api (via Affinity) | 2.0.17 | MIT | Affinity's logging facade, no provider bound |
| jopt-simple, commons-math3 (via JMH) | 5.0.4, 3.6.1 | MIT, Apache-2.0 | JMH option parsing and statistics |

The GPL-with-Classpath-exception tools are build- and measurement-time only; no hot path links them.
protobuf (C++, Java, Python) is BSD-3-Clause. Jackson 3 and its annotations are Apache-2.0, HdrHistogram
BSD-2-Clause, GoogleTest BSD-3-Clause, nlohmann/json MIT, JUnit 6 EPL-2.0 (its opentest4j, apiguardian and
jspecify dependencies are Apache-2.0), pytest MIT. `perf` and `valgrind` (GPL-2.0) run as tools and
aren't linked. CPython is PSF-2.0. Versions are pinned in `versions.env` and `_plans/dependency-pins.md`.

## Verification status

Behavioural. `verify.sh` asserts the six criteria above, and all of them held on the host runs `r03-run1..3`
(bare-metal host, untuned: governor `powersave`, tuned `balanced`, clocksource `tsc`, kernel 7.2, Temurin
25.0.5+8, GCC 16.2, Python 3.14.8; lab VM down; commit 9802788; load average 1.15 to 1.25 at each start). Threads sat
on distinct physical cores other than CPU 0, placed with `sched_setaffinity` and asserted per thread. Ranges over the
three runs; a ratio is the range of each run's median over its 3 alternations.

| Quantity | Range |
|---|---|
| C++ allocations per insert, `node-map` / `flat-map` (exact) | 2 / 0 after `reserve` |
| JMH allocation per insert, `node-map` / `flat-map` (exact) | 128 B / 0.014 to 0.016 B |
| Python record object, `dict` / slotted (exact) | 3.41x (bound 2x) |
| Python bytes per tracked parcel, `dict` / `slots-int` (exact) | 2.05x (bound 2x, margin 1.02x) |
| Cachegrind LL read misses per lookup, `node-map` / `flat-map` (exact) | 5.94 / 0.70, 8.54x (bound 2x) |
| `perf` `LLC-load-misses:u` per lookup, ratio (C++) | 25.86x to 26.77x (bound 2x) |
| Hub sweep p50, `fat-record` / `hot-cold`, ratio | C++ 7.31x to 7.38x, Java 21.07x to 21.10x (bound 2x) |
| Cachegrind D1 read misses per slot, `fat-record` / `hot-cold` (exact) | 1.2500 / 0.1406, 8.89x (bound 4x) |
| L1 misses per increment, `adjacent-counters` / `pair-padded`, store increment | C++ 590x to 622x, Java 106x to 167x (bound 10x) |
| C++ `fetch_add` per-batch p50, `adjacent-counters` / `pair-padded` | 9.89x to 11.96x (bound 3x) |
| Line, C++ receive-thread allocations | `node-map` 400,000 (27.8 MB), `flat-map` 0 (exact) |
| Line runs | 200,000 parcels counted, none dropped; 82 reports pass `lowlat-report check`; every Java report carries `build.flags` and every pinned report `runtime.placement.cpus` |
| Observed: C++ hub lookup p50, `node-map` / `flat-map` | 389 to 393 ns / 113 ns, ratio 3.43x to 3.48x |
| Observed: Java hub lookup p50, `node-map` / `flat-map` | 321 to 322 ns / 57 to 58 ns, ratio 5.53x to 5.67x |
| Observed: line tracker (4,800 parcels) lookup p50, `node-map` / `flat-map` | 46 to 48 ns / 20 ns |
| Observed: store-increment batch p50 (1,000 increments), `adjacent-counters` / `pair-padded` | C++ 5,115 to 5,279 ns / 1,597 to 1,624 ns (3.18x to 3.29x); Java ratio 2.89x to 3.06x |
| Observed: Python sweep p50, list of records / array columns | 40.9 to 41.0 ms / 43.1 to 43.7 ms |

The store-increment batch ratios sit within 10 % of 3x (C++ 6 % to 10 % above, Java 4 % below to 2 % above) and are not asserted: a store buffer hides part of the
coherence traffic from a loop of plain stores, so the L1 miss counts carry the claim and the read-modify-write batch
time shows the effect in time. Exact counters carry no timing margin: the node map's 2 allocations per insert meet
their bound of 2, and the Python `dict` against `slots-int` clears 2x by 1.02x, because both are deterministic. Every
latency and hardware-counter bound clears with at least 2x.
