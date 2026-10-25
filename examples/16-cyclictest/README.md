# 16-cyclictest

Chapter 16: measuring jitter with `cyclictest`. Chapter 14 changed the kernel and Chapter 15 changed where the work runs. Both
ended in the same instrument, and the number it prints depends on how it was run. Before the line's commissioning sign-off,
someone runs `cyclictest` on the controller and reads one number. Whether that number means anything is decided by the policy
the thread ran under, the clock it slept on, whether memory was locked, how many samples were taken, and whether the histogram
was wide enough to hold the worst of them.

This example runs `cyclictest` twice on the same guest, once with its defaults (`naive`) and once the way the method says
(`method`), and checks that the second run is what it claims to be before it looks at a latency. It adds a C++ probe that does
the same measurement in a hundred lines, `rtla timerlat` to split a spike into interrupt latency and thread latency, and an
idle-driver pair that shows what the guest's idle path costs a wake-up. Every number is lane `vm`: the guest is a KVM guest, the
host still schedules its vCPUs, and nothing here is a bare-metal figure. The C++ subset is deliberate. `cyclictest` is a C tool,
the probe is C++, and the measurement method doesn't depend on the language of the code under test. There's no Python lane: the
GIL is a user-space pause like a safepoint, so it doesn't change what the instrument does to a wake-up.

## Technique

- **(a) What `cyclictest` measures.** A thread sleeps with `clock_nanosleep(TIMER_ABSTIME)` to an absolute wake time, wakes,
  reads the clock and records actual minus intended wake time, in microseconds. The next wake time is the previous intended time
  plus the interval, so the schedule doesn't drift. If the thread wakes after the next intended time has already passed, the
  missed periods are skipped: a stall of 40 ms at a 1 ms interval records one late sample, not forty. The sample count therefore
  falls short of duration over interval when the system stalls, which is why the count is a criterion and not a footnote.
- **(b) The defaults, at rt-tests v2.11.** SCHED_OTHER at priority 0; no `mlockall`; `-p` implies SCHED_FIFO unless the policy is
  already FIFO or RR; the clock is `CLOCK_REALTIME` although the help text says monotonic (`used_clock` is never initialised
  without `-c`, and v2.10 defaulted to monotonic); and it writes 0 to `/dev/cpu_dma_latency`, a power-management request that
  holds the CPUs out of deep idle states, unless `--default-system` is given. `naive` keeps every one of those. `method` names
  the policy, the priority, the CPU, the clock and the lock, and leaves the PM-QoS request alone because it is the one default
  worth keeping for a latency measurement.
- **(c) The histogram.** `-h 20000` tracks latencies up to 20 ms in 1 us buckets. A sample beyond the range is counted, not
  binned, so the percentiles would silently exclude the worst samples. The JSON doesn't carry the overflow count at all; the
  histfile's `# Histogram Overflows:` line does. `lowlat-report from-cyclictest` fails the conversion on an overflow.
- **(d) Why `Avg` is never quoted.** `cyclictest` prints `Avg` and the JSON has `avg`. The converter reads neither, nothing here
  stores one, and no sentence quotes one. A mean of a latency distribution is dominated by the mass near the floor and moves
  little when the tail doubles, so it can't answer the question a deadline asks. The percentiles come from the histogram.
- **(e) Sample count.** p99.9 is the value 1 in 1,000 samples exceeds. 300 s at 1 ms is 300,000 samples, so 300 of them sit above
  p99.9. `naive` runs 10 s, so 10 sit above it; its p99.9 is one slow sample's word, and the README says so next to the number.
- **(f) The cross-check.** `cyclic-probe` (`examples/common/cyclic-probe`) wakes on an absolute `CLOCK_MONOTONIC` time and
  records the same quantity into the measurement kit's HdrHistogram. In the `method` lane it runs beside `cyclictest` on CPU 2
  with the same period, duration, policy and priority. Two instruments that agree to within 2x have the same definition of
  latency. If they didn't, one would be measuring something else.
- **(g) Attribution.** `rtla timerlat` runs a per-CPU timer and records two latencies per wake: from the timer's intended expiry to
  the timer interrupt handler (IRQ latency), and on to the thread running (thread latency). Interrupt latency is the hardware, the
  hypervisor and code that masks interrupts. The rest is the scheduler, other threads and interrupts that ran first. `rtla` uses
  user-space threads by default; `-P f:95` sets the policy and `chrt -p` reads it back. The RT guest kernel has no BTF, so
  `rtla` can't load its BPF collector (`Error loading vmlinux BTF: -ESRCH`) and falls back to tracefs. Auto-analysis prints the
  attribution for the sample that crossed `-T`; the threshold is the variable `TIMERLAT_THRESHOLD_US`.
