---
title: "Outline"
order: 0
overview: true
part: "Prerequisites & the Lab"
description: "What this site covers and how it's organized: 33 chapters across ten parts plus six appendices, every technique measured against one scan-to-divert budget."
---

This site teaches latency engineering through one workload: a high-speed parcel
sortation line. A `line-simulator` emits parcels past an in-motion checkweigher, a
dimensioner, a barcode scanner, a print-and-apply labeler and a sortation diverter,
with a PLC encoder supplying belt position as the shared clock. The controller has a
fixed time to read the scan and fire the diverter, and that time comes from physics:

```text
decision deadline = distance(scanner -> diverter) / belt speed
                  = 1.2 m / 2.5 m/s  =  480 ms, minus encoder jitter and actuation
```

{% include excalidraw.html
   file="00-sortation-line"
   alt="A conveyor carries parcels past a checkweigher, dimensioner, scanner and labeler to a diverter; the controller must sense, decide and act within the scan-to-divert deadline."
   caption="Figure 0.1 — The sortation line. Belt speed and the scanner-to-diverter distance set the decision deadline." %}

Every chapter measures its technique against that **scan-to-divert** budget and
reports a distribution (p50, p99, p99.9), never a mean. Coordinated omission is
physical here: the belt never waits for a slow consumer, so a sample that was never
taken is a parcel sent down the wrong lane.

Examples are original and shown in **C++20/23, Python 3.14 and Java 25** on the plain
JVM. Where a technique has no clean equivalent in one of the three, the chapter says
so and explains why. That divergence is part of the lesson. Everything on a critical
path is open source; the commercial landscape is surveyed in Appendix F and never
required.

The arc is below. Chapters link as they ship.

## Part 0 — Prerequisites & the Lab
- Ch0 · [Setup: Fedora 44, the three toolchains, Docker Engine, the KVM/libvirt VM lab, a PREEMPT_RT kernel, `linuxptp`, and the line simulator]({{ '/docs/00-prerequisites/' | relative_url }})

## Part 1 — Understanding & Measuring Latency
- Ch1 · [Latency vs bandwidth; latency as a distribution]({{ '/docs/01-latency-distribution/' | relative_url }})
- Ch2 · [Modeling with Little's Law and Amdahl's Law]({{ '/docs/02-littles-amdahl/' | relative_url }})
- Ch3 · [Measuring correctly: clocks, percentiles, coordinated omission, HdrHistogram]({{ '/docs/03-coordinated-omission/' | relative_url }})
- Ch4 · [Benchmark harnesses: Google Benchmark, `pyperf`, JMH]({{ '/docs/04-benchmark-harnesses/' | relative_url }})

## Part 2 — The Managed-Runtime Question
- Ch5 · [What the JVM costs: allocation, escape analysis, JIT warmup vs AOT]({{ '/docs/05-jvm-costs/' | relative_url }})
- Ch6 · [GC for tails: Generational ZGC and Shenandoah]({{ '/docs/06-gc-tails/' | relative_url }})
- Ch7 · [Off-heap and lock-free Java: Chronicle, Agrona, the Disruptor, thread affinity]({{ '/docs/07-offheap-lockfree/' | relative_url }})
- Ch8 · [Zero-copy and flat data: Panama (FFM), Valhalla value objects, and the C++ comparison]({{ '/docs/08-zero-copy-flat/' | relative_url }})

## Part 3 — Accelerating Code
- Ch9 · Eliminating work: allocation, cache locality, false sharing
- Ch10 · Lock-free and wait-free synchronization

## Part 4 — Threading & I/O Models
- Ch11 · Stackful vs stackless: threads and fibers vs event loops and coroutines
- Ch12 · I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core
- Ch13 · Where the code runs: bare metal, VMs and containers, and when not to use containers

## Part 5 — The OS, Isolation & the Network Edge
- Ch14 · PREEMPT_RT: what real-time Linux does and doesn't promise
- Ch15 · CPU partitioning and the noisy-neighbour problem
- Ch16 · Measuring jitter with `cyclictest`
- Ch17 · Kernel bypass: DPDK, AF_XDP/XDP, RDMA
- Ch18 · Latency config as code: CI/CD, deployment, and rollouts gated on a latency and jitter SLO

## Part 6 — Transports by Latency Budget
- Ch19 · Match every message to a channel by its budget; separate command and data paths
- Ch20 · Request and command: gRPC, per-call deadlines and priority
- Ch21 · The real-time backbone: OMG DDS (Cyclone DDS, Fast DDS) and QoS
- Ch22 · Aeron and SBE: reliable UDP and IPC with zero-copy encoding
- Ch23 · The exchange boundary: FIX with Artio
- Ch24 · Streaming and bulk: WebSockets with protobuf, and Kafka
- Ch25 · Fieldbus and local IPC: Modbus and D-Bus

## Part 7 — Observing Without Wrecking It
- Ch26 · Low-overhead measurement: eBPF, USDT, sampling, off-path export
- Ch27 · What to watch: per-channel latency, jitter, command timing, consumer lag

## Part 8 — Failure: Detect, Withstand, Act, Observe
- Ch28 · A failure taxonomy for the sortation line
- Ch29 · Detect: liveliness, heartbeats, watchdogs, deadline misses
- Ch30 · Withstand and act: restart, failover, redundant paths, graceful degradation
- Ch31 · Observe: feeding every tier back into observability

## Part 9 — The Whole Line
- Ch32 · A latency-tiered line end to end, holding command latency while the data path is flooded

## Appendices
- A · Resilience model
- B · Latency, throughput and channel strategy
- C · Coverage map against the reference books
- D · PTP / IEEE-1588 time sync with `linuxptp`
- E · Free-threaded Python vs the GIL
- F · The commercial low-latency landscape (survey only)
