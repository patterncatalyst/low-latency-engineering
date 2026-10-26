# 15-cpu-partitioning

Chapter 15: CPU partitioning. Ch14 asked what the kernel's preemption model does to a woken thread. This chapter asks what
else is allowed to run on the CPU, take its cache line or interrupt it. The decide thread shares four vCPUs with a label
printer's spooler, a log shipper and a WMS client, and any of them can take the CPU, a timer tick or a disk interrupt at the
wrong moment for the paddle. Partitioning is several mechanisms, each with its own counter: the scheduler (`isolcpus`), the
tick (`nohz_full`), RCU callbacks (`rcu_nocbs`), interrupt affinity (`irqaffinity`, per-IRQ `smp_affinity`) and the
housekeeping defaults tuned's `cpu-partitioning` profile sets. What no mechanism partitions here is the last-level cache,
memory bandwidth or the host under the guest.

Everything runs in the lab guest, lane `vm`. Nothing is compared with a host number, and a host lane doesn't exist: the host
can't run SCHED_FIFO work, and the host must never be tuned.

## Technique

- **(a) Shared against isolated.** `shared` is the RT-kernel snapshot with no isolation, noise on all four CPUs. `isolated` is
  the same kernel with tuned `cpu-partitioning` (`isolated_cores=2-3`, which adds `nohz_full=2-3` and `rcu_nocbs=2-3` and sets
  systemd's `CPUAffinity` and the default IRQ mask) plus `isolcpus=domain,managed_irq,2-3 irqaffinity=0-1`, with noise on CPUs
  0-1. Tuned adds no `isolcpus` on its own, so both are needed.
- **(b) The tick.** One busy task on an isolated, `nohz_full` CPU takes no local timer (LOC) interrupts. The same task on a
  housekeeping CPU takes one per millisecond (`HZ` is 1000). LOC, RES, CAL and TLB deltas per CPU come from
  `/proc/interrupts`.
- **(c) The scheduler.** `isolcpus=domain` takes CPUs 2-3 out of the load-balancing domains, so unpinned threads aren't
  spread across them. That keeps noise off, and it is also why two threads started under `taskset -c 2,3` pile onto one CPU.
- **(d) IRQs.** The guest's virtio-blk request-queue IRQs are managed by the kernel: one queue per CPU, and a write to their
  `smp_affinity_list` is refused. A completion arrives on the CPU that submitted the I/O. So the defect pair moves the
  submitter, not the IRQ: `irq-steered` submits disk I/O from CPUs 0-1 and `irq-on-measure-cpu` submits it from a thread on
  CPU 3. The `smp_affinity` write itself is shown on the one IRQ that isn't managed, a virtio-net queue, beside the refused
  write on a managed virtio-blk queue, with the errno recorded.
- **(e) The cache.** `cache-noise` is the isolated snapshot with `stress-ng --stream` and `--cache` on CPUs 0-1 instead of CPU
  hogs. Isolation doesn't partition the last-level cache or the memory bus, so its p99.9 is observed against the CPU-noise
  lane.
- **(f) The JVM's own threads.** `jvm-taskset-isolated` runs the whole JVM under `taskset -c 2,3`: the VM thread, the GC and
  compiler workers and the signal dispatcher inherit the mask, and with `isolcpus=domain` nothing balances the two busy
  threads. `hot-thread-pinned` runs the JVM on CPUs 0-1 and moves only the hot thread to CPU 3, with OpenHFT Affinity (the
  call example 07 uses).

## Workload

- **cyclictest:** FIFO 95 on CPU 3, 1 ms interval, `--clock=monotonic`, `-m` (mlockall), 300 s, histogram range 20 ms. A
  thread sleeps to an absolute wake time with `clock_nanosleep(TIMER_ABSTIME)` and records how late it woke.
- **The decide thread:** `placement-probe` spins on CPU 2. Alone, for the tick count (10 s). Beside the noise, for its
  involuntary context switches (20 s).
- **The line:** four simulator instances at 2.5 kHz each, 10 kHz together, for 20 s: 200,000 parcels. The simulators run on
  CPUs 0-1. The receive and decide thread is Ch12's `io-receive --variant epoll` with 3 microseconds of modelled decide work
  per parcel, restricted to CPUs 2-3 with `taskset`. UDP 47410 to 47413 (r05 owns 47400 to 47429).
- **Noise:** `stress-ng --cpu` and `hackbench`, one worker or group per CPU of the noise set, always under
  `timeout -s KILL ... taskset -c`. The isolated lanes refuse to put noise on CPUs 2-3 (`guest_noise`).
- **The IRQ pair:** cyclictest on CPU 3 for 60 s beside `stress-ng --hdd` with O_DIRECT 4 KiB writes under `/var/tmp`
  (a disk filesystem; `/tmp` may be tmpfs).
- **Java:** each placement runs 10 s on Temurin 25.0.5 by path (`/opt/temurin-25.0.5/bin/java`, never `/usr/bin/java`).
  Two busy threads in `jvm-taskset-isolated`, one in `hot-thread-pinned`; the program samples the last-run CPU of every
  JVM thread every 100 ms and reads the hot threads' own involuntary switches from `/proc/thread-self/status`.

## Lanes

| Lane | Snapshot | Noise | What it shows |
|---|---|---|---|
| `shared` | `lab-ready-r05-rt` | CPUs 0-3 | the baseline: tick, switches, tail |
| `isolated` | `lab-ready-r05-iso` | CPUs 0-1 | the cure; also the `smp_affinity` demo and both Java placements |
| `irq-steered` | `lab-ready-r05-iso` | disk I/O from CPUs 0-1 | completions stay on 0-1 |
| `irq-on-measure-cpu` | `lab-ready-r05-iso` | disk I/O from CPU 3 | the defect: completions on the measured CPU |
| `cache-noise` | `lab-ready-r05-iso` | `--stream`, `--cache` on CPUs 0-1 | what isolation doesn't partition (observed) |

The lanes alternate `shared isolated irq-steered irq-on-measure-cpu cache-noise`, three times, and each lane starts from a
clean snapshot (`lane_revert`), so no lane inherits another's state. The vCPU pins (vCPUs 2 and 3 on two host CPUs on
distinct cores) are libvirt configuration in the r05 snapshots. They are pins, not host isolation. Each lane's directory
holds the pins as `virsh vcpupin` printed them, because the guest can't see them.

