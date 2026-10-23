---
title: "Eliminating work: allocation, cache locality, false sharing"
order: 9
part: "Accelerating Code"
description: "At hub scale an open-addressing map on a packed key looks a parcel up in a p50 of 113-115 ns against 388-394 ns for a node map in C++, and padding five camera counters cuts L1 misses per increment 609-617x (bare-metal, untuned host, three runs)."
duration: 55 minutes
---

## Learning objectives

By the end of this chapter you can:

- Replace a node-based map with open addressing on a packed key, and say what that removes.
- Split a record into hot and cold columns, and predict the cache lines a sweep touches per slot.
- Read false sharing from the L1 miss count, and say when the batch time hides it.
- Say why the same tracker needs no change at line scale and does at hub scale.

## Why this matters

Every scan asks the tracker one question: where is this parcel? On one line the answer lives among about 4,800 parcels in flight (Chapter 2, *Modelling with Little's Law and Amdahl's Law*: 10 kHz over a 480 ms budget). A hub-wide tracker holds 1,000,000. The code is the same. What changes is the working set against the caches, which decides whether a lookup costs cache hits or trips to memory.

The budget is physical: 1.2 m at 2.5 m/s is 480 ms from scan to divert, and the belt doesn't wait. At line scale that's forgiving, so this chapter says which results matter at line rate and which only at hub scale. It covers the lookup map, the record the sweep reads, and the counters five cameras write.

[Chapter 5]({{ '/docs/05-jvm-costs/' | relative_url }}) covers TLABs and escape analysis, and [Chapter 6]({{ '/docs/06-gc-tails/' | relative_url }}) the collector's bill for a node map's garbage. [Chapter 7]({{ '/docs/07-offheap-lockfree/' | relative_url }}) padded its rings by design; here the padding is measured.

The code is in `examples/09-eliminating-work/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="09-working-set" alt="Nested bands show the host caches: L3 of 24 MiB, L2 of 1.25 MiB and L1d of 48 KiB with 64-byte lines. Inside L2 sits the line tracker with 4,800 parcels, where a node-map lookup takes a p50 of 47-48 ns and a flat-map lookup (amber) 19-20 ns. A separate RAM band holds the hub trackers of 1,000,000 parcels: the node-map, 148.1 MB built, with a lookup p50 of 388-394 ns and 5.04-5.15 last-level misses per lookup, and the flat-map (amber), 126.0 MB built, with 113-115 ns and 0.19-0.23 misses. A dashed box notes that both hub maps exceed the 24 MiB L3." caption="Figure 9.1: The 4,800-parcel line tracker fits L2 and both maps look up in tens of nanoseconds; at 1,000,000 parcels both maps live in RAM, 148.1 MB for the node-map and 126.0 MB for the flat map, and the layout sets the misses." %}

Profile for every number in this chapter: bare-metal host, untuned: `powersave` governor, `balanced` profile, kernel 7.2; 8-core/16-thread Intel laptop CPU; 64-byte lines, L1d 48 KiB and L2 1.25 MiB per core, L3 24 MiB shared; threads placed on distinct physical cores with `sched_setaffinity`, an experiment control, not isolation. Ranges span `r03-run1` to `r03-run3`.

The line tracker fits L2. A lookup among its 4,800 parcels takes a p50 of 47-48 ns in a node map and 19-20 ns in a flat map (observed). The hub tracker fits nothing: building it allocates 148.1 MB as a node map and 126.0 MB as a flat map, the flat figure including the cold columns. Both are far beyond the 24 MiB L3, so at hub scale the layout can't make the table fit. It can only make each lookup touch fewer lines.

## One lookup, two designs

### Node map against open addressing

A scan arrives with an 18-digit barcode. The first-draft tracker keys a `std::unordered_map<std::string, FatRecord>` with it. Eighteen characters is longer than libstdc++'s 15-character small-string buffer, so the key's text goes to the heap, and so does the map node: two allocations per insert, counted exactly with a replaced `operator new`, the Chapter 5 pattern. A lookup chases a bucket, a node and the key's characters, three dependent loads.

The alternative packs the barcode into a `uint64` and maps it to a slot in an `absl::flat_hash_map`. Java compares `HashMap<String, ParcelState>` with Agrona's `Long2LongHashMap`, open addressing over one `long[]`. First #A, the node map, then #B, the flat map.

{% include codetabs.html langs="C++|Java" %}

```cpp
  Tracked track(const Scan& scan) {
    const auto sscc = pack_sscc(scan.barcode);
    if (!sscc) return Tracked::rejected;
    if (const auto it = map_.find(scan.barcode); it != map_.end()) {
      rescan(it->second, scan);
      return Tracked::updated;
    }
    map_.emplace(std::string{scan.barcode}, make_record(scan, *sscc));
    return Tracked::inserted;
  }
