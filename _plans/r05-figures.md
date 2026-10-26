---
title: "r05 figures (S13)"
layout: plan
render_with_liquid: false
---

# r05 figures: S13

Three figures per chapter for Ch14-Ch16 (Part 5, first half). One spec per figure in `diagrams/NN-slug.py`, generated into `assets/diagrams/NN-slug.{svg,excalidraw}` by `scripts/generate_diagram.py`; never hand-edited.

Visual grammar as [r01-figures.md](r01-figures.md):
- canvas 880 wide, 300-460 high;
- headline note at `x` 440, `y` 28, size 14, bold, `#b8650a`;
- at most one takeaway;
- edges end on box edges;
- languages in the order C++, Python, Java (Part 5 has no Python lane; Java appears in 14.2 and 15.3 only);
- ASCII; no mean, and no cyclictest `Avg`;
- captions `Figure N.x: ...` with a colon, no em dash.

Every measured value is lane `vm` and says so (one "lane vm, lowlat-target, 4 vCPU" note per figure is enough). Host CPU indices never appear; the pinned vCPUs are drawn as "vCPU 2 -> host CPU (pinned)" and "vCPU 3 -> host CPU (pinned)". The diverter window is drawn as a `model` band written `+/-0.8 ms` (ASCII), labelled so, never as a measurement.

## Figures

| Name | Fig | Chapter | Purpose | Layout sketch | Numbers from S12 |
|---|---|---|---|---|---|
| `14-preemption-ladder` | 14.1 | Ch14 | Where a SCHED_FIFO thread waits after its timer fires under `lazy`, `full` and PREEMPT_RT | Three horizontal lanes, one per model, on a shared time axis from "timer fires" to "thread runs". Lazy: a SCHED_NORMAL holder keeps the CPU up to one tick (amber), then a non-preemptible section. Full: preempted at the next preemption point. RT: hard-IRQ stub, `irq/N` thread at FIFO 50, `ktimers` at FIFO 1, spinlock as rtmutex. A right-hand column per lane: cyclictest p99.9 and max ("worst of N samples") | cyclictest p99, p99.9, max per lane (`stock-lazy`, `stock-full`, `rt`); `irq/` and `ktimers` counts per snapshot (exact) |
| `14-wake-path-in-a-vm` | 14.2 | Ch14 | The part of the wake path RT can't reach | Two nested bands: guest (timer IRQ, scheduler, FIFO thread; the Java lane's safepoint as a user-space pause beside it) inside the host (vCPU thread, host scheduler, VM exit and entry). Amber arrows mark host-side preemption and steal. Takeaway: "RT bounds the guest's share; steal and safepoints stay" | steal ticks per lane over its total ticks; Java wake p99.9 and safepoint count per kernel (observed) |
| `14-priority-inversion` | 14.3 | Ch14 | Priority inversion and PI on one CPU | Two timelines on one CPU. `plain-mutex`: low (FIFO 10) holds the lock, medium (FIFO 50) spins 20 ms bursts, high (FIFO 90) waits through them (amber). `pi-mutex`: low inherits 90, finishes its 1 ms, high runs. Wait p99 per variant on the right | high-priority wait p99 for `plain-mutex` and `pi-mutex`; the ratio (by construction, labelled so) |
| `15-partition-map` | 15.1 | Ch15 | Housekeeping against isolated CPUs in the 4-vCPU guest | Four vCPU columns: 0-1 housekeeping (kthreads, `rcuox`, workqueues, IRQs, ssh, simulator, noise), 2-3 isolated (decide thread on 2, cyclictest on 3). Rows: tick, RCU callbacks, IRQs, kthreads, tasks. Each row names the parameter that moves it (`nohz_full`, `rcu_nocbs`, `irqaffinity` and tuned, `isolcpus=domain`) | LOC per second on CPU 2 with one busy task, `shared` and `isolated` (exact); `/sys/.../isolated` and `nohz_full` values |
| `15-noise-paths` | 15.2 | Ch15 | The five paths noise takes to the measured thread, and which isolation closes | Noise sources on the left (stress-ng CPU, disk I/O, stream/cache, host work), the measured thread on vCPU 3 on the right, five arrows: scheduler, IRQ (managed virtio-blk completes on the submitting CPU), tick, cache and memory bandwidth, host. Closed paths in neutral, open paths (cache, host) in amber | cyclictest p99.9 on CPU 3 for `shared`, `isolated`, `cache-noise`, `irq-on-measure-cpu`; virtio-blk interrupts on CPU 3 for `irq-steered` and `irq-on-measure-cpu` (exact) |
| `15-jvm-under-isolcpus` | 15.3 | Ch15 | Why `taskset` on the whole JVM misplaces it, and the hot-thread alternative | Left: `taskset -c 2,3 java` with the JVM's threads (GC, JIT, VM thread, hot thread) piled onto CPU 2, CPU 3 idle (no balancing under `isolcpus=domain`). Right: JVM on 0-1, only the hot thread on CPU 3 | JVM thread count seen on 2-3 per lane (exact); hot thread involuntary switches (exact) |
| `16-what-cyclictest-measures` | 16.1 | Ch16 | Intended against actual wake, and the missed-period skip | One time axis with ticks every interval (intended wakes, absolute); actual wakes as offsets, latency = actual minus intended. One long stall spanning three intervals records one late sample, the skipped wakes drawn hollow and labelled "not sampled" | parameters only (interval 1,000 us, 300 s); the `method` sample count against duration / interval (exact) |
| `16-naive-vs-method` | 16.2 | Ch16 | What each option does to the number | Two columns, `naive` and `method`, rows per setting: policy and priority, `mlockall`, pinning, clock (`CLOCK_REALTIME` default at v2.11 against `--clock=monotonic`), duration and samples, histogram and overflow. Bottom row: p99, p99.9, max per lane | p99, p99.9, max per lane; sample count and overflow (exact); policy in effect (exact) |
| `16-timerlat-attribution` | 16.3 | Ch16 | Splitting a spike into IRQ latency and thread latency | One wake drawn as timer expiry, IRQ handler start (IRQ latency), thread start (thread latency), return to user. Underneath, what delays each part: SMIs, NMIs and masked interrupts for the IRQ part; other threads and IRQs for the thread part. Note: "tracefs path, the RT build has no BTF" | timerlat IRQ and thread latency p99 and max on CPU 3 (observed) |

