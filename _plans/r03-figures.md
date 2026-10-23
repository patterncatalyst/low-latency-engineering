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

Measured values: filled in at S9 from `examples/09-eliminating-work/results/r03-run{1,2,3}/` and `examples/10-lockfree-waitfree/results/r03-run{1,2,3}/`, one row per value with its source file and field (the r02-figures form), ranges across the three runs, no mean.

## Status

| Step | Status |
|---|---|
| specs and generated files | todo |
| `_data/diagrams.yml` entries | todo |
| chapters embed the figures (S10–S11) | todo |
