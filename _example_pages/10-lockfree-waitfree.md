---
layout: plan
title: "Example 10: lock-free and wait-free"
order: 10
permalink: /examples/10-lockfree-waitfree/
card_eyebrow: "Example 10 · Chapter 10"
card_title: "Who waits for whom"
card_blurb: "At p99 a mutex claim costs 6.10-6.45x a fetch-add claim in C++ and 14.13-15.23x in Java, and a seqlock lowers the writer's p99 by 205.5-231.0x and 34.5-37.1x (bare-metal, untuned host)."
description: "At p99 a mutex claim costs 6.10-6.45x a fetch-add claim in C++ and 14.13-15.23x in Java, and a seqlock lowers the writer's p99 by 205.5-231.0x and 34.5-37.1x (bare-metal, untuned host)."
languages: "C++ · Java · Python"
---

Four tunnel cameras claim slots in one log, two induction stations race for one belt gap, and the diverter reads parcel state while the tracker writes it. Each is a synchronisation question with a blocking, a lock-free and a wait-free answer: `mutex`, `cas-loop` and `fetch-add` for the claim; release/acquire against `seq_cst` (Java: `setRelease`/`getAcquire` against `volatile`, tested with jcstress) for the induction gap; a shared lock against a seqlock (Java: `StampedLock`) for the read side. A stalled producer shows that a wait-free claim doesn't make the consumer's wait bounded. Python runs the claim under the GIL and the free-threaded build.

## Run

```bash
examples/10-lockfree-waitfree/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host. Threads are placed on distinct physical cores with `sched_setaffinity`, an experiment control that is not isolation. A full run takes about 4 minutes, and the jcstress step uses every CPU.

## What `verify.sh` asserts

- Each sequence is claimed exactly once in every synchronised variant (C++, Java, and Python `lock` in both builds), and the free-threaded `--racy-claim` loses or duplicates at least one (exact).
- `fetch-add` takes exactly 1 step per claim, `cas-loop` fails at least 1 CAS, the least-switching `mutex` producer has at least 100 voluntary context switches and the most-switching `fetch-add` producer at most 10.
- The `mutex` claim p99 is at least 2.5x the `fetch-add` p99 in C++ and at least 3x in Java (median of 3 alternations).
- With a 1 ms sleep between claim and publish, the consumer waits at least 0.5 ms at that sequence.
- Litmus (exact): C++ `seq-cst` and Java `volatile` read `0, 0` zero times; release/acquire reads it at least once.
- Torn snapshots are 0 in every read-side variant, and the writer p99 of the seqlock is at most a third of the shared lock's.
- The four line variants count 200,000 parcels, drop none and receive every divert command, and every report passes `lowlat-report check`.

All of it held on the host runs `r03-run1..3` (bare-metal host, untuned, commit 20664bd). The p99.9 ratios, `cas-loop` against `fetch-add`, the per-store cost, the Python tails and the line percentiles are observed and not asserted.

## Chapter and source

- Chapter: [Chapter 10, Lock-free and wait-free synchronization]({{ '/docs/10-lockfree-waitfree/' | relative_url }})
- Source: [`examples/10-lockfree-waitfree/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/10-lockfree-waitfree), with its `README.md`, the C++, Java and Python directories and the committed `results/r03-run1..3/`.