```

```java
    @Override
    public Tracked track(Scan scan) {
        long sscc = Sscc.pack(scan.barcode);
        if (sscc == Sscc.INVALID) {
            return Tracked.REJECTED;
        }
        ParcelState existing = map.get(scan.barcode);
        if (existing != null) {
            existing.rescan(scan);
            return Tracked.UPDATED;
        }
        map.put(scan.barcode, ParcelState.of(scan, sscc));
        return Tracked.INSERTED;
    }
```

{% include codetabs.html langs="C++|Java" %}

```cpp
  Tracked track(const Scan& scan) {
    const auto sscc = pack_sscc(scan.barcode);
    if (!sscc) return Tracked::rejected;
    const auto [it, fresh] = index_.try_emplace(*sscc, 0U);  // one probe for both outcomes
    if (fresh) {
      it->second = table_.insert(make_record(scan, *sscc));
      return Tracked::inserted;
    }
    table_.rescan_slot(it->second, scan);
    return Tracked::updated;
  }
```

```java
    @Override
    public Tracked track(Scan scan) {
        long sscc = Sscc.pack(scan.barcode);
        if (sscc == Sscc.INVALID) {
            return Tracked.REJECTED;
        }
        long slot = index.get(sscc);
        if (slot == MISSING) {
            index.put(sscc, table.insert(scan, sscc));
            return Tracked.INSERTED;
        }
        table.rescan((int) slot, scan);
        return Tracked.UPDATED;
    }
```

{% include excalidraw.html file="09-node-vs-flat-map" alt="Two lanes. In the node-map lane an 18-digit barcode goes to a bucket (load 1), a node holding the ParcelState (load 2) and a heap string with the key text (load 3). Results: 2 allocations per insert in C++ (exact) and 128 B/op in Java, a hub lookup p50 of 388-394 ns in C++ and 321-323 ns in Java, and 5.94 last-level read misses per lookup in cachegrind. In the flat-map lane (amber) a packed uint64 barcode goes to one probe group of control bytes and slots, then to columns indexed by the slot. Results: 0 allocations after reserve in C++ (exact) and 0.017-0.018 B/op in Java, a hub lookup p50 of 113-115 ns in C++ and 56-61 ns in Java, and 0.70 last-level read misses per lookup." caption="Figure 9.2: One probe group and no allocation against three dependent loads and two allocations per insert: the hub lookup p50 falls from 388-394 ns to 113-115 ns in C++ and from 321-323 ns to 56-61 ns in Java." %}

In #A, `map_.find(scan.barcode)` takes a `string_view` because the hash is transparent (`StringHash`, with `std::equal_to<>`), so a lookup builds no `std::string`. The allocations happen at `emplace(std::string{...}, ...)`. In #B, `try_emplace(*sscc, 0U)` finds or inserts in one probe and reports which with `fresh`, and the map was `reserve`d once, so an insert allocates nothing. In Java, #A's `map.put` allocates a node and a `ParcelState`. #B's `Long2LongHashMap(expected, 0.55f, MISSING)` rounds its capacity up to a power of two and doesn't resize for `expected` entries; `MISSING` is what `get` returns for an absent key.

### What the saving is

The allocation counters are exact. C++ `node-map` makes 2 allocations per insert and `flat-map` makes 0 after `reserve`. JMH's `gc` profiler gives 128 B per insert-and-erase pair for the Java node map and 0.017-0.018 B for the flat map. Insert latency doesn't improve with that: the Java line-scale insert p50 is 96-97 ns for the node map and 108-110 ns for the flat one. What the flat map removes is garbage, whose price Chapter 6 measures.

At hub scale the lookups differ. The C++ lookup p50 is 388-394 ns for the node map and 113-115 ns for the flat map: 3.41-3.48x within each run, observed. Java's is 321-323 ns against 56-61 ns, 5.33-5.73x, also observed. Cachegrind, a simulation of a cache with this host's geometry, counts 5.94 last-level read misses per node-map lookup and 0.70 per flat-map lookup, 8.54x and exact. On the hardware, `perf stat` (user-space events) counts 5.04-5.15 and 0.19-0.23 last-level misses per lookup in the first alternation. L1 misses only halve, about 10.0 against 5.3 per lookup, so what disappears is the deep misses. Even 394 ns is under a millionth of the 480 ms budget; at hub scale the flat map buys CPU per parcel and headroom at saturation, not a deadline.

## Hot and cold columns

At every encoder tick the tracker sweeps its table for parcels due at the diverter. The sweep needs two fields of each record, `due_tick` (8 B) and `state` (1 B). The record you'd naturally write, `FatRecord`, is 80 B (a `static_assert` pins it), so each slot drags 71 unread bytes through the cache. #A is the fat table (`FatTable` in C++, `ObjectTable` in Java).

{% include codetabs.html langs="C++|Java" %}

```cpp
  [[nodiscard]] std::size_t sweep_due(std::uint64_t tick) const noexcept {
    std::size_t due = 0;
    for (const FatRecord& r : rows_) due += is_due(r.state, r.due_tick, tick);
    return due;
  }
