# 14-preempt-rt

Chapter 14: PREEMPT_RT, and what real-time Linux does and doesn't promise. Part 4 asked where the thread runs. This chapter asks
what stands between the timer and the thread once it's on a CPU: the kernel's non-preemptible sections, interrupt handlers, lock
holders, the host's scheduler, and in a JVM the runtime's own pauses. The diverter paddle fires inside a window, not before a
deadline (±2 mm at 2.5 m/s is ±0.8 ms of slack, a labelled `model` input in the chapter), so the tail of the wake-up decides
whether a parcel is sorted, and the median doesn't.

One kernel source, three preemption models, one guest. The comparison is `stock-lazy` (Fedora's default) against `stock-full`
(the same kernel, switched at run time) against `rt` (the PREEMPT_RT build of the same source). Every number is lane `vm`: the
host can't run SCHED_FIFO work (`RLIMIT_RTPRIO` is 0), so there's no host lane and no host-against-VM comparison in this part.

## Technique

- **(a) cyclictest under load.** A SCHED_FIFO 95 thread sleeps to an absolute `CLOCK_MONOTONIC` time with
  `clock_nanosleep(TIMER_ABSTIME)` and records how late it woke. Options that matter: `-m` (`mlockall`), `-p 95` (FIFO 95),
  `-a 3` (CPU 3), `-i 1000` (1 ms), `-D` (duration), `-h` (histogram range) and `--clock=monotonic`. rt-tests v2.11 sleeps on
  `CLOCK_REALTIME` when no clock is named, although its help says monotonic, so every call here passes the clock. It runs under
  `hackbench` and `stress-ng --cpu` on all four vCPUs.
- **(b) The C++ probe.** `cyclic-probe` (`examples/common/cyclic-probe`) does the same thing in about a hundred lines on CPU 2, with
  the same period and duration, and writes a `lowlat-report/1` document. It cross-checks cyclictest and is the only latency
  instrument the Java and C++ lanes share.
- **(c) The line.** The simulator and the Ch12 `epoll` consumer at 10 kHz for 20 s: 200,000 parcels, the consumer at SCHED_FIFO
  on CPU 2.
- **(d) Priority inversion.** A low-priority thread (FIFO 10) holds a lock for 1 ms, a medium one (FIFO 50) spins in 20 ms bursts,
  and a high one (FIFO 90) wants the lock. `plain-mutex` is `std::mutex`, which has no priority inheritance, so the medium
  thread starves the holder and the high thread waits behind work it doesn't share a lock with. `pi-mutex` is a small RAII
  wrapper over `pthread_mutexattr_setprotocol(PTHREAD_PRIO_INHERIT)`: the holder runs at the waiter's priority.
- **(e) Java.** A periodic wake-up (`LockSupport.parkNanos` to absolute `System.nanoTime()` deadlines) on a thread that JNA moves
  to SCHED_FIFO 95 on CPU 2, beside a thread that allocates, with `-Xlog:safepoint` to a file. A real-time kernel bounds what the
  kernel adds to a wake-up. It doesn't stop the JVM from pausing every Java thread at a safepoint. Java monitors have no
  priority inheritance either.
- **(f) Mechanism counters.** The `irq/` kernel threads (PREEMPT_RT forces every device IRQ handler into a thread), `ktimers`,
  `ksoftirqd`, `rcuc` and their scheduling policies, the `/proc/interrupts` deltas of the measured window, steal ticks, the
  preempt mode, `uname -v` and the command line.

## Workload

- **Window:** 300 s at a 1 ms interval, three alternations. cyclictest (CPU 3) and `cyclic-probe` (CPU 2) run in the same window,
  while `hackbench -g 4` and `stress-ng --cpu 4` run at SCHED_OTHER on all four vCPUs, each under `timeout -s KILL`. The load is
  the shared lane's: nothing is isolated in this chapter (Ch15 isolates).
- **Line:** four simulator instances at 2.5 kHz each on CPUs 0 and 1, the consumer pinned to CPU 2 at FIFO 90, loopback, 3
  microseconds of modelled decide work per parcel. No external load.
- **Priority inversion:** 200 rounds on CPU 3, five 20 ms bursts per round, `--cpu 3` (never 0, where sshd runs). One high-priority
  wait is recorded per round.
- **Java:** 60 s at 1 ms on Temurin 25.0.5 called by path (`/opt/temurin-25.0.5/bin/java`; the guest's `/usr/bin/java` is
  Fedora's OpenJDK and isn't used). The allocator runs on CPU 1.
- **Interleave:** `stock-lazy stock-full rt`, three times. Every lane starts from a freshly reverted snapshot.

## Lanes and what runs where

| Lane | Snapshot | Kernel and mode | Notes |
|---|---|---|---|
| `stock-lazy` | `lab-ready-r05-stock` | 7.2.11-200.fc44, `PREEMPT_DYNAMIC`, boot mode lazy | Fedora's default; the debugfs knob reads `full (lazy)` |
| `stock-full` | `lab-ready-r05-stock` | the same kernel, `echo full > /sys/kernel/debug/sched/preempt` | no reboot; read back before the lane starts: `(full) lazy` |
| `rt` | `lab-ready-r05-rt` | 7.2.11-200.lowlatrt.fc44, `PREEMPT_RT` | the knob reads `(full) lazy`; threaded IRQs, rtmutex, `ktimers` |

All three lanes use the same guest profile, `pinned-shared`: four vCPUs, vCPUs 2 and 3 pinned to single host CPUs in libvirt
(the guest can't see that, so the host driver records `virsh vcpupin` into every report), no isolation.

## Files

- `cpp/`: `pi-demo` (the priority-inversion demo) and `pi_mutex.hpp` (the RAII wrapper over `PTHREAD_PRIO_INHERIT`). The periodic
  waker is `examples/common/cyclic-probe`, shared with Ch15 and Ch16.
- `java/`: `PeriodicWake` (absolute-deadline `parkNanos` loop), `Sched` and `Libc` (JNA: `sched_setscheduler`, `sched_setaffinity`,
  `gettid`), and `Main` (the lane: hot thread, allocating thread, report).
- `lanes.sh`: the lanes, snapshots, durations, ports and the counts each kernel must show.
- `vm/run.sh`: the host driver. `vm/guest-run.sh`: the steps that run in the guest.
- `verify.sh`: build, unit tests, the run, and the criteria table.

## Run

```bash
./verify.sh                                  # RECHECK: re-evaluate the committed results (results/*vm-run*); runs nothing
RECHECK=results/<run-id> ./verify.sh         # re-evaluate one results directory
flock -o "$LOCK" env VM=1 ./verify.sh        # a real run: three lanes x 3, each from a reverted snapshot; the guest is shut down at the end
DRY_RUN=1 vm/run.sh                          # print the plan and the guest commands; touches no VM and no libvirt
VM=1 SMOKE=1 RESULTS_DIR=/tmp/x ./verify.sh  # one alternation, short durations, nothing enforced (a check of the scripts)
```

A real run needs the lab guest and its three snapshots, and refuses to start without `VM=1`. `vm/run.sh` builds the binaries once on
the host, writes `SHA256SUMS`, and for every lane and alternation:

1. `require_quiet_host --lab-run`: the host may run the guest, but its load1 must be at most 2;
2. `lane_revert <snapshot>`: reverts the guest, pushes the binaries and checks each sha256 in the guest;
3. `guest-run.sh begin`: the guest profile, the `stock-full` write and its read-back, the binary checksums;
4. `guest_noise` (hackbench and `stress-ng --cpu` on 0 to 3), `cyclictest_run` from the host, `cyclic-probe` in the guest, and the
   `/proc/interrupts` deltas of the same window;
5. `guest-run.sh line`, `pi`, `java` and `end`: the line, the inversion demo, the Java lane, steal ticks and the mechanism counters;
6. `guest_fetch` into `results/<run>/vm/<lane>/altN/`.

cyclictest is the one tool the host starts: `lib.sh cyclictest_run` converts its output with `lowlat-report from-cyclictest`, which
lives on the host. Everything else that needs only the guest is in `vm/guest-run.sh`, and every load and FIFO program there runs
under `timeout -s KILL`. Nothing on the host changes: no sudo, no sysctl, no tuning. The guest is reached over vsock ssh behind
passt. UDP ports 47400 to 47403 are this example's (r05 owns 47400 to 47429).

## Expected effect and criteria

Counters first, then latency. Everything marked exact is a count the kernel or the runtime reports. The numbers in 2 are provisional.

1. **(exact)** Each lane reports the kernel and mode its name says: stock lanes run 7.2.11-200.fc44 with `PREEMPT_DYNAMIC` and no
   `PREEMPT_RT`; `rt` runs the lowlatrt build with `CONFIG_PREEMPT_RT=y` and `PREEMPT_RT` in `uname -v`; the debugfs knob reads
   `full (lazy)` in `stock-lazy` and `(full) lazy` in `stock-full` and `rt`.
2. **(exact)** `irq/` kernel threads: stock 15 (14 `aerdrv` PCIe port services and one `acpi`, all requested by the drivers
   themselves, none for a virtio IRQ), `rt` 80 (a thread for every device IRQ). `ktimers`: stock 0, `rt` 4 at SCHED_FIFO 1.
   The counts are the S1 probe values; the S11 calibration confirms them or corrects them.
3. Priority inversion: the `pi-mutex` high-priority wait p99 is at most a quarter of `plain-mutex`'s, in every lane (median of 3).
   The expected ratio is about 10x or better by construction.
4. **Observed:** cyclictest p99.9 on `rt` against `stock-lazy` under load (median of 3). A guest RT kernel can't remove the host's
   preemption of the vCPU thread. The bound the plan proposed (`rt` at most half of `stock-lazy`) was to be asserted only if it
   cleared twice over in every calibration run; it didn't (`rt` over `stock-lazy` was 0.83x, 1.20x and 1.28x), so it stays
   observed. `CRIT4_ASSERTED=1` asserts it anyway.
5. Every lane and alternation: 200,000 parcels, `dropped = 0`, `lowlat-report check` on every report, the probe's samples plus
   missed periods equal to duration over period, `runtime.environment.kind` = `vm` with a `guest_profile` that names the lane's
   snapshot and records the vCPU pins, an embedded profile that says `virt.type` `kvm`, and one set of binary checksums across all
   lanes.
6. **(exact)** The Java hot thread is SCHED_FIFO 95: `chrt -p <tid>` taken while the lane ran.

## Reading the numbers

- Compare lanes only inside one run. The guest is scheduled by an untuned, shared host; its steal ticks are printed beside each lane
  and `host_load1` is recorded per lane.
- cyclictest truncates a latency to whole microseconds and doesn't write an average; the converter reads the percentiles from the
  histogram buckets. The histogram covers 20 ms, and a sample beyond it fails the lane, because the tail percentiles would
  then be upper bounds rather than measurements.
- cyclictest and the probe run on different CPUs in the same window, so their percentiles agree in shape, not sample for sample.
- A late wake that skips a period records one late sample, not one per missed wake (both tools do this), so the sample count can
  fall short of duration over interval. The probe reports `missed_periods` and the criterion checks that the two add up.

## Observed, not asserted

`stock-full` against `stock-lazy`; the probe against cyclictest; the line's percentiles per lane; steal ticks; the `/proc/interrupts`
deltas for CPUs 2 and 3 (`LOC`, `RES`, and the rest); the Java wake tail against the safepoint count and total; the `ksoftirqd` and
`rcuc` threads and their policies. An idle baseline per kernel is not part of this driver yet.

## What the VM can't show

- SMIs (`hwlatdetect` has nothing to read from inside a guest), and the bare-metal RT bounds the kernel community quotes.
- The host's scheduling of the vCPU thread. Pinning keeps the vCPU on one host CPU, and it still shares that CPU with whatever the
  host runs. Steal ticks show some of it.
- Real device interrupts. The guest's NIC and disk are virtio devices, so `irq/` counts here follow the virtual hardware.

## Hand-rolled constructs, and why

- `pi_mutex.hpp` wraps `pthread_mutexattr_setprotocol(PTHREAD_PRIO_INHERIT)` because `std::mutex` has no way to ask for priority
  inheritance. It is the only lock in the example that isn't `std::mutex`. The wrapper is RAII and satisfies `Lockable`, so it
  works with `std::lock_guard`.
- `pi-demo` busy-spins on purpose, in two places. The holder burns 1 ms of its own CPU time (`CLOCK_THREAD_CPUTIME_ID`), so a
  preempted holder still needs its full 1 ms. The medium thread's 20 ms bursts are the load that preempts it. Both run under
  `timeout -s KILL` in the guest, because a FIFO spinner on the only CPU it may use can starve the shell.
- The Java lane calls `sched_setscheduler`, `sched_setaffinity` and `gettid` through JNA, because the JDK has no API for a thread's
  scheduling policy or a single thread's affinity. The calls happen once, at setup. The wake loop is plain `LockSupport.parkNanos`.
- `chrt` runs the line's consumer at FIFO because `io-receive` has no policy option and the epoll variant does its work on one thread.
- The Java reports get `safepoints` and `safepoint_total_ns` from the unified log after the run, by parsing the `Total:` field of each
  `Safepoint` line. The JVM exposes no counter for the safepoint time of one run that the report could read.

## Licences

| Component | Version | Licence | Use |
|---|---|---|---|
| rt-tests (cyclictest, hackbench) | Fedora 44 `realtime-tests`, v2.11 | GPL-2.0-only | tools only: separate processes in the guest, never linked into a hot path |
| stress-ng | Fedora 44, 0.22.01 | GPL-2.0-or-later | tools only: the load, a separate process in the guest |
| JNA | 5.19.1 | Apache-2.0 OR LGPL-2.1-or-later | the Java lane's setup calls (policy, affinity, tid); not called in the wake loop |
| Temurin (Eclipse Adoptium) | 25.0.5+8 | GPLv2 + Classpath Exception | the JDK for the Java lane, by path |
| Linux kernel (stock and PREEMPT_RT builds of 7.2.11) | 7.2.11-200.fc44 | GPL-2.0 | the guest kernels |
| protobuf, abseil | per `versions.env` | BSD-3-Clause, Apache-2.0 | the wire contract linked into the simulator and `io-receive` |
| HdrHistogram, nlohmann/json, GoogleTest, Jackson, JUnit | per `versions.env` | BSD / MIT / Apache-2.0 / EPL-2.0 | reports and tests |

## Observation surfaces

Terminal output only: `verify.sh` prints each check with its measured value and bound, then a criteria table and the labelled lane
lines. Grafana: no panel by design (Part 7 covers observability); these are one-shot measurements, not telemetry.

## Verification status

Unverified. The code is written and the host-side checks pass (shell lint, the C++ and Java unit tests, a dry run of the driver
and a recheck of a synthetic results tree), but the example hasn't been run in the lab guest. The S7 smoke (one alternation, short
durations) carries the probe the earlier steps couldn't: that JNA sets the Java hot thread to SCHED_FIFO in the guest. The
calibration runs (S11) confirm or correct the exact `irq/` and `ktimers` counts and decide whether criterion 4 is asserted, and the
three committed runs (S12) set the status. Until then no figure from this example is quotable.
