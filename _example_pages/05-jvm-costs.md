---
layout: plan
title: "Example 05: what the JVM costs"
order: 5
permalink: /examples/05-jvm-costs/
card_eyebrow: "Example 05 · Chapter 5"
card_title: "Allocation, warm-up and the AOT cache"
card_blurb: "Escape analysis takes a 24 B/op decision to under 1 B/op, and an unwarmed JVM's first 2,000 parcels have a p99.9 of 14.4 to 27.7 ms against 0.28 to 0.35 ms steady (bare-metal, untuned host)."
description: "Escape analysis takes a 24 B/op decision to under 1 B/op, and an unwarmed JVM's first 2,000 parcels have a p99.9 of 14.4 to 27.7 ms against 0.28 to 0.35 ms steady (bare-metal, untuned host)."
languages: "Java · C++"
---

A light in-flight parcel tracker sits on the scan-to-divert path. Its `decide` runs on JMH and on the line at 1 kHz for 20 s in Java, and beside it in C++. The example measures three costs of a managed runtime: heap bytes per decision (`gc.alloc.rate.norm`, with escape analysis on and off), the warm-up tail of the first 2,000 parcels (bind at once, replay 20,000 synthetic parcels first, or start from a Leyden AOT cache), and time to ready.

## Run

```bash
examples/05-jvm-costs/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host. `RECHECK=results/<run-id>` re-evaluates a committed run without running anything.

## What `verify.sh` asserts

- JMH `-prof gc`: `escaping` allocates at least 24 B per decision, `scalar-replaced` at most 1 B, and `--no-escape-analysis` at least 24 B again; in C++ `--allocating` allocates at least 16 B and once per parcel, and the value variant at most 1 B.
- `--unwarmed`: the first-window p99.9 is at least 5x the steady p99.9 of the same run.
- `warmed`: the first-window p99 is at most 3x the steady p99.
- `aot-cache`: the median time to ready is at most 0.8x the no-cache median, and the AOT log shows the cache opened.
- Every Java report's `build.flags` carries the JVM arguments, and every line run counts 20,000 parcels, drops none and passes `lowlat-report check`.

All of it held on the quiet-host runs `r02-run1..3`. The criterion on the unwarmed first window is asserted on p99.9; the chapter and the README give the detail.

## Chapter and source

- Chapter: [Chapter 5, What the JVM costs: allocation, escape analysis, JIT warmup vs AOT]({{ '/docs/05-jvm-costs/' | relative_url }})
- Source: [`examples/05-jvm-costs/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/05-jvm-costs), with its `README.md`, the Java and C++ directories and the committed `results/r02-run1..3/`.