- **(h) The idle pair.** The guest's cpuidle driver is `none` (governor `menu`) in every snapshot. `cpuidle_haltpoll` is built in
  but loads only when the host sets the realtime hint or `cpuidle_haltpoll.force=1` is on the kernel command line, and the host
  doesn't set the hint. `haltpoll-forced` adds the argument with `grubby` after the snapshot revert, reboots once and checks that
  `current_driver` is `haltpoll`; `idle-default` leaves the guest as it is. Both run `cyclictest` with `--default-system`, so its
  PM-QoS write can't hide the difference.

## Workload

- **Noise:** `stress-ng --cpu 2` on guest CPUs 0 and 1 (the housekeeping CPUs) for the whole lane plus 15 s, under
  `timeout -s KILL` and `taskset`. `guest_noise` refuses a CPU list that overlaps `ISOLATED_CPUS=2-3`.
- **Measurement:** CPU 3 (`cyclictest`, `rtla`) and CPU 2 (the probe). The snapshot is `lab-ready-r05-iso`: the PREEMPT_RT kernel,
  tuned `cpu-partitioning` with `isolated_cores=2-3` (`nohz_full=2-3`, `rcu_nocbs=2-3`), `isolcpus=domain,managed_irq,2-3`,
  `irqaffinity=0-1`, vCPUs 2 and 3 each pinned to one host CPU. The pins are libvirt configuration in the snapshot. They are a pin,
  not host isolation: the host can still preempt the vCPU threads.
- **Durations:** `naive` 10 s, `method` 300 s, `timerlat` 120 s, the idle pair 120 s each. `SMOKE=1` shortens them (5, 20, 10,
  10 s) and runs one alternation.