```

```java
    @Override
    public int sweepDue(long tick) {
        int due = 0;
        for (int i = 0; i < slots; i++) {
            ParcelState r = rows[i];
            if (r != null && r.state == ParcelState.IN_FLIGHT && r.dueTick <= tick) {
                due++;
            }
        }
        return due;
    }
```

#B keeps the two fields in their own columns and the rest apart (`HotColdTable`, `ColumnTable`).

{% include codetabs.html langs="C++|Java" %}

```cpp
  [[nodiscard]] std::size_t sweep_due(std::uint64_t tick) const noexcept {
    std::size_t due = 0;
    for (std::size_t i = 0; i < state_.size(); ++i) due += is_due(state_[i], due_[i], tick);
    return due;
  }
```

```java
    @Override
    public int sweepDue(long tick) {
        int due = 0;
        for (int i = 0; i < slots; i++) {
            if (state[i] == ParcelState.IN_FLIGHT && dueTick[i] <= tick) {
                due++;
            }
        }
        return due;
    }
```

{% include excalidraw.html file="09-hot-cold-split" alt="In the fat-record lane each slot is one 80-byte struct. The sweep reads the due tick and the state, 9 of the 80 bytes, and takes a p50 of 4.21-4.26 ms in C++ and 9.30-9.40 ms in Java over 1,000,000 slots, with 1.2500 cachegrind D1 read misses per slot. In the hot-cold lane (amber) the due_tick column holds 8 B per slot and the state column 1 B per slot; a dashed ghost box holds the cold fields, 71 B per slot, which the sweep never reads. The sweep takes 0.57-0.58 ms in C++ and 0.44-0.45 ms in Java, with 0.1406 D1 read misses per slot." caption="Figure 9.3: The due sweep reads 9 of every 80 bytes. Splitting them into hot columns takes the sweep p50 from 4.21-4.26 ms to 0.57-0.58 ms in C++ and from 9.30-9.40 ms to 0.44-0.45 ms in Java." %}

`is_due` combines its two tests with a bitwise `&`, so the C++ sweep has no data-dependent branch and its time is the memory it reads. The Java fat table is an array of ordinary `ParcelState` objects (not Chapter 8's `MemorySegment` table) allocated in shuffled order; the hot columns are primitive arrays.

The line arithmetic predicts it: an 80 B slot is 1.25 cache lines and a 9 B slot 0.1406 of one. Cachegrind counts exactly that: 1.2500 against 0.1406 D1 read misses per slot, 8.89x. The hardware agrees: 9 MB of hot columns for 1,000,000 slots fit L3, and `perf` counts no last-level misses per slot for them against 0.84-0.90 for the 80 MB of fat records.

The C++ sweep p50 is 4.21-4.26 ms for the fat record and 0.57-0.58 ms for the columns, 7.30-7.43x. The Java sweep is 9.30-9.40 ms against 0.44-0.45 ms, 20.91-20.99x. The Java gap is larger because each fat slot is a reference to a 96 B object (JOL), a dependent load, where the C++ rows are contiguous and the prefetcher streams them. Chapter 8's flat table won for this reason; this chapter doesn't re-measure it.

## False sharing

Five cameras in the scan tunnel each count reads and no-reads, and each thread writes only its own counters. In the hardware's terms, five 8 B counters fit in one 64-byte line, and a store by one camera invalidates the other four cameras' copies of it. The line ping-pongs between cores.

Padding is the fix, and it isn't idiomatic C++ or Java. It's a latency construct, and the comments in `counters.hpp` and `CameraCounters.java` say so. `alignas(Align)` rounds a struct's address and size up to `Align`, so each array element starts on its own boundary. `AdjacentBank` forces the opposite: the five read counters share one line, and `alignas(kLine)` on the second member starts the no-read counters in the next. `std::hardware_destructive_interference_size` is 64 B here, and the padded layout uses twice that because Chapter 7 asserted that the L2 spatial prefetcher fetches lines in pairs. A Java heap array's alignment isn't controllable, so the counters live in one `MemorySegment` from `Arena.ofAuto().allocate(size, 128)`, Chapter 8's idiom.

{% include codetabs.html langs="C++|Java" %}

```cpp
struct alignas(kLine) AdjacentBank {
  std::array<std::atomic<std::uint64_t>, kCameras> reads{};
  alignas(kLine) std::array<std::atomic<std::uint64_t>, kCameras> no_reads{};
};
```

```java
        ADJACENT(8, 64),
        LINE_PADDED(64, 8),
        PAIR_PADDED(128, 8);
