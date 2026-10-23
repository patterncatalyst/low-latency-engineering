---
title: "r03 figures (S9)"
layout: plan
render_with_liquid: false
---

# r03 figures — S9

Two or more figures per chapter for Ch9–Ch10 (Part 3). One spec per figure in `diagrams/NN-slug.py`, generated into `assets/diagrams/NN-slug.{svg,excalidraw}` by `scripts/generate_diagram.py`; never hand-edited. Visual grammar as [r01-figures.md](r01-figures.md): canvas 880 wide, 300–460 high; headline note at `x` 440, `y` 28, size 14, bold, `#b8650a`; at most one takeaway; style roles; edges end on box edges; languages in the order C++, Python, Java; ASCII; no mean.

## Figures

| Name | Fig | Chapter | Shows |
|---|---|---|---|
| `09-working-set` | 9.1 | Ch9 | L1d 48 KiB, L2 1.25 MiB, L3 24 MiB as nested bands; the line tracker (4,800 parcels) inside L2 in both maps; the hub tracker (1,000,000) as a node map far outside L3 and as a flat map near L3's size; sizes from S5 measurements |
| `09-node-vs-flat-map` | 9.2 | Ch9 | lookup by barcode: bucket -> node -> heap string (three dependent loads, two allocations per insert) against open addressing on a packed `uint64` key (one probe group, no allocation); misses per lookup and hub lookup p50 |
| `09-hot-cold-split` | 9.3 | Ch9 | a fat record row (all fields, one line per slot) against hot columns (tick + state, about 9 B per slot) with cold fields aside; lines touched per slot and sweep p50 |
| `09-false-sharing` | 9.4 | Ch9 | five camera threads on distinct cores writing counters in one 64-byte line (amber ping-pong) against one per 128-byte range; 64-byte padding as the observed middle case; SMT siblings as a ghost; L1 misses per increment and batch p50 |
| `10-progress-guarantees` | 10.1 | Ch10 | blocking / lock-free / wait-free ladder with the three claim variants: futex sleep, CAS retry loop, one `lock xadd`; claim p99.9, retries, voluntary context switches |
| `10-store-buffer` | 10.2 | Ch10 | two induction stations, each with a store buffer, writing their own flag and reading the other's; the both-zero outcome counts under release/acquire against 0 under `seq_cst`/volatile |
| `10-seqlock` | 10.3 | Ch10 | writer bumps the sequence odd, writes, bumps it even; readers read sequence, data, sequence and retry on change; against a shared mutex where the writer waits; writer p99.9, torn reads 0 |
| `10-stalled-producer` | 10.4 (optional) | Ch10 | a fetch-add log with one claimed but unpublished slot; the consumer stopped at it for the stall |

## Values the figures may quote

Parameters: 4,800 and 1,000,000 parcels; 10 kHz x 20 s; five cameras; 1,000 increments per sample; 4 producers x 1,000,000 claims; 10,000,000 trials; 1 ms stall; four cameras at 2.5 kHz x 20 s; cache sizes from `profile.json`.

Code constants, not measurements: the fat record is 80 B (`sizeof(FatRecord)`, `static_assert` in `records.hpp`), of which the sweep reads `due_tick` (8 B) and `state` (1 B), leaving 71 B cold; the cache sizes in 9.1 are `profile.json` bytes divided by 1,024 (49,152 B = 48 KiB; 1,310,720 B = 1.25 MiB; 25,165,824 B = 24 MiB). Slot numbers in 10.4 and the five-camera drawing in 9.4 are illustrations of the configured parameters.

Measured values come only from the committed host runs `examples/09-eliminating-work/results/r03-run{1,2,3}/` and `examples/10-lockfree-waitfree/results/r03-run{1,2,3}/` (bare metal, `powersave`, `balanced`). Each figure quotes a range across the three runs; no mean. A ratio is the run's median over its 3 alternations, quoted as the range of the three runs' medians. An absolute p50 or p99 marked "median of 3 alternations" is that median per run; one marked "alternation 1" is the first alternation of each run (the log prints the p99 and p99.9 of alternation 1 only). Exact counters (allocations, cachegrind, steps, torn snapshots, both-zero counts under `seq_cst`) are single values. Every value below is extracted from the committed files by one script (session scratchpad, `s9/extract.py`) and its output is pasted here; rows in the form value, source, runs.

