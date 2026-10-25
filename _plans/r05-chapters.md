---
title: "r05 chapters (S14–S16)"
layout: plan
render_with_liquid: false
---

# r05 chapters: S14–S16

One chapter per example, written from the example's code and its committed S12 (or S20) results. Shape, numbers, voice, Liquid and listing rules follow [r04-chapters.md](r04-chapters.md) unless this brief changes them. Each executor edits only its own chapter file and its claims table below; `_data/diagrams.yml` is S13's, and READMEs, the outline and `_example_pages/` are S17's. Plan: [r05-plan.md](r05-plan.md); fact sources: [dependency-pins.md](dependency-pins.md), sections "Runtime facts for Ch14-16 prose" and "r05 guest probes (S1, 2026-10-25)".

## Files

| Step | File | `order` | `part` | Title | Slug (D19) | Example |
|---|---|---|---|---|---|---|
| S14 | `_docs/14-preempt-rt.md` | 14 | `The OS, Isolation & the Network Edge` | PREEMPT_RT: what real-time Linux does and doesn't promise | `14-preempt-rt` | `examples/14-preempt-rt/` |
| S15 | `_docs/15-cpu-partitioning.md` | 15 | `The OS, Isolation & the Network Edge` | CPU partitioning and the noisy-neighbour problem | `15-cpu-partitioning` | `examples/15-cpu-partitioning/` |
| S16 | `_docs/16-cyclictest.md` | 16 | `The OS, Isolation & the Network Edge` | Measuring jitter with `cyclictest` | `16-cyclictest` | `examples/16-cyclictest/` |

The `part` string equals `part_name` in `_parts/05-rt-linux.md` (checked at S2); `validate.py` check `parts` enforces it. Titles are the outline's (`_docs/00-outline.md`, Ch14-16). Permalinks follow the slug: `/docs/14-preempt-rt/`, `/docs/15-cpu-partitioning/`, `/docs/16-cyclictest/` (the S22 Pages checks).

`duration`: `55 minutes` each.

`description` (one sentence, quoted, because each holds `: ` once numbers go in). The drafts below carry no numbers; the executor rewrites each with the chapter's headline measured values from S12, every one lane `vm`, no mean:
- Ch14: "In a 4-vCPU KVM guest on this machine, a PREEMPT_RT kernel threads every device interrupt and gives kernel locks priority inheritance, and a before/after cyclictest run under load shows what that does and doesn't change for a SCHED_FIFO thread when the host still schedules the vCPU."
- Ch15: "In a 4-vCPU KVM guest, isolating CPUs 2-3 with isolcpus, nohz_full, rcu_nocbs and tuned cpu-partitioning stops the tick, the scheduler's balancing and steered interrupts reaching the measured thread, while the cache, memory bandwidth and the host stay shared."
- Ch16: "How cyclictest measures wake latency, why its defaults (SCHED_OTHER, no mlockall, CLOCK_REALTIME at v2.11) change the number, how a disciplined run with a histogram and enough samples gets a p99.9 you can trust, and how rtla timerlat splits a spike into IRQ and thread latency."

Commits: `docs(§14): Ch14 PREEMPT_RT (S14)`, `docs(§15): Ch15 CPU partitioning (S15)`, `docs(§16): Ch16 Measuring jitter with cyclictest (S16)`.

## What changes from r04

- **Languages and code tabs:**
  - Ch14: `langs="C++|Java"`. Subset sentence: "C++ carries the measured lanes; Java gets one observed lane, because a real-time kernel bounds the kernel's delays, not the pauses a JVM takes in user space."
  - Ch15: `langs="C++|Java"`. Subset sentence: "C++ and Java both run here, since the JVM's own threads are a neighbour inside the process that isolation has to place."
  - Ch16: `langs="C++"`. Subset sentence: "This chapter is C++ only: cyclictest is a C tool and the cross-check probe is C++, and the measurement method doesn't depend on the language under test."
  - Python-absent sentence, the same idea in each chapter, in its own words: "There's no Python lane: the GIL is a user-space pause like a safepoint, so it doesn't change what the kernel, the CPU placement or the instrument does to a wake-up." (Ch14 names the kernel, Ch15 the placement, Ch16 the instrument.)
