---
title: "r02 figures (S15)"
layout: plan
render_with_liquid: false
---

# r02 figures — S15

Two or more figures per chapter for Ch5–Ch8 (Part 2). One spec per figure in
`diagrams/NN-slug.py`, generated into `assets/diagrams/NN-slug.{svg,excalidraw}`
by `scripts/generate_diagram.py`. Never hand-edit generated files. The chapters
(S16–S19) embed them through the include and `_data/diagrams.yml`.

## Visual grammar (every figure)

Visual grammar: as [r01-figures.md](r01-figures.md). Spec shape, canvas (880 wide,
300–460 high), headline note (`x` 440, `y` 28, middle, size 14, bold, `#b8650a`),
at most one bottom takeaway, style roles, edge rules (every edge ends on a box
edge or another arrow), language order C++, Python, Java, ASCII text, no mean.

## Figures

| Name | Fig | Chapter | Shows |
|---|---|---|---|
| `05-jit-tiers` | 5.1 | Ch5 | interpreter -> C1 -> C2 with deoptimization back to the interpreter; the same 1 kHz x 20 s line run three ways (`--unwarmed`, `warmed`, `aot-cache`) with the first-window p99.9 and the time to ready |
| `05-escape-analysis` | 5.2 | Ch5 | JMH `decide()` three ways: `escaping` (24 B/op), `scalar-replaced` (under 1 B/op), `--no-escape-analysis` (24 B/op again) |
| `06-collector-pauses` | 6.1 | Ch6 | the same tracker under Parallel, G1, Generational ZGC and Generational Shenandoah: what stops threads and the JFR maximum pause |
| `06-headroom-stall` | 6.2 | Ch6 | ZGC on a 4 GB heap against the heap at 1.05x the live set: allocation stalls and p99.9 |
| `06-refcount-vs-tracing` | 6.3 | Ch6 | C++ ownership (`--bulk-free` against `deferred-free`), CPython refcounting plus the generational cycle collector (`cyclic-garbage` against `frozen`), and the JVM's tracing collectors (`--stop-the-world` against `zgc`) |
| `07-handoff-topology` | 7.1 | Ch7 | receive thread -> hand-off -> decide thread -> command channel, with the audit journal; three hand-off variants and the decide thread's voluntary context switches |
| `07-ring-sequences` | 7.2 | Ch7 | a ring of slots: monotonic sequences, `slot = sequence & (slots - 1)`, producer and consumer cursors on their own cache lines, the full-ring case |
| `07-affinity-vm` | 7.3 | Ch7 | VM only: guest `isolcpus=3 nohz_full=3 rcu_nocbs=3`, vCPU 3 pinned to host CPU 13, `stress-ng --cpu 3` on guest CPUs 0-2, unpinned against pinned decide thread; labelled VM, never compared with host numbers |
| `08-zero-copy-decode` | 8.1 | Ch8 | one receive buffer, `parseFrom` (a message, a `Dimensions` and a `String` per datagram) against a reused `FlatView` over the 80-byte `parcel-v1` record |
| `08-flat-vs-pointer-layout` | 8.2 | Ch8 | `ParcelState[]` of references against a flat `MemorySegment` of 24-byte structs, swept over 1,000,000 parcels; value classes as a ghost box (JDK 28 early access, not GA; the book pins JDK 25 LTS) |

## Values the figures may quote

Parameters (configured, not measured): 1 kHz x 20 s and the first window of
parcels 0-1,999 (Ch5); 20,000 replay parcels (`--warm-up`); 10 kHz x 30 s, 4 GB
heap, about 400 MB/s scan history (`--alloc-mb-per-s 400`), heap at 1.05x the
live set (`UNDERSIZED_PERCENT` 105) (Ch6); 65,536 slots (`--slots`), 10 kHz x 20 s
= 200,000 parcels, 8 slots as a drawing only (Ch7); 80-byte `parcel-v1` record,
1,000,000 parcels in the sweep, 24-byte flat slot (Ch8).