| Figure and value | Source and field | Runs 1-3 (as quoted) | Run 1, run 2, run 3 |
|---|---|---|---|
| l1d size | `09-eliminating-work/results/r03-run1/profile.json` `cpu.caches.l1d.size_bytes` | 49,152 B | exact |
| l2 size | `09-eliminating-work/results/r03-run1/profile.json` `cpu.caches.l2.size_bytes` | 1,310,720 B | exact |
| l3 size | `09-eliminating-work/results/r03-run1/profile.json` `cpu.caches.l3.size_bytes` | 25,165,824 B | exact |
| 9.1 hub build footprint, node-map (MB) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `build footprint`, from cpp/hub-lookup-node-map.a1.json `runtime.counters.build_bytes`` | 148.1 MB | 148.1, 148.1, 148.1 |
| 9.1 hub build footprint, flat-map (MB) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `build footprint`, from cpp/hub-lookup-flat-map.a1.json `runtime.counters.build_bytes`` | 126.0 MB | 126.0, 126.0, 126.0 |
| 9.1 JOL ParcelState instance (B) | `09-eliminating-work/results/r03-run{1,2,3}/java/footprint.json `parcel_state_instance_bytes`` | 96 B | 96, 96, 96 |
| 9.1 JOL node-map tracker per parcel (100,000 parcels) (B) | `09-eliminating-work/results/r03-run{1,2,3}/java/footprint.json `node_map_bytes_per_parcel`` | 202 B | 202, 202, 202 |
| 9.1 JOL flat-map tracker per parcel (100,000 parcels) (B) | `09-eliminating-work/results/r03-run{1,2,3}/java/footprint.json `flat_map_bytes_per_parcel`` | 87 B | 87, 87, 87 |
| 9.1 line-scale lookup p50 node-map (4,800 parcels, fits L2) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `line-scale lookups`` | 47-48 ns | 47, 48, 47 |
| 9.1 line-scale lookup p50 flat-map | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `line-scale lookups`` | 19-20 ns | 20, 20, 19 |
| 9.2 C++ node-map allocations per insert (exact) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log criterion 1a` | 2 | 2, 2, 2 |
| 9.2 C++ flat-map allocations after reserve (exact) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log criterion 1b` | 0 | 0, 0, 0 |
| 9.2 JMH node-map B/op | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `insert-node-map ... B/op`` | 128 B/op | 128, 128, 128 |
| 9.2 JMH flat-map B/op | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `insert-flat-map ... B/op`` | 0.017-0.018 B/op | 0.018, 0.017, 0.018 |
| 9.2 C++ hub lookup p50 node-map (median of 3 alternations) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `hub lookup p50 (ns) by alternation`` | 388-394 ns | 394, 393, 388 |
| 9.2 C++ hub lookup p50 flat-map (median of 3 alternations) | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 113-115 ns | 115, 113, 113 |
| 9.2 C++ hub lookup p50 ratio node-map / flat-map (median of 3, observed) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `observed 2a`` | 3.41-3.48x | 3.41, 3.48, 3.45 |
| 9.2 C++ LL misses per lookup, node-map (perf :u, alternation 1) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `hub lookup node-map`` | 5.04-5.15 | 5.15, 5.04, 5.04 |
| 9.2 C++ LL misses per lookup, flat-map (perf :u, alternation 1) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `hub lookup flat-map`` | 0.19-0.23 | 0.22, 0.23, 0.19 |
| 9.2 cachegrind LL read-miss ratio per lookup, node-map / flat-map (exact) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log criterion 2c` | 8.54x | 8.54, 8.54, 8.54 |
| 9.2 cachegrind LL read misses per lookup, node-map (exact) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `cachegrind per lookup`` | 5.94 | 5.94, 5.94, 5.94 |
| 9.2 cachegrind LL read misses per lookup, flat-map (exact) | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 0.70 | 0.70, 0.70, 0.70 |
| 9.2 Java hub lookup p50 ratio node-map / flat-map (median of 3, observed) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `observed 2b`` | 5.33-5.73x | 5.33, 5.73, 5.65 |
| 9.2 Java hub lookup p50 node-map (median of 3 alternations) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `hub lookup p50 (ns) by alternation` (Java)` | 321-323 ns | 323, 321, 321 |
| 9.2 Java hub lookup p50 flat-map (median of 3 alternations) | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 56-61 ns | 61, 56, 57 |
| 9.3 cachegrind D1 read misses per slot, fat-record (exact) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `cachegrind per slot`` | 1.2500 | 1.2500, 1.2500, 1.2500 |
| 9.3 cachegrind D1 read misses per slot, hot-cold (exact) | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 0.1406 | 0.1406, 0.1406, 0.1406 |
| 9.3 cachegrind D1 ratio per slot (exact) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log criterion 3c` | 8.89x | 8.89, 8.89, 8.89 |
| 9.3 C++ hub sweep p50 fat-record (median of 3 alternations) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `hub sweep p50 (ns) by alternation` (C++)` | 4.21-4.26 ms | 4.26, 4.21, 4.26 |
| 9.3 C++ hub sweep p50 hot-cold (median of 3 alternations) | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 0.57-0.58 ms | 0.57, 0.57, 0.58 |
| 9.3 C++ hub sweep p50 ratio fat-record / hot-cold | `09-eliminating-work/results/r03-run{1,2,3}/verify.log criterion 3a` | 7.30-7.43x | 7.43, 7.43, 7.30 |
| 9.3 Java hub sweep p50 fat-record (median of 3 alternations) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log (Java)` | 9.30-9.40 ms | 9.40, 9.30, 9.30 |
| 9.3 Java hub sweep p50 hot-cold (median of 3 alternations) | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 0.44-0.45 ms | 0.45, 0.44, 0.44 |
| 9.3 Java hub sweep p50 ratio fat-record / hot-cold | `09-eliminating-work/results/r03-run{1,2,3}/verify.log criterion 3b` | 20.91-20.99x | 20.91, 20.92, 20.99 |
| 9.4 C++ store batch p50 adjacent-counters (1,000 increments, median of 3) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `[store increment] per-batch`` | 5,119-5,163 ns | 5,163, 5,119, 5,139 |
| 9.4 C++ store batch p50 pair-padded | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 1,606-1,616 ns | 1,606, 1,608, 1,616 |
| 9.4 C++ store batch p50 ratio (observed) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `observed 4a'`` | 3.15-3.19x | 3.19, 3.18, 3.15 |
| 9.4 C++ rmw batch p50 adjacent-counters (median of 3) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `[rmw increment] per-batch`` | 51.9-55.9 us | 51.9, 51.9, 55.9 |
| 9.4 C++ rmw batch p50 pair-padded | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 4.89-4.90 us | 4.90, 4.89, 4.89 |
| 9.4 C++ rmw batch p50 ratio (asserted >= 3x) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log criterion 4a` | 10.50-11.44x | 10.50, 10.62, 11.44 |
| 9.4 C++ L1 misses per increment, store, adjacent-counters (median of 3) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `[store increment] L1-dcache-load-misses:u`` | 0.093-0.095 | 0.095, 0.093, 0.095 |
| 9.4 C++ L1 misses per increment, store, pair-padded | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 0.00015-0.00016 | 0.00016, 0.00015, 0.00015 |
| 9.4 C++ L1 misses per increment, rmw, adjacent-counters (median of 3) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `[rmw increment] L1-dcache-load-misses:u`` | 0.43-0.44 | 0.44, 0.43, 0.43 |
| 9.4 C++ L1 misses per increment, rmw, pair-padded | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 0.0002 | 0.0002, 0.0002, 0.0002 |
| 9.4 C++ L1-miss ratio per increment, store (asserted >= 10x) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log criterion 4b` | 609-617x | 609, 617, 613 |
| 9.4 Java L1-miss ratio per increment, store (asserted >= 10x) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log criterion 4c` | 270-287x | 280, 270, 287 |
| 9.4 Java store batch p50 adjacent-counters (median of 3) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log (Java) `[store increment] per-batch p50`` | 6,415-6,551 ns | 6,551, 6,415, 6,483 |
| 9.4 Java store batch p50 pair-padded | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 2,117-2,127 ns | 2,127, 2,119, 2,117 |
| 9.4 Java store batch p50 ratio (observed) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `observed 4c'`` | 3.02-3.08x | 3.08, 3.02, 3.05 |
| 9.4 Java getAndAdd batch p50 ratio (observed) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `observed 4c''`` | 10.97-12.34x | 10.97, 12.11, 12.34 |
| 9.4 C++ 64-byte padding (line-padded) store batch p50 (observed) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `observed: line-padded (64 B)`` | 1,656-1,676 ns | 1,658, 1,656, 1,676 |
| 9.4 C++ two cameras on SMT siblings, store batch p50 (observed) | `09-eliminating-work/results/r03-run{1,2,3}/verify.log `two cameras on SMT siblings`` | 4,299-4,331 ns | 4,331, 4,299, 4,307 |
| 9.4 C++ two cameras on distinct cores, store batch p50 (observed) | `09-eliminating-work/results/r03-run{1,2,3}/same line` | 2,111-2,193 ns | 2,193, 2,111, 2,133 |
| 10.1 C++ mutex claim p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `cpp mutex claim p50 / p99 / p99.9`` | 2,633-2,985 ns | 2,633, 2,985, 2,641 |
| 10.1 C++ cas-loop claim p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `cpp cas-loop claim p50 / p99 / p99.9`` | 478-502 ns | 489, 502, 478 |
| 10.1 C++ fetch-add claim p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `cpp fetch-add claim p50 / p99 / p99.9`` | 400-468 ns | 400, 411, 468 |
| 10.1 C++ mutex claim p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 4,851-5,503 ns | 4,859, 5,503, 4,851 |
| 10.1 C++ cas-loop claim p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 1,207-1,237 ns | 1,227, 1,237, 1,207 |
| 10.1 C++ fetch-add claim p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 859-940 ns | 859, 871, 940 |
| 10.1 C++ claim p99 ratio mutex / fetch-add (median of 3, asserted) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 3` | 6.10-6.45x | 6.45, 6.20, 6.10 |
| 10.1 C++ claim p99.9 ratio mutex / fetch-add (median of 3, observed) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `observed ... p99.9 per alternation`` | 5.64-5.92x | 5.66, 5.64, 5.92 |
| 10.1 C++ mutex voluntary switches, least-switching producer (median of 3) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 2` | 5,406-9,746 | 9,746, 5,406, 9,508 |
| 10.1 C++ fetch-add voluntary switches, most-switching producer (median of 3) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 2` | 1 | 1, 1, 1 |
| 10.1 C++ cas-loop largest retry count in one claim (run 1 of each) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 2` | 7-10 | 7, 10, 8 |
| 10.1 C++ fetch-add steps per claim (exact) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 2` | 1 | 1, 1, 1 |
| 10.1 Java mutex claim p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `java mutex claim p50 / p99 / p99.9`` | 8,187-8,383 ns | 8,383, 8,367, 8,187 |
| 10.1 Java cas-loop claim p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `java cas-loop claim p50 / p99 / p99.9`` | 1,409-1,837 ns | 1,409, 1,837, 1,419 |
| 10.1 Java fetch-add claim p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `java fetch-add claim p50 / p99 / p99.9`` | 516-584 ns | 516, 523, 584 |
| 10.1 Java mutex claim p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 11,615-12,223 ns | 12,223, 12,015, 11,615 |
| 10.1 Java cas-loop claim p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 3,177-3,647 ns | 3,177, 3,647, 3,337 |
| 10.1 Java fetch-add claim p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 1,841-1,957 ns | 1,957, 1,841, 1,865 |
| 10.1 Java claim p99 ratio mutex / fetch-add (median of 3, asserted) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 3` | 14.13-15.23x | 14.13, 15.23, 15.15 |
| 10.1 Java claim p99.9 ratio mutex / fetch-add (median of 3, observed) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `observed ... p99.9 per alternation`` | 6.24-6.40x | 6.25, 6.40, 6.24 |
| 10.1 Java mutex voluntary switches, least-switching producer (median of 3) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 2` | 47,556-61,712 | 60,262, 61,712, 47,556 |
| 10.1 Java fetch-add voluntary switches, most-switching producer (median of 3) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 2` | 1-3 | 3, 1, 2 |
| 10.1 Java cas-loop largest retry count in one claim (run 1 of each) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 2` | 27-55 | 27, 55, 32 |
| 10.1 Java fetch-add steps per claim (exact) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 2` | 1 | 1, 1, 1 |
| 10.2 C++ release-acquire both-zero in 10,000,000 trials (exact count) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `C++ release-acquire outcomes`` | 2,306,475-9,888,040 | 9,888,040, 2,306,475, 2,325,615 |
| 10.2 C++ seq-cst both-zero in 10,000,000 trials (exact) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 5` | 0 | 0, 0, 0 |
| 10.2 Java setRelease/getAcquire jcstress 0, 0 samples (millions, quick mode) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 5; `java-jcstress-summary.txt`` | 85.0-98.6 M | 91.8, 85.0, 98.6 |
| 10.2 Java volatile jcstress 0, 0 samples (exact) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 5` | 0 | 0, 0, 0 |
| 10.2 C++ release store p50 (observed) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `per-store cost`` | 0 ns | 0, 0, 0 |
| 10.2 C++ seq_cst store p50 (observed) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 4 ns | 4, 4, 4 |
| 10.3 C++ shared-mutex writer p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `cpp writer update p50 / p99 / p99.9`` | 5,979-6,603 ns | 5,979, 6,091, 6,603 |
| 10.3 C++ shared-mutex writer p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 10,511-15,687 ns | 10,511, 13,671, 15,687 |
| 10.3 C++ seqlock writer p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `cpp writer update p50 / p99 / p99.9`` | 25-32 ns | 25, 26, 32 |
| 10.3 C++ seqlock writer p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 3,127-3,389 ns | 3,127, 3,235, 3,389 |
| 10.3 C++ writer p99 ratio lock / seqlock-style (median of 3, asserted) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 6` | 205.5-231.0x | 205.5, 231.0, 224.7 |
| 10.3 C++ writer p99.9 ratio (median of 3, observed) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `observed ... p99.9 per alternation`` | 4.44-5.17x | 4.70, 4.44, 5.17 |
| 10.3 C++ torn snapshots (exact) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 6` | 0 | 0, 0, 0 |
| 10.3 Java rw-lock writer p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `java writer update p50 / p99 / p99.9`` | 8,083-8,287 ns | 8,287, 8,083, 8,287 |
| 10.3 Java rw-lock writer p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 11,855-13,375 ns | 12,471, 11,855, 13,375 |
| 10.3 Java stamped-lock writer p99 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `java writer update p50 / p99 / p99.9`` | 206-234 ns | 206, 210, 234 |
| 10.3 Java stamped-lock writer p99.9 (alternation 1) | `10-lockfree-waitfree/results/r03-run{1,2,3}/same line` | 3,775-4,443 ns | 3,775, 3,927, 4,443 |
| 10.3 Java writer p99 ratio lock / seqlock-style (median of 3, asserted) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 6` | 34.5-37.1x | 34.5, 37.1, 35.4 |
| 10.3 Java writer p99.9 ratio (median of 3, observed) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log `observed ... p99.9 per alternation`` | 2.60-3.01x | 3.01, 2.60, 3.01 |
| 10.3 Java torn snapshots (exact) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 6` | 0 | 0, 0, 0 |
| 10.4 C++ consumer wait at the stalled sequence (1 ms stall) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 4` | 1.05-1.07 ms | 1.05, 1.06, 1.07 |
| 10.4 Java consumer wait at the stalled sequence (1 ms stall) | `10-lockfree-waitfree/results/r03-run{1,2,3}/verify.log criterion 4` | 1.11-1.14 ms | 1.11, 1.14, 1.14 |

