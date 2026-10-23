---
title: "r03 chapters (S10–S11)"
layout: plan
render_with_liquid: false
---

# r03 chapters — S10–S11

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

## Ch9 — arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Hook | The tracker answers one question per scan: where is this parcel? At one line it holds about 4,800 parcels (Ch2: 10 kHz x 480 ms); a hub-wide tracker holds 1,000,000. Same code, a different working set relative to the caches. |
| Map | Node map (`std::unordered_map<std::string,...>`, `HashMap<String,...>`, `dict` per parcel) -> 1M hub lookups and line-rate inserts -> allocation per insert and dependent misses per lookup fall when the key is a packed `uint64` in an open-addressing table (abseil, Agrona) -> exact allocation counters; same-run p50 ratio; cachegrind LL misses per lookup |
| Layout | Fat record against hot/cold columns -> sweep of 1M slots for due parcels each tick (Ch8's sweep with the record you would naturally write) -> bytes and lines touched per slot drop about 9x -> cachegrind D1 misses per slot (exact); same-run p50 ratio. Says why Ch8's flat table won |
| False sharing | Five camera counters adjacent against padded to 128 B -> per-camera threads on distinct cores -> each write steals the line -> L1 misses per increment, same-run batch p50; observed 64 B padding (Ch7's prefetcher claim, now measured), SMT siblings (shared L1: no penalty), `LongAdder` |
| Python | Fewer objects, not layout: `slots`, `int` keys (tracemalloc, exact); array sweep still boxes; processes show the hardware effect under interpreter cost (observed) |
| Line | 10 kHz x 20 s with the hub table loaded: allocation per parcel (C++ exact), end-to-end percentiles observed; both variants fit 480 ms by orders of magnitude; the saving is CPU per parcel and headroom, said plainly |
| Cross-check | perf hardware counters against cachegrind's simulated counts, for the same functions |

Boundaries: TLAB and escape analysis are Ch5 (back-link); the GC cost of a node map's garbage is Ch6 (back-link); the flat off-heap table and FFM are Ch8 (back-link, no re-measure of 08); ring padding was asserted in Ch7 by design, and Ch9 measures it.

## Ch10 — arc

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

Filled in at S10/S11 from `r03-run1..3`, in the r02-chapters form (claim | evidence file and field). Report failures and outliers plainly.

### Ch10 claims (S11, `examples/10-lockfree-waitfree/results/r03-run{1,2,3}/`)

Ranges across the three runs; ratios are the range of each run's median over its 3 alternations; p99 absolutes are alternation 1. Report fields are in `*.json` `percentiles` and `runtime.counters`; the printed values in `verify.log`.

| Claim | Evidence |
|---|---|
| Each sequence claimed exactly once, every synchronised variant, C++ and Java; Python `lock` 0 lost in GIL and free-threaded builds (exact) | `verify.log` criterion 1 |
| `fetch-add` 1 step per claim (exact); `cas-loop` at least 2,711,734 failed CAS in C++ and 3,824,735 in Java (least contended of 3 runs, per run); largest retry count in one claim 7-10 (C++), 27-55 (Java) | `verify.log` criterion 2; `runtime.counters` |
| `mutex` least-switching producer voluntary switches 5,406-9,746 (C++), 47,556-61,712 (Java); `fetch-add` most-switching 1 (C++), 1-3 (Java) | `verify.log` criterion 2 (medians of 3); `runtime.ctx_switches` |
| Claim p99 (alt 1): `mutex` 2,633-2,985 / `cas-loop` 478-502 / `fetch-add` 400-468 ns (C++); 8,187-8,383 / 1,409-1,837 / 516-584 ns (Java) | `verify.log` criterion 3 print; `cpp-<variant>-alt1.json`, `java-<variant>-alt1.json` `percentiles` |
| Claim p99 ratio `mutex`/`fetch-add` 6.10-6.45x C++ (bound 2.5x, worst margin 2.44x), 14.13-15.23x Java (bound 3x); asserted | `verify.log` criterion 3 |
| Claim p99.9 ratio 5.64-5.92x C++, 6.24-6.40x Java; observed (host interrupt floor); `cas-loop` vs `fetch-add` observed | `verify.log` "observed ... p99.9 per alternation", "observed: ... cas-loop over fetch-add" |
| Stalled producer (1 ms): consumer wait 1.05-1.07 ms C++, 1.11-1.14 ms Java (bound 0.5 ms, 2x by construction); unstalled largest wait 105-145 us C++, 0.67-0.84 ms Java (observed) | `*-fetch-add-stalled-consumer-wait.json`; `verify.log` criterion 4 |
| Litmus: C++ `seq_cst` both-zero 0 and Java `volatile` 0 (exact); C++ release/acquire 2,306,475-9,888,040 of 10,000,000; Java `setRelease`/`getAcquire` 85.0-98.6 million jcstress samples (at least 1 asserted) | `verify.log` criterion 5; `cpp-litmus-*.json` `runtime.counters`; `java-jcstress-summary.txt` |
| Per-store p50: C++ release 0 ns, `seq_cst` 4 ns; Java `setRelease` 0, `volatile` 4 ns; observed. The JMH `LoopUnrollLimit=1` note (1.2 ns, 0.25 vs 1.00 `lock_loads` per store) is a calibration observation from the README, not a committed run | `verify.log` "per-store cost"; `examples/10-lockfree-waitfree/README.md` |
| Seqlock: torn snapshots 0 (exact) in 2.44-2.62 billion C++ and 1.22-1.30 billion Java reads; reader retries 4,904,289-26,715,000 (C++), 6,125,589-6,366,054 (Java), observed | `verify.log` criterion 6; `cpp-cell-seqlock-alt*.json`, `java-cell-stamped-lock-alt*.json` |
| Writer p99 (alt 1): shared lock 5,979-6,603 ns (C++), 8,083-8,287 ns (Java); seqlock 25-32 ns, 206-234 ns; ratio 205.5-231.0x C++, 34.5-37.1x Java (bound 3x, asserted); p99.9 ratio 4.44-5.17x, 2.60-3.01x observed | `verify.log` criterion 6 |
| Python free-threaded `--racy-claim` lost 97,002 / 115,804 / 116,017 of 400,000 (run 3, 2, 1); GIL build 0; `itertools-count` 0 in both builds (observed); GIL stayed off | `verify.log` criterion 1 and observed line |
| Python `lock` claim p99 664-686 ns (GIL), 13,007-13,367 ns (free-threaded); observed | `verify.log` "observed: Python claim tail" |
| Line: 200,000 parcels, dropped 0 per camera, all commands received (four variants); end-to-end p99 (observed): C++ `mutex` 100,479-107,967 ns, `fetch-add` 93,951-116,159 ns; Java `blocking-queue` 127,423-162,175 ns, `agrona-mpsc` 109,503-113,471 ns | `verify.log` criterion 7; `*-line-*.json` |
| Outliers and failures: none; no asserted bound cleared with under 2x margin (smallest: C++ claim p99 2.44x, stall wait 2.11x by construction) | `verify.log` criteria lines |

## Verification status footer

The Ch0–Ch8 form, naming the asserted criteria, what is observed only, and the runs (`r03-run1` to `r03-run3`, bare-metal host, untuned).