- **Interleave:** `naive method timerlat haltpoll-forced idle-default`, three times. Every lane starts with `require_quiet_host
  --lab-run` (the host's load1 must be at most 2), a snapshot revert, a check that the pushed binaries hash as built, and a wait
  until the guest is idle.

## Lanes and what runs where

| Lane | Command | Policy and clock |
|---|---|---|
| `naive` | `cyclictest -D 10 -h 20000 -q` | SCHED_OTHER 0, unpinned, no `-m`, `CLOCK_REALTIME` (the v2.11 default), PM-QoS written |
| `method` | `cyclictest -m -p95 --policy=fifo -a3 -i 1000 -D 300 -h 20000 --clock=monotonic -q` | SCHED_FIFO 95 on CPU 3, `CLOCK_MONOTONIC`, memory locked, PM-QoS written |
| `method` (probe) | `cyclic-probe --cpu 2 --interval-us 1000 --duration-ms 300000 --priority 95 --mlockall` | SCHED_FIFO 95 on CPU 2, `CLOCK_MONOTONIC`, same window |
| `timerlat` | `rtla timerlat hist -c 3 -d 120s -P f:95 -p 1000 -T $TIMERLAT_THRESHOLD_US -b 1 -E 9999` | FIFO 95 tracer threads on CPU 3, tracefs collection |
| `haltpoll-forced` | the `method` options plus `--default-system`, `-D 120` | idle driver `haltpoll` (forced, one reboot) |
| `idle-default` | the same | idle driver `none` |

Every program runs as `sudo timeout -s KILL N ...` inside the guest. `-q` only quiets the console; `--json` and `--histfile` are
how the result leaves `cyclictest`. The host driver converts each pair with `lowlat-report from-cyclictest` (percentiles from
the histogram buckets, the clock, policy and priority from the recorded command line, `nodename` and `avg` dropped, `sysinfo.realtime` ignored
because it reads 0 even on a PREEMPT_RT kernel).

## Files

- `vm/run.sh`: the host driver. Builds `cyclic-probe` once, writes `SHA256SUMS`, then for every lane runs `require_quiet_host
  --lab-run`, `lane_revert`, `vcpupin_record`, `guest_noise`, `interrupts_delta` around `guest-run.sh lane`, `guest_fetch` and the
  converter; shuts the guest down at the end unless `KEEP_VM=1`.
- `vm/guest-run.sh`: runs in the guest. It sources nothing from the repository (it is pushed beside the probe by `lane_revert`),
  so the guest needs no checkout. It records `chrt -p` and `taskset -pc` of every task of the measured process while it runs, the
  idle driver and per-state usage before and after, steal ticks, and gzips the histfile.
- `vm/timerlat-summary.awk`: reduces `rtla timerlat hist` output to the IRQ and thread columns (count, over range, min, max, p50,
  p99, p99.9). No trace file is kept.
- `check/recompute_hist.py`: the independent recomputation of a report's percentiles from the gzipped histfile (criterion 4).
- `lanes.sh`: the lanes, parameters and guest layout that `verify.sh` and `vm/run.sh` share.
- `cpp/`: `method.hpp` fixes the probe's parameters to the `method` lane's. The probe itself is `examples/common/cyclic-probe`.
- `tests/`: host-only tests: the recomputation against the converter, the rtla parser, and `verify.sh` on a synthetic results tree.
- `verify.sh`: evaluates a results directory or runs everything with `VM=1`.

## Run

```bash
./verify.sh                                  # evaluates results/latest if it exists; otherwise says what to do (exit 2)
flock -o "$LOCK" env VM=1 ./verify.sh        # the whole thing: build, unit tests, 5 lanes x 3 from lab-ready-r05-iso, evaluate
RECHECK=results/<run-id> ./verify.sh         # evaluate a results directory, run nothing
DRY_RUN=1 SMOKE=1 RESULTS_DIR=/tmp/x vm/run.sh   # print what vm/run.sh and vm/guest-run.sh would run, touch nothing
SMOKE=1 RESULTS_DIR=/tmp/x VM=1 ./verify.sh  # short lanes, one alternation, nothing enforced
```

A plain `./verify.sh` never measures: the host can't run SCHED_FIFO work (`RLIMIT_RTPRIO` is 0), and a real run needs the lab
guest. Expect a full run to take roughly an hour, mostly the five snapshot reverts per alternation and the 300 s `method` lane. Nothing on the
host changes: no sudo, no sysctl, no tuning. The guest is reached over vsock ssh behind passt.

## Expected effect and criteria

Counters first, then latency. "Exact" marks a count the kernel, the tool or the file reports; the rest are medians of three
alternations. The bounds are provisional: the calibration step (S11) decides which stay asserted.

1. **(exact)** `method`: the sample count is within 1% of duration over interval (300,000) and at least 100,000, and the
   histogram overflow count is 0.
2. **(exact)** `naive` ran SCHED_OTHER with priority 0 and `CLOCK_REALTIME`; `method` ran SCHED_FIFO 95 on CPU 3 with
   `CLOCK_MONOTONIC`, and the probe ran SCHED_FIFO 95 on CPU 2. Read back with `chrt -p` and `taskset -pc` while the program ran.
3. The probe's p99 and `cyclictest`'s `method` p99 are within 2x of each other (larger over smaller, floored at 1 us, the
   resolution of `cyclictest`), median of 3. Provisional: `CRIT3_ASSERTED=0` observes it.
4. **(exact)** The converter's p50, p90, p99, p99.9 and max equal an independent recomputation from the gzipped histfile, in every
   `cyclictest` lane and alternation. Below 262 us the figures are equal to the nanosecond; above, the report holds the top of
   an HdrHistogram bucket, and the recomputation applies that rule.
5. **(exact)** The run's own facts: one set of binary checksums in every lane (the one in `SHA256SUMS`), snapshot
   `lab-ready-r05-iso`, `virt: kvm`, a PREEMPT_RT kernel, `/sys/devices/system/cpu/isolated` = `2-3`, vCPUs 2 and 3 each pinned
   to one host CPU, the idle driver per lane (`haltpoll` or `none`), and every report passes `lowlat-report check`.

`verify.sh` prints every criterion with its measured value and bound, a criteria table, and the observed figures. A miss is
reported after all criteria have been evaluated.

## Reading the numbers

- `naive` against `method` is observed, and the direction is stated whichever way it goes. The two differ in six things at once
  (policy, priority, pinning, memory lock, clock and duration), so the comparison says what the defaults cost together, not which
  default costs what. The expectation is that `naive` is worse in the tail, because an unpinned SCHED_OTHER thread shares the
  scheduler with everything else. The run decides.
- `naive` rests on about 10,000 samples. Its p99.9 and max are one or ten samples; treat them as an illustration of the
  sample-count point and not as a distribution.
- The probe and `cyclictest` run in the same window on different CPUs (2 and 3). They share the host's scheduling of the vCPUs but
  not a CPU, so their percentiles agree in kind, not sample by sample.
- `timerlat` counts its own wakes with its own threads. Its thread latency is not `cyclictest`'s latency; the split says where a
  spike came from, not what `cyclictest` would have seen. A run that crosses the threshold stops early and prints the analysis,
  and `verify.sh` says how many did.
- The idle pair is a single reboot's worth of evidence per alternation, with the host's scheduling underneath it. Steal ticks
  and the interrupt deltas on CPUs 2 and 3 are printed beside every lane.

## Observed, not asserted

`naive` against `method` (p99.9 and max, with the direction); the `timerlat` IRQ and thread percentiles and how many runs crossed
the threshold; `timerlat` thread p99 against `cyclictest` p99; `haltpoll-forced` against `idle-default` (p99.9, driver, per-state
usage on CPU 3); steal ticks on CPU 3; `LOC` interrupts on CPU 3.

## What the VM can't show

- **SMIs.** `hwlatdetect` drives the hwlat tracer, which spins with interrupts off and looks for gaps in the TSC. In a guest a gap
  can be the hypervisor taking the vCPU away, so it isn't an SMI test and its number is an upper bound on what the guest can't
  control. This example doesn't run it.
- **Bare-metal idle states.** The guest's `none` and `haltpoll` drivers are the guest's view. The host decides what the physical
  CPU does when the vCPU thread halts. A C-state exit latency on real hardware isn't in these numbers.
- **Host preemption.** The pins keep a vCPU on one host CPU. They don't stop the host scheduling something else there, and a guest
  `cyclictest` can't see that except as a late wake or as steal ticks.
- **A real NIC and real interrupt sources.** Part of what `timerlat` attributes to IRQ latency on bare metal is device activity; the
  guest has virtio devices on managed queues.

## Hand-rolled constructs, and why

- `check/recompute_hist.py` re-derives the percentiles with a rank rule and a bucket rule written out in its docstring. It shares no
  code with the measurement kit on purpose: a check that calls the converter proves nothing about the converter.
- `vm/timerlat-summary.awk` computes percentiles from `rtla`'s histogram rows. `rtla timerlat top` prints min, avg and max only, and
  `hist` is the mode with a distribution.
- `vm/guest-run.sh` reads policy and affinity with `chrt` and `taskset` and not from a library: the point is what the kernel says
  the thread is running with, as an administrator would ask.
- The probe is hand-written because the chapter's cross-check needs a second implementation of "actual minus intended wake".
  It uses `clock_nanosleep` and `clock_gettime` directly (`std::chrono::steady_clock` can't be told which clock id to sleep on).

## Licences

| Component | Version | Licence | Use |
|---|---|---|---|
| rt-tests (`cyclictest`) | v2.11 (Fedora `realtime-tests` 2.11-1.fc44) | GPL-2.0-only | the measuring tool, in the guest only; never linked |
| `rtla` | 7.2.11-200.fc44 (part of the kernel tree) | GPL-2.0 | `timerlat`, in the guest only; never linked |
| stress-ng | 0.22.01-1.fc44 | GPL-2.0-or-later | the noise generator, in the guest only |
| HdrHistogram_c | 0.12.1 | CC0-1.0 OR BSD-2-Clause | the probe's and the converter's histogram |
| nlohmann/json, GoogleTest | per `versions.env` | MIT / BSD-3-Clause | the probe's report and tests |

## Observation surfaces

Terminal output only: `verify.sh` prints each criterion with its measured value and bound, the criteria table and the observed
figures. Grafana: no panel by design (Part 7 covers observability); these are one-shot measurements, not telemetry.

## Verification status

Unverified until S12. The scripts, the converter, the recomputation, the `rtla` parser and `verify.sh` pass their host-side
checks (shellcheck, `bash -n`, `DRY_RUN=1`, the pytest suite, ctest for the probe and the method parameters). No lane has run in
the guest yet, so no number from this example is quoted anywhere. The `rtla timerlat hist` output layout, the
`cyclictest -q` console behaviour and `pgrep -x` on the measurement process are assumptions the first guest run confirms.