```

Each counter has one writer, so the increment is a relaxed load and a relaxed store. A contrast run uses an atomic read-modify-write instead.

{% include codetabs.html langs="C++|Java" %}

```cpp
  void bump_read() noexcept { reads.store(reads.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed); }
  // ...
  void add_read() noexcept { reads.fetch_add(1, std::memory_order_relaxed); }
```

```java
    private void bump(long offset) {
        LONG.setRelease(cells, offset, (long) LONG.get(cells, offset) + 1);
    }

    // ...
    public void addRead(int camera) {
        LONG.getAndAdd(cells, layout.readOffset(camera), 1L);
    }
```

{% include excalidraw.html file="09-false-sharing" alt="Two lanes of five camera threads on distinct cores. In the adjacent-counters lane (amber arrows) all five write counters 0 to 4, 8 B apart, in one 64-byte cache line. In C++ that costs 0.093-0.095 L1 misses per increment for stores and 0.43-0.44 for read-modify-write, and a batch of 1,000 increments has a p50 of 5,119-5,163 ns for stores and 51.9-55.9 us for read-modify-write. In the pair-padded lane each counter has its own 128-byte range: 0.00015-0.00016 misses per increment for stores, about 0.0002 for read-modify-write, and batch p50s of 1,606-1,616 ns and 4.89-4.90 us. A third box records 64-byte padding as an observed middle case, a store batch p50 of 1,656-1,676 ns. In Java the miss count falls 270-287x and the C++ one 609-617x." caption="Figure 9.4: Padding takes the L1 misses per increment from about 0.09 to nearly 0 for stores. The miss count falls 609-617x in C++ and 270-287x in Java; the store batch time moves about 3x, and the read-modify-write batch about 10x." %}

The miss count shows it decisively, and the batch time shows it less. For the store increment, L1 misses per increment fall 609-617x in C++ (0.093-0.095 to 0.00015-0.00016) and 270-287x in Java, both asserted at 10x or more. The batch of 1,000 increments moves only 3.15-3.19x in C++ (5,119-5,163 ns to 1,606-1,616 ns) and 3.02-3.08x in Java, observed. A store buffer hides most of it: stores retire into the buffer and the loop's loads of its own counter are forwarded from it, so line transfers overlap with execution. Those ratios clear 3x by only about 5 %, so the assertion sits on the miss count.

A read-modify-write can't hide behind the buffer: a `lock xadd` must own the line before it completes. C++ batch time moves 10.50-11.44x (51.9-55.9 us to 4.89-4.90 us), asserted at 3x or more, and Java's `getAndAdd` moves 10.97-12.34x, observed.

Two variations are observed only. Padding to 64 B each gives a store batch p50 of 1,656-1,676 ns against 1,606-1,616 ns for 128 B: 2-4 % slower in every run, too small to demonstrate Chapter 7's prefetcher reason. And two cameras on the SMT siblings of one core, adjacent layout, took 4,299-4,331 ns against 2,111-2,193 ns on distinct cores. Siblings were slower, not penalty-free. They share one L1, so no line moves between cores, but they also compete for the core's execution resources. This run doesn't pad the siblings, so it can't separate the two effects.

## Python: fewer objects, not tighter ones

Python can't place an object or pad a field, so the lever is the number of objects. `tracemalloc` counts 790.8 B per tracked parcel (100,000 parcels) for a `dict` per parcel, 462.8 B for a `@dataclass(slots=True)` record keyed by the barcode `str`, and 385.8 B keyed by the packed `int`.

```python
@dataclass(slots=True)
class ParcelRecord:
    # ...
    sscc: int
    due_tick: int
    scan_tick: int
