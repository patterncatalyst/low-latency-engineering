---
title: "r01 figures (S20)"
layout: plan
render_with_liquid: false
---

# r01 figures — S20

Two or more figures per chapter for Ch0–Ch4. One spec per figure in
`diagrams/NN-slug.py`, generated into `assets/diagrams/NN-slug.{svg,excalidraw}`
by `scripts/generate_diagram.py`. Never hand-edit generated files.

## Visual grammar (every figure)

- **Spec file**: the same shape as `diagrams/00-sortation-line.py`: docstring
  `Figure N.M — <title>.` plus the regenerate line, the `ROOT`/`sys.path`/`g.OUT`
  boilerplate, one `g.emit(...)`, and the `__main__` parse check printing
  `ok: <name>`.
- **Canvas**: width 880; height 300–460; 20 px margins; nothing outside the canvas.
- **Headline**: one note at the top centre (`x` 440, `y` 28, `anchor` middle,
  `size` 14, `bold`, `color` `#b8650a`) stating the figure's point.
- **Takeaway**: at most one note at the bottom centre, `size` 12, plain.
- **Style roles** (fixed across the set):
  - `accent`: the technique or subject of the figure
  - `user`: a user-space program (consumers, simulator, harnesses)
  - `kernel`: kernel, OS, clock, socket, hardware, belt
  - `ink`: a result or measurement output (report, histogram, percentile)
  - `sub`: a supporting station or step
  - `ghost`: something absent, not seen, or not measured
  - `band`: a container (host, guest, a run, a language lane); never a node
- **Edges**: `amber: True` only for the path the figure is about; `dashed: True`
  for "not seen", "back-filled" or "optional". Every edge ends on a box edge or
  another arrow, computed from box coordinates.
- **Three languages**: always in the order C++, Python, Java (top to bottom or
  left to right), style `user`, titled exactly `C++`, `Python`, `Java`.
- **Text**: ASCII only (`->`, `~`, `us`, `ms`, `x`); short labels, at most ~28
  characters per detail line. No mean anywhere: never draw or label a mean.
- **Numbers**: only configured parameters (rates, durations, sizes) or the S19
  values listed below, quoted as ranges across `r01-run1..3`.

## Figures

The "Shows" column is the brief each figure was drawn from (2026-10-21); measured values in it are from the first S19 runs. The current values are in each figure and its chapter.

| Name | Fig | Chapter | Shows |
|---|---|---|---|
| `00-sortation-line` | 0.1 | Ch0 | exists |
| `00-lab-topology` | 0.2 | Ch0 | host (unprivileged user space + Docker Engine; no NAT, bridge or firewall change) and the `lowlat-target` KVM guest (PREEMPT_RT kernel, Docker, cyclictest from `realtime-tests`, linuxptp, chrony, tuned); ssh over AF_VSOCK via libvirt-ssh-proxy; passt user-mode networking; snapshots `lab-ready` and `lab-ready-rt`; "VM numbers and bare-metal numbers are never compared" |
| `00-measurement-pipeline` | 0.3 | Ch0 | line-simulator (C++) -> UDP datagrams on 127.0.0.1 -> three consumers (C++, Python, Java) each recording into HdrHistogram -> `lowlat-report/1` JSON with the embedded machine profile (`profile.sh`) -> `lowlat-report check` (schema + decode + recompute percentiles) |
| `01-batch-vs-per-parcel` | 1.1 | Ch1 | same 1 kHz arrivals, two designs: per-parcel handles each on arrival; batch-32 holds parcels until 32 arrive, so the first waits ~31 ms; equal throughput (<1 % apart), batch p50 15.2–16.1 ms vs per-parcel p50 74–186 us |
| `01-bimodal-tail` | 1.2 | Ch1 | 1 parcel in 100 takes a ~2 ms slow path (busy loop, holds the core); the one or two parcels behind it queue; the median stays in the fast mode, p99 lands in the slow mode; a single summary number describes neither group |
| `02-littles-law` | 2.1 | Ch2 | the consumer as a queue: arrivals lambda = 1000/s in, L parcels in the system, residence W; L = lambda x W; L sampled vs lambda x W-bar agree within 0.4–4.0 % (C++ and Java); W-bar is a modelling input only, never a reported latency |
| `02-amdahl-phases` | 2.2 | Ch2 | one batch as a serial phase plus a parallel phase split over N workers with barriers, at N = 1, 2, 4; serial fraction s ~0.095–0.099; C++ at N=4 predicted 3.10–3.11x, measured 2.78–2.84x; Java predicted 3.09x, measured 2.70–2.74x; Python threads with the GIL < 1x |
| `03-three-clocks` | 3.1 | Ch3 | a parcel's timestamps: intended emit (the belt's schedule) -> actual send -> receipt -> done; which interval each variant measures: intended-time (from the schedule), receipt-time (from arrival), closed-loop (send-to-done of a request that waited for the previous one) |
| `03-coordinated-omission` | 3.2 | Ch3 | a 200 ms consumer stall at 1 kHz: the belt keeps emitting ~200 parcels; a closed-loop measurer waits and records one long sample, so its p99 stays under ~7 us (naive); correction back-fills the missed samples (dashed) and p99 becomes ~98–99 ms; intended-time p99 ~100–102 ms sees the stall directly |
| `04-three-harnesses` | 4.1 | Ch4 | the same check-digit workload in Google Benchmark (C++, `DoNotOptimize`, repetitions), pyperf (Python, worker processes + warm-ups) and JMH (Java, forks, warm-up iterations, `Blackhole`), each emitting percentiles (median, p99) rather than a single number |
| `04-dead-code-elimination` | 4.2 | Ch4 | guarded variant (result consumed by `DoNotOptimize` / `Blackhole`) vs eliminated variant (result unused, the compiler or JIT removes the work); the eliminated median is 472–476x lower in C++ and 3,200–3,300x lower in Java: the benchmark measured nothing |

## Values the figures may quote

Measured values come only from the committed runs
`examples/*/results/r01-run{1,2,3}/` (bare-metal host, `powersave`, `balanced`),
quoted as ranges across the three runs. Examples 00, 01, 02 and 04 were
re-measured on 2026-10-22 after code fixes (commits `759c56d`, `26a547c`) and
their figures were updated to the new ranges; 03 keeps its 2026-10-21 runs.
This page lists no numbers, so it cannot drift from the results.

## Status

| Step | Status |
|---|---|
| Generator seeded per figure (byte-identical regeneration) | done |
| Ch0 + Ch1 figures | done |
| Ch2 figures | done |
| Ch3 + Ch4 figures | done |
| `_data/diagrams.yml` + `assets/diagrams/README.md` wiring | done |
| Opus validation | done: 8/8 criteria met after fixes (numbers, semantics, style roles, geometry) |
