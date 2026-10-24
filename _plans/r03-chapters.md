---
title: "r03 chapters (S10–S11)"
layout: plan
render_with_liquid: false
---

# r03 chapters: S10–S11

One chapter per example, written from the example's code and its committed S8 (or S15) results. Binding for both chapters. Shape, numbers, voice, Liquid and listing rules follow [r02-chapters.md](r02-chapters.md) unless this brief changes them. Each executor edits only its own chapter file; `_data/diagrams.yml`, READMEs, the outline and `_example_pages/` are S12's.

## Files

| Step | File | `order` | `part` | Title | Example |
|---|---|---|---|---|---|
| S10 | `_docs/09-eliminating-work.md` | 9 | `Accelerating Code` | Eliminating work: allocation, cache locality, false sharing | `examples/09-eliminating-work/` |
| S11 | `_docs/10-lockfree-waitfree.md` | 10 | `Accelerating Code` | Lock-free and wait-free synchronization | `examples/10-lockfree-waitfree/` |

`duration`: `55 minutes` each. Commits: `docs(§9): Ch9 Eliminating work (S10)`, `docs(§10): Ch10 Lock-free and wait-free synchronization (S11)`.

## What changes from r02

- **Code tabs:** C++ first, the include default order, always passed explicitly: `langs="C++|Python|Java"`, or a subset where a language has nothing equivalent (Ch10 parts b and c have no Python lane; say so in one sentence and teach why).
- **Profile line:** from `r03-run1/profile.json`. Add the cache geometry (64-byte line, L1d 48 KiB and L2 1.25 MiB per core, L3 24 MiB shared) and "threads placed on distinct physical cores by `sched_setaffinity` (an experiment control, not isolation)" if Q1 = yes. Never the CPU part name; perf and valgrind as major.minor.
- **Comparisons:** latency comparisons only within one run, as the median of 3 alternations where `verify.sh` alternates; never a p50 across runs. A margin under 2x is stated where the claim is made.
- **Counters:** quote hardware counters per operation and name their source (`perf stat` user-space events, cachegrind simulation, JMH `perfnorm`). Cachegrind numbers are a simulation of a cache with the host's geometry, labelled so.
- **House voice from the first draft** (`lgtm-professional-voice`, "House voice: write it this way", modelled on Geewax's *API Design Patterns*; paste it into the executor prompt). Open each section on a concrete thing in the line (the tracker, a camera thread, the diverter) before naming the abstraction. Contract negations and "it is" forms. Vary sentence length. No rhetorical triads; three real items (three languages, three percentiles) are a list, not a cadence. Captions are `Figure N.x: …` with a colon, never an em dash. Before handing back: `scan.sh --tier ban` 0 and `scan.sh --stats` with no `stiff`, `uniform` or `em dash` flag.
- **No VM part:** if a reader asks about isolation, point to Chapter 15 (Part 5).

## Ch9: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Hook | The tracker answers one question per scan: where is this parcel? At one line it holds about 4,800 parcels (Ch2: 10 kHz x 480 ms); a hub-wide tracker holds 1,000,000. Same code, a different working set relative to the caches. |
| Map | Node map (`std::unordered_map<std::string,...>`, `HashMap<String,...>`, `dict` per parcel) -> 1M hub lookups and line-rate inserts -> allocation per insert and dependent misses per lookup fall when the key is a packed `uint64` in an open-addressing table (abseil, Agrona) -> exact allocation counters; same-run p50 ratio; cachegrind LL misses per lookup |
| Layout | Fat record against hot/cold columns -> sweep of 1M slots for due parcels each tick (Ch8's sweep with the record you would naturally write) -> bytes and lines touched per slot drop about 9x -> cachegrind D1 misses per slot (exact); same-run p50 ratio. Says why Ch8's flat table won |
| False sharing | Five camera counters adjacent against padded to 128 B -> per-camera threads on distinct cores -> each write steals the line -> L1 misses per increment, same-run batch p50; observed 64 B padding (Ch7's prefetcher claim, now measured), SMT siblings (shared L1: no penalty), `LongAdder` |
| Python | Fewer objects, not layout: `slots`, `int` keys (tracemalloc, exact); array sweep still boxes; processes show the hardware effect under interpreter cost (observed) |
| Line | 10 kHz x 20 s with the hub table loaded: allocation per parcel (C++ exact), end-to-end percentiles observed; both variants fit 480 ms by orders of magnitude; the saving is CPU per parcel and headroom, stated without a latency claim |
| Cross-check | perf hardware counters against cachegrind's simulated counts, for the same functions |

Boundaries: TLAB and escape analysis are Ch5 (back-link); the GC cost of a node map's garbage is Ch6 (back-link); the flat off-heap table and FFM are Ch8 (back-link, no re-measure of 08); ring padding was asserted in Ch7 by design, and Ch9 measures it.

## Ch10: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Hook | A five-camera scan tunnel reads every parcel; every read goes to one tracker. Who writes next, and what happens when one writer stalls? |
| Progress | Mutex, CAS loop, fetch-add claim -> 4 producers x 1M claims -> mutex tails carry futex sleeps; CAS retries are unbounded but someone always progresses; fetch-add is one step on x86 -> exactly-once (exact), steps per claim (exact), voluntary context switches, same-run p99.9 ratio |
| Stall | A producer stopped between claim and publish -> the consumer waits at that slot -> wait-free claim, blocking structure -> consumer wait at least 0.5 ms for a 1 ms stall |
| Memory order | Induction-gap test -> 10M trials on two cores -> release/acquire lets both stations claim one gap (store buffer); `seq_cst`/volatile forbids it -> forbidden outcome 0 (exact), allowed outcome at least 1; `VarHandle` mode mapping; per-store cost observed |
| Read side | Shared mutex against seqlock (`StampedLock` optimistic in Java) -> 1 writer, 3 readers -> the writer never waits for readers -> torn reads 0 (exact), writer p99.9 ratio |
| Reclamation | ABA and reclamation in prose: monotonic 64-bit sequences avoid ABA; hazard pointers and epochs in C++ (C++26 status only), the collector in Java, the GIL in Python |
| Line | Four simulator instances as four cameras -> MPSC into the tracker -> no difference at 2.5 kHz per camera, observed; the microbenchmark at saturation shows where it would differ |
| Cross-check | C++ harness against jcstress for the litmus test; context-switch counters against claim tails |

Boundaries: SPSC rings, Agrona/Disruptor idle strategies and Chronicle are Ch7 (back-link); thread-per-core and event loops are Part 4 (Ch11, Ch12); isolation is Ch15.

## Claims and evidence tables

Filled in at S10/S11 from `r03-run1..3`, in the r02-chapters form (claim | evidence file and field). Report failures and outliers as they are.

### Ch9 (S10)

Evidence root: `examples/09-eliminating-work/results/r03-run{1,2,3}/` (re-measured at commit 9802788, S15; every number below is from those runs). Ranges are across the three runs; ratios are the range of each run's median over its 3 alternations; `verify.log` lines are named by their label. No failure or outlier: every criterion held in all three runs.

| Claim | Evidence file and field |
|---|---|
| Profile line (governor, tuned, kernel 7.2; L1d 49,152 B, L2 1,310,720 B, L3 25,165,824 B; 64-byte lines) | `r03-run1/profile.json` `cpu.caches.*`, `virt`; `verify.log` line 1 |
| Placement: threads on distinct physical cores, asserted per thread | `verify.log` 'pinned threads use physical cores' and `placement:` lines |
| Line tracker 4,800 parcels: lookup p50 46-48 ns node map, 20 ns flat map (observed) | `verify.log` 'line-scale lookups' |
| Hub build footprint 148.1 MB node map, 126.0 MB flat map (exact) | `verify.log` 'build footprint' (148142568 B, 125964092 B) |
| C++ node map 2 allocations per insert; flat map 0 after reserve (exact) | `verify.log` 1a, 1b |
| JMH 128 B per insert-and-erase pair (node map), 0.014-0.016 B (flat map) | `verify.log` 1c, 1d; `insert-node-map`, `insert-flat-map` line |
| Java line-scale insert p50 60-62 ns node map, 99-103 ns flat map across all nine alternations (observed); the insert gets worse | `java/insert-aN-insert{NodeMap,FlatMap}/java-insert-*-map.json` p50, three runs |
| C++ hub lookup p50 389-393 ns node map, 113 ns flat map (median of 3 alternations) | `verify.log` 'hub lookup p50 (ns) by alternation' (C++) |
| C++ lookup p50 ratio 3.43-3.48x (observed) | `verify.log` observed 2a |
| Java lookup p50 321-322 ns vs 57-58 ns; ratio 5.53-5.67x (observed) | `verify.log` 'hub lookup p50 (ns) by alternation' (Java); observed 2b |
| Cachegrind LL read misses per lookup 5.94 vs 0.70, 8.54x (exact, simulated cache of the host geometry) | `verify.log` 'cachegrind per lookup'; criterion 2c |
| `perf` LL misses per lookup 5.00-5.13 vs 0.19-0.20 (alternation 1, `:u`); L1 misses per lookup about 10.0 vs 5.3 | `verify.log` 'hub lookup node-map' and 'hub lookup flat-map' lines (L1 10.011-10.061, 5.256-5.285) |
| `perf` LL-miss ratio 25.86-26.77x (median of 3, asserted at least 2x) | `verify.log` criterion 2d |
| Hub lookup under a millionth of the 480 ms budget | 389-393 ns against 480,000,000 ns; budget from Ch2 and `README.md` |
| `FatRecord` 80 B, reads 9 B (`due_tick` 8 B, `state` 1 B), 71 B cold | `cpp/include/lowlat/eliminating/records.hpp` (`static_assert(sizeof(FatRecord) == 80)`) |
| Cachegrind D1 read misses per slot 1.2500 vs 0.1406, 8.89x (exact; 80/64 and 9/64 lines) | `verify.log` 'cachegrind per slot'; criterion 3c |
| `perf` L1 misses per slot 1.2525-1.2526 vs 0.1410; LL misses per slot 0.85-0.88 vs 0 | `verify.log` 'hub sweep fat-record' and 'hub sweep hot-cold' lines |
| 9 MB hot columns vs 80 MB fat records at 1,000,000 slots | 9 B and 80 B per slot times 1,000,000 (arithmetic, record sizes above) |
| C++ sweep p50 4.18-4.21 ms vs 0.57 ms; ratio 7.31-7.38x (asserted at least 2x) | `verify.log` 'hub sweep p50 (ns) by alternation' (C++); criterion 3a |
| Java sweep p50 9.25-9.27 ms vs 0.44 ms; ratio 21.07-21.10x (asserted at least 2x) | `verify.log` 'hub sweep p50 (ns) by alternation' (Java); criterion 3b |
| Java `ParcelState` 96 B per object (JOL) | `java/footprint.json` `parcel_state_instance_bytes`; `verify.log` 'JOL footprint' |
| L1 misses per increment, store: C++ 0.093-0.094 vs 0.00016, ratio 590-622x (asserted at least 10x) | `verify.log` '[store increment] L1-dcache-load-misses:u'; criterion 4b |
| Java store L1-miss ratio 106-167x (asserted at least 10x) | `verify.log` criterion 4c |
| Java padded layout 0.00033-0.0013 L1 misses per increment; the six of nine runs above 0.0004 retired 3.9-6.2 million more instructions than line-padded's 44.198 per increment | `java/counters-pair-padded.aN.json` and `counters-line-padded.json` `runtime.hw_counters.per_op`, three runs |
| Store batch p50 (1,000 increments): C++ 5,115-5,279 ns vs 1,597-1,624 ns, ratio 3.18-3.29x (observed) | `verify.log` '[store increment] per-batch'; observed 4a' |
| Java store batch ratio 2.89-3.06x (observed) | `verify.log` observed 4c' |
| Store-batch ratios sit 6-10 % (C++) above 3x and 4 % below to 2 % above (Java), not asserted | `verify.log` observed 4a' (margins 1.06-1.10x) and observed 4c' (0.96-1.02x) |
| C++ rmw batch p50 48.3-57.3 us vs 4.89-5.01 us, ratio 9.89-11.96x (asserted at least 3x) | `verify.log` '[rmw increment] per-batch'; criterion 4a |
| Java `getAndAdd` batch ratio 11.02-12.29x (observed) | `verify.log` observed 4c'' |
| 64-byte padding store batch p50 1,653-1,692 ns vs 1,603-1,625 ns for 128 B in the same alternation (2-6 % slower, observed); 0.00016 L1 misses per increment | `verify.log` 'observed: line-padded (64 B)' (1,665/1,624, 1,653/1,625, 1,692/1,603); `cpp/counters-line-padded.json` and `cpp/counters-pair-padded.a1.json` `runtime.hw_counters.per_op.L1-dcache-load-misses` (0.000156, 0.000158, 0.000157 vs 0.000156, 0.000155, 0.000156) |
| SMT siblings 4,311-4,383 ns vs 1,948-2,197 ns on distinct cores (adjacent layout, observed); L1 misses per increment 0.00020-0.00022 vs 0.081-0.098 | `verify.log` 'observed: two cameras on SMT siblings'; `cpp/counters-smt-siblings.json` and `cpp/counters-adjacent-counters.2-cameras.json` `runtime.hw_counters.per_op.L1-dcache-load-misses` |
| Java: each camera warms its whole measured loop, because an inner-batch-only warm-up would leave the outer loop on C1's profiling tier; padded layout 0.00033-0.0013 (the un-warmed case is not a committed result) | `java/.../CountersRun.java` `timeBatches` warm-up; `README.md` (Java section); padded row above |
| Python bytes per tracked parcel 790.8 (dict), 462.8 (slots-str), 385.8 (slots-int) | `python/footprint.json` `tracked_bytes_per_parcel`; `verify.log` Python block |
| Python record container 3.41x (asserted at least 2x, exact); dict vs slots-int 2.05x (asserted, margin 1.02x); vs slots-str 1.71x (observed) | `verify.log` criteria 1e, 1f; observed 1f' |
| Python sweep p50 40.9-41.0 ms (list of records) vs 43.1-43.7 ms (array columns), 1,000,000 slots (observed) | `verify.log` 'hub-sweep-fat-record' and 'hub-sweep-hot-cold' lines |
| Python processes batch p50 150,143-151,551 ns adjacent vs 55,647-56,767 ns padded; ratio 2.67-2.70x within a run (observed) | `verify.log` 'counters-processes-*' lines; ratio computed per run |
| Python free-threaded threads 165,631-221,951 ns vs 60,351-61,279 ns; GIL threads 62,463-68,543 ns vs 65,119-78,975 ns (observed) | `verify.log` 'counters-threads-free-threaded-*' and 'counters-threads-gil-*' lines |
| Line, C++: 400,000 tracker allocations (27.8 MB) on the receive thread for the node map, 0 for the flat map (exact) | `verify.log` line-node-map / line-flat-map lines; criteria 5a, 5b |
| Line, C++ end-to-end p50 56.8-57.6 us, p99 78.8-79.7 us, p50s within 1 us per run, worst parcel 0.46-4.80 ms (observed) | `verify.log` line-node-map / line-flat-map lines; 'line end-to-end fits the 480 ms' line |
| Java line receive-thread allocation 710.2 B vs 582.5 B per parcel (observed) | `verify.log` 'line-node-map', 'line-flat-map' (Java) lines |
| perf vs cachegrind agree on ranking; simulated cache has no prefetcher | values above; cachegrind is a cache simulation, `perf` counts hardware events |
| Cachegrind counts lookups by difference (200,000 lookups minus one); `perf stat` counts only the timed loop through `--control` FIFOs | `README.md` (C++ section) |
| Hub FlatMapTracker `expected` 1,062,500 = 1,000,000 + 1,000,000/16; 2^21 slots; resize threshold 0.55 x 2^21 = 1,153,433 | `java/.../HubLookupBenchmark.java` (`PARCELS + PARCELS / 16`), `FlatMapTracker.java` comment, Agrona `Long2LongHashMap` (capacity rounded to a power of two) |
| Toolchain: Temurin 25.0.5+8, GCC 16.2, Python 3.14.8; CPU 0 left out of placement | `r03-run1/profile.json` `tools.*`; `verify.sh` (CPU 0 comment); `_plans/dependency-pins.md` (3.14.8+freethreaded) |

### Ch10 claims (S11, `examples/10-lockfree-waitfree/results/r03-run{1,2,3}/`)

Ranges across the three runs; ratios are the range of each run's median over its 3 alternations; p99 absolutes are alternation 1. Report fields are in `*.json` `percentiles` and `runtime.counters`; the printed values in `verify.log`.

| Claim | Evidence |
|---|---|
| Each sequence claimed exactly once, every synchronised variant, C++ and Java; Python `lock` 0 lost in GIL and free-threaded builds (exact) | `verify.log` criterion 1 |
| `fetch-add` 1 step per claim (exact); `cas-loop` at least 2,711,734 failed CAS in C++ and 3,824,735 in Java (least contended of 3 runs, per run); largest retry count in one claim 7-10 (C++), 27-55 (Java) | `verify.log` criterion 2; `runtime.counters` |
| `mutex` least-switching producer voluntary switches 5,406-9,746 (C++), 47,556-61,712 (Java); `fetch-add` most-switching 1 (C++), 1-3 (Java) | `verify.log` criterion 2 (medians of 3); `runtime.ctx_switches` |
| Claim p99 (alt 1): `mutex` 2,633-2,985 / `cas-loop` 478-502 / `fetch-add` 400-468 ns (C++); 8,187-8,383 / 1,409-1,837 / 516-584 ns (Java) | `verify.log` criterion 3 print; `cpp-<variant>-alt1.json`, `java-<variant>-alt1.json` `percentiles` |
| Claim p99 ratio `mutex`/`fetch-add` 6.10-6.45x C++ (bound 2.5x, worst margin 2.44x), 14.13-15.23x Java (bound 3x); asserted | `verify.log` criterion 3 |
| Claim p99.9 ratio 5.64-5.92x C++, 6.24-6.40x Java; observed only, not asserted; `cas-loop` vs `fetch-add` observed | `verify.log` "observed ... p99.9 per alternation", "observed: ... cas-loop over fetch-add" |
| Stalled producer (1 ms): consumer wait 1.05-1.07 ms C++, 1.11-1.14 ms Java (bound 0.5 ms, 2x by construction); unstalled largest wait 105-145 us C++, 0.67-0.84 ms Java (observed) | `*-fetch-add-stalled-consumer-wait.json`; `verify.log` criterion 4 |
| Litmus: C++ `seq_cst` both-zero 0 and Java `volatile` 0 (exact); C++ release/acquire 2,306,475-9,888,040 of 10,000,000; Java `setRelease`/`getAcquire` 85.0-98.6 million jcstress samples (at least 1 asserted) | `verify.log` criterion 5; `cpp-litmus-*.json` `runtime.counters`; `java-jcstress-summary.txt` |
| Per-store p50: C++ release 0 ns, `seq_cst` 4 ns; Java `setRelease` 0, `volatile` 4 ns; observed. The chapter states the `LoopUnrollLimit=1` reason qualitatively (no uncommitted numbers) | `verify.log` "per-store cost"; `examples/10-lockfree-waitfree/README.md` |
| Seqlock: torn snapshots 0 (exact) in 2.44-2.62 billion C++ and 1.22-1.30 billion Java reads; reader retries 4,904,289-26,715,000 (C++), 6,125,589-6,366,054 (Java), observed | `verify.log` criterion 6; `cpp-cell-seqlock-alt*.json`, `java-cell-stamped-lock-alt*.json` |
| Writer p99 (alt 1): shared lock 5,979-6,603 ns (C++), 8,083-8,287 ns (Java); seqlock 25-32 ns, 206-234 ns; ratio 205.5-231.0x C++, 34.5-37.1x Java (bound 3x, asserted); p99.9 ratio 4.44-5.17x, 2.60-3.01x observed only | `verify.log` criterion 6 |
| Python free-threaded `--racy-claim` lost 97,002 / 115,804 / 116,017 of 400,000 (run 3, 2, 1); GIL build 0; `itertools-count` 0 in both builds (observed); GIL stayed off | `verify.log` criterion 1 and observed line |
| Python `lock` claim p99 664-686 ns (GIL), 13,007-13,367 ns (free-threaded); observed | `verify.log` "observed: Python claim tail" |
| Line: 200,000 parcels, dropped 0 per camera, all commands received (four variants); end-to-end p99 (observed): C++ `mutex` 100,479-107,967 ns, `fetch-add` 93,951-116,159 ns; Java `blocking-queue` 127,423-162,175 ns, `agrona-mpsc` 109,503-113,471 ns | `verify.log` criterion 7; `*-line-*.json` |
| Outliers and failures: none; no asserted bound cleared with under 2x margin (smallest: C++ claim p99 2.44x, stall wait 2.11x by construction) | `verify.log` criteria lines |

## Verification status footer

The Ch0–Ch8 form, naming the asserted criteria, what is observed only, and the runs (`r03-run1` to `r03-run3`, bare-metal host, untuned).
