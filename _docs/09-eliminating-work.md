---
title: "Eliminating work: allocation, cache locality, false sharing"
order: 9
part: "Accelerating Code"
description: "At hub scale an open-addressing map on a packed key looks a parcel up in a p50 of 113 ns against 389-393 ns for a node map in C++, and padding five camera counters cuts L1 misses per increment 590-622x (bare-metal, untuned host, three runs)."
duration: 55 minutes
---

## Learning objectives

By the end of this chapter you can:

- Replace a node-based map with open addressing on a packed key, and say what that removes.
- Split a record into hot and cold columns, and predict the lines a sweep touches per slot.
- Read false sharing from the L1 miss count, and say when batch time hides it.

## Why this matters

Every scan asks the tracker one question: where is this parcel? On one line the answer lives among about 4,800 parcels in flight (Little's Law: arrival rate times time in the system). A hub-wide tracker holds 1,000,000. What changes is the working set against the caches, which decides whether a lookup costs cache hits or trips to memory.

The budget is physical: 1.2 m at 2.5 m/s is 480 ms from scan to divert, and the belt doesn't wait. At line scale that's forgiving: the lookup map, the sweep's record and the five cameras' counters matter at hub scale and at saturation, and the line run shows how little they move at 10 kHz. Lock-free rings pad their cursors by design; here the padding is measured.

The code is in `examples/09-eliminating-work/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="09-working-set" alt="Nested bands show the host caches: L3 of 24 MiB, L2 of 1.25 MiB and L1d of 48 KiB with 64-byte lines. Inside L2 sits the line tracker with 4,800 parcels, where a node-map lookup takes a p50 of 46-48 ns and a flat-map lookup (amber) 20 ns. A separate RAM band holds the hub trackers of 1,000,000 parcels: the node-map, 148.1 MB built, with a lookup p50 of 389-393 ns and 5.00-5.13 last-level misses per lookup, and the flat-map (amber), 126.0 MB built, with 113 ns and 0.19-0.20 misses. A dashed box notes that both hub maps exceed the 24 MiB L3." caption="Figure 9.1: The 4,800-parcel line tracker fits L2 and both maps look up in tens of nanoseconds; at 1,000,000 parcels both maps live in RAM, 148.1 MB for the node-map and 126.0 MB for the flat map, and the layout sets the misses." %}

Profile for every number in this chapter: bare-metal host, untuned: `powersave` governor, `balanced` profile, kernel 7.2; 8-core/16-thread Intel laptop CPU; 64-byte lines, L1d 48 KiB and L2 1.25 MiB per core, L3 24 MiB shared; threads placed on distinct physical cores with `sched_setaffinity`, an experiment control, not isolation, with CPU 0 left out; Temurin 25.0.5+8, Clang 22.1.8 with GCC 16.2's libstdc++, Python 3.14.8 and 3.14.8+freethreaded. Ranges span `r03-run1` to `r03-run3`.

The line tracker fits L2. A lookup among its 4,800 parcels takes a p50 of 46-48 ns in a node map and 20 ns in a flat map (observed). The hub tracker fits nothing: building it allocates 148.1 MB as a node map and 126.0 MB as a flat map, the flat figure including the cold columns. Both are far beyond the 24 MiB L3, so layout can only make each lookup touch fewer lines.

## One lookup, two designs

### Node map against open addressing

A scan arrives with an 18-digit barcode. The first-draft tracker keys a `std::unordered_map<std::string, FatRecord>` with it. Eighteen characters exceed libstdc++'s 15-character small-string buffer, so the key's text goes to the heap along with the map node: two allocations per insert, counted exactly with a replaced `operator new`. A lookup makes at least three dependent loads: the bucket, the node and the key's characters (libstdc++ adds a hop through the previous node).

The alternative packs the barcode into a `uint64` and maps it to a slot in an `absl::flat_hash_map`. Java compares `HashMap<String, ParcelState>` (#A, with the C++ node map) with Agrona's `Long2LongHashMap`, open addressing over one `long[]` (#B, with the flat map).

{% include codetabs.html langs="C++|Java" %}

```cpp
  [[nodiscard]] Tracked track(const Scan& scan) {
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
  [[nodiscard]] Tracked track(const Scan& scan) {
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

{% include excalidraw.html file="09-node-vs-flat-map" alt="Two lanes. In the node-map lane an 18-digit barcode goes to a bucket (load 1), a node holding the ParcelState (load 2) and a heap string with the key text (load 3). Results: 2 allocations per insert in C++ (exact) and 128 B/op in Java, a hub lookup p50 of 389-393 ns in C++ and 321-322 ns in Java, and 5.94 last-level read misses per lookup in cachegrind. In the flat-map lane (amber) a packed uint64 barcode goes to one probe group of control bytes and slots, then to columns indexed by the slot. Results: 0 allocations after reserve in C++ (exact) and 0.014-0.016 B/op in Java, a hub lookup p50 of 113 ns in C++ and 57-58 ns in Java, and 0.70 last-level read misses per lookup." caption="Figure 9.2: One probe group and no allocation against three dependent loads and two allocations per insert: the hub lookup p50 falls from 389-393 ns to 113 ns in C++ and from 321-322 ns to 57-58 ns in Java." %}

In #A, `map_.find(scan.barcode)` takes a `string_view` because the hash is transparent (`StringHash`, with `std::equal_to<>`), so a lookup builds no `std::string`. The allocations happen at `emplace(std::string{...}, ...)`. In #B, `try_emplace(*sscc, 0U)` finds or inserts in one probe and reports which with `fresh`, and the map was `reserve`d once, so an insert allocates nothing. In Java, #A's `map.put` allocates a node and a `ParcelState`. #B's `Long2LongHashMap(expected, 0.55f, MISSING)` rounds its capacity up to a power of two and resizes at 0.55 of it; the hub's 1,062,500 expected entries get 2^21 slots, so the hub map never resizes. `MISSING` is what `get` returns for an absent key.

### What the saving is

The allocation counters are exact. C++ `node-map` makes 2 allocations per insert and `flat-map` makes 0 after `reserve`. JMH's `gc` profiler gives 128 B per insert-and-erase pair for the Java node map and 0.014-0.016 B for the flat map. Insert latency gets worse: the Java line-scale insert p50 is 60-62 ns for the node map and 99-103 ns for the flat one, across all nine alternations. The flat map removes garbage, and with it the young collections that garbage brings closer.

At hub scale the C++ lookup p50 is 389-393 ns for the node map and 113 ns for the flat map: 3.43-3.48x within each run, observed. Java's is 321-322 ns against 57-58 ns, 5.53-5.67x (observed). Cachegrind, a simulated cache with this host's geometry, counts 5.94 last-level read misses per node-map lookup and 0.70 per flat-map lookup, 8.54x and exact. On the hardware, `perf stat` (user-space events) counts 5.00-5.13 and 0.19-0.20 in the first alternation. L1 misses only halve, about 10.0 against 5.3 per lookup, so the misses that disappear went to memory. Even 393 ns is under a millionth of the 480 ms budget; the flat map buys CPU and headroom, not a deadline.

## Hot and cold columns

At every encoder tick the tracker sweeps its table for parcels due at the diverter. The sweep needs two fields of each record, `due_tick` (8 B) and `state` (1 B). The natural record, `FatRecord`, is 80 B (a `static_assert` pins it), so each slot drags 71 unread bytes through the cache. #A is the fat table (`FatTable` in C++, `ObjectTable` in Java).

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

{% include excalidraw.html file="09-hot-cold-split" alt="In the fat-record lane each slot is one 80-byte struct. The sweep reads the due tick and the state, 9 of the 80 bytes, and takes a p50 of 4.18-4.21 ms in C++ and 9.25-9.27 ms in Java over 1,000,000 slots, with 1.2500 cachegrind D1 read misses per slot. In the hot-cold lane (amber) the due_tick column holds 8 B per slot and the state column 1 B per slot; a dashed ghost box holds the cold fields, 71 B per slot, which the sweep never reads. The sweep takes 0.57 ms in C++ and 0.44 ms in Java, with 0.1406 D1 read misses per slot." caption="Figure 9.3: The due sweep reads 9 of every 80 bytes. Splitting them into hot columns takes the sweep p50 from 4.18-4.21 ms to 0.57 ms in C++ and from 9.25-9.27 ms to 0.44 ms in Java." %}

`is_due` combines its two tests with a bitwise `&`, so the C++ sweep has no data-dependent branch and its time is the memory it reads. The Java fat table is an array of ordinary `ParcelState` objects (not a flat `MemorySegment` table) allocated in shuffled order; the hot columns are primitive arrays.

An 80 B slot is 1.25 cache lines and a 9 B slot 0.1406 of one, and cachegrind counts exactly that: 1.2500 against 0.1406 D1 read misses per slot, 8.89x. The hardware agrees: 9 MB of hot columns for 1,000,000 slots fit L3, and `perf` counts no last-level misses per slot for them against 0.85-0.88 for the 80 MB of fat records.

The C++ sweep p50 is 4.18-4.21 ms for the fat record and 0.57 ms for the columns, 7.31-7.38x. The Java sweep is 9.25-9.27 ms against 0.44 ms, 21.07-21.10x. Java's gap is larger because each fat slot is a reference to a 96 B object (JOL), a dependent load; the C++ rows are contiguous and the prefetcher streams them. A flat off-heap table avoids the reference for the same reason; this chapter doesn't measure one.

## False sharing

Five cameras in the scan tunnel each count reads and no-reads, and each thread writes only its own counters. In the hardware's terms, five 8 B counters fit in one 64-byte line, and a store by one camera invalidates the other four cameras' copies of it. The line ping-pongs between cores.

Padding is the fix, and it isn't idiomatic C++ or Java: it's a latency construct, as the comments in `counters.hpp` and `CameraCounters.java` say. `alignas(Align)` rounds a struct's address and size up to `Align`, so each array element starts on its own boundary. `AdjacentBank` forces the opposite: the five read counters share one line, and `alignas(kLine)` on the second member starts the no-read counters in the next. `std::hardware_destructive_interference_size` is 64 B here; the padded layout uses twice that, 128 B, because the L2 spatial prefetcher fetches lines in pairs. A Java heap array's alignment isn't controllable, so the counters live in a `MemorySegment` from `Arena.ofAuto().allocate(size, 128)`, the FFM idiom for aligned off-heap memory.

#A is the adjacent layout. In the Java `Layout` constants the two arguments are the camera stride and the offset of the no-read counter from its camera's read counter, both in bytes: `ADJACENT(8, 64)` puts cameras 8 B apart with the no-read counters a line later.

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

#B is the padded camera: `CameraCounters<Align>` in `counters.hpp`, instantiated at 128 B, and the `CameraCounters` constructor in Java, which asks the arena for a 128-byte-aligned segment.

{% include codetabs.html langs="C++|Java" %}

```cpp
template <std::size_t Align>
struct alignas(Align) CameraCounters {
  std::atomic<std::uint64_t> reads{0};
  std::atomic<std::uint64_t> no_reads{0};
// ...
using PairPaddedCamera = CameraCounters<kLinePair>;  // 128 B each: one camera per line pair
```

```java
    public CameraCounters(Layout layout) {
        this.layout = layout;
        // Arena.ofAuto: any thread may access it, and the collector frees it; the segment is zero-filled.
        this.cells = Arena.ofAuto().allocate(layout.segmentBytes(), 128);
    }
```

Each counter has one writer, so the increment is a relaxed load and a relaxed store (in Java a plain `get` and a `setRelease`; both are plain `mov`s on x86-64). A contrast run uses an atomic read-modify-write instead.

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

{% include excalidraw.html file="09-false-sharing" alt="Two lanes of five camera threads on distinct cores. In the adjacent-counters lane (amber arrows) all five write counters 0 to 4, 8 B apart, in one 64-byte cache line. In C++ that costs 0.093-0.094 L1 misses per increment for stores and 0.42-0.44 for read-modify-write, and a batch of 1,000 increments has a p50 of 5,115-5,279 ns for stores and 48.3-57.3 us for read-modify-write. In the pair-padded lane each counter has its own 128-byte range: 0.00016 misses per increment for stores, 0.0002-0.0004 for read-modify-write, and batch p50s of 1,597-1,624 ns and 4.89-5.01 us. A third box records 64-byte padding as an observed middle case, a store batch p50 of 1,653-1,692 ns. In Java the miss count falls 106-167x and the C++ one 590-622x." caption="Figure 9.4: Padding takes the L1 misses per increment from about 0.09 to nearly 0 for stores. The miss count falls 590-622x in C++ and 106-167x in Java; the store batch time moves about 3x, and the read-modify-write batch about 10x." %}

The L1 miss count falls over a hundredfold; the batch time moves about 3x. For stores, L1 misses per increment fall 590-622x in C++ (0.093-0.094 to 0.00016) and 106-167x in Java, both asserted at 10x or more. The batch of 1,000 increments moves only 3.18-3.29x in C++ (5,115-5,279 ns to 1,597-1,624 ns) and 2.89-3.06x in Java, observed. A store buffer hides most of it: stores retire into the buffer and the loop's loads of its own counter are forwarded from it, so line transfers overlap with execution. Those ratios sit 6-10 % above 3x (C++) and 4 % below to 2 % above it (Java), too close to assert, so the assertion is on the miss count.

A read-modify-write can't hide behind the buffer: a `lock xadd` must own the line before it completes. C++ batch time moves 9.89-11.96x (48.3-57.3 us to 4.89-5.01 us), asserted at 3x or more, and Java's `getAndAdd` moves 11.02-12.29x, observed.

Two variations are observed only. Padding to 64 B gives a store batch p50 of 1,653-1,692 ns against 1,603-1,625 ns for 128 B in the same alternation, and the same L1 misses per increment, 0.00016 (`counters-line-padded.json`): 2-6 % slower in every run, too small to demonstrate the line-pair prefetcher reason. And two cameras on the SMT siblings of one core, adjacent layout, took 4,311-4,383 ns against 1,948-2,197 ns on distinct cores. Siblings were slower. They share one L1, so no line moves between cores: 0.00020-0.00022 L1 misses per increment against 0.081-0.098 for two cameras on distinct cores (`counters-smt-siblings.json`, `counters-adjacent-counters.2-cameras.json`). The extra time isn't traffic between cores; it arises inside the shared core, which this run doesn't break down.

## Python: fewer objects, not tighter ones

Python can't place an object or pad a field; the lever is the number of objects. `tracemalloc` counts 790.8 B per tracked parcel (100,000 parcels) for a `dict` per parcel, 462.8 B for a `@dataclass(slots=True)` record keyed by the barcode `str`, and 385.8 B keyed by the packed `int`.

```python
@dataclass(slots=True)
class ParcelRecord:
    # ...
    sscc: int
    due_tick: int
    scan_tick: int
```

`slots=True` drops the per-instance `__dict__`; the fields sit in fixed slots. The record container is 3.41x smaller (asserted at 2x or more, exact), and the whole tracked parcel is 2.05x smaller against the `int`-keyed shape, a thin 1.02x margin over its bound, though the count is exact. Against the `str`-keyed shape it's 1.71x, observed, because the 18-character key costs the same in both.

Columns don't help: sweeping 1,000,000 slots takes a p50 of 40.9-41.0 ms over a list of records and 43.1-43.7 ms over `array('Q')`, since iterating the array builds an `int` per element (observed).

The hardware effect survives the interpreter. Camera processes sharing an array through `multiprocessing.shared_memory` take a batch p50 of 150,143-151,551 ns adjacent against 55,647-56,767 ns padded, 2.67-2.70x within each run, and free-threaded threads 165,631-221,951 ns against 60,351-61,279 ns. Threads under the GIL show no consistent difference, 62,463-68,543 ns against 65,119-78,975 ns, because only one runs at a time (all observed).

## Measure

Run from the repository root:

```bash
examples/09-eliminating-work/verify.sh
```

A full run takes about nine minutes; `RECHECK=results/<run-id>` re-checks committed reports. Comparisons alternate A B A B A B and take the median of three ratios inside one run.

| Criterion | Claim | Bound | Measured |
|---|---|---|---|
| 1a, 1b | C++ allocations per insert, node map, flat map after `reserve` | at least 2, 0 | 2, 0 (exact) |
| 1c, 1d | JMH bytes per insert, node map, flat map | at least 64, at most 1 | 128, 0.014-0.016 |
| 1e, 1f | Python record container, dict per parcel over `slots-int` | at least 2x | 3.41x, 2.05x (exact) |
| 2c, 2d | LL misses per lookup, node map over flat map | at least 2x | 8.54x cachegrind, 25.86-26.77x `perf` |
| 3a, 3b | sweep p50, fat record over hot/cold, C++ and Java | at least 2x | 7.31-7.38x, 21.07-21.10x |
| 3c | cachegrind D1 misses per slot | at least 4x | 8.89x (exact) |
| 4b, 4c | L1 misses per increment, adjacent over padded, C++ and Java | at least 10x | 590-622x, 106-167x |
| 4a | C++ read-modify-write batch p50 | at least 3x | 9.89-11.96x |
| 5a, 5b | C++ line allocations per parcel, node map, flat map | at least 1, 0 | 2, 0 (exact) |

The line run (10 kHz, 20 s, preloaded hub) has 400,000 tracker allocations on the receive thread (27.8 MB) for the node map and none for the flat map. End-to-end the two are indistinguishable: p50 56.8-57.6 us and p99 78.8-79.7 us for both, the p50s within 1 us in each run, and the worst parcel 0.46-4.80 ms against 480 ms. At line rate the saving is CPU and headroom rather than latency. On the Java line the receive thread allocates 710.2 B per parcel against 582.5 B, the difference being the node map's insert.

## Cross-check

`perf` and cachegrind count independently. `perf stat` counts only the timed loop, through its `--control` FIFOs. Cachegrind can't isolate libstdc++'s hash and compare inside one function, so it counts lookups by difference: 200,000 lookups minus one. Per slot, `perf` gives 1.2525-1.2526 L1 misses for the fat record and 0.1410 for the columns, against cachegrind's 1.2500 and 0.1406. Per lookup, `perf` counts 5.00-5.13 last-level misses for the node map against cachegrind's 5.94. A simulated cache has no prefetcher, so the counts differ; both rank the designs alike.

In Java, warming only the inner batch would leave the outer loop on C1's profiling tier, whose counters all five threads write, so each camera warms its whole measured loop first, and the padded layout measures 0.00033-0.0013 L1 misses per increment. The six runs above 0.0004 retired 3.9-6.2 million more JVM instructions than the line-padded layout's 44.198 per increment.

## What you learned

- A node map costs two allocations per insert and at least three dependent loads per lookup. Open addressing on a packed `uint64` removes both; at hub scale the C++ lookup p50 falls from 389-393 ns to 113 ns.
- Both hub trackers exceed the 24 MiB L3, so layout sets the misses per lookup.
- A sweep that reads 9 of 80 bytes touches 1.25 lines per slot as a fat record and 0.1406 as columns.
- False sharing shows in L1 misses per increment (590-622x in C++); batch time moves about 3x for stores and 10x for read-modify-writes. SMT siblings were slower than distinct cores.
- At 4,800 parcels the tracker fits L2; all of this is headroom.

## For deeper coverage

- Enberg, *Latency* (Manning), as further reading.
- Back-links: [Chapter 5]({{ '/docs/05-jvm-costs/' | relative_url }}) (TLAB, escape analysis), [Chapter 6]({{ '/docs/06-gc-tails/' | relative_url }}) (GC cost), [Chapter 7]({{ '/docs/07-offheap-lockfree/' | relative_url }}) (ring padding), [Chapter 8]({{ '/docs/08-zero-copy-flat/' | relative_url }}) (flat table, FFM).
- Chapter 2, *Modelling with Little's Law and Amdahl's Law* (Part 1), for the parcels in flight.
- [Chapter 10, *Lock-free and wait-free synchronization*]({{ '/docs/10-lockfree-waitfree/' | relative_url }}) (Part 3), for what a stalled writer does to shared counters.
- Chapter 15, *CPU partitioning and the noisy-neighbour problem* (Part 5), for CPU isolation, which the thread placement here isn't.
- `examples/09-eliminating-work/README.md` and `examples/common/MEASUREMENT.md`.
- Abseil's [Swiss tables design notes](https://abseil.io/about/design/swisstables) and the Python data model's [`__slots__`](https://docs.python.org/3.14/reference/datamodel.html#slots).

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts the exact allocation counts (C++, JMH, Python bytes, the line's receive thread); last-level misses per lookup at least 2x higher for the node map in cachegrind and `perf`; the fat-record sweep p50 at least 2x the hot/cold p50 in C++ and Java, and cachegrind D1 misses per slot at least 4x; L1 misses per increment at least 10x higher adjacent than padded in C++ and Java, and the C++ read-modify-write batch p50 at least 3x; and that every report passes `lowlat-report check`. Observed only: the lookup p50 ratios, store-increment and `getAndAdd` batch times, 64-byte padding, SMT siblings, line-scale lookups, footprints, the line's end-to-end percentiles and the Python sweep and counters. It held on `r03-run1` to `r03-run3` (bare-metal host, untuned, commit 9802788).*
