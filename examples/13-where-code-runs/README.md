# 13-where-code-runs

Chapter 13: where the code runs. Ch11 asked who holds a wait and Ch12 asked what wakes the thread. This chapter asks
where the thread runs: on bare metal, in a VM, or in a container in that VM. The decide path is the same binary in all of
them. What changes is the jitter floor under it, the network path in front of it, and what each runtime believes about the
CPUs it may use. A container is a cgroup and a few namespaces, not a smaller machine, and the most expensive mistakes are
the ones where a runtime sizes its pools from a machine it doesn't have.

## Technique

- **(a) The jitter floor and the decide path in three places.** The line simulator and the Ch12 `epoll` consumer run on the
  host (`host`), natively in the lab guest (`vm`), and in a container in that guest. The simulator's emit lateness is the
  floor: it bounds what any consumer can claim.
- **(b) Container networking.** `container-host-net` shares the guest's network namespace. `container-bridge` puts the
  consumer behind a veth and the default bridge; the simulators stay in the guest, so every datagram crosses the veth.
- **(c) CPU quota against cpuset.** `--cpus=2` is CFS bandwidth: 200 ms of CPU per 100 ms period, any CPU, and a cgroup that
  spends it early is stopped until the period ends (`nr_throttled`, `throttled_usec`). `--cpuset-cpus=2,3` is a mask: two
  CPUs, no throttling, threads time-slice. A pool of 4 busy workers beside the consumer makes the difference visible.
- **(d) What each runtime thinks it has.** C++ `std::thread::hardware_concurrency()` reads the kernel's online CPU list, which
  a container doesn't narrow, so it says 4 under both limits. Python `os.process_cpu_count()` follows the affinity mask: 4
  under the quota, 2 under the cpuset. Java `availableProcessors()` reads both the quota (rounded up) and the cpuset: 2 under
  both, and it sizes the virtual-thread scheduler, the GC threads and the Vert.x event loops from that.
- **(e) Default seccomp and io_uring.** Docker's default seccomp profile blocks `io_uring_setup`. The same binary gets
  `EPERM` in a container and success outside one.
- **(f) When not to use a container,** below.

## Workload

- **Line:** four simulator instances (four tunnel cameras) at 2.5 kHz each, 10 kHz together, for 20 s: 200,000 parcels per
  lane run. The simulator and the consumer run in the same environment, because their timestamps are on one
  `CLOCK_MONOTONIC` (the clock-domain rule). For `container-bridge` the simulators run in the guest and the consumer in the
  container. The consumer is Ch12's `io-receive --variant epoll`, pinned to one CPU, with 3 microseconds of modelled decide
  work per parcel. Latency is measured from the intended emit time.
- **Pool:** in `container-cpu-quota` and `container-cpuset` a `busy-pool` of 4 workers (sized by
  `hardware_concurrency()`, so 4 on the guest whatever the limit) spins beside the consumer. Under `--cpus=2` the container
  asks for more CPU time than it may spend and is throttled. Under `--cpuset-cpus=2,3` it has two CPUs and no quota.
- **Service:** the Ch12 Quarkus service in the Java container (virtual-thread variant, 3 kHz x 2 ms), under the same two
  limits, driven by the Ch12 open-loop client in the guest.
- **Interleave:** `host vm container-host-net container-bridge container-cpu-quota container-cpuset`, three times. Every
  comparison is inside this one run.

## Lanes and what runs where

| Lane | Where | Network | Limit |
|---|---|---|---|
| `host` | bare metal: the host, untuned and shared, lab VM booted and idle | loopback | none |
| `vm` | native in the guest (stock kernel, 4 vCPU, unpinned) | loopback | none |
| `container-host-net` | Docker in the guest | `--network host` | none |
| `container-bridge` | Docker in the guest; simulators in the guest | bridge, veth | none |
| `container-cpu-quota` | Docker in the guest | bridge (loopback inside) | `--cpus=2` |
| `container-cpuset` | Docker in the guest | bridge (loopback inside) | `--cpuset-cpus=2,3` |

Containers are created only in the guest, only through `container_run` (`examples/_lib/lib.sh`) and only with its
allowlisted options: `--network host|bridge`, `--cpus`, `--cpuset-cpus`, the default seccomp profile, and bind mounts under
one declared output directory. No `--privileged`, no host Docker (decision D7). The Quarkus service runs with
`--network host` so the client reaches it on loopback without publishing a port.

## Files