- **cyclictest in place:** every chapter restates in two sentences what cyclictest measures (a thread sleeps to an absolute wake time with `clock_nanosleep(TIMER_ABSTIME)` and records how late it woke) and names the options that matter (`-m`, `-p95`, `--policy=fifo`, `--clock=monotonic`, `-a`, `-i`, `-h`). Ch16 explains it fully; Ch14 and Ch15 don't point to Ch16 for it.
- **Profile line, per lane** (all lane `vm`; never a host lane):
  - `lowlat-target`, 4 vCPU KVM guest, `host-passthrough`, q35;
  - snapshot (`lab-ready-r05-stock`, `-rt` or `-iso`) and guest profile (`isolate-cpu23` + tuned `cpu-partitioning` for `-iso`);
  - vcpupin: vCPUs 2 and 3 pinned to two host CPUs on distinct physical cores (host CPU indices stay in the lab README, never in prose);
  - guest kernel `7.2.11-200.fc44` (stock) or `7.2.11-200.lowlatrt.fc44` (RT) with its preempt model (`lazy`, `full` or PREEMPT_RT);
  - tuned profile, cpuidle driver, `/sys/devices/system/cpu/isolated`, `nohz_full`;
  - guest steal ticks and host load1 at the lane start.
  - Never the host CPU part, the host kernel build or a host CPU index.
- **Comparisons:** within one run, median of 3 alternations by snapshot revert; never a percentile across runs. A latency bound is asserted only where S11 found at least 2x in all three runs; otherwise it's observed and the chapter says why. Exact counters (`irq/` threads, LOC per second, interrupt deltas, samples, overflows, policy) are labelled "exact".
- **No mean, no `Avg`:** cyclictest prints `Avg` and the JSON has `avg`; the converter drops both and the prose never mentions a value for them. The diverter window (±2 mm at 2.5 m/s = ±0.8 ms) is a `model` input in a labelled block, not a measurement.
- **Runtime facts:** every sentence about the kernel, cyclictest, rtla, tuned, IRQs, cpuidle, KVM or the JVM names its row in `dependency-pins.md` in the claims table. A sentence without a row is cut or reworded to what the source says. S19 checks each one.
- **What the VM can't show:** a short section per chapter (SMIs and bare-metal RT bounds in Ch14; host isolation, SMT siblings, CAT/MBA and real NIC IRQs in Ch15; `hwlatdetect` and bare-metal idle states in Ch16).
- **Standalone:** no "as we saw in Chapter N" and no forward teasers in the body (grep `Chapter [0-9]|Ch[0-9]|Part [0-9]` outside For deeper coverage = 0). Restate SCHED_FIFO, vCPU, isolation and cyclictest in place.
- **Companion projects** in For deeper coverage only: linux-systems-programming Ch24 (timers, deadlines, a cyclictest note), Ch32 (cgroups), Ch35 (virtualization and KVM), Ch40 (low-latency fast path: pinning, busy-poll). Cited, never ported.
- **House voice from the first draft:** the §5 bundle below, pasted verbatim into every S14-S16 prompt. Before hand-back: `scan.sh --tier ban` 0 and `scan.sh --stats` clean.

## Section spine (every chapter)

Learning objectives, Why this matters (the hook), Diagram, Concept, How the code works (before/after pairs with `#A`/`#B` callouts), Measure (a before/after cyclictest pair with the VM profile beside it), Cross-check, What the VM can't show, What you learned, For deeper coverage, verification-status footer. About 2,000-2,500 words, 1,900 floor (`wordcount.sh`), no cap.