## How to run

```bash
VM=1 ./verify.sh                                  # build, unit tests, then vm/run.sh: revert per lane, run, fetch, evaluate
RECHECK=results/<run-id> ./verify.sh              # re-evaluate a results directory, run nothing
DRY_RUN=1 vm/run.sh                               # print every command, touch no VM
SMOKE=1 RESULTS_DIR=/tmp/ch15-smoke VM=1 ./verify.sh   # one alternation, short lanes, nothing enforced
```

Run it under the host benchmark lock (`flock -o "$LOCK" ./verify.sh`). `vm/run.sh` builds once on the host
(`line-simulator`, `io-receive`, `placement-probe`, the shaded Java jar) and writes `SHA256SUMS`. Before every lane it
requires a quiet host (`require_quiet_host --lab-run`: load1 at most 2, recorded), reverts the guest to the lane's snapshot,
pushes the binaries and checks their sha256 in the guest, then runs the lane's steps from `vm/guest-run.sh`. When the lanes
are done it shuts the guest down unless `KEEP_VM=1`. The committed runs use `RESULTS_DIR=results/r05-vm-run{1,2,3}`.
Nothing on the host changes: no sudo, no sysctl, no tuned. The guest is reached over vsock ssh behind passt; guest `sudo`
appears only inside `vm/guest-run.sh`, for debugfs and `/proc/irq`.

A plain `./verify.sh` has nothing to run, prints how to start a run and exits 2.

## Expected effect and criteria

Counters first, then latency. A calibration run (S11) checked the bounds below before the measured runs: every asserted bound
cleared 2x. The thinnest were the shared CPU's LOC rate (2.12x) and the JVM threads under `taskset` (2.10x).

1. **(exact)** `/sys/devices/system/cpu/isolated` and `nohz_full` are `2-3` in the four isolated-snapshot lanes and empty in
   `shared`.
2. **(exact)** LOC interrupts per second on CPU 2 with one busy task and no other load: `isolated` at most 10, `shared` at
   least 500. The S1 probe saw 0 against about 1012.
3. **(exact)** No `stress-ng` or `hackbench` thread is ever seen on CPUs 2-3 in `isolated` or `cache-noise`. The decide
   thread's involuntary context switches over 20 s beside the noise: `isolated` at most 10, `shared` at least 100 (the
   example 07 precedent).
4. (observed) cyclictest p99.9 on CPU 3, `isolated` against `shared`. In this VM the isolated CPU sits idle between wakes,
   and an idle vCPU halts to the host, so every wake waits for the host to run the vCPU thread again. In `shared` the noise
   on CPU 3 keeps the vCPU running, so its wakes don't take that path. The S8 smoke put the same CPU at p99.9 507 us idle
   against 33 us when a `SCHED_IDLE` spinner kept it from halting. Isolation removes the scheduler's work from the CPU, which
   the counters in 2 and 3 show. It can't keep the host from descheduling an idle vCPU, so the latency is observed, never
   asserted (`P999_ASSERTED=1` asserts it).
5. **(exact)** virtio-blk request-queue interrupts on CPU 3 beside the disk I/O: `irq-steered` is 0, `irq-on-measure-cpu` at
   least 1,000.
6. **(exact)** Java: `hot-thread-pinned` has exactly one JVM thread on CPUs 2-3 and at most 10 involuntary switches;
   `jvm-taskset-isolated` has at least 10 JVM threads on CPUs 2-3.
7. The line in `shared` and `isolated`, every alternation: 200,000 parcels counted, none dropped.
8. Every report passes `lowlat-report check` and says `runtime.environment.kind` `vm` with the lane's snapshot and both vCPU
   pins; every profile says `virt.type` `kvm`; the guest ran the binaries `SHA256SUMS` lists, the same in every lane; each
   cyclictest run took at least 98 percent of its expected samples with no histogram overflow.

