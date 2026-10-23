---
layout: plan
title: "Example 06: GC for tails"
order: 6
permalink: /examples/06-gc-tails/
card_eyebrow: "Example 06 · Chapter 6"
card_title: "Four collectors, one tracker"
card_blurb: "On a 4 GB heap with a 1.8 GB live set the maximum GC pause is 158 to 170 ms under Parallel and 0.017 to 0.036 ms under Generational ZGC; at 1.05 times the live set ZGC stalls the allocating thread (bare-metal, untuned host)."
description: "On a 4 GB heap with a 1.8 GB live set the maximum GC pause is 158 to 170 ms under Parallel and 0.017 to 0.036 ms under Generational ZGC; at 1.05 times the live set ZGC stalls the allocating thread (bare-metal, untuned host)."
languages: "Java · C++ · Python"
---

An in-flight parcel tracker runs at 10 kHz for 30 s with a 1.8 GB live set and about 400 MB/s of scan-history garbage. Eight JVM variants run the same bytecode under Parallel, G1, Generational ZGC and Generational Shenandoah, a heap at 1.05 times the live set, and the observed `thp`, `jfr-off` and non-generational Shenandoah variants. A Python lane (`cyclic-garbage`, `frozen`) and a C++ lane (`bulk-free`, `deferred-free`, `no-free`) ask the same question where there is a cycle collector, and where there is none.

## Run

```bash
examples/06-gc-tails/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It needs 4 GB for a heap, refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and never changes the host. `RECHECK=results/<run-id>` re-evaluates a committed run, and `SWEEP=1` runs the heap-multiple sweep behind the 1.05x choice.

## What `verify.sh` asserts

- The Parallel maximum pause is at least 10 ms and 20x ZGC's, ZGC's is under 1 ms, and Generational Shenandoah's is at most a fifth of Parallel's.
- ZGC's end-to-end p99.9 is at most a third of Parallel's.
- `undersized-heap` records at least one ZGC allocation stall, and its p99.9 is at least 3x right-sized ZGC's.
- Python: `frozen` runs 0 generation-2 collections in the window and `cyclic-garbage` at least 1.
- C++: the `bulk-free` maximum is at least 10x the `deferred-free` p99.9.
- Every report counts 300,000 parcels, drops none and passes `lowlat-report check`, and each Java report names its collector and heap.

All of it held on the quiet-host runs `r02-run1..3`. The `thp` variant got no huge pages from the host, so it is a second ZGC run on 4 KB pages and shows nothing about huge pages.

## Chapter and source

- Chapter: [Chapter 6, GC for tails: Generational ZGC and Shenandoah]({{ '/docs/06-gc-tails/' | relative_url }})
- Source: [`examples/06-gc-tails/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/06-gc-tails), with its `README.md`, the three language directories and the committed `results/r02-run1..3/`.
