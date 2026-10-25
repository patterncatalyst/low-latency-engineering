---
layout: plan
title: "Example 11: stackful and stackless"
order: 11
permalink: /examples/11-stackful-stackless/
card_eyebrow: "Example 11 · Chapter 11"
card_title: "Who holds the wait"
card_blurb: "A parked wait costs a C++ thread 9,245,449 B of address space and a fiber 69,645 B, while a coroutine needs only its counted 208 B frame; a round trip is 18.25-18.33x faster between fibers than between threads, and one 2 ms blocking call lifts the neighbours' p99 wake lateness from 52 us to 1,917-1,952 us (bare-metal, untuned host)."
description: "A parked wait costs a C++ thread 9,245,449 B of address space and a fiber 69,645 B, while a coroutine needs only its counted 208 B frame; a round trip is 18.25-18.33x faster between fibers than between threads, and one 2 ms blocking call lifts the neighbours' p99 wake lateness from 52 us to 1,917-1,952 us (bare-metal, untuned host)."
languages: "C++ · Java · Python"
---

A lookup at the warehouse management system takes about 2 ms, and at 10 kHz that is 20 lookups in flight. Something has to hold each wait: a thread or fiber that keeps a stack, or a coroutine or event-loop task that keeps only a frame. The example parks 10,000 tasks on one timer and reads the cost per wait, passes a turn between two tasks (OS threads, Boost.Fiber, C++ coroutines; Java platform and virtual threads; Python threads and `asyncio` in the GIL and free-threaded builds), and then lets one task make a 2 ms blocking call while 1,000 neighbours wake every 2 ms. A JFR run shows which blocking calls pin a virtual thread's carrier, and a five-variant line run carries the same decisions on the sortation line.

## Run

```bash
examples/11-stackful-stackless/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host. A full run takes about 12 minutes, a clean build included, and the 10,000-thread runs need the process and map limits of an ordinary desktop session.

## What `verify.sh` asserts

- The address space per parked wait of a C++ thread is at least 10x a fiber's, and a fiber's is at least 10x the coroutine's counted frame; the Java platform thread's full resident cost is at least 5x a virtual thread's, and Python's thread RSS at least 5x an `asyncio` task's.
- The coroutine frame is at most 1,024 B with one allocation per frame (exact), and every fiber and coroutine run has all 10,000 tasks armed.
- A C++ thread hand-off costs at least 0.9 voluntary context switches per round trip, and fibers and coroutines at most 0.001 (exact counts; 0 observed).
- The round-trip p50 of a thread is at least 5x a fiber's and a coroutine's in C++, and a Java platform thread's at least 2x a virtual thread's (median of 3 alternations).
- With a 2 ms blocking call, the neighbour fibers' wake-lateness p99 is at least 1 ms; in the `asyncio` twin the fraction of wakes later than 1.5 ms is at least 2x its baseline's, and each blocking call logs exactly one slow-callback warning (exact).
- The five line variants count 200,000 parcels, drop none and receive every divert command, and every report passes `lowlat-report check`.

All of it held on the host runs `r04-run1..3` (bare-metal host, untuned, commit 4434ed1). The RSS ratios, the Java switch counts, the semaphore hand-off, the pinning counts, the coroutine allocation elision (HALO) and the line percentiles are observed and not asserted.

## Chapter and source

- Chapter: [Chapter 11, Stackful vs stackless: threads and fibers vs event loops and coroutines]({{ '/docs/11-stackful-stackless/' | relative_url }})
- Source: [`examples/11-stackful-stackless/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/11-stackful-stackless), with its `README.md`, the C++, Java and Python directories and the committed `results/r04-run1..3/`.
