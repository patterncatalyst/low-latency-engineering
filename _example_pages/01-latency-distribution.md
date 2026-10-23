---
layout: plan
title: "Example 01: latency is a distribution"
order: 1
permalink: /examples/01-latency-distribution/
card_eyebrow: "Example 01 · Chapter 1"
card_title: "Per-parcel, batch-32 and a bimodal tail"
card_blurb: "On a bare-metal, untuned host, equal throughput has a different shape: batching raises the p50 82x to 180x, and one slow parcel in a hundred moves p99 while the median stays in the fast mode."
description: "On a bare-metal, untuned host, equal throughput has a different shape: batching raises the p50 82x to 180x, and one slow parcel in a hundred moves p99 while the median stays in the fast mode."
languages: "C++ · Python · Java"
---

Three consumer variants receive the same 1 kHz stream. Per-parcel handling and batch-of-32 process the same parcels per second, but the batch variant makes each parcel wait for 31 others. The bimodal variant spends about 2 ms of CPU on one parcel in 100; the median stays in the fast mode, and p99 lands in the slow mode among the parcels queued behind it.

## Run

```bash
examples/01-latency-distribution/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host.

## What `verify.sh` asserts

- Every report has `count = 10000`, `dropped = 0` and passes `lowlat-report check`.
- Per-parcel and batch-32 throughput differ by less than 1 %.
- Batch-32 p50 is at least 10x the per-parcel p50.
- Bimodal p99 is at least 20x its own p50.
- Bimodal p50 stays under a quarter of the run's measured slow-path duration.

All of it held on the quiet-host runs `r02-run1..3` in C++, Python and Java.

## Chapter and source

- Chapter: [Chapter 1, Latency vs bandwidth: latency is a distribution]({{ '/docs/01-latency-distribution/' | relative_url }})
- Source: [`examples/01-latency-distribution/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/01-latency-distribution), with its `README.md`, the three language directories and the committed `results/r02-run1..3/`.

