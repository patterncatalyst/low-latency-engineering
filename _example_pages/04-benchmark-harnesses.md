---
layout: plan
title: "Example 04: benchmark harnesses"
order: 4
permalink: /examples/04-benchmark-harnesses/
card_eyebrow: "Example 04 · Chapter 4"
card_title: "Google Benchmark, JMH and pyperf"
card_blurb: "One SSCC-18 check digit under three harnesses: the optimizer deletes the unguarded version, and each harness reports its own view of the distribution."
description: "One SSCC-18 check digit under three harnesses: the optimizer deletes the unguarded version, and each harness reports its own view of the distribution."
languages: "C++ · Python · Java"
---

The GS1 mod-10 check digit of an SSCC-18, run over 1,024 prefixes, benchmarked with Google Benchmark (C++), JMH in SampleTime mode (Java) and pyperf (Python). The C++ and Java benchmarks come in a guarded form and an eliminated form that the optimizer or the JIT removes; Python has no dead-code elimination, so the contrast there is warm-up. The harness output is converted to `lowlat-report/1` files.

## Run

```bash
examples/04-benchmark-harnesses/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host.

## What `verify.sh` asserts

- C++: the eliminated median is at least 10x lower than the guarded median.
- Java: the eliminated p50 is at least 10x lower than the guarded p50, and the JMH output includes p0.99 and p0.999.
- Python: the pyperf JSON holds at least 20 values from at least 3 worker processes.
- The check digit agrees across the C++, Java and Python tests, and the six converted reports pass `lowlat-report check`.

All of it held on the quiet-host runs `r02-run1..3`.

## Chapter and source

- Chapter: [Chapter 4, Benchmark harnesses: Google Benchmark, pyperf and JMH]({{ '/docs/04-benchmark-harnesses/' | relative_url }})
- Source: [`examples/04-benchmark-harnesses/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/04-benchmark-harnesses), with its `README.md`, the three language directories and the committed `results/r02-run1..3/`.

