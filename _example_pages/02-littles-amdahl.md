---
layout: plan
title: "Example 02: Little's Law and Amdahl's Law"
order: 2
permalink: /examples/02-littles-amdahl/
card_eyebrow: "Example 02 · Chapter 2"
card_title: "Two laws, predicted then measured"
card_blurb: "Sampled in-flight parcels against lambda x W, and the speedup of a sort-plan update behind one lock against Amdahl's prediction, with the Python GIL as the counter-example."
description: "Sampled in-flight parcels against lambda x W, and the speedup of a sort-plan update behind one lock against Amdahl's prediction, with the Python GIL as the counter-example."
languages: "C++ · Python · Java"
---

Part A drives a consumer with a variable service time and compares the sampled number of parcels in the system with lambda x W-bar (the time-average is a labelled modelling input in the report's `model` block, never a reported latency). Part B shares a fixed batch of parcels among N workers, each doing parallel work and then updating a table under one lock, and compares the measured speedup with Amdahl's prediction from the measured serial fraction. Python threads and Python processes show what the GIL does to the same plan.

## Run

```bash
examples/02-littles-amdahl/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host.

## What `verify.sh` asserts

- C++ and Java: `count = 10000`, `dropped = 0`, and sampled L within 5 % of lambda x W-bar.
- C++ and Java: the N = 4 speedup is within 15 % of the Amdahl prediction.
- Python threads: N = 4 speedup under 1.3x. Python processes: over 2x.
- The C++, Java and Python unit tests pass, and every report passes `lowlat-report check`.

All of it held on the quiet-host runs `r02-run1..3`.

## Chapter and source

- Chapter: [Chapter 2, Modelling with Little's Law and Amdahl's Law]({{ '/docs/02-littles-amdahl/' | relative_url }})
- Source: [`examples/02-littles-amdahl/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/02-littles-amdahl), with its `README.md`, the three language directories and the committed `results/r02-run1..3/`.