The counters are exact when they are a count the kernel reports. `verify.sh` judges them in every alternation and prints
the worst one with its margin. The latency ratio is the median of the alternations.

## Observed, not asserted

`cache-noise` p99.9 against the CPU-noise `isolated` lane; the IRQ defect's p99.9; the `smp_affinity` write (the virtio-net
IRQ is accepted and its effective affinity moves, the managed virtio-blk IRQ is refused with its errno); the number of noise
threads seen on CPUs 2-3 in `shared`; where the two busy JVM threads landed under `taskset`; steal ticks per lane; the
host's load1 at each lane start; the guest's kernel, preempt model, tuned profile, systemd `CPUAffinity`, PID 1's affinity
and `default_smp_affinity`.

## Files a lane writes

Under `RESULTS_DIR/vm/LANE/altN/`: `profile.json` (the guest's), `vcpupin.json`, `facts.json`, `lane.json`, `steal.json`,
`binaries.txt`, `cyclictest/LANE-t0.json` (a `lowlat-report/1`, with `runtime.counters.samples`, `overflows` and the pins),
`interrupts-cyclictest.json` (LOC, RES, CAL, TLB and every IRQ row, per CPU, over the cyclictest run),
and in the main lanes `interrupts-tick.json`, `tick.json`, `tick-probe.json`, `decide-probe.json`, `noise-cpus.json` and
`line/` (`consumer.json`, `lateness.json`). `isolated` adds `irq-affinity.json`, `java-hot-thread-pinned.json` and
`java-jvm-taskset-isolated.json`. `vm/LABEL` says `vm`.

## Observation surfaces

Terminal output only: `verify.sh` prints each criterion with its measured value, bound and margin, and a criteria table at
the end. Grafana: no panel by design (Part 7 covers observability); the numbers here are one-shot measurements, not telemetry.

## What the VM can't show

- Host isolation. vCPUs 2 and 3 are pinned to host CPUs, but the host still schedules other work around them, and SMT
  siblings of the pinned CPUs still run host work. The pins are pins, not isolation.
- Cache and memory-bandwidth partitioning (CAT, MBA). The guest has no `resctrl`, so `cache-noise` can show the interference
  and nothing can remove it.
- Real NIC interrupts. The guest's NIC is a single-queue virtio device; RSS, multi-queue steering and a NIC's own IRQ
  moderation aren't here.
- Everything below the guest: SMIs, the host's frequency scaling, the host scheduler.

## Hand-rolled constructs, and why

- `placement-probe` spins on a volatile sink, and `JvmPlacement`'s hot threads spin with `Thread.onSpinWait()`. A busy loop is
  the load; the decide thread in production would block or poll.
- `noise-sample` in `guest-run.sh` reads `/proc/PID/task/TID/stat` for every `stress-ng` and `hackbench` thread in one pass.
  `lib.sh thread_cpus` samples one PID at a time, and a `hackbench` group is dozens of processes.
- `JvmPlacement` reads `/proc/thread-self/status` and `/proc/self/task/*/stat` directly: neither the context-switch counters
  nor the last-run CPU of a thread is in the JDK's management interfaces.
- The `smp_affinity` demo is a short Python script run under the guest's `sudo`, because Python's `OSError` carries the errno
  that a shell redirect would flatten into a message.
- Thread pinning in Java is OpenHFT Affinity, the library example 07 uses, not a second hand-written JNA mapping.

## Licences

| Component | Version | Licence | Use |
|---|---|---|---|
| rt-tests (`cyclictest`, `hackbench`) | 2.11 | GPL-2.0 | the instrument and one noise source; run in the guest, never linked |
| stress-ng | 0.22.01 | GPL-2.0 | noise and disk I/O; run in the guest, never linked |
| tuned (`cpu-partitioning`) | 2.28.0 | GPL-2.0-or-later | the guest's isolation profile |
| OpenHFT Java-Thread-Affinity | 2026.2 (chronicle-bom 2026.26) | Apache-2.0 | moves the Java hot thread to CPU 3 |
| JNA | 5.19.1 | Apache-2.0 / LGPL-2.1 | Affinity's native bridge, inside the shaded jar |
| Jackson | per `examples/pom.xml` | Apache-2.0 | `JvmPlacement`'s report |
| Temurin (Eclipse Adoptium) | 25.0.5+8 | GPLv2 + Classpath Exception | the JVM in the guest, by path |
| liburing | per `versions.env` | MIT / LGPL-2.1 dual | Ch12's `io-receive`, statically linked |
| HdrHistogram, nlohmann/json, GoogleTest | per `versions.env` | BSD / MIT / BSD-3-Clause | reports and tests |

## Verification status

**Unverified.** The code, the driver and `verify.sh` are written and checked on the host (shell syntax, shellcheck, unit tests,
a dry run, and `verify.sh` against a synthetic results tree that exercises each criterion and its failure). The VM smoke (S8)
and a calibration run (S11) passed every criterion; the three committed runs (S12) are next, and until they land this section
stays unverified.
