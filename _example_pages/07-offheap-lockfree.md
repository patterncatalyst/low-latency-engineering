---
layout: plan
title: "Example 07: off-heap and lock-free Java"
order: 7
permalink: /examples/07-offheap-lockfree/
card_eyebrow: "Example 07 · Chapter 7"
card_title: "Rings, journals and a pinned thread"
card_blurb: "Swapping a parking queue for an Agrona spinning ring cuts the decide thread's voluntary context switches from 199,383-199,582 to 38-47 per 200,000 parcels and its steady hand-off p99 from 10,455-11,743 ns to 572-674 ns (bare-metal, untuned host); the VM part pins the spinner to an isolated vCPU."
description: "Swapping a parking queue for an Agrona spinning ring cuts the decide thread's voluntary context switches from 199,383-199,582 to 38-47 per 200,000 parcels and its steady hand-off p99 from 10,455-11,743 ns to 572-674 ns (bare-metal, untuned host); the VM part pins the spinner to an isolated vCPU."
languages: "Java · C++"
---

The receive thread hands each scan to a decide thread at 10 kHz for 20 s (200,000 parcels). Ten Java variants each swap one stage: an `ArrayBlockingQueue` against Agrona and Disruptor rings for the hand-off, a Chronicle Queue against a `FileChannel.write` per parcel for the audit journal, and a Chronicle Map against a `HashMap` for the 1,000,000-entry manifest. A C++ lane measures the same hand-off over `std::atomic`. The VM part runs the spinner unpinned and pinned to an isolated vCPU in the lab guest.

## Run

```bash
examples/07-offheap-lockfree/verify.sh                 # host part
scripts/lab/revert-vm.sh lowlat-target lab-ready-iso && scripts/lab/lab-up.sh
VM=1 examples/07-offheap-lockfree/verify.sh            # VM part
scripts/lab/lab-down.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host. The VM part restores the guest from a snapshot, and the isolation lives in the guest only.

## What `verify.sh` asserts

- Host: the decide thread's voluntary context switches are at most 1 % of the parcels for `agrona-spsc` and `disruptor` and at least 25 % for `blocking-queue`; the steady-window hand-off p99 of both rings is at most a fifth of `blocking-queue`'s in the same run.
- Host: Disruptor and Agrona publish at most 1 B/op in JMH, and `linked-queue` at least 16 B/op.
- Host: the Chronicle tailer reads back 200,000 events in order, the Chronicle decide thread makes no write system call against one per event for `write-per-parcel`, and its minor faults show the first touch of the mapped file.
- Host: the old generation after a full collection is at most a quarter as large with the Chronicle Map manifest as with the `HashMap`.
- VM: the pinned decide thread has at most 10 involuntary context switches and the unpinned at least 100; the pinned hand-off p99.9 is at most half the unpinned one; the pinned thread is confined to CPU 3.
- Every run counts 200,000 parcels, drops none, has no overflow, receives every divert command and passes `lowlat-report check`.

The host part held on the quiet-host runs `r02-run1..3`; the Disruptor's p99 passed its bound with margins of 2.86 to 3.48. A margin of 1.01 in run 1 of the committed set from before S22 (git history, d419992) did not recur. The VM part held on `r02-vm-run1..3`, each from the snapshot `lab-ready-iso`, and its numbers carry the label `vm` and are never compared with the host's.

## Chapter and source

- Chapter: [Chapter 7, Off-heap and lock-free Java: Chronicle, Agrona, the Disruptor, thread affinity]({{ '/docs/07-offheap-lockfree/' | relative_url }})
- Source: [`examples/07-offheap-lockfree/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/07-offheap-lockfree), with its `README.md`, the Java and C++ directories, the `vm/` scripts and the committed `results/r02-run1..3/` and `results/r02-vm-run1..3/`.
