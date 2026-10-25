---
title: "r05 plan: the OS, isolation and jitter"
render_with_liquid: false
description: "Relay plan for r05: Part 5, Ch14–16 (PREEMPT_RT, CPU partitioning and noisy neighbours, measuring jitter with cyclictest) in the lowlat KVM guest, C++23 and Java 25. Ch17–18 move to r06. Step status is kept current so a fresh session can resume."
---

Planned by Opus on 2026-10-25 on `release/r05`, cut from main at `461f6d4` (r04 merged in #7, tag `r04.x`, release published). The Status column is updated as steps land. The open questions in §6 are answered in S2, before any code.

## 0. Facts that shape the plan (read-only probes, 2026-10-25; S0 and S1 re-check them)

- **RT guest kernel: already built and installed.**
  - `build-rt-kernel.sh` output is in `~/.cache/lowlat/kernel-rt/`. It holds five RPMs `kernel-rt{,-core,-modules,-modules-core,-modules-extra}-7.2.11-200.lowlatrt.fc44.x86_64`, plus `SHA256SUMS` and `BUILDINFO`:
    - `source_nvr=kernel-7.2.11-200.fc44`, `buildid=.lowlatrt`;
    - preempt-rt fragment sha256 `27cb1d0c…`;
    - image `fedora:44@sha256:43b29f65…`;
    - built 2026-10-21.
  - The SRPM pin is `LAB_STOCK_KERNEL="7.2.11-200.fc44"` in `versions.env`.
  - `install-rt-kernel.sh` installs the RT kernel next to the stock kernel of the same NVR, so stock and RT lanes differ only in the preemption model.
  - Nothing needs building in r05 unless Q4 says so.
- **Lab state.**
  - `lowlat-target` is defined and shut off: 4 vCPU (`<vcpu placement='static'>4`), 8 GiB, `host-passthrough` CPU, q35, vsock, no `<cputune>` in the current XML.
  - Snapshots: `lab-ready` (stock, tooled), `lab-ready-rt` (RT kernel, no isolation, no pin), `lab-ready-iso` (RT + `isolcpus=3 nohz_full=3 rcu_nocbs=3` + vCPU 3 pinned to one host CPU + Temurin) and `lab-ready-r04` (stock-unpinned, Docker images).
  - No `lowlat-peer` exists. Other projects' domains (`ebpf-*`, `systems-*`) are shut off and stay untouched.
- **vCPUs for partitioning.**
  - With 4 vCPUs, the split is housekeeping CPUs 0–1 (kernel threads, IRQs, ssh, simulator, noise) and isolated CPUs 2–3 (receive/decide and the measurement thread).
  - That's enough for one measured pipeline plus `cyclictest` on the isolated set. It's tight for noise plus simulator on the housekeeping pair (Q2).
  - Today `isolate-cpu3.conf` isolates only CPU 3, and `pin-vcpu.sh` pins only one vCPU.
- **Kernel config** (Fedora's 7.2.11-200.fc44 config; S1 re-reads it in the guest from `/boot/config-*` for both kernels):
  - `PREEMPT_DYNAMIC=y`, with `PREEMPT_LAZY=y` as the build's default model. So the stock ladder is lazy against full, not voluntary; S1 confirms the modes offered by `/sys/kernel/debug/sched/preempt`.
  - `NO_HZ_FULL=y`, `RCU_NOCB_CPU=y`, `HZ=1000`, `HALTPOLL_CPUIDLE=y`, `XDP_SOCKETS=y`, `VIRTIO_NET=m`.
- **Guest NIC and AF_XDP** (matters for r06; probed cheaply in r05 S1).
  - The device: one virtio-net device on a passt backend (`<interface type='user'><backend type='passt'/>`). It's QEMU's userspace virtio-net with no vhost and no `<driver queues>`, so it's single-queue.
  - XDP modes:
    - Generic (SKB) XDP works on any netdev.
    - Native XDP is implemented by `virtio_net`, with conditions: guest offloads switched off through `VIRTIO_NET_F_CTRL_GUEST_OFFLOADS`, an MTU limit, and on one queue pair, XDP_TX/REDIRECT fall back to a shared, locked TX queue.
    - AF_XDP zero-copy on `virtio_net` landed upstream (RX in v6.11, TX in v6.13) and needs the device to offer `VIRTIO_F_RING_RESET` and to negotiate `VIRTIO_F_ACCESS_PLATFORM` (else `virtqueue_dma_dev()` is NULL and the bind fails with -EINVAL). Whether QEMU's userspace device offers them behind passt is unverified; S0 checks the v7.2 source, S1 probes the errno.
  - Traffic sources:
    - ssh runs over vsock, so an XDP program on `eth0` can't lock us out.
    - Guests can't reach each other, so the only external traffic source for the virtio NIC is the host through passt. That's an r06 design decision (§7, Q8).
- **Host can't run RT work, by rule and in fact.** `ulimit -r` is 0 (no SCHED_FIFO), and host sudo, tuned, sysctl and boot parameters are forbidden. Every r05 number is lane `vm`. There's no host lane and no host-vs-VM comparison in Part 5.
- **Prior evidence.**
  - r01 S13 smoke (60 s, unpinned, untuned, hackbench): the RT guest did not beat stock (worst 1277 us against 170 us on one vCPU). Its follow-up says to measure with vCPU pinning and isolation, over many runs, and to state that a guest RT kernel can't remove host-side preemption.
  - r02 Ch7 VM runs on `lab-ready-iso`:
    - involuntary context switches: pinned+isolated 0–5, unpinned 119,779–360,310;
    - hand-off p99.9: 54 us against 0.43–1.56 ms.
  - So isolation effects are large in this guest, and RT-vs-stock effects may be small or reversed.
- **Kit already has:**
  - `profile.sh` records `preempt_model`, the latency cmdline (`isolcpus`, `nohz_full`, `rcu_nocbs`, `irqaffinity`, `threadirqs`, `preempt`), `/sys/devices/system/cpu/{isolated,nohz_full}` and the tuned profile.
  - `lib.sh` has `lab_ssh`, `guest`, `guest_fetch`, `interleave_env`, `require_quiet_host --lab-idle`, `assert_placement`, `task_ctx_switches` and `scrub_results`.
  - `validate.py vm-runs` checks `*vm-run*` directories for `vm/LABEL` = `vm` and `virt.type` `kvm`.
  - Missing: no cpuidle driver, no dynamic preempt mode, no IRQ affinity summary, no vcpupin record, and no `cyclictest` parser.
- **Guest tools from cloud-init:** `realtime-tests` (cyclictest, hackbench), `tuned` + `tuned-profiles-cpu-partitioning`, `realtime-setup`, `stress-ng`, `perf`, `kernel-tools`, `numactl`, pinned Temurin 25.0.5. No `rtla`, no libxdp/xdp-tools.
- **Sibling material (cited in For deeper coverage, never ported):** `~/Dev/linux-systems-programming` Ch24 (timers, deadlines, a cyclictest note), Ch35 (virtualization and KVM), Ch40 (low-latency fast path: pinning, busy-poll), Ch32 (cgroups).
- **UDP ports in use:** 47200–47336. r05 uses 47400–47429.
- **Release rule:** merged PR + `r05.x` tag + notes-only GitHub release, no tarball. Pages 200 checks after merge.

## 1. Approach

**Split (D1, Q1).** r05 ships Ch14–16 and r06 ships Ch17–18. Reasons:
- Ch14–16 run entirely on lab assets that already exist: the RT kernel, the isolation profile mechanism, `pin-vcpu.sh`, `cyclictest` in the guest.
- Ch17 needs a lab-network decision that touches what the host exposes (§7, Q8) and three new dependency families (libbpf/libxdp/xdp-tools, DPDK, guest hugepages).
- Ch18 versions the config that Ch14–17 create, so it has to come last.
- Every r05 measurement is VM-only and serial on one guest, so five chapters of calibration plus three runs each would hold the shared host's CPUs for a very long stretch.
- r04's three chapters already took 22 steps.
- The cost: every later iteration shifts by one (r06 to r07 … r12 to r13), applied in S2.

**One question across Part 5's first half: what stands between the timer and the thread on the diverter path?** The spine hook is physical. The divert must fire inside a window, not just before a deadline. At 2.5 m/s a ±2 mm paddle window is ±0.8 ms of timing slack (a labelled `model` input, never a measurement), so tail jitter, not median latency, is what mis-sorts parcels.
- **Ch14 (the kernel):** the preemption ladder on the same 7.2.11 source: `stock-lazy` (Fedora's default) against `stock-full` against `rt`. Measured with cyclictest and a C++ probe under in-guest load on a pinned vCPU.
  - What RT promises: bounded kernel preemption latency, threaded IRQs, priority inheritance (PI) in kernel locks.
  - What it doesn't: host-side vCPU preemption (steal), user-space pauses (a JVM safepoint), priority inversion in user code without a PI mutex.
- **Ch15 (the placement):** isolation of CPUs 2–3 against a shared guest, with noise on the housekeeping CPUs:
  - scheduler isolation (`isolcpus`), the tick (`nohz_full`), RCU callbacks (`rcu_nocbs`);
  - IRQ affinity (`irqaffinity=` and per-IRQ `smp_affinity`), plus tuned `cpu-partitioning`;
  - what isolation doesn't partition: last-level cache, memory bandwidth, and the host underneath;
  - the JVM's own threads as the neighbour inside the process.
- **Ch16 (the instrument):** how cyclictest measures (absolute `clock_nanosleep` wake against the intended time) and how the method changes the number (naive defaults against a disciplined run). The run also covers:
  - histograms and overflow;
  - sample count needed for p99.9;
  - why `Avg` is never quoted;
  - cross-checking against our own probe;
  - attributing a spike to IRQ versus thread latency with `rtla timerlat`;
  - the guest idle path (`cpuidle-haltpoll`).

**Before/after cyclictest in every chapter** (the CLAUDE.md rule), with cyclictest's meaning restated in place, so chapters stand alone:
- Ch14: `stock-lazy` against `rt` under load.
- Ch15: `shared` against `isolated` under noise.
- Ch16: `naive` against `method`.

**Criteria** (carried over from r04):
- Mechanism counters first, latency second. Mechanism counters here means `/proc/interrupts` deltas, involuntary context switches, IRQ-thread counts, the CPU a thread last ran on, cyclictest sample and overflow counts, and safepoint counts.
- Within-run comparisons only: lanes alternate A B A B A B by snapshot revert inside one run, and are judged on the median of 3 alternations.
- Every asserted bound clears 2x in all three S11 calibration runs, or a sub-2x margin is stated and the user decides. Exact counters are labelled "exact".
- Distributions only (p50/p99/p99.9 and max labelled "worst of N samples"). cyclictest's `Avg` is dropped by the converter and never quoted.

**Run locations:**
- All runs are in `lowlat-target`.
- Lanes are separate snapshots, reverted before each lane, so the guest state is known.
- One set of binaries is built once per run in the guest, checksummed and pushed into each lane.
- Host conditions: load1 ≤ 2 at the start and before every lane (the driver aborts otherwise), and the host's load is recorded.
- Guest steal ticks are recorded per lane.

**Languages (D8):**
- Ch14 is C++ plus one Java lane (RT bounds the kernel, not the runtime's pauses).
- Ch15 is C++ plus Java (the JVM's own threads against isolation).
- Ch16 is C++ only.
- There is no Python lane in r05. The GIL is a user-space pause like a safepoint, so it doesn't change any kernel, placement or measurement lesson; each chapter says so in one sentence.

**Rejected:**
- Shipping Ch14–18 in one iteration: see the split reasons above.
- A host lane: the host can't SCHED_FIFO and must never be tuned.
- Changing guest vCPUs to 6+ by default: the host is shared, and every snapshot would change (Q2).
- Using the old `lab-ready-iso` as-is: it isolates one CPU and pins one vCPU, which isn't enough for the pipeline plus cyclictest.
- Running tuned on the host or using host `isolcpus`: forbidden.
- `stress-ng`/`hackbench` load on the host: forbidden, and it would mix in other users' work.
- Hand-rolled cyclictest only: the reader's tool is cyclictest; our probe is the cross-check.
- Quoting cyclictest `Avg`: the no-mean rule.
- A Python lane: rule 1, per the Languages paragraph above.
- Kubernetes or containers as the noisy neighbour: r04 covered cgroups. Noise is in-guest `stress-ng`, named in one sentence.
- Intel CAT/resctrl cache partitioning: KVM doesn't virtualize it on this lab. Named in prose as what the VM can't show.
- A full PREEMPT_NONE/VOLUNTARY ladder: the 7.2 build offers lazy and full (S1 confirms).
- Rebuilding the RT kernel on a newer NVR: Q4, hold recommended.

## 2. Per chapter

### Ch14: `examples/14-preempt-rt/` (VM)

- **Lanes:**
  - `stock-lazy`: snapshot `lab-ready-r05-stock`, the Fedora default mode, recorded.
  - `stock-full`: same snapshot. In the guest, `echo full > /sys/kernel/debug/sched/preempt` (S1 confirms the knob), or the `preempt=full` boot argument if the runtime switch is absent.
  - `rt`: `lab-ready-r05-rt`.
  - All lanes use the same vCPU pins (D3) and no isolation, alternated x3.
- **Workload:**
  - (a) cyclictest SCHED_FIFO 95 with `mlockall` on guest CPU 3, 1 ms interval, 300 s, under `hackbench` + `stress-ng --cpu` at SCHED_OTHER on all 4 vCPUs (`timeout`-bounded);
  - (b) the C++ probe `cyclic-probe` on CPU 2 with the same settings (`lowlat-report/1`);
  - (c) the line: simulator → C++ consumer at 10 kHz x 20 s, loopback, consumer at FIFO on CPU 2;
  - (d) a priority-inversion demo on one CPU:
    - low (FIFO 10) holds a lock for 1 ms;
    - medium (FIFO 50) spins 20 ms bursts;
    - high (FIFO 90) acquires;
    - variants `plain-mutex` and `pi-mutex` (`pthread_mutexattr_setprotocol(PTHREAD_PRIO_INHERIT)` through a small RAII wrapper; `std::mutex` has no PI, said in prose);
    - the whole demo runs under `timeout -s KILL`.
- **Java:**
  - Periodic wake (`LockSupport.parkNanos` to absolute deadlines) on CPU 2.
  - The hot thread is set FIFO through JNA `sched_setscheduler` (pinned JNA 5.19.1); the rest of the JVM stays SCHED_OTHER.
  - An allocating background thread runs alongside, with `-Xlog:safepoint` counted.
  - Wake lateness p99.9 and safepoint count/total per kernel, observed.
  - Java monitors have no PI: a one-sentence divergence.
- **Measured:**
  - cyclictest and probe p50/p99/p99.9/max;
  - line end-to-end p50/p99/p99.9;
  - IRQ kthreads (`irq/*`) count;
  - `ksoftirqd`/threaded softirq evidence;
  - steal ticks;
  - PI wait-time distribution;
  - Java safepoints.
- **Asserts (provisional; S11 decides):**
  1. exact: `rt` runs `PREEMPT_RT` with `CONFIG_PREEMPT_RT=y`; the stock lanes report the mode their name says.
  2. exact: `irq/` kthreads > 0 in `rt`, 0 in stock lanes without `threadirqs` (S1 confirms).
  3. PI: `pi-mutex` high-priority wait p99 ≤ 1/4 of `plain-mutex` p99 (≥ 10x by construction, stated as such).
  4. cyclictest p99.9 `rt` ≤ 1/2 of `stock-lazy` under load (median of 3): asserted only with ≥2x margin at S11, else observed and explained (host preemption floor).
  5. line: 200,000 parcels, `dropped=0`, `check`, `runtime.environment.kind` = `vm`, guest profile recorded, binary checksums equal across lanes.
- **Observed:**
  - `stock-full` against `stock-lazy`;
  - idle baselines;
  - Java wake tails against safepoints;
  - steal.
- **What the VM can't show:** SMIs, host-side preemption of the vCPU thread, bare-metal RT bounds.
- **Figures:**
  - 14.1 `14-preemption-ladder`: where a FIFO thread waits under each model.
  - 14.2 `14-wake-path-in-a-vm`: guest timer, VM exit, host scheduler; the part RT can't reach.
  - 14.3 `14-priority-inversion`.

### Ch15: `examples/15-cpu-partitioning/` (VM)

- **Lanes:**
  - `shared`: `lab-ready-r05-rt`, noise on all CPUs.
  - `isolated`: `lab-ready-r05-iso`, guest profile `isolate-cpu23` + the tuned part per D7, noise on CPUs 0–1.
  - Defect pair inside `isolated`: `irq-steered` against `irq-on-measure-cpu`. The latter writes `smp_affinity` of the virtio-blk IRQ to CPU 3, with disk noise from `stress-ng --hdd` on 0–1.
  - `cache-noise`: `isolated` with `stress-ng --stream/--cache` on 0–1, observed.
  - Alternated x3.
- **Workload:**
  - cyclictest FIFO 95 on CPU 3 for 300 s;
  - a single busy decide thread on CPU 2 for the tick count;
  - the line at 10 kHz x 20 s with receive/decide on 2–3.
- **Java:**
  - `jvm-taskset-isolated`: `taskset -c 2,3 java …`, the whole JVM.
  - `hot-thread-pinned`: the JVM on 0–1, the hot thread moved to CPU 3 through JNA affinity, as Ch7 did with OpenHFT Affinity; reuse whichever S5 picks.
  - Counts which JVM threads ran on 2–3 and shows that `isolcpus` (domain) stops load balancing, so threads pile up.
- **Measured:**
  - `/proc/interrupts` deltas per CPU (LOC, RES, CAL, TLB, virtio);
  - involuntary context switches;
  - last-run CPU of every noise and JVM thread (sampled);
  - cyclictest/probe distributions;
  - line percentiles;
  - steal.
- **Asserts (provisional):**
  1. exact: `isolated` has `/sys/devices/system/cpu/isolated` = `2-3` and `nohz_full` = `2-3`; `shared` has both empty.
  2. exact: LOC interrupts per second on CPU 2 with one busy task: `isolated` ≤ 10, `shared` ≥ 500 (HZ 1000); S1 measures the residual.
  3. exact: no noise thread is ever seen on 2–3 in `isolated`; pinned decide thread involuntary switches ≤ 10 `isolated`, ≥ 100 `shared` (Ch7 precedent).
  4. cyclictest p99.9 on CPU 3: `isolated` ≤ 1/2 of `shared` (median of 3).
  5. exact: virtio-blk interrupts on CPU 3: `irq-steered` = 0; `irq-on-measure-cpu` ≥ 1,000 (S11 sizes it).
  6. Java exact: `hot-thread-pinned` has exactly one JVM thread on 2–3 and ≤ 10 involuntary switches; `jvm-taskset-isolated` has ≥ 10 JVM threads on 2–3.
  7. line clean as in Ch14.
- **Observed:**
  - `cache-noise` p99.9 against CPU-only noise (isolation doesn't partition the LLC or memory bandwidth);
  - IRQ defect latency;
  - Java `taskset` placement detail.
- **What the VM can't show:** host isolation (the vCPU pins are pins, not isolation, and SMT siblings still run host work), CAT/MBA, NIC IRQs of real hardware.
- **Figures:**
  - 15.1 `15-partition-map`: 4 vCPUs, housekeeping against isolated; ticks, RCU, IRQs, kthreads.
  - 15.2 `15-noise-paths`: scheduler, IRQ, tick, cache, host.
  - 15.3 `15-jvm-under-isolcpus`.

### Ch16: `examples/16-cyclictest/` (VM)

- **Lanes** (on `lab-ready-r05-iso`, noise on 0–1):
  - `naive`: `cyclictest` with defaults, SCHED_OTHER, no `-m`, unpinned, 10 s.
  - `method`: `-m -p95 --policy=fifo -a 3 -i 1000 -h 20000 --histfile`, JSON output, 300 s.
  - `probe`: our C++ probe with the same parameters, run alongside on CPU 2.
  - `timerlat`: `rtla timerlat` on CPU 3 for 120 s, with auto-analysis at a threshold S11 sets.
  - `haltpoll-on` / `haltpoll-off`: the cpuidle driver per S1, observed.
  - Alternated x3.
- **Measured:**
  - per-lane distributions;
  - sample and overflow counts;
  - the policy and priority actually in effect (`chrt -p`);
  - timerlat IRQ against thread latency p99;
  - cpuidle driver and state usage.
- **Asserts (provisional):**
  1. exact: `method` sample count = duration / interval ± 1% and ≥ 100,000; histogram overflow = 0 (or the run fails with the bucket range shown).
  2. exact: `naive` ran SCHED_OTHER and `method` ran SCHED_FIFO 95 on CPU 3.
  3. cross-check: probe p99 and cyclictest p99 in the same lane within 2x of each other (asserted if the S11 margin holds).
  4. the converter's percentiles from `--histfile` match an independent recomputation (exact).
- **Observed:** `naive` against `method` (direction stated whatever it is), the timerlat split, haltpoll.
- **What the VM can't show:** SMI detection (`hwlatdetect` is meaningless in a guest), bare-metal idle states.
- **Figures:**
  - 16.1 `16-what-cyclictest-measures`: the intended-to-actual wake timeline.
  - 16.2 `16-naive-vs-method`.
  - 16.3 `16-timerlat-attribution`.

## 3. Steps

Model: `sonnet` executes and `opus` plans and validates. MAIN means the main session: lab lifecycle, VM runs and user gates.
- One checkpoint commit per step, with scopes `r05.x`, `demo-14`, `demo-15`, `demo-16`, `§14`, `§15`, `§16`.
- Stage exact paths; never `--autostash`.
- Max 2 repair rounds per step; a third goes to the user.
- VM steps are strictly serial on `lowlat-target`. Code authoring of S7–S9 may run in parallel in separate directories, but their VM smoke runs go in order S7, S8, S9.

| id | Title | Files touched | Depends on | Model | Where | Status |
|---|---|---|---|---|---|---|
| S0 | Upstream survey, fact-source rows, r04 bookkeeping | `_plans/dependency-pins.md` ("r05 pins", "Runtime facts for Ch14-16 prose"), `versions.env` (only if a tarball is pinned), `_plans/iteration-plan.md` (r04 complete: #7, `r04.x`), `_plans/r04-plan.md` (S21 done) | – | sonnet (opus validates) | host, read-only | done |
| S1 | Guest probes (read-only in intent; guest reverted after) | `_plans/dependency-pins.md` ("r05 guest probes") | S0 | opus (MAIN) | VM | todo |
| S2 | Record answers to §6; iteration-plan split and renumber; commit `r05-plan.md`, `r05-chapters.md`, `r05-figures.md` | `_plans/iteration-plan.md`, `_plans/r05-*.md`, `CLAUDE.md` only if a rule changes | S0, S1, user | opus (MAIN) | host | todo |
| S3 | Report/profile contract, additive in `lowlat-report/1`; cyclictest converter | `contracts/measurement/latency-report.schema.json`, `contracts/measurement/examples/`, `examples/common/measure-py/**` (`lowlat-report from-cyclictest`), `examples/common/measure-fixtures/`, `scripts/profile.sh`, `scripts/scrub-host-ids.py` | S0 | sonnet | host | todo |
| S4 | `lib.sh` VM-lane helpers | `examples/_lib/lib.sh`, `examples/_lib/tests/` | S3 | sonnet | host | todo |
| S5 | Build wiring 14–16 | `examples/CMakeLists.txt`, `examples/1[4-6]-*/cpp/CMakeLists.txt`, `examples/pom.xml`, `examples/1[45]-*/java/pom.xml`, `.github/workflows/ci.yml` | S0 | sonnet | host | todo |
| S6 | Lab: `isolate-cpu23` profile, tuned profile file, multi-vCPU pin, snapshots, prereq checks | `scripts/lab/guest-profiles/isolate-cpu23.conf`, `scripts/lab/tuned/lowlat-partition/tuned.conf` (if D7), `scripts/lab/pin-vcpu.sh`, `scripts/lab/install-guest-tools.sh`, `scripts/check-prereqs.sh` (`--vm --r05`), `scripts/lab/README.md` | S1, S2, S5 | opus (MAIN) | VM | todo |
| S7 | Example 14 + `verify.sh` + `vm/run.sh` + `vm/guest-run.sh` + README | `examples/14-preempt-rt/**` | S4, S5, S6 | sonnet (VM smoke by MAIN) | host code, VM smoke | todo |
| S8 | Example 15 | `examples/15-cpu-partitioning/**` | S4, S5, S6; VM smoke after S7's | sonnet (VM smoke by MAIN) | host code, VM smoke | todo |
| S9 | Example 16 | `examples/16-cyclictest/**` | S4, S5, S6; VM smoke after S8's | sonnet (VM smoke by MAIN) | host code, VM smoke | todo |
| S10 | Idiom review before calibration | all r05 code | S7–S9 | opus + sonnet fixes | host | todo |
| S11 | Calibration gate: 3 dry runs each into `results/latest`; margin table; user decides asserted vs observed | READMEs, Follow-ups | S10 | opus (MAIN) | VM | todo |
| S12 | Measurement `r05-vm-run{1,2,3}` for 14, 15, 16, serial, one recorded commit | `examples/1[4-6]-*/results/r05-vm-run*/` | S11 | opus (MAIN) | VM | todo |
| S13 | Figures 14.1–16.3; value table from S12 only | `_plans/r05-figures.md`, `diagrams/1[4-6]-*.py`, `assets/diagrams/`, `_data/diagrams.yml` | S12 | sonnet | host | todo |
| S14 | Ch14 prose | `_docs/14-preempt-rt.md`, `_plans/r05-chapters.md` (claims) | S13 | sonnet | host | todo |
| S15 | Ch15 prose | `_docs/15-cpu-partitioning.md`, `_plans/r05-chapters.md` | S13 | sonnet | host | todo |
| S16 | Ch16 prose | `_docs/16-cyclictest.md`, `_plans/r05-chapters.md` | S13 | sonnet | host | todo |
| S17 | Wiring: example pages, outline links, examples README, reconciliation, iteration plan | `_example_pages/1[4-6]-*.md`, `_docs/00-outline.md`, `examples/README.md`, `_plans/reconciliation-plan.md`, `_plans/iteration-plan.md` | S14–S16 | sonnet | host | todo |
| S18 | `validate.py` new checks + `--self-test` planted cases + CI | `scripts/validate.py`, `.github/workflows/ci.yml` | S5, S17 | sonnet | host | todo |
| S19 | Prose fact check + house-voice pass with stats | `_docs/1[4-6]-*.md`, READMEs 14–16, `_data/diagrams.yml`, `_plans/r05-*` | S18 | opus + sonnet | host | todo |
| S20 | Re-measure gate | results, chapters, figures, reconciliation | S19 | opus (MAIN) | host (VM if re-measure) | todo |
| S21 | Opus validation | – | S20 | opus (MAIN) | host | todo |
| S22 | Ship: PR `release/r05` → main, `ci-ok` green, squash-merge (user OK), delete branch, tag `r05.x`, notes-only release, no tarball, Pages 200 checks | – | S21, user OK | opus (MAIN) | host | todo |

### Step contents and acceptance criteria

**S0 survey + fact sources + bookkeeping** (read-only; nothing installed on the host)
- Pins and holds, with version, licence, source, date and hold reason:
  - rt-tests: the latest upstream tag (kernel.org `rt-tests.git`) against Fedora 44 `realtime-tests`;
  - `rtla`: the Fedora package against the kernel 7.2 tree's `tools/tracing/rtla`;
  - stress-ng (upstream tag against Fedora);
  - newest Fedora 44 kernel NVR in Bodhi (for Q4);
  - JNA (already 5.19.1, re-check);
  - OpenHFT Affinity (if Ch15 reuses it);
  - tuned version and whether `realtime-virtual-guest` / `cpu-partitioning` exist in F44.
- Runtime fact rows (topic, finding with quote, source with tag or URL) for every fact the prose will state:
  - PREEMPT_RT guarantees and non-guarantees (kernel `Documentation/core-api/real-time/`, v7.2);
  - preempt dynamic modes and lazy preemption (`kernel/sched/core.c`, `Kconfig.preempt` at v7.2);
  - threaded IRQs and `threadirqs`;
  - rt_mutex PI and `PTHREAD_PRIO_INHERIT` (glibc manual, `futex(2)` `FUTEX_LOCK_PI`);
  - RT throttling replaced by the fair deadline server (`dl_server`, version it landed in) and `sched_rt_runtime_us`;
  - `isolcpus` flags (`domain`, `managed_irq`) and their deprecation notes;
  - `nohz_full` conditions (one runnable task, residual 1 Hz tick);
  - `rcu_nocbs`, `irqaffinity`, `/proc/irq/*/smp_affinity`, managed IRQs (`kernel-parameters.txt` and `core-api/irq`);
  - tuned `cpu-partitioning` variables (`isolated_cores`, `no_balance_cores`) and what it changes (tuned profile source at the pinned tag);
  - cyclictest options and JSON/histogram format (rt-tests source and man page);
  - `rtla timerlat` IRQ against thread latency (kernel `Documentation/tools/rtla/`);
  - `cpuidle-haltpoll` load conditions (`drivers/cpuidle/cpuidle-haltpoll.c`: `KVM_HINTS_REALTIME` or `force`);
  - KVM steal time;
  - JVM safepoints and `-Xlog:safepoint` (JDK 25 docs);
  - Java monitors and PI (JLS/HotSpot: none);
  - virtio_net XDP native conditions and AF_XDP zero-copy (`drivers/net/virtio_net.c` at v7.2, `VIRTIO_F_RING_RESET`), for r06.
- Bookkeeping:
  - `iteration-plan.md`: r04 "complete (merged in #7, tag `r04.x`)", r05 "in progress on `release/r05`";
  - `r04-plan.md`: S21 `done` with the PR, tag and release.
- Acceptance:
  - every pin is exact (no ranges, `latest` or prereleases);
  - every runtime fact named in §2 has a source row;
  - every row cites a tag or a dated URL;
  - `python3 scripts/validate.py` passes;
  - the bookkeeping diff touches only those two status lines and rows.

**S1 guest probes** (MAIN)
- Setup: `revert-vm.sh lowlat-target lab-ready-rt`, then `lab-up.sh`.
- Probes:
  - modes in `/sys/kernel/debug/sched/preempt` on stock (boot the stock entry) and on RT;
  - `/boot/config-*` of both kernels for `NO_HZ_FULL`, `RCU_NOCB_CPU`, `TIMERLAT_TRACER`, `OSNOISE_TRACER`, `HALTPOLL_CPUIDLE`, `XDP_SOCKETS`;
  - `irq/` kthread count per kernel;
  - `/proc/interrupts` layout and where the virtio-blk/virtio-net IRQs land by default under disk load, and whether `smp_affinity` is writable (managed IRQs may refuse);
  - `cpuidle` current driver;
  - `cyclictest --help` (JSON support);
  - `rtla` availability;
  - `tuned-adm profile cpu-partitioning` with `isolated_cores=2-3` in the guest, and what `/proc/cmdline` and the BLS entry look like after reboot (grubby/btrfs quirk);
  - the LOC residual on an isolated `nohz_full` CPU with one busy task;
  - an `isolcpus` domain with `taskset -c 2,3` and two busy threads (do they pile up on one CPU?);
  - Java: whether JNA `sched_setscheduler` on the hot thread works as root in the guest;
  - r06 pre-probe: attach an XDP_PASS program to `eth0` in generic then native mode (`ip link … xdpgeneric/xdpdrv`), record success or errno, detach. Then an AF_XDP bind with `XDP_ZEROCOPY` and `XDP_COPY` (one-shot C probe), recording errnos. Use guest-only `dnf install xdp-tools libxdp`.
- Finish: revert to `lab-ready-rt`, then `lab-down.sh`.
- Acceptance:
  - every probe has a recorded result (value or errno) in `dependency-pins.md`;
  - `virsh snapshot-list` is unchanged except as S6 later adds;
  - other domains' state is unchanged (`virsh list --all` before and after, recorded);
  - the host `profile.sh` diff shows only `captured_at`/`load`.

**S2 decisions**
- Acceptance:
  - §6 answers in Follow-ups with dates;
  - `iteration-plan.md` shows r05 = Ch14–16 and r06 = Ch17–18, with later rows renumbered (if Q1 is yes);
  - `r05-chapters.md` (files, `part: "The OS, Isolation & the Network Edge"`, slugs, langs per chapter, the prose bundle in §5) and `r05-figures.md` committed (`docs(r05.x): plan`).

**S3 contract**
- Additive profile fields:
  - `kernel.preempt_mode` (from debugfs when readable, else null);
  - `cpuidle.driver` and `cpuidle.governor`;
  - `irq.default_smp_affinity`;
  - `irq.balance` (irqbalance active or banned list).
- Additive report fields:
  - `runtime.environment.guest_profile` gains `snapshot`, `profile` and `vcpupin` (written by the host driver from `virsh vcpupin`; the guest can't see it);
  - `runtime.counters` holds the interrupts deltas, `samples`, `overflows` and `safepoints`.
- `lowlat-report from-cyclictest`: reads cyclictest `--json` and `--histfile`, writes `lowlat-report/1` with percentiles and max, and never writes cyclictest's average. It fails on overflow > 0 unless `--allow-overflow`, recorded in `notes`.
- Acceptance:
  - planted fixtures: a histogram with known counts yields the expected p50/p99/p99.9, and a recomputation from the raw buckets matches exactly;
  - a fixture containing `Avg` produces no average field;
  - an overflow fixture fails;
  - every committed r01–r04 report still passes `check` (RECHECK sweep);
  - `profile.sh | jq .kernel,.cpuidle,.irq` works on the host (unprivileged; fields null where unreadable).

**S4 lib.sh**
- Helpers:
  - `lane_revert SNAP` (revert, up, clock set, push the run's binaries and verify checksums);
  - `require_quiet_host --lab-run` (host load1 ≤ 2 before every lane; aborts the run otherwise);
  - `guest_noise CPUS SECONDS KIND` (`stress-ng`/`hackbench` under `timeout -s KILL`, `taskset` to CPUS, refuses CPUS that include the isolated set in an `isolated` lane);
  - `interrupts_delta CPU… -- CMD`;
  - `cyclictest_run OUT ARGS` (always `timeout`, `--json`, `--histfile`, then `from-cyclictest`);
  - `thread_cpus PID` (last-run CPU of every task, sampled);
  - `vcpupin_record`.
- Acceptance:
  - `examples/_lib/tests/` covers each helper with fake `virsh`/`ssh`/`stress-ng` on PATH;
  - `guest_noise` refuses a missing `timeout`;
  - shellcheck and `bash -n` pass;
  - no helper calls `sudo` except inside a `lab_ssh` command string, checked by a test that greps the function bodies.

**S5 build wiring**
- Pieces:
  - C++ targets `cyclic-probe` (shared in `examples/common/` if 14 and 16 both use it), `pi-demo` and the Ch15 placement probe;
  - Java modules `14-preempt-rt/java` and `15-cpu-partitioning/java` (JNA, release 25);
  - CI builds and runs unit tests: the converter, and PI wrapper logic without FIFO. CI never needs root or KVM.
- Acceptance:
  - `cmake --preset release` build and `ctest` pass;
  - `mvn -B -f examples/pom.xml verify` passes with `-Xlint:all -Werror`;
  - the `lang-floor` check passes;
  - one wiring test per new target.

**S6 lab** (MAIN; guest and lab-domain config only)
- `isolate-cpu23.conf`: `PROFILE_ARGS="isolcpus=domain,managed_irq,2-3 nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1"`, documented line by line. The exact `isolcpus` flags are per the S0 rows.
- `pin-vcpu.sh` takes `PIN_MAP="2:<hostA> 3:<hostB>"` (additive; the old single-pin interface still works). The host CPUs are on distinct physical cores, chosen by the documented `/proc/interrupts` method.
- The tuned profile file (D7) is versioned under `scripts/lab/tuned/`.
- Snapshots, all with the same pins:
  - `lab-ready-r05-stock`: from `lab-ready-rt`, stock entry default, no isolation, tools;
  - `lab-ready-r05-rt`: RT, no isolation;
  - `lab-ready-r05-iso`: RT + `isolate-cpu23` + tuned part.
- `check-prereqs.sh --vm --r05 {stock|rt|iso}`.
- Acceptance:
  - `virsh snapshot-list` lists the three snapshots;
  - `check-prereqs.sh --vm --r05 <x>` passes after reverting to each: kernel, cmdline, `/sys/.../isolated`, vcpupin from `virsh vcpupin`, tools (cyclictest version, rtla, stress-ng, Temurin);
  - reverting to `lab-ready-r04` still yields the unpinned domain;
  - host `profile.sh` unchanged;
  - other domains untouched.

**S7 / S8 / S9 examples**
- Each `verify.sh` asserts its §2 criteria. Plain `./verify.sh` is RECHECK-capable and refuses a real run without `VM=1`.
- `vm/run.sh` follows 13's driver: revert per lane, `interleave_env` across lane snapshots, `guest_fetch`, `lab-down` at the end unless `KEEP_VM=1`.
- `vm/guest-run.sh` holds the in-guest steps.
- Every destructive command is under `timeout`.
- `DRY_RUN=1` and `SMOKE=1` modes are included.
- READMEs state the technique, workload, expected effect, observation surfaces (terminal; Grafana "no panel by design") and licences (rt-tests GPL-2.0, stress-ng GPL-2.0, JNA Apache-2.0/LGPL, tools only, never linked into a hot path).
- Acceptance:
  - one `SMOKE=1` VM run per example exits 0 (MAIN, serial S7, then S8, then S9);
  - variant names come only from §2 (`variant-names`);
  - every guest report has `virt.type` `kvm`, the lane's snapshot and a vcpupin record;
  - binary checksums are equal across lanes;
  - the guest is down after each smoke.

**S10 idiom review**
- `lgtm-idiomatic-review` on 14–16 and the kit diff. Checks:
  - the PI wrapper is RAII and the only non-`std::mutex` lock, justified in the README;
  - `std::jthread`/`stop_token`, `std::print`, `std::expected`;
  - `clock_nanosleep(TIMER_ABSTIME)` against a monotonic deadline (no drift);
  - `mlockall` checked;
  - JNA calls checked for errno;
  - Java hot loop warmed;
  - no busy-spin without a stated reason;
  - objdump confirms the probe loop survives.
- Acceptance: ban-tier 0 after triage; every measured-path change recorded so S11 runs on the final code.

**S11 calibration** (MAIN)
- 3 dry runs of 14, 15 and 16 (serial, host load1 ≤ 2 checks per lane).
- Margin table per non-exact criterion.
- Tuned parameters go into the READMEs: load mix, overflow range, timerlat threshold, IRQ count floor.
- Acceptance: margin table committed in Follow-ups; every asserted bound ≥ 2x in all 3 runs, or a recorded user decision moves it to observed; exact counters labelled.

**S12 measurement** (MAIN)
- `r05-vm-run1..3` per example at one recorded commit.
- `run-start.json`: host load1, lab VM state, snapshot per lane, vcpupin, commit.
- Driver logs scrubbed and moved in after exit.
- Acceptance:
  - every report passes `check`;
  - every `verify.log` ends with all criteria passing;
  - `vm-runs` and `host-ids` pass;
  - r05 results ≤ 25 MB (raw cyclictest histograms gzipped or summarized);
  - the line-simulator diff against main is empty.

**S13 figures**
- Acceptance:
  - 3 `_data/diagrams.yml` entries per chapter;
  - byte-identical regeneration;
  - captions `Figure N.x: …` with no em dash;
  - every number traceable to an S12 file or a parameter in `r05-figures.md`.

**S14 / S15 / S16 prose** (executor prompt gets the §5 bundle verbatim)
- Acceptance:
  - `wordcount.sh` ≥ 1,900 (target 2,000–2,500, no cap);
  - full spine: Learning objectives, Why this matters, Diagram, Concept, How the code works (before/after pairs with `#A`/`#B`), Measure, Cross-check, What you learned, For deeper coverage, verification-status footer;
  - a before/after cyclictest pair with the VM profile beside it (snapshot, guest profile, vcpupin, kernel, tuned, cpuidle);
  - every number is lane `vm` and traceable;
  - no mean and no `Avg`;
  - every runtime fact matches an S0/S1 source row (the claims table lists the row per fact);
  - 0 body references to other chapters (grep `Chapter [0-9]|Ch[0-9]|Part [0-9]` outside For deeper coverage = 0);
  - the Python-absent sentence and the C++/Java subset sentence are present;
  - `scan.sh --tier ban` 0, no em dash, contractions in use, no honest/lie framing about people;
  - one Opus validation, max 2 repair rounds.

**S17 wiring**
- Acceptance:
  - examples page lists 00–16;
  - outline Ch14–16 linked with `relative_url`;
  - reconciliation rows 14.x/15.x/16.x plus runs rows labelled `vm`;
  - no site link to `/plans/`.

**S18 validate.py**
- New checks:
  - `vm-lanes`: every report under `results/r05-vm-run*` has `runtime.environment.kind` `vm`, a snapshot in the r05 set, a vcpupin record, and a `profile.kernel.preempt_model` consistent with the lane (`rt*` → PREEMPT_RT, `stock-*` → PREEMPT_DYNAMIC).
  - `cyclictest-pairs`: each of chapters 14–16 has a before and an after cyclictest-derived report in every run.
  - `no-avg`: no `Avg`/`average`/`mean` latency in `_docs/1[4-6]*` or READMEs, outside a `model` block.
  - `timeout-guard`: every `stress-ng`, `hackbench`, `chrt` or spinner invocation in `examples/1[4-6]-*/**` is under `timeout`.
  - `no-host-root`: `sudo` appears only inside guest command strings.
- `variant-names` extended to the new lanes.
- Acceptance: each check fails its planted case under `--self-test` and passes on the tree; `ci-ok` green.

**S19 fact check + voice**
- Opus ties every factual sentence about kernels, cyclictest, tuned, IRQs, the JVM and KVM to a source row or a committed run, and fixes misses.
- Then a `lgtm-professional-voice` pass.
- Acceptance: before/after `scan.sh --stats` table in Follow-ups; ban-tier 0; invariants (numbers, inline code, fences, links) identical as multisets.

**S20 re-measure gate**
- Any S18/S19 change to measured code or `verify.sh` triggers a re-run of `r05-vm-run1..3`.
- Otherwise record "no re-measure needed" with the diff stat.

**S21 Opus validation**
- Acceptance:
  - every quoted number recomputed from committed files;
  - §3 criteria hold;
  - Jekyll builds with 0 warnings;
  - `validate.py` and `--self-test` pass;
  - word counts in range;
  - figures byte-identical;
  - host-ids clean.

**S22 ship** (user OK required)
- Acceptance:
  - PR squash-merged and branch deleted;
  - tag `r05.x` on main;
  - notes-only release, no tarball;
  - Pages deploy succeeds and `/docs/14-preempt-rt/`, `/docs/15-cpu-partitioning/` and `/docs/16-cyclictest/` return 200.

## 4. Risks

| Risk | Detection |
|---|---|
| RT doesn't beat stock in the guest (r01 smoke saw worse), so the before/after looks wrong | Pinned vCPUs in every lane; criterion 4 asserted only with margin; the chapter explains the host preemption floor with steal ticks; PI and IRQ-thread counters carry the asserted RT lesson |
| Host noise from other engineers swamps lanes | host load1 ≤ 2 before every lane (abort); host load and guest steal recorded; alternation by revert; median of 3 |
| Long saturating guest runs hurt the shared host | load bounded to 4 vCPUs; lanes 300 s; driver aborts on host load; runs scheduled per Q5 |
| A FIFO spinner or PI demo starves the guest | `timeout -s KILL` on every one (`timeout-guard`); one CPU only; fair server left at default; snapshot revert recovers; ssh over vsock unaffected |
| tuned `cpu-partitioning` rewrites the guest bootloader in a way grubby on btrfs `/boot` mishandles | S1 probe; D7 fallback: arguments only through `apply-guest-profile.sh`, runtime parts scripted |
| Managed virtio IRQs refuse `smp_affinity` writes, so the IRQ defect can't be built | S1 probe; fallback to a non-managed IRQ (virtio config, or the RTC) or drop the pair to observed, recorded |
| `nohz_full` residual tick higher than assumed in a KVM guest | S1 measures the residual; S11 sets the bound |
| `isolcpus` flags deprecated or changed in 7.2 | S0 source row; profile uses the documented form |
| cyclictest overflow or too few samples make p99.9 meaningless | histogram range 20 ms; overflow fails the run; ≥ 100,000 samples asserted |
| cyclictest `Avg` leaks into prose or a figure | converter drops it; `no-avg` check |
| Stale guest tree or binaries after a revert | `lane_revert` pushes the run's binaries and checks sha256 every lane; clock set by `revert-vm.sh` |
| Snapshot sprawl or wrong snapshot in a lane | `check-prereqs.sh --vm --r05 <lane>` at lane start; snapshot name in every report; `vm-lanes` check |
| vCPU pins leak into other snapshots or the domain default | pins live in the r05 snapshots' XML; S6 verifies that `lab-ready-r04` reverts unpinned |
| Other projects' VMs touched | name guard; `virsh list --all` recorded before and after each MAIN VM step |
| Host identifiers in guest output (guest home path, host CPU numbers in captures) | `scrub_results`; `host-ids`; only the CPU class in prose, host CPU indices only in lab README form |
| Unsourced runtime facts trigger extra review rounds | S0 rows before prose; §5 bundle; S19 check |
| Chapters lean on each other (cyclictest explained only in Ch16) | each chapter restates cyclictest in two sentences; grep criterion in S14–16 |
| Java JNA FIFO call fails or needs root | S1 probe; Java lanes run under guest sudo with the effect asserted (`chrt -p` of the tid) |
| Results bloat from histograms and traces | gzip raw histfiles; timerlat summaries only; S12 size check |

## 5. Prose executor bundle (pasted into every S14–S16 prompt)

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

## 6. Decisions and open questions

| D | Decision | Recommendation |
|---|---|---|
| D1 | Iteration scope | r05 = Ch14–16; r06 = Ch17–18; later iterations +1 (Q1) |
| D2 | Guest vCPUs | keep 4: housekeeping 0–1, isolated 2–3 (Q2) |
| D3 | vCPU pins | pin vCPU 2 and 3 to two host CPUs on distinct physical cores, libvirt config only, the same in all r05 snapshots (Q3) |
| D4 | Snapshots | `lab-ready-r05-stock`, `-rt`, `-iso`; revert before every lane |
| D5 | Kernel | hold `7.2.11-200.fc44` (stock and RT the same NVR); newer NVR recorded in Holds (Q4) |
| D6 | Ch14 ladder | `stock-lazy`, `stock-full`, `rt` (S1 confirms the modes) |
| D7 | Isolation mechanism | kernel args through `isolate-cpu23` + tuned `cpu-partitioning` for runtime parts if the S1 bootloader probe is clean, else args-only plus scripted IRQ/irqbalance/workqueue steps (Q6) |
| D8 | Languages | Ch14 C++ + one observed Java lane (Q7); Ch15 C++ + Java; Ch16 C++; no Python in r05, one sentence each |
| D9 | Tool sources | rt-tests, rtla, stress-ng from Fedora if they equal the latest upstream; otherwise the pinned upstream tag built in the guest |
| D10 | cyclictest output | `--json` + `--histfile` → `lowlat-report from-cyclictest`; never `Avg` |
| D11 | Own probe | C++ `cyclic-probe` cross-check emitting `lowlat-report/1` |
| D12 | Load | in-guest only, `timeout`-bounded, cpuset-bound |
| D13 | Durations | 300 s cyclictest lanes at 1 ms; line 10 kHz x 20 s; 3 alternations (Q5) |
| D14 | Destructive demos | PI demo and FIFO spinners under `timeout -s KILL`, one CPU, snapshot-recoverable |
| D15 | Comparison wording | all `vm`; no host lane; RT/isolation latency asserted only at ≥2x, else observed; before/after always shown |
| D16 | Results naming | `results/r05-vm-run{1,2,3}/vm/<lane>/altN/`, `vm/LABEL` (existing `vm-runs` applies) |
| D17 | Binaries | built once per run in the guest, sha256 per lane, equal across lanes |
| D18 | New checks | `vm-lanes`, `cyclictest-pairs`, `no-avg`, `timeout-guard`, `no-host-root` |
| D19 | Slugs | `14-preempt-rt`, `15-cpu-partitioning`, `16-cyclictest` |
| D20 | Sibling reuse | linux-systems-programming 24/32/35/40 and Ch7's affinity pattern, cited only |
| D21 | Spine hook | diverter fire-window jitter (±2 mm at 2.5 m/s = ±0.8 ms) as a labelled `model` input |
| D22 | Review economy | §5 bundle; one Opus validation per prose step; max 2 repair rounds |

Open questions for the user (answered in S2):
1. **Q1: Split r05?** Recommend yes: r05 = Ch14–16, r06 = Ch17–18, renumbering r06–r12 to r07–r13. Ch17's lab network and new dependency families plus Ch18's dependence on all of Part 5's config make a second iteration cleaner. VM time on a shared host is the binding constraint.
2. **Q2: Guest vCPUs 4 or 6?** Recommend 4. It keeps every existing snapshot, the Ch13 profile and the host load bounded; 2 housekeeping + 2 isolated is enough for one pipeline plus cyclictest.
3. **Q3: Pin two vCPUs (2 and 3) to two host CPUs** for the duration of r05 runs (libvirt config in the r05 snapshots only, no host isolation)? Recommend yes, on distinct physical cores chosen by the `/proc/interrupts` method, avoiding CPU 0. Without pins, the RT and isolation lanes measure the host scheduler.
4. **Q4: Kernel: hold 7.2.11-200.fc44 or rebuild on the newest F44 NVR?** Recommend hold. Stock and RT share one NVR, the build is verified and installed, and a rebuild costs an hour+ plus three snapshots. Record the newer NVR in Holds and re-check in r06.
5. **Q5: VM time budget.** About 3 h per full measurement set and about the same for calibration, with the guest saturating 4 vCPUs during load lanes. Recommend accepting 300 s lanes, with the driver aborting whenever host load1 > 2, and runs scheduled when the host is otherwise quiet.
6. **Q6: May tuned run inside the guest** (it rewrites the guest's bootloader entries)? Recommend yes in the guest only, if the S1 probe shows a clean `/proc/cmdline` after reboot. Otherwise args-only through `apply-guest-profile.sh`.
7. **Q7: Java lane in Ch14?** Recommend yes, as one observed lane: a FIFO Java thread's wake tail is the same under both kernels when a safepoint stops it. That's what RT doesn't promise. Ch15's Java lane is asserted.
8. **Q8 (r06 heads-up, no r05 action beyond the S1 XDP_PASS probe): Ch17 traffic source.**
   - (a) In-guest veth pair across two network namespaces: AF_XDP native copy-mode, no host change, but not the virtio path.
   - (b) Add two extra guest NICs joined by a libvirt `type='udp'` link on host loopback (QEMU-owned unprivileged sockets, no bridge, NAT or firewall). That gives a real virtio path for AF_XDP and a DPDK virtio PMD on a NIC that isn't the passt uplink. It does open loopback UDP ports on the host.
   - Recommend (a) as the measured lane plus (b) as a probe in r06 S0 if you approve the loopback sockets.

## 7. r06 outline (Ch17–18), planned separately

- **Ch17, kernel bypass:**
  - Measured: AF_XDP on veth (and on virtio if Q8b is approved), comparing XDP_COPY against zero-copy where S1 found it available against a kernel UDP socket. Mechanism counters are syscalls per packet, wakeups and busy-poll CPU.
  - DPDK in the guest: virtio PMD on a dedicated NIC with guest hugepages and `vfio-pci` no-IOMMU or `uio_pci_generic`, labelled illustrative.
  - RDMA conceptual only.
  - Languages: C++ (libxdp/libbpf, DPDK) only. Java has no bypass API (FFM to libxdp is possible and named), OSS Aeron is UDP-only, and Aeron's DPDK transport is paid. Appendix F surveys OpenOnload/ef_vi.
  - Before/after cyclictest: on the isolated CPU next to a busy-poll receive core, IRQ-driven against polling.
  - New pins: libbpf, libxdp/xdp-tools, DPDK LTS.
  - Guest-only hugepages, never host.
- **Ch18, latency config as code:**
  - One versioned bundle (guest profiles, tuned profile, vcpupin map, sysctls) with a schema, plus apply/verify/rollback scripts.
  - CI lints and dry-runs the bundle.
  - A canary applies it to `lowlat-target` and gates promotion on a latency+jitter SLO (cyclictest p99.9 and scan-to-divert p99.9 bounds from Ch14–16 numbers), with rollback by snapshot. The promotion target is `lowlat-peer` (`LAB_PEER=1`) or a second snapshot.
  - Kubernetes rollout gating in prose, or an optional headless minikube analysis step, decided in r06.

## Follow-ups

| Item | Decision |
|---|---|
| User decisions, 2026-10-25 | Q1 split: yes, r05 = Ch14-16 and r06 = Ch17-18. Q3 vCPU pins: yes, vCPUs 2 and 3 pinned in the r05 snapshots only. Q6 tuned in the guest: yes, if the S1 bootloader probe is clean, else args only. Q7 Ch14 Java: one observed lane. Q2 (4 vCPUs), Q4 (hold 7.2.11-200.fc44) and Q5 (300 s lanes, abort on host load1 > 2) take the recommended defaults. Q8 is deferred to r06. |