Deviations from the figure list above, recorded here so the chapters (S10, S11) state them:

- 9.1: the hub flat map is not "near L3's size". The committed footprints are 148.1 MB built for the node-map and 126.0 MB for the flat map, both far beyond the 24 MiB L3. The abseil index alone (about 34 MB at capacity 2^21, from the S5 validation) is not recorded in any committed file, so it is not drawn.
- 9.4: the SMT-sibling ghost is not drawn. The committed observation (two cameras on SMT siblings, store batch p50 4,299-4,331 ns, against 2,111-2,193 ns on distinct cores, adjacent layout) shows no "siblings share L1, no penalty" result, and the prose in S10 has to explain it before a figure shows it. Batch time is shown as measured: C++ store 3.15-3.19x, C++ rmw 10.50-11.44x (asserted at least 3x), Java store 3.02-3.08x (observed). The asserted claim is the miss count.
- 10.1 and 10.3 quote p99; p99.9 is in the table as observed (it sits at the host's interrupt floor, about 3-5 us).
- 10.2: the C++ release/acquire both-zero count varies by run (2,306,475-9,888,040 of 10,000,000); the figure quotes the range, the assertion is "at least 1".

## Status

| Step | Status |
|---|---|
| specs and generated files | done (8 figures: 09-working-set, 09-node-vs-flat-map, 09-hot-cold-split, 09-false-sharing, 10-progress-guarantees, 10-store-buffer, 10-seqlock, 10-stalled-producer) |
| `_data/diagrams.yml` entries | done (4 for Ch9, 4 for Ch10) |
| chapters embed the figures (S10-S11) | Ch9 done (S10); Ch10 todo |
