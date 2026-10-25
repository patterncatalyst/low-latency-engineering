---
layout: plan
title: "Example 12: I/O engines"
order: 12
permalink: /examples/12-io-engines/
card_eyebrow: "Example 12 · Chapter 12"
card_title: "What wakes the thread"
card_blurb: "In C++ at saturation, epoll makes 1.379-1.417 system calls per parcel and io_uring 0.062-0.068, with 14.7-16.2 completions per io_uring_enter; thread-per-core makes 0 hand-offs per parcel against 1; and in a Quarkus service where 5 kHz x 2 ms puts 10 requests in flight, an 8-thread worker pool has a p99 162.85-223.10x that of virtual threads (bare-metal, untuned host)."
description: "In C++ at saturation, epoll makes 1.379-1.417 system calls per parcel and io_uring 0.062-0.068, with 14.7-16.2 completions per io_uring_enter; thread-per-core makes 0 hand-offs per parcel against 1; and in a Quarkus service where 5 kHz x 2 ms puts 10 requests in flight, an 8-thread worker pool has a p99 162.85-223.10x that of virtual threads (bare-metal, untuned host)."
languages: "C++ · Java · Python"
---

A hub concentrator takes four tunnel cameras' UDP feeds, and each datagram needs something to tell a receive thread there is work. The example receives the same feed through `epoll` plus `recvmsg`, `recvmmsg` and a multishot `io_uring` receive over a provided-buffer ring (plus Boost.Asio on its io_uring backend), and counts system calls per parcel inside the program. It then compares thread-per-core against an acceptor with a worker pool, counting cross-thread hand-offs per parcel. One tier up, a Quarkus sort-plan service waits 2 ms on its downstream in four ways: `event-loop`, `worker-pool`, `virtual-thread` and a defect that sleeps on the event loop. Plain-JDK and Python (`asyncio`, `uvloop`, blocking threads) lanes and `strace` summaries cross-check the counters.

## Run

```bash
examples/12-io-engines/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host. Threads are placed on distinct physical cores with `sched_setaffinity`, an experiment control that is not isolation. A full run takes about 15 minutes, a clean build included.

## What `verify.sh` asserts

- At saturation `io-uring` makes at most a quarter of `epoll`'s system calls per parcel, and nothing drops.
- `thread-per-core` makes 0 hand-offs per parcel and `acceptor-pool` 1 (exact), with the acceptor's busy share inside a guard band and no drops in either layout.
- At 5 kHz against a pool of 8, the `worker-pool` p99 is at least 3x the `virtual-thread` p99 (median of 3), and the pool counters show 8 active workers (exact) while `event-loop` and `virtual-thread` use none.
- The defect logs blocked-thread warnings and runs at most one request per loop thread (exact).
- The line variants count 200,000 parcels, drop none, and every report passes `lowlat-report check`; every multi-thread start skew is under 1 ms.

All of it held on the host runs `r04-run1..3` (bare-metal host, untuned, commit 4434ed1). `asio-io-uring`, `recvmmsg`'s calls per parcel, the line percentiles, the `io-uring` tail against `epoll`, the layout p99 ratio, the defect against its control and the plain-JDK, Python and `strace` results are observed and not asserted.

## Chapter and source

- Chapter: [Chapter 12, I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core]({{ '/docs/12-io-engines/' | relative_url }})
- Source: [`examples/12-io-engines/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/12-io-engines), with its `README.md`, the C++, Java (Quarkus) and Python directories and the committed `results/r04-run1..3/`.