- `cpp/`: `place-probe` (`hardware_concurrency()`, the online CPU list, the affinity mask, `cpu.max`,
  `cpuset.cpus.effective`, `cpu.stat`, the `io_uring_setup` errno from the raw system call; `std::expected` errors),
  `busy-pool` (`std::jthread` and `stop_token`, a spin start gate, padded counters, an external-linkage sink), and the
  `lowlat_place` library with its tests.
- `java/`: `CpuProbe` records `availableProcessors()`, the most virtual threads mounted at once under a spin, the GC thread flags.
- `place-py/`: `python -m lowlat_place` records `os.cpu_count()`, `os.process_cpu_count()` and the affinity mask. There is no
  latency lane in Python here.
- `vm/lane-cpp.sh`: one C++ lane in whatever environment it starts in (POSIX sh, so it runs in a ubi-minimal image).
  `vm/service-lane.sh` runs the Quarkus service in its container and counts its threads. `vm/guest-run.sh` runs in the
  guest. `vm/run.sh` drives everything from the host.
- `containers/`: the three images (UBI 10) and `IMAGES.lock`. The C++ image holds `line-simulator`, `io-receive`,
  `place-probe` and `busy-pool`; `vm/run.sh` copies those four files out of it, so the host, the guest and the containers run
  one file each. libstdc++ and libgcc are linked statically; glibc is not, and it still differs between the three places
  (each lane records its glibc version in `probe-cpp.json`).

## Run

```bash
flock -o "$LOCK" ./verify.sh            # host lane x 3 only: ends non-zero as a partial run, by design (the other lanes need the guest)
flock -o "$LOCK" env VM=1 ./verify.sh   # the whole thing: revert lab-ready-r04, six lanes interleaved x 3, evaluate
RECHECK=results/<run-id> ./verify.sh    # evaluate a results directory, run nothing
DRY_RUN=1 SMOKE=1 RESULTS_DIR=/tmp/x vm/run.sh   # print the commands vm/run.sh and vm/guest-run.sh would run
```

`vm/run.sh` reverts the guest to snapshot `lab-ready-r04`, deploys the repository, pushes two jars, checks the three images
against `IMAGES.lock`, requires an idle guest (`require_quiet_host --lab-idle`), runs the lanes, fetches the guest's results,
and shuts the guest down. If the images were rebuilt, `containers/build-images.sh` (in the guest) rewrites `IMAGES.lock`;
commit it and take the snapshot again. Nothing on the host changes: no sudo, no sysctl, no Docker. The guest is reached over
vsock ssh behind passt. UDP ports 47340 to 47343 and TCP 47344 are this example's (00 to 12 use 47000 to 47336).

## Expected effect and criteria

Counters first, then latency. Everything marked exact is a count the kernel or the runtime reports; the rest are medians of
three alternations within the one run.

1. **(exact)** `container-cpu-quota` has `nr_throttled >= 1` and `throttled_usec >= 1`, and `container-cpuset` has both at
   0, read from the container's own `cpu.stat` at the end of its run.
2. **(exact)** On the 4-vCPU guest: C++ `hardware_concurrency()` = 4 under both limits; Python `os.process_cpu_count()` = 4
   under the quota and 2 under the cpuset; Java `availableProcessors()` = 2 under both.
3. **(exact)** `io_uring_setup` returns `EPERM` in every container lane and 0 in the guest outside a container.
4. `container-cpu-quota` consumer p99.9 is at least 2x `container-cpuset`'s, the median of 3 alternations. It's asserted:
   the calibration runs measured 14.2x to 27.0x over 9 alternations. `CRIT4_ASSERTED=0` makes it observed.
5. Every lane and alternation: 200,000 parcels, `dropped = 0`, `lowlat-report check`, `runtime.environment.kind` matching the
   lane, the guest profile recorded, the container image digest equal to `IMAGES.lock`, and one set of binary checksums
   across all lanes.

## Reading the numbers

- The host lane is a bare-metal host, untuned and shared (`powersave`, `balanced`, a desktop session running). `verify.sh` records the
  host's load and busy share across each host alternation in `host/altN/host-quiet.json` and prints them as observed; it
  never refuses on them. In the committed runs the host consumer p99.9 had per-run medians of 195 to 264 microseconds (single alternations
  176 to 573) with a host load1 between 0.97 and 2.45 over the nine alternations, which is what an unquiet host looks like. The host simulators are pinned to the CPUs left after the consumer's core
  (and its SMT sibling) and CPU 0's core, and that mask is recorded beside the load.

