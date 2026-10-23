---
layout: plan
title: "Example 03: coordinated omission"
order: 3
permalink: /examples/03-coordinated-omission/
card_eyebrow: "Example 03 · Chapter 3"
card_title: "One 200 ms stall, measured four ways"
card_blurb: "The same stall is invisible to a service-side timer and a closed-loop client, and obvious to a clock that starts at the belt's schedule; HdrHistogram's correction recovers it."
description: "The same stall is invisible to a service-side timer and a closed-loop client, and obvious to a clock that starts at the belt's schedule; HdrHistogram's correction recovers it."
languages: "C++ · Python · Java"
---

A consumer stalls once for 200 ms at parcel 5000 of a 1 kHz, 10 s run. The same run is recorded as receipt time, intended time, a naive closed-loop client and a closed-loop client corrected with HdrHistogram's expected-interval back-fill. A control run without the stall and a clock-read probe complete the picture.

## Run

```bash
examples/03-coordinated-omission/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host.

## What `verify.sh` asserts

- `intended-time` p99 is at least 50 ms; `receipt-time` p99 is under 1 ms.
- `closed-loop-corrected` p99 is within 2x of `intended-time` p99; `closed-loop-naive` p99 is under 1 ms.
- Control run: `intended-time-control` p99 is under 1 ms, and the corrected closed loop is within 2x of the naive one.
- Every report passes `lowlat-report check`.

All of it held on the quiet-host runs `r02-run1..3` in C++, Java and Python.

## Chapter and source

- Chapter: [Chapter 3, Measuring correctly: clocks, percentiles and coordinated omission]({{ '/docs/03-coordinated-omission/' | relative_url }})
- Source: [`examples/03-coordinated-omission/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/03-coordinated-omission), with its `README.md`, the three language directories and the committed `results/r02-run1..3/`.

