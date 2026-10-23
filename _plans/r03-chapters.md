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

## Verification status footer

The Ch0–Ch8 form, naming the asserted criteria, what is observed only, and the runs (`r03-run1` to `r03-run3`, bare-metal host, untuned).