## Ch14: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Why this matters | The diverter paddle fires inside a window, not before a deadline: ±2 mm at 2.5 m/s is ±0.8 ms of slack (`model` block). The decide thread is SCHED_FIFO on one vCPU; between its timer firing and the thread running sit the kernel's non-preemptible sections, interrupt handlers, lock holders and the host scheduler. |
| Diagram | Fig 14.1 (where a FIFO thread waits under `lazy`, `full` and PREEMPT_RT) and Fig 14.2 (guest timer, VM exit, host scheduler: the part RT can't reach) |
| Concept | Preemption models on one 7.2.11 source: `lazy` (Fedora's default, one tick to yield for SCHED_NORMAL), `full`, PREEMPT_RT (rtmutex sleeping locks, forced-threaded IRQs at FIFO 50, `ktimers` at FIFO 1, PI in kernel locks). What RT doesn't promise: no numeric bound, host-side preemption of the vCPU thread (steal), user-space pauses (a safepoint), priority inversion in user code without a PI mutex, immediate preemption for SCHED_OTHER. The fair server (50 ms per 1000 ms) and `sched_rt_runtime_us` = 1000000 at v7.2 |
| How the code works | `cyclic-probe`: `mlockall`, `sched_setscheduler(SCHED_FIFO, 95)`, `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)` against a deadline advanced by the period. Before/after: `plain-mutex` (#A, `std::mutex`, no PI) against `pi-mutex` (#B, RAII wrapper over `pthread_mutexattr_setprotocol(PTHREAD_PRIO_INHERIT)`). `stock-full` is one debugfs write, read back. Java tab: the `parkNanos` loop to an absolute `System.nanoTime()` deadline and the JNA `sched_setscheduler(0, SCHED_FIFO, ...)` call on the hot thread, Temurin by path |
| Measure | Before/after cyclictest: `stock-lazy` against `rt` under `hackbench` + `stress-ng --cpu` on all 4 vCPUs, 300 s, 1 ms, CPU 3, with the profile line per lane. Exact: preempt model per lane; `irq/` and `ktimers` counts per snapshot (S1: stock 15 driver-requested, none for virtio; RT 80; `ktimers` 0 against 4). PI: high-priority wait p99 `pi-mutex` against `plain-mutex` (≥ 10x by construction, said so). cyclictest p99.9 `rt` against `stock-lazy` asserted only at ≥ 2x in S11, else observed with steal ticks. Line: 200,000 parcels, 0 dropped. Observed: `stock-full`, idle baselines, the Java wake tail against safepoint count and total |
| Cross-check | Probe p99 against cyclictest p99 in the same lane; steal ticks against the tail; `irq/` thread names against `/proc/interrupts` rows; the Java lane's late wakes against `-Xlog:safepoint` lines by time |
| What the VM can't show | SMIs, host-side preemption of the vCPU thread, bare-metal RT bounds |
| What you learned | RT bounds the kernel's share of the wake path and gives kernel locks PI; it doesn't remove the host, the runtime or user-space inversion |

Boundaries: isolation, `nohz_full` and IRQ steering are Ch15's, named in one clause here (a scope note, not a teaser); cyclictest method is restated briefly.

## Ch15: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Why this matters | The decide thread shares four vCPUs with the label printer's spooler, a log shipper and the WMS client. Every one of them can take the CPU, its cache or its interrupt line at the wrong moment for the paddle. |
| Diagram | Fig 15.1 (4 vCPUs: housekeeping 0-1 against isolated 2-3; ticks, RCU, IRQs, kthreads) and Fig 15.2 (noise paths: scheduler, IRQ, tick, cache, host) |
| Concept | `isolcpus=domain,managed_irq,2-3` (domain isolation is irreversible at boot; cpuset partitions are the runtime alternative, "less flexible", not deprecated), `nohz_full` (one runnable task, 1 Hz residual on housekeeping CPUs), `rcu_nocbs` (`rcuox` threads), `irqaffinity=0-1`, per-IRQ `smp_affinity` and managed IRQs (kernel-owned, can't be written). tuned `cpu-partitioning` with `isolated_cores=2-3`: workqueue and systemd affinity, `default_smp_affinity`, the boot args, and no `isolcpus` on its own. blk-mq completes on the submitting CPU's queue. What isolation doesn't partition: LLC, memory bandwidth, the host |
| How the code works | The placement probe (busy decide thread on CPU 2, tick count from `/proc/interrupts`). Before/after: `shared` (#A) against `isolated` (#B) as profile files (`isolate-cpu23.conf`, the tuned variables). The IRQ pair: `irq-steered` (#A, disk I/O submitted from CPUs 0-1) against `irq-on-measure-cpu` (#B, a thread on CPU 3 doing disk I/O). The `smp_affinity` write on virtio-net, and the refused write on a virtio-blk queue IRQ. Java tab: `taskset -c 2,3 java ...` against the JVM on 0-1 with only the hot thread moved to CPU 3 |
| Measure | Before/after cyclictest on CPU 3: `shared` against `isolated` under noise on 0-1 (all 4 CPUs for `shared`), profile line per lane. Exact: `isolated`/`nohz_full` = `2-3` against empty; LOC per second on CPU 2 with one busy task (`isolated` ≤ 10, `shared` ≥ 500; S1: 0/s against about 1012/s); no noise thread seen on 2-3; decide-thread involuntary switches; virtio-blk interrupts on CPU 3 (`irq-steered` 0, `irq-on-measure-cpu` ≥ 1,000); Java thread counts on 2-3. cyclictest p99.9 `isolated` against `shared` per S11. Observed: `cache-noise`, IRQ defect latency, the `smp_affinity` errno |
| Java | `jvm-taskset-isolated` piles JVM threads onto 2-3 with no balancing (S1: two busy threads under `taskset -c 2,3` both ran on CPU 2); `hot-thread-pinned` puts exactly one JVM thread there |
| Cross-check | `/proc/interrupts` deltas against the cyclictest tail by lane; sampled last-run CPU of every noise and JVM thread against the isolated list; steal ticks |
| What the VM can't show | Host isolation (vCPU pins are pins, not isolation; SMT siblings still run host work), CAT/MBA (no resctrl in the guest, S1), real NIC IRQs |
| What you learned | Isolation is several mechanisms, each with its own counter; the shared cache and the host stay shared |

Boundaries: the kernel's preemption model is Ch14's (named in one clause); cgroup quotas and cpusets in containers were Part 4's (For deeper coverage only).

## Ch16: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Why this matters | Before the line's commissioning sign-off, someone runs cyclictest on the controller and reads one number. Whether that number means anything depends on how it was run. |
| Diagram | Fig 16.1 (intended against actual wake on a timeline; missed periods skipped) and Fig 16.2 (`naive` against `method`) |
| Concept | How cyclictest measures: absolute `clock_nanosleep(TIMER_ABSTIME)`, latency = actual minus intended wake, a stall longer than one interval records one late sample (coordinated omission, sample count falls short). Defaults at v2.11: SCHED_OTHER, priority 0, `CLOCK_REALTIME` despite the help text, PM-QoS write to `/dev/cpu_dma_latency` unless `--default-system`. Histograms (`-h`, `--histfile`), overflow, samples needed for p99.9, why `Avg` is never quoted. `rtla timerlat`: IRQ against thread latency, tracefs fallback without BTF. cpuidle: `none` by default, `cpuidle-haltpoll` only with the realtime hint or `force` |
| How the code works | The two command lines as a before/after pair: `naive` (#A, defaults) against `method` (#B, `-m -p95 --policy=fifo --clock=monotonic -a 3 -i 1000 -h 20000 --histfile`, JSON). The converter `lowlat-report from-cyclictest`: percentiles from the histfile, overflow fails the run, `avg` dropped, `nodename` scrubbed, `sysinfo.realtime` ignored. The C++ probe beside it on CPU 2 |
| Measure | Before/after cyclictest: `naive` against `method` on `lab-ready-r05-iso` with noise on 0-1, profile line per lane; direction stated whatever it is. Exact: `method` sample count = duration / interval ± 1% and ≥ 100,000, overflow 0; policy and priority actually in effect (`chrt -p`); the clock each lane used. Converter percentiles match an independent recomputation. Probe against cyclictest p99 within 2x if S11 holds. Observed: the timerlat split, `haltpoll-forced` against `idle-default` |
| Cross-check | Probe against cyclictest in the same lane; histfile recomputation against the converter; timerlat thread latency against cyclictest |
| What the VM can't show | SMI detection (`hwlatdetect` in a guest sees host-taken time, not an SMI count), bare-metal idle states |
| What you learned | The instrument's settings are part of the number; report the command line, the clock, the sample count and the overflow beside it |

Boundaries: what RT and isolation change is Ch14 and Ch15's (named in one clause each); this chapter changes only the method.

## Fact-source rows per chapter

Section names: "RF" = `dependency-pins.md` "Runtime facts for Ch14-16 prose"; "S1" = "r05 guest probes (S1, 2026-10-25)"; "Pins" = "r05 pins (surveyed 2026-10-25)".

- **Ch14:** RF "PREEMPT_RT: what it guarantees", "PREEMPT_RT: what it doesn't guarantee", "Preempt models at v7.2 and which are offered", "Lazy preemption semantics", "Threaded IRQs and `threadirqs`", "rt_mutex priority inheritance", "`PTHREAD_PRIO_INHERIT` and `FUTEX_LOCK_PI`", "`std::mutex` has no PI", "RT throttling, the fair deadline server, `sched_rt_runtime_us`", "`ksoftirqd`, threaded softirqs and `ktimers`", "KVM steal time", "JVM safepoints and `-Xlog:safepoint` (JDK 25)", "Java monitors have no priority inheritance", "`LockSupport.parkNanos` and `parkUntil` (JDK 25)", "JNA `sched_setscheduler` and thread ids", "How cyclictest measures", "`hwlatdetect` and SMIs in a guest". S1 "Kernels per snapshot", "Preempt modes, stock 7.2.11", "Preempt modes, RT 7.2.11", "`sched_rt_runtime_us`", "`irq/` kthreads", "`ktimers`, `ksoftirqd`", "cyclictest default clock", "Java in the guest". Pins: rt-tests, stress-ng, Fedora 44 kernel, JNA.
- **Ch15:** RF "`isolcpus` flags", "`isolcpus` deprecation notes", "`nohz_full` conditions", "`rcu_nocbs`", "`irqaffinity`, `/proc/irq/*/smp_affinity`, `default_smp_affinity`", "Managed IRQs", "tuned `cpu-partitioning`: variables", "tuned `cpu-partitioning`: what it changes", "`/proc/interrupts` rows LOC, RES, CAL, TLB", "Intel CAT, MBA and resctrl under KVM", "KVM steal time", "JNA `sched_setscheduler` and thread ids", "How cyclictest measures". S1 "IRQ affinity", "tuned `cpu-partitioning` in the guest", "`nohz_full` tick residual", "`isolcpus=domain` pile-up", "resctrl / CAT / MBA", "cyclictest default clock", "Java in the guest". Pins: tuned, tuned profile packages, OpenHFT Affinity (if S5 reuses it), JNA, stress-ng.
- **Ch16:** RF "How cyclictest measures", "cyclictest defaults and options", "cyclictest histogram file format", "cyclictest `--json` format", "`rtla timerlat`: IRQ against thread latency", "`cpuidle-haltpoll` load conditions", "`hwlatdetect` and SMIs in a guest", "KVM steal time". S1 "cyclictest default clock", "cyclictest `-p 95` JSON", "rtla", "cpuidle". Pins: rt-tests, realtime-tests, rtla.

## Claims and evidence tables

Skeletons for S14-S16. Each executor fills the evidence column from `r05-vm-run1..3` and the fact rows, in the r04 form (claim | lane | evidence file and field | status). Results paths are `examples/NN-slug/results/r05-vm-run{1,2,3}/vm/<lane>/altN/`. Every status starts `unverified`; S19 sets `verified` or rewrites the claim. Report failures and outliers as they are.

### Ch14 claims (`examples/14-preempt-rt/results/r05-vm-run{1,2,3}/`)

| Claim | Lane | Source row or results path | Status |
|---|---|---|---|
| The ±0.8 ms diverter window is a `model` input (±2 mm at 2.5 m/s) | -- | `_plans/r05-plan.md` D21; arithmetic | unverified |
| `rt` reports PREEMPT_RT; stock lanes report `lazy` and `full` (exact) | all | `vm/<lane>/altN/guest-profile.json` `kernel.preempt_model`, `kernel.preempt_mode`; S1 "Preempt modes" | unverified |
| `stock-full` is a runtime write of `full` to debugfs `sched/preempt`, no reboot | stock-full | S1 "Preempt modes, stock 7.2.11"; RF "Preempt models at v7.2" | unverified |
| x86 at v7.2 offers `full` and `lazy` only (no none or voluntary) | -- | RF "Preempt models at v7.2 and which are offered" | unverified |
| `lazy` gives a SCHED_NORMAL task one tick to yield | -- | RF "Lazy preemption semantics" | unverified |
| `irq/` thread count per snapshot (exact); stock has none for virtio IRQs | stock-*, rt | `vm/<lane>/altN/kthreads.json` (S7 names the file); S1 "`irq/` kthreads" | unverified |
| `ktimers` count: `rt` 4, stock 0 (exact) | stock-*, rt | same file; S1 "`ktimers`, `ksoftirqd`"; RF "`ksoftirqd`, threaded softirqs and `ktimers`" | unverified |
| RT forces threaded IRQs at FIFO 50 and turns kernel spinlocks into PI rtmutexes | -- | RF "Threaded IRQs and `threadirqs`", "rt_mutex priority inheritance" | unverified |
| `std::mutex` does no PI; the wrapper sets `PTHREAD_PRIO_INHERIT` | -- | RF "`std::mutex` has no PI", "`PTHREAD_PRIO_INHERIT` and `FUTEX_LOCK_PI`" | unverified |
| PI demo: `pi-mutex` high-priority wait p99 against `plain-mutex` (≥ 10x by construction) | rt | `vm/rt/altN/cpp/pi-*.json` `percentiles.p99`; `verify.log` criterion 3 | unverified |
| cyclictest p99/p99.9/max, `stock-lazy` against `rt` under load (median of 3; asserted or observed per S11) | stock-lazy, rt | `vm/<lane>/altN/cyclictest.json` `percentiles`; `verify.log` criterion 4 | unverified |
| Probe p99 against cyclictest p99, same lane | all | `vm/<lane>/altN/cpp/cyclic-probe.json`, `cyclictest.json` | unverified |
| `stock-full` against `stock-lazy` (observed) | stock-* | `cyclictest.json` `percentiles` | unverified |
| Steal ticks per lane | all | `vm/<lane>/altN/steal.json` `steal_ticks`, `total_ticks`; RF "KVM steal time" | unverified |
| A guest RT kernel can't remove host-side preemption of the vCPU thread | -- | RF "PREEMPT_RT: what it doesn't guarantee" | unverified |
| Fair server 50 ms per 1000 ms; `sched_rt_runtime_us` 1000000 at v7.2 | -- | RF "RT throttling, the fair deadline server"; S1 "`sched_rt_runtime_us`" | unverified |
| Line: 200,000 parcels, `dropped=0`, kind `vm`, binary checksums equal across lanes (exact) | all | `vm/<lane>/altN/cpp/consumer.json`; `binaries-*.txt`; `verify.log` criterion 5 | unverified |
| Java wake lateness p99.9 and safepoint count/total per kernel (observed); Temurin by path | stock-lazy, rt | `vm/<lane>/altN/java/*.json`; RF "JVM safepoints", "`LockSupport.parkNanos`"; S1 "Java in the guest" | unverified |
| Java hot thread ran SCHED_FIFO (`chrt -p <tid>`) | stock-lazy, rt | S7 smoke log; `java/*.json` `runtime.counters` | unverified |
| Java monitors give no PI guarantee | -- | RF "Java monitors have no priority inheritance" | unverified |
| Profile line per lane | all | `guest-profile.json`; `run-start.json` (vcpupin, snapshot, host load1) | unverified |

### Ch15 claims (`examples/15-cpu-partitioning/results/r05-vm-run{1,2,3}/`)

| Claim | Lane | Source row or results path | Status |
|---|---|---|---|
| `isolated`: `/sys/devices/system/cpu/isolated` and `nohz_full` = `2-3`; `shared` both empty (exact) | shared, isolated | `vm/<lane>/altN/guest-profile.json`; `verify.log` criterion 1 | unverified |
| tuned `cpu-partitioning` sets no `isolcpus` on its own; `isolcpus` added via grubby | isolated | S1 "tuned `cpu-partitioning` in the guest"; RF "tuned `cpu-partitioning`: what it changes" | unverified |
| `isolcpus` domain isolation is irreversible at boot; cpusets are the runtime alternative | -- | RF "`isolcpus` flags", "`isolcpus` deprecation notes" | unverified |
| LOC per second on CPU 2 with one busy task: `isolated` ≤ 10, `shared` ≥ 500 (exact) | shared, isolated | `vm/<lane>/altN/interrupts.json` (S8 names the file); S1 "`nohz_full` tick residual" | unverified |
| `nohz_full` needs one runnable task; housekeeping CPUs carry a 1 Hz residual | -- | RF "`nohz_full` conditions" | unverified |
| No noise thread seen on 2-3 in `isolated`; decide-thread involuntary switches ≤ 10 against ≥ 100 (exact) | shared, isolated | `vm/<lane>/altN/thread-cpus.json`; `cpp/*.json` `runtime.ctx_switches`; `verify.log` criterion 3 | unverified |
| cyclictest p99.9 on CPU 3, `isolated` against `shared` (median of 3) | shared, isolated | `vm/<lane>/altN/cyclictest.json` `percentiles`; `verify.log` criterion 4 | unverified |
| virtio-blk IRQs are managed and refuse `smp_affinity`; virtio-net's moves | isolated | S1 "IRQ affinity"; RF "Managed IRQs"; `vm/isolated/altN/smp-affinity.json` | unverified |
| blk-mq completes on the submitting CPU's queue | -- | S1 "IRQ affinity" (observed in the guest; no kernel doc row: S15 words it as observed or S19 adds a row) | unverified |
| virtio-blk interrupts on CPU 3: `irq-steered` 0, `irq-on-measure-cpu` ≥ 1,000 (exact) | irq-* | `vm/irq-*/altN/interrupts.json`; `verify.log` criterion 5 | unverified |
| `cache-noise` p99.9 against CPU-only noise (observed) | cache-noise, isolated | `cyclictest.json` `percentiles` | unverified |
| No resctrl (CAT/MBA) in the guest | -- | S1 "resctrl / CAT / MBA"; RF "Intel CAT, MBA and resctrl under KVM" | unverified |
| `jvm-taskset-isolated`: ≥ 10 JVM threads on 2-3, piled up without balancing | jvm-taskset-isolated | `java/*.json`; S1 "`isolcpus=domain` pile-up"; `verify.log` criterion 6 | unverified |
| `hot-thread-pinned`: exactly one JVM thread on 2-3, ≤ 10 involuntary switches (exact) | hot-thread-pinned | `java/*.json`; `verify.log` criterion 6 | unverified |
| Line clean (200,000 parcels, 0 dropped, checksums equal) | all | `cpp/consumer.json`; `verify.log` criterion 7 | unverified |
| Steal ticks per lane | all | `steal.json`; RF "KVM steal time" | unverified |
| Profile line per lane | all | `guest-profile.json`; `run-start.json` | unverified |

### Ch16 claims (`examples/16-cyclictest/results/r05-vm-run{1,2,3}/`)

| Claim | Lane | Source row or results path | Status |
|---|---|---|---|
| cyclictest sleeps to an absolute time and records actual minus intended wake | -- | RF "How cyclictest measures" | unverified |
| A stall longer than one interval records one late sample (missed periods skipped) | -- | RF "How cyclictest measures" | unverified |
| Defaults at v2.11: SCHED_OTHER, priority 0, PM-QoS write unless `--default-system` | -- | RF "cyclictest defaults and options" | unverified |
| Default clock is `CLOCK_REALTIME` despite the help text; `--clock=monotonic` gives monotonic | naive, method | RF "How cyclictest measures"; S1 "cyclictest default clock"; `cyclictest.json` `cmdline:` | unverified |
| `naive` ran SCHED_OTHER; `method` ran SCHED_FIFO 95 on CPU 3 (exact) | naive, method | `vm/<lane>/altN/chrt.txt` (S9 names it); `verify.log` criterion 2 | unverified |
| `method` samples = duration / interval ± 1% and ≥ 100,000; overflow 0 (exact) | method | `cyclictest.json` `runtime.counters.samples`, `overflows`; `verify.log` criterion 1 | unverified |
| Converter percentiles equal an independent recomputation from `--histfile` (exact) | method | `verify.log` criterion 4; RF "cyclictest histogram file format" | unverified |
| JSON has `avg` and `nodename`; the report has neither; `sysinfo.realtime` reads 0 on RT | -- | RF "cyclictest `--json` format"; S1 "cyclictest `-p 95` JSON" | unverified |
| `naive` against `method` p99/p99.9/max (observed, direction stated) | naive, method | `cyclictest.json` `percentiles` | unverified |
| Probe p99 within 2x of cyclictest p99, same lane | method, probe | `cpp/cyclic-probe.json`, `cyclictest.json`; `verify.log` criterion 3 | unverified |
| timerlat IRQ against thread latency p99 (observed); tracefs path, no BTF in the RT build | timerlat | `vm/timerlat/altN/timerlat.txt`; RF "`rtla timerlat`"; S1 "rtla" | unverified |
| cpuidle `none` by default; haltpoll only with the realtime hint or `force` | idle-default, haltpoll-forced | `guest-profile.json` `cpuidle.driver`; RF "`cpuidle-haltpoll` load conditions"; S1 "cpuidle" | unverified |
| `haltpoll-forced` against `idle-default` (observed, both `--default-system`) | idle-default, haltpoll-forced | `cyclictest.json` `percentiles`; cpuidle state usage | unverified |
| `hwlatdetect` in a guest isn't an SMI test | -- | RF "`hwlatdetect` and SMIs in a guest" (the reasoning sentence is labelled as reasoning) | unverified |
| Profile line per lane | all | `guest-profile.json`; `run-start.json` | unverified |

## §5 prose bundle (from `r05-plan.md`, verbatim; paste into every S14-S16 prompt)

- **House voice (Geewax rubric):**
  - contractions throughout;
  - no em dashes;
  - no honest/lie framing about people or tools;
  - concrete, line-grounded examples (the sortation line, the diverter window), never contrived;
  - sections open on a line object;
  - peer-to-peer register;
  - no meta-narration ("in this section we will").
- **Facts:**
  - the S0/S1 rows for the chapter, listed;
  - every runtime fact needs a source row, and a sentence that can't be sourced is cut or reworded to what the source says;
  - the claims table names the row per fact.
- **Standalone:** no "as we saw in Chapter N" and no forward teasers. Restate cyclictest, SCHED_FIFO, vCPU and isolation in place. Cross-links only in For deeper coverage or a one-clause scope note.
- **Length:** about 2,000–2,500 words, 1,900 floor, no cap; never cut a needed explanation.
- **Numbers:** lane `vm` with the full VM profile; distributions only; median of 3; sub-2x margins stated.

## Verification status footer

The r04 form: the asserted criteria by number, what's observed only, and the runs (`r05-vm-run1` to `r05-vm-run3`), with the lane profile (snapshot, guest profile, vcpupin, guest kernel and preempt model, tuned, cpuidle). Every number is lane `vm`; no host lane exists in Part 5.

## Status

| Step | Status |
|---|---|
| brief (S2) | done |
| Ch14 prose and claims (S14) | todo |
| Ch15 prose and claims (S15) | todo |
| Ch16 prose and claims (S16) | todo |