- The Quarkus comparison between the quota and the cpuset is confounded and observed only. The open-loop client runs in the
  guest on CPUs 0 and 1, and the quota container is free to use those CPUs too, while the cpuset container can't.
- The `container-cpuset` lane carries the simulators, the consumer and the pool in one cgroup on two CPUs, and the quota lane
  carries them in one cgroup under one quota. That is the point of the lane (everything the container runs shares its limit),
  and it means the simulators' emit lateness moves with the limit as well.
- The busy pool's start skew is observed. Four spinning workers on two CPUs are spread by the scheduler, not by the gate, so a
  1 ms bound would measure the scheduler.
- A plain `./verify.sh` is a host-only partial run and exits non-zero by design: a run without the other
  lanes proves nothing about them.

## Observed, not asserted

Host against VM jitter floor and end-to-end percentiles; bridge against host network; guest steal ticks (from
`/proc/stat`); the simulator's emit lateness per lane; Quarkus p99 under the quota against the cpuset; Java ergonomics (GC
threads, Vert.x event loops, carriers).

## D9: what these comparisons are

Every number is labelled with its lane and means "on this machine's KVM, in this run". The host and the guest don't share a
kernel, a CPU model view or a clock, so host against VM is printed and never asserted. Container costs are measured
against the VM-native lane in the same guest, so they're container-in-VM costs, not container-on-bare-metal costs. The host
lane runs with the lab VM booted and idle, and the guest's busy share across it is recorded.

## What the VM can't show

- A production hypervisor: this is a desktop KVM guest with passt networking, unpinned vCPUs and no tuning.
- Dedicated or isolated host cores. Isolation is Part 5; here the guest's 4 vCPUs are scheduled by the host like any process.
- SR-IOV or passthrough NICs. The bridge lane crosses a software veth and a software bridge inside the guest.
- A quiet host. The host is untuned and shared, so the jitter floor includes whatever the host does.

## When not to use a container

Containers are fine for the control plane, telemetry and analytics, and for anything that wants a reproducible filesystem. On
the scan-to-divert path they add three things you can measure here: the veth and bridge in front of a bridged consumer, a
cgroup limit that can stop every thread in it at once (a quota throttles the whole group, not the busy thread), and runtimes
that size their pools from a machine they can't see. If the decide path must live in one, give it `--network host` or a
cpuset rather than a quota, size pools from the cgroup (or pass the number explicitly), and gate the rollout on a
latency-and-jitter SLO and not just a health check. A quota on a latency-sensitive service fails the first time a busy
neighbour shares its cgroup.

## Hand-rolled constructs, and why

- `busy-pool` spins because it's the load. Busy-spinning is the opposite of what a decide path should do; here it is the load that
  makes the limit visible. Its start gate is a spinning atomic counter instead of `std::latch`, because a futex wake can
  arrive a millisecond late on an idle core.
- `place-probe` calls `io_uring_setup` through the raw system call, not liburing: the probe must report what the kernel or a
  seccomp filter answers, with nothing linked that could change it.
- `cgroup_probe` parses the one-line and key-value cgroup v2 files (`cpu.max`, `cpu.stat`, `cpuset.cpus.effective`) by hand.
  There's no maintained C++ cgroup v2 library, and each file is a line or a list of `key value` pairs that
  `std::from_chars` reads in a few lines; every parse returns `std::expected` and the tests cover the odd forms.
- `lane-cpp.sh` is POSIX sh and coreutils only. The images have no `jq`, no Python and no `taskset`.
- `CpuProbe` reads the virtual-thread scheduler's parallelism from `jdk.management.VirtualThreadSchedulerMXBean` (exact), and
  samples `getMountedVirtualThreadCount()` while a spinning load saturates the carriers, as a cross-check: its maximum is the
  parallelism. The pool size after the spin is recorded and observed only.
- The vm lane runs the uv-managed CPython that `examples/.python-version` names, like the other lanes. `vm/guest-run.sh
  prepare` installs it in the guest with `uv python install`.

## Licences