## Values the figures may quote

Parameters:
- 4 vCPU guest, housekeeping 0-1, isolated 2-3;
- cyclictest FIFO 95, interval 1,000 us, 300 s per lane, histogram 20,000 us;
- `naive`: defaults, 10 s;
- load: `hackbench` + `stress-ng --cpu` on all 4 vCPUs (Ch14), noise on 0-1 (Ch15, Ch16), with the S11 load mix from the READMEs;
- PI demo: FIFO 10 low holding 1 ms, FIFO 50 medium spinning 20 ms bursts, FIFO 90 high;
- line 10 kHz x 20 s, 200,000 parcels;
- timerlat 120 s on CPU 3, threshold from S11;
- HZ 1000;
- the diverter window ±0.8 ms (±2 mm at 2.5 m/s), a `model` input.

Code and kernel constants, not measurements:
- threaded IRQ handlers at SCHED_FIFO 50, `ktimers` at SCHED_FIFO 1 (S0 fact rows);
- fair server 50 ms per 1000 ms; `sched_rt_runtime_us` 1000000 at v7.2;
- `nohz_full` residual 1 Hz on housekeeping CPUs (kernel docs).

Measured values come only from the committed runs `examples/14-preempt-rt/results/r05-vm-run{1,2,3}/`, `examples/15-cpu-partitioning/results/r05-vm-run{1,2,3}/` and `examples/16-cyclictest/results/r05-vm-run{1,2,3}/`, all under `vm/<lane>/altN/`. S1 probe values (`dependency-pins.md`, "r05 guest probes") may appear in a figure only as context the chapter also states, labelled "S1 probe", never in place of an S12 value. Each figure quotes a range across the three runs; no mean. A ratio is the run's median over its 3 alternations, quoted as the range of the three runs' medians. Exact counters (`irq/` threads, `ktimers`, LOC per second, interrupt deltas, thread counts, samples, overflows, policy) are single values. Rounding rule for the book: times in us, ms and s truncate (percentiles, as HdrHistogram reports a value and `verify.log` prints it, and times derived from kernel counters such as `throttled_usec`); ratios, per-parcel rates and derived byte counts round to the digits shown; a per-task byte count is the report's integer field as the producer wrote it (truncated). Figures and chapters follow the same rule. Every value below is extracted by one script (session scratchpad, `s13/extract.py`) and its output is pasted here: value, source and field, runs 1-3 as quoted, run 1/2/3.

| Figure and value | Source and field | Runs 1-3 (as quoted) | Run 1, run 2, run 3 |
|---|---|---|---|
| (S13 fills this table from S12; one row per value named in the Figures table above) | | | |

Deviations from the figure list above are recorded here so the chapters (S14-S16) state them.

- (S13 records them.)

## Status

| Step | Status |
|---|---|
| figure list and layouts (S2) | done |
| specs and generated files (S13) | todo |
| `_data/diagrams.yml` entries (S13) | todo |
| value table from S12 (S13) | todo |
| chapters embed the figures (S14-S16) | todo |
