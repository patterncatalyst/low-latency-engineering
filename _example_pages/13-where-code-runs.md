---
layout: plan
title: "Example 13: where the code runs"
order: 13
permalink: /examples/13-where-code-runs/
card_eyebrow: "Example 13 · Chapter 13"
card_title: "Where the thread runs"
card_blurb: "On this machine, in this run, the same decide path shows a simulator emit-lateness p99 of 62-64 us on the bare-metal host, 80-83 us in a VM and 85-103 us in a container behind a bridge; --cpus=2 raised the consumer p99.9 13.16-18.91x over --cpuset-cpus=2,3, and io_uring_setup returned EPERM in every container."
description: "On this machine, in this run, the same decide path shows a simulator emit-lateness p99 of 62-64 us on the bare-metal host, 80-83 us in a VM and 85-103 us in a container behind a bridge; --cpus=2 raised the consumer p99.9 13.16-18.91x over --cpuset-cpus=2,3, and io_uring_setup returned EPERM in every container."
languages: "C++ · Java · Python"
---

The same decide path runs on the bare-metal host, natively in the lab guest, and in containers inside that guest: host network, the default bridge, `--cpus=2` and `--cpuset-cpus=2,3`. The simulator's emit lateness is the jitter floor of each lane, a CPU quota is compared with a cpuset under a busy pool, and each runtime reports what it thinks it may use (`hardware_concurrency()`, `os.process_cpu_count()`, `availableProcessors()`). A probe calls `io_uring_setup` in every lane to show Docker's default seccomp profile. Every number is lane-labelled and compared only inside one interleaved run on this machine.

## Run

```bash
flock -o "$LOCK" env VM=1 examples/13-where-code-runs/verify.sh
```

`VM=1` reverts the lab guest to snapshot `lab-ready-r04`, deploys the repository, checks the three images against `containers/IMAGES.lock`, runs six lanes interleaved three times and shuts the guest down. Without `VM=1` only the host lane runs and the script ends non-zero as a partial run, by design. It needs the `lowlat-target` guest, and nothing on the host changes: no sudo, no sysctl, no firewall rule.

## What `verify.sh` asserts

- Under `--cpus=2` the cgroup counts at least 1 throttle and 1 throttled microsecond, and under `--cpuset-cpus=2,3` both are 0 (exact).
- On the 4-vCPU guest the runtimes report what the chapter says: C++ 4 under both limits, Python 4 under the quota and 2 under the cpuset, Java 2 under both (exact).
- `io_uring_setup` returns `EPERM` in every container lane and succeeds in the guest outside a container (exact).
- The consumer p99.9 under the quota is at least 2x the cpuset's (median of 3 alternations).
- In every lane and alternation: 200,000 parcels, none dropped, the lane's environment record and image digest, and one set of C++ binary checksums across lanes.

All of it held on the runs `r04-run1..3` (commit 4434ed1; bare-metal host, untuned, with the lab guest booted and idle; guest profile `stock-unpinned`, snapshot `lab-ready-r04`; images pinned in `IMAGES.lock`). Host against VM, bridge against host network, emit lateness per lane, steal ticks, the Quarkus p99 under the two limits and the thread counts are observed and not asserted.

## Chapter and source

- Chapter: [Chapter 13, Where the code runs: bare metal, VMs and containers, and when not to use containers]({{ '/docs/13-where-code-runs/' | relative_url }})
- Source: [`examples/13-where-code-runs/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/13-where-code-runs), with its `README.md`, the C++, Java and Python directories, the container images and the VM driver and the committed `results/r04-run1..3/`.