Measured values come only from the committed runs. Host figures (bare metal,
`powersave`, `balanced`) are ranges across `examples/0[5-8]-*/results/r02-run{1,2,3}/`;
VM figures are ranges across `examples/07-offheap-lockfree/results/r02-vm-run{1,2,3}/`.
Each was re-read from the report JSON or `verify.log` on 2026-10-22. No mean is quoted.

| Figure | Value shown | Range | Source (under `examples/`) |
|---|---|---|---|
| 5.1 | `--unwarmed` first-window p99.9 | 13.4-28.5 ms | `05-jvm-costs/results/r02-run{1,2,3}/java-unwarmed-first-2000.json` `percentiles.p99_9` (28.459, 13.353, 28.410 ms) |
| 5.1 | `warmed` first-window p99.9 | 0.29-0.36 ms | `…/java-warmed-first-2000.json` `percentiles.p99_9` (0.342, 0.287, 0.357 ms) |
| 5.1 | `aot-cache` first-window p99.9 | 0.61-3.2 ms | `…/java-aot-cache-first-2000.json` `percentiles.p99_9` (0.606, 0.685, 3.224 ms) |
| 5.1 | time to ready, `aot-cache` (median of 5 launches) | 51-55 ms | `…/time-to-ready.json` `median_aot_cache` (51.1, 54.8, 50.7 ms) |
| 5.1 | time to ready, no cache (median of 5 launches) | 173-177 ms | `…/time-to-ready.json` `median_no_cache` (174.3, 176.9, 173.1 ms) |
| 5.2 | `escaping` `gc.alloc.rate.norm` | 24 B/op (24.0005-24.0006) | `05-jvm-costs/results/r02-run{1,2,3}/alloc-per-op.json` `escaping` |
| 5.2 | `scalar-replaced` `gc.alloc.rate.norm` | under 1 B/op (0.0002) | `…/alloc-per-op.json` `scalar-replaced` |
| 5.2 | `--no-escape-analysis` `gc.alloc.rate.norm` | 24 B/op (24.0003-24.0004) | `…/alloc-per-op.json` `--no-escape-analysis` |
| 6.1, 6.3 | `--stop-the-world` max GC pause | 158-170 ms | `06-gc-tails/results/r02-run{1,2,3}/java-stop-the-world-gc-pause.json` `percentiles.max` (157.5, 169.6, 158.1 ms) |
| 6.1 | `g1` max GC pause | 21.0-21.6 ms | `…/java-g1-gc-pause.json` `percentiles.max` (21.037, 21.234, 21.561 ms) |
| 6.1, 6.3 | `zgc` max GC pause | 0.017-0.036 ms | `…/java-zgc-gc-pause.json` `percentiles.max` (0.036, 0.030, 0.017 ms) |
| 6.1 | `shenandoah-gen` max GC pause | 0.53-0.82 ms | `…/java-shenandoah-gen-gc-pause.json` `percentiles.max` (0.715, 0.526, 0.819 ms) |
| 6.2 | `zgc` (4 GB) p99.9 | 0.135-0.153 ms | `…/java-zgc.json` `percentiles.p99_9` (0.153, 0.141, 0.135 ms) |
| 6.2 | `zgc` (4 GB) allocation stalls | 0 | `…/java-zgc-gc-pause.json` `runtime.alloc_stalls.count` |
| 6.2 | `undersized-heap` allocation stalls | 532-976 | `…/java-undersized-heap-gc-pause.json` `runtime.alloc_stalls.count` (532, 976, 613) |
| 6.2 | `undersized-heap` p99.9 | 49.6-134.9 ms | `…/java-undersized-heap.json` `percentiles.p99_9` (49.611, 134.873, 52.396 ms) |
| 6.3 | C++ `--bulk-free` max latency | 3.65-3.87 ms | `…/cpp-bulk-free.json` `percentiles.max` (3.65, 3.76, 3.87 ms) |
| 6.3 | C++ `deferred-free` p99.9 latency | 0.135-0.141 ms | `…/cpp-deferred-free.json` `percentiles.p99_9` (0.139, 0.135, 0.141 ms) |
| 6.3 | Python `cyclic-garbage` gen-2 collections | 9 | `…/python-cyclic-garbage-gc-pause.json` `notes` (`gen2_collections=9` in all three runs) |
| 6.3 | Python `cyclic-garbage` max pause | 144-151 ms | `…/python-cyclic-garbage-gc-pause.json` `percentiles.max` (150.6, 150.6, 144.0 ms) |
| 6.3 | Python `frozen` gen-2 collections | 0 | `…/python-frozen-gc-pause.json` `notes` (`gen2_collections=0`) |
| 7.1 | `blocking-queue` decide-thread voluntary context switches | 199,523-199,540 | `07-offheap-lockfree/results/r02-run{1,2,3}/java-blocking-queue.json` `runtime.ctx_switches.voluntary` |
| 7.1 | `agrona-spsc` decide-thread voluntary context switches | 29-47 | `…/java-agrona-spsc.json` `runtime.ctx_switches.voluntary` (29, 32, 47) |
| 7.1 | `disruptor` decide-thread voluntary context switches | 37-41 | `…/java-disruptor.json` `runtime.ctx_switches.voluntary` (41, 37, 37) |
| 7.3 (VM) | unpinned decide-thread involuntary context switches | 174,388-313,298 | `07-offheap-lockfree/results/r02-vm-run{1,2,3}/verify.log`, `placement unpinned: involuntary N` (nine alternations) |
| 7.3 (VM) | pinned-isolated involuntary context switches | 0-5 | same lines, `placement pinned-isolated: involuntary N` (nine alternations) |
| 7.3 (VM) | unpinned hand-off p99.9, steady window (median of 3 alternations per run) | 1.09-1.86 ms | `…/r02-vm-run{1,2,3}/verify.log`, criterion 2 line (1,864,703, 1,087,487, 1,640,447 ns) |
| 7.3 (VM) | pinned hand-off p99.9, same | 51-55 us | same lines (51,167, 54,559, 52,383 ns) |
| 8.1 | `protobuf-decode` JMH `gc.alloc.rate.norm` | 544-576 B/op | `08-zero-copy-flat/results/r02-run{1,2,3}/verify.log`, criterion 2 (575.8, 543.8, 575.8) |
| 8.1 | `protobuf-decode` JMH p50 | 150-160 ns | same lines (160, 150, 156) |
| 8.1 | `flat-ffm` JMH `gc.alloc.rate.norm` | under 1 B/op (0.0012) | same lines (0.00124, 0.00123, 0.00126) |
| 8.1 | `flat-ffm` JMH p50 | 16 ns | same lines (16, 16, 16) |
| 8.1 | line end-to-end allocation, `protobuf-decode` | 531-591 B/parcel | `…/verify.log`, criterion 3 (530.98, 530.98, 591.38) |
| 8.1 | line end-to-end allocation, `flat-ffm` | 8.76 B/parcel | same lines (8.7632 in all three) |
| 8.2 | `object-table` sweep p50 | 5.01-5.03 ms | `…/verify.log`, criterion 4 (5,009,407, 5,009,407, 5,033,983 ns) |
| 8.2 | `flat-table` sweep p50 | 0.97-1.00 ms | same lines (986,623, 995,839, 969,215 ns) |
| 8.2 | object 40 B, compact-headers 32 B, flat slot 24 B | exact | `…/verify.log` compact-headers (observed) JOL lines: `ParcelState 40 B` / `32 B`; flat table 2,400,000 B for 100,000 slots |

## Status

| Step | Status |
|---|---|
| 10 specs, 20 generated files | done 2026-10-22 |
| `_data/diagrams.yml` entries for Ch5–Ch8 | done 2026-10-22 |
| Chapters embed the figures (S16–S19) | todo |
