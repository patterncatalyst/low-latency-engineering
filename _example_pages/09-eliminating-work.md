---
layout: plan
title: "Example 09: eliminating work"
order: 9
permalink: /examples/09-eliminating-work/
card_eyebrow: "Example 09 · Chapter 9"
card_title: "A tracker with less to do"
card_blurb: "At 1,000,000 parcels an open-addressing flat map looks a parcel up in a p50 of 113 ns against 389-393 ns for a node map in C++, and padding five camera counters cuts L1 misses per increment 590-622x (bare-metal, untuned host)."
description: "At 1,000,000 parcels an open-addressing flat map looks a parcel up in a p50 of 113 ns against 389-393 ns for a node map in C++, and padding five camera counters cuts L1 misses per increment 590-622x (bare-metal, untuned host)."
languages: "C++ · Java · Python"
---

The in-flight parcel tracker looks a barcode up, inserts or updates the parcel, and sweeps for parcels that reached the diverter at every encoder tick. The example removes work from that tracker in three places: the lookup map (a node map against open addressing on a packed 64-bit key), the record layout the sweep reads (an 80-byte struct against hot columns of 9 B), and the counters five scan-tunnel cameras write (adjacent in one cache line against padded). C++ leads, Java follows in its idiom, and Python shows what the object model costs. The tracker is measured at the line's 4,800 parcels, where it fits L2, and at hub scale, 1,000,000 parcels, where it does not.

## Run

```bash
examples/09-eliminating-work/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host. Threads are placed on distinct physical cores with `sched_setaffinity`, an experiment control that is not isolation.

## What `verify.sh` asserts

- Allocation (exact): the C++ node map makes at least 2 allocations per insert and the flat map none after `reserve`; JMH `node-map` allocates at least 64 B per insert and `flat-map` at most 1 B; the Python `dict` record is at least 2x the slotted record, and `--dict-per-parcel` holds at least 2x the bytes of `slots-int` per tracked parcel.
- Hub lookups: cachegrind last-level read misses per lookup are at least 2x higher for the node map (exact), and so are `perf` `LLC-load-misses:u` per lookup in C++.
- Hub sweep: the fat-record p50 is at least 2x the hot/cold p50 in C++ and Java, and cachegrind D1 read misses per slot are at least 4x higher (exact).
- Counters: L1 misses per increment are at least 10x higher adjacent than padded in C++ and Java, and the C++ `fetch_add` per-batch p50 is at least 3x.
- Line, C++: the node map allocates on the receive thread (at least 1 per parcel) and the flat map does not (exact).
- Every report passes `lowlat-report check`, the line runs count 200,000 parcels with none dropped, and every pinned report carries its thread placement.

All of it held on the host runs `r03-run1..3` (bare-metal host, untuned, commit 9802788). The lookup p50 ratios, the store-increment batch times and the Python lane are observed and not asserted.

## Chapter and source

- Chapter: [Chapter 9, Eliminating work: allocation, cache locality, false sharing]({{ '/docs/09-eliminating-work/' | relative_url }})
- Source: [`examples/09-eliminating-work/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/09-eliminating-work), with its `README.md`, the C++, Java and Python directories and the committed `results/r03-run1..3/`.