```

`slots=True` drops the per-instance `__dict__`: the fields sit in fixed slots after the object header. The record container is 3.41x smaller (asserted at 2x or more, exact), and the whole tracked parcel is 2.05x smaller against the `int`-keyed shape, a thin 1.02x margin over its bound, though the count is exact. Against the `str`-keyed shape it's 1.71x, observed, because the 18-character key costs the same in both. Slots don't remove the integers: every attribute value is still an object.

Compact columns don't help. Sweeping 1,000,000 slots takes a p50 of 41.1-41.6 ms over a list of records and 42.9-43.3 ms over `array('Q')` columns, because iterating the array builds an `int` per element (observed).

The hardware effect is still there under the interpreter. Camera processes sharing an array through `multiprocessing.shared_memory` take a batch p50 of 140,927-161,023 ns adjacent against 55,199-55,775 ns padded, about 2.5-2.9x within each run. Threads on the free-threaded build show 175,871-184,447 ns against 60,895-61,407 ns. Threads under the GIL show no difference, 46,815-54,271 ns against 47,103-57,567 ns, because only one runs at a time (all observed). 

## Measure

Run from the repository root:

```bash
examples/09-eliminating-work/verify.sh
```

A full run takes about nine minutes. `ALLOW_BUSY=1` measures on a loaded host, noisily; `RECHECK=results/<run-id>` re-evaluates committed reports. Latency comparisons alternate A B A B A B and judge the median of the three ratios; a p50 is only ever compared inside one run.

| Criterion | Claim | Bound | Measured |
|---|---|---|---|
| 1a, 1b | C++ allocations per insert, node map, flat map after `reserve` | at least 2, 0 | 2, 0 (exact) |
| 1c, 1d | JMH bytes per insert, node map, flat map | at least 64, at most 1 | 128, 0.017-0.018 |
| 1e, 1f | Python record container, dict per parcel over `slots-int` | at least 2x | 3.41x, 2.05x (exact) |
| 2c, 2d | LL misses per lookup, node map over flat map | at least 2x | 8.54x cachegrind, 23.65-26.11x `perf` |
| 3a, 3b | sweep p50, fat record over hot/cold, C++ and Java | at least 2x | 7.30-7.43x, 20.91-20.99x |
| 3c | cachegrind D1 misses per slot | at least 4x | 8.89x (exact) |
| 4b, 4c | L1 misses per increment, adjacent over padded, C++ and Java | at least 10x | 609-617x, 270-287x |
| 4a | C++ read-modify-write batch p50 | at least 3x | 10.50-11.44x |
| 5a, 5b | C++ line allocations per parcel, node map, flat map | at least 1, 0 | 2, 0 (exact) |

The line run sends 10 kHz for 20 s (200,000 parcels) to a consumer holding the preloaded hub. The node map makes 400,000 tracker allocations on the receive thread (27.8 MB); the flat map makes none. End-to-end the two are indistinguishable: p50 56.8-57.7 us and p99 78-83 us for both, the two p50s within 1 us in each run, and the worst parcel 0.94-2.87 ms against 480 ms. At line rate the saving is CPU and headroom rather than latency; the first-draft tracker meets the budget by orders of magnitude. On the Java line the receive thread allocates 710.2-710.5 B per parcel against 582.5 B; the difference is the node map's insert.

## Cross-check

`perf` and cachegrind count the same sweeps independently. Per slot, `perf` gives 1.2525-1.2526 L1 misses for the fat record and 0.1409-0.1410 for the columns, against cachegrind's 1.2500 and 0.1406. Per lookup, `perf` counts 5.04-5.15 last-level misses for the node map where cachegrind counts 5.94, and 0.19-0.23 for the flat map where cachegrind counts 0.70. A simulated cache has no prefetcher, so the counts differ; both rank the designs the same way.

Measure what you think you measure. In Java, warming only the inner batch leaves the outer loop on C1's profiling tier, whose shared profile counters bounce between the five cores and add about 0.005 L1 misses per increment to the padded layout. Each camera therefore warms its whole measured loop first, and the padded layout measures 0.00033-0.00037.

## What you learned

- A node map costs two allocations per insert and three dependent loads per lookup. Open addressing on a packed `uint64` removes both; at hub scale the C++ lookup p50 falls from 388-394 ns to 113-115 ns.
- Both hub trackers exceed the 24 MiB L3, so the layout sets the misses per lookup (5.94 against 0.70 in simulation).
- A sweep that reads 9 of 80 bytes touches 1.25 lines per slot as a fat record and 0.1406 as columns: 7.30-7.43x in C++ and 20.91-20.99x in Java.
- False sharing shows in L1 misses per increment (609-617x in C++); a store loop's batch time moves about 3x, a read-modify-write's about 10x. SMT siblings were slower than distinct cores.
- At 4,800 parcels the tracker fits L2 and all of this is headroom. In Python the lever is fewer objects.

The next chapter, [*Lock-free and wait-free synchronization*]({{ '/docs/10-lockfree-waitfree/' | relative_url }}) (Part 3), asks what a stalled writer does to the rest. Chapter 15, *CPU partitioning and the noisy-neighbour problem* (Part 5), covers isolation.

## For deeper coverage

- Enberg, *Latency* (Manning), as further reading.
- Back-links: [Chapter 5]({{ '/docs/05-jvm-costs/' | relative_url }}) (TLAB, escape analysis), [Chapter 6]({{ '/docs/06-gc-tails/' | relative_url }}) (GC cost), [Chapter 7]({{ '/docs/07-offheap-lockfree/' | relative_url }}) (ring padding), [Chapter 8]({{ '/docs/08-zero-copy-flat/' | relative_url }}) (flat table, FFM).
- `examples/09-eliminating-work/README.md` and `examples/common/MEASUREMENT.md`.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts the exact allocation counts (C++, JMH, Python bytes, the line's receive thread); that last-level misses per lookup are at least 2x higher for the node map in cachegrind and `perf`; that the fat-record sweep p50 is at least 2x the hot/cold p50 in C++ and Java and cachegrind D1 misses per slot at least 4x; that L1 misses per increment are at least 10x higher adjacent than padded in C++ and Java and the C++ read-modify-write batch p50 at least 3x; and that every report passes `lowlat-report check`, with `dropped` of 0, `build.flags` and `runtime.placement`. Observed only: the hub lookup p50 ratios, store-increment and `getAndAdd` batch times, 64-byte padding, SMT siblings, line-scale lookups, footprints, the line's end-to-end percentiles and the Python sweep and process and thread counters. It held on `r03-run1` to `r03-run3` (bare-metal host, untuned, commit 20664bd).*