| Component | Version | Licence | Use |
|---|---|---|---|
| Boost (Asio) | 1.92.0 | BSL-1.0 | Ch12's Asio lane, built with the C++ image |
| liburing | 2.15 | MIT / LGPL-2.1 dual | Ch12's `io-receive`, statically linked |
| Quarkus | per `examples/12-io-engines/quarkus/pom.xml` | Apache-2.0 | the Java container's service |
| Temurin (Eclipse Adoptium) | 25.0.5+8 | GPLv2 + Classpath Exception | the JDK in the host, guest and Java image |
| UBI 10 base images | per `containers/IMAGES.lock` | UBI EULA, free to redistribute | all three images |
| Docker Engine | 29.9.2, in snapshot `lab-ready-r04` (the lab's setup record) | Apache-2.0 | containers, in the guest only |
| protobuf | per `versions.env` | BSD-3-Clause | the wire contract, linked into the simulator and `io-receive` |
| abseil | 20250512.1 | Apache-2.0 | protobuf's dependency |
| CPython | 3.14.9 | PSF-2.0 | the Python lanes (uv-managed, python-build-standalone) |
| uv | 0.13.5 | MIT / Apache-2.0 | installs and runs that CPython |
| libstdc++, libgcc | the compiler's | GPLv3 with the GCC Runtime Library Exception | linked statically into the four binaries; the exception permits that under any licence |
| HdrHistogram, nlohmann/json, GoogleTest, Jackson, pytest | per `versions.env` | BSD / MIT / Apache-2.0 / EPL-2.0 | reports and tests |

## Observation surfaces

Terminal output only: `verify.sh` prints each criterion with its measured value, bound and margin, and the labelled lane
table. Grafana: no panel by design (Part 7 covers observability); the numbers here are one-shot measurements, not telemetry.

## Verification status

Behavioural. `verify.sh` asserts the five criteria above, and all of them held on `r04-run1..3` (commit 4434ed1, results
committed in cd4a269; load average at most 2 at each start). Host lane: bare metal, untuned (governor `powersave`, tuned
`balanced`, kernel 7.2), the lab VM booted and idle. VM lane: guest profile `stock-unpinned`, snapshot `lab-ready-r04`,
4 vCPU unpinned, kernel 7.2, tuned `virtual-guest`, `virt: kvm`, each run restored from the snapshot. Container lanes:
`place-cpp:r04@sha256:007fe524247d…`, `place-java:r04@sha256:da6684ca44f2…` and `place-py:r04@sha256:276c666a6165…` (full
digests in `containers/IMAGES.lock`) on UBI 10.2 `ubi-minimal`, Docker's default seccomp profile, Docker Engine 29.9.2.
Every lane ran the same four C++ binaries. Latency figures are each run's median over its 3 alternations, truncated to
microseconds as `verify.log` prints them, and compare lanes only within one interleaved run.

| Quantity | Range |
|---|---|
| `nr_throttled` under `--cpus=2` / `--cpuset-cpus=2,3` (exact) | 206 to 207 / 0 |
| `throttled_usec`, quota (summed over 4 vCPUs) / cpuset (exact) | 37.7 to 40.6 s / 0 |
| `hardware_concurrency()` in the VM, quota, cpuset (exact) | 4, 4, 4 |
| `os.process_cpu_count()` in the VM, quota, cpuset (exact) | 4, 4, 2 |
| `availableProcessors()` in the VM, quota, cpuset (exact) | 4, 2, 2 |
| `io_uring_setup` in a container, 36 probes (exact) | `EPERM` in all; 0 in the 9 VM probes |
| Consumer p99.9, quota / cpuset (bound 2x) | ratio 13.16x to 18.91x (53,411 to 55,574 us / 2,912 to 4,067 us); smallest margin 6.58x |
| Every lane and alternation | 200,000 parcels counted, none dropped, environment record and image digest match, one set of binary checksums |
| Reports | 48 pass `lowlat-report check` in each run |
| Observed: emit lateness p99, host / VM / container-host-net / container-bridge | 62 to 64 / 80 to 83 / 81 to 89 / 85 to 103 us |
| Observed: consumer p99, host / VM / container-host-net / container-bridge | 97 to 98 / 99 to 101 / 101 to 104 / 105 to 140 us |
| Observed: consumer p99.9, host / VM / container-host-net / container-bridge | 195 to 264 / 145 to 161 / 142 to 153 / 167 to 211 us |
| Observed: VM steal ticks (10 ms each) over 9 alternations | 0 to 1 of 8,848 to 9,886 |

Outliers and failures: none. The host and VM figures come from different kernels, clocks and CPUs and are printed side by
side, never compared as a claim; the bridge against host-network gap is under 2x in every run (1.39x, 1.04x and 1.03x).
The Quarkus p99 under the two limits changed order between runs and is observed only.
