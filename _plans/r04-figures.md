---
title: "r04 figures (S12)"
layout: plan
render_with_liquid: false
---

# r04 figures: S12

Two or more figures per chapter for Ch11–Ch13 (Part 4). One spec per figure in `diagrams/NN-slug.py`, generated into `assets/diagrams/NN-slug.{svg,excalidraw}` by `scripts/generate_diagram.py`; never hand-edited.

Visual grammar as [r01-figures.md](r01-figures.md):
- canvas 880 wide, 300–460 high;
- headline note at `x` 440, `y` 28, size 14, bold, `#b8650a`;
- at most one takeaway;
- edges end on box edges;
- languages in the order C++, Python, Java;
- ASCII; no mean;
- captions `Figure N.x: …` with a colon.

Ch13 figures label every measured value with its lane (`host`, `vm`, `container`).

## Figures

| Name | Fig | Chapter | Shows |
|---|---|---|---|
| `11-who-holds-the-wait` | 11.1 | Ch11 | Three lanes of 10,000 waiting lookups: OS threads each with a kernel stack and a reserved user stack, fibers and virtual threads with a small user-space stack (fiber stack size, VT stack chunk on the heap), coroutines with a heap frame of measured bytes; bytes per wait and RSS for 10,000, from S11 |
| `11-switch-path` | 11.2 | Ch11 | One round trip three ways: thread A futex-wake, kernel schedule, thread B (amber kernel crossing); fiber context swap in user space; coroutine resume by symmetric transfer; voluntary switches per round trip and round-trip p50 |
| `11-blocking-in-a-fiber` | 11.3 (optional) | Ch11 | One carrier thread running several fibers; one makes a blocking 2 ms call and every other fiber's wake slides right; the asyncio twin as a ghost row; neighbour wake lateness |
| `12-readiness-vs-completion` | 12.1 | Ch12 | Left: `epoll_wait` returns "ready", then `recvmsg` per datagram (two crossings per parcel). Right: io_uring submission and completion rings with a multishot `recvmsg` and a provided buffer ring, one `io_uring_enter` reaping many CQEs; syscalls per parcel |
| `12-thread-per-core` | 12.2 | Ch12 | Four cameras into four `SO_REUSEPORT` sockets, each owned by one pinned thread with its own ring (shared nothing), against one receive thread fanning out through the Ch10 MPSC queue to four workers; hand-offs per parcel and saturation p99 |
| `12-vt-vs-event-loop` | 12.3 | Ch12 | Quarkus service at λ with a 2 ms dependency: event-loop threads with a non-blocking timer; a worker pool of 16 with a queue building in front when λW > 16 (Little's law, Ch2); virtual threads mounted on carriers and unmounted while sleeping; the `blocking-on-event-loop` defect as an amber stall; p99 per variant |
| `13-three-places` | 13.1 | Ch13 | Nested bands: laptop host (bare metal) holding the KVM guest holding a Docker container; what each layer adds on the path from simulator to decide (VM exits and steal, veth and bridge, cgroup controllers, seccomp filter); jitter floor and end-to-end p99 per lane, labelled |
| `13-quota-vs-cpuset` | 13.2 | Ch13 | Timeline of 100 ms CFS periods: four workers under `--cpus=2` burn the quota early and the cgroup is throttled to the period edge (amber gaps, `nr_throttled`), against `--cpuset-cpus=2,3` with no budget and no gaps; consumer p99.9 per lane. An original drawing, not the companion site's Figure 32.1 |
| `13-cpu-count-views` | 13.3 (optional) | Ch13 | One container, three answers: `hardware_concurrency()`, `os.process_cpu_count()`, `availableProcessors()` under quota and under cpuset, and the pool sizes each runtime derives |

## Values the figures may quote

Parameters:
- 10,000 parked tasks;
- 1,000,000 round trips in batches of 1,000;
- 2 ms lookup wait;
- 10 kHz x 20 s;
- four cameras at 2.5 kHz x 20 s and the S10 saturation rate;
- worker pool 16 and the S10 λ;
- `--cpus=2`, `--cpuset-cpus=2,3`, 4 vCPU guest;
- 100 ms CFS period (Docker default, S0 citation).

Code constants, not measurements:
- fiber stack 64 KiB (`protected_fixedsize_stack`);
- `ulimit -s` from the profile;
- image tags and digests from `IMAGES.lock`.

Measured values come only from the committed runs `examples/11-stackful-stackless/results/r04-run{1,2,3}/`, `examples/12-io-engines/results/r04-run{1,2,3}/` and `examples/13-where-code-runs/results/r04-run{1,2,3}/{host,vm,container-*}/`. Each figure quotes a range across the three runs; no mean. A ratio is the run's median over its 3 alternations, quoted as the range of the three runs' medians. Exact counters (frame bytes, syscalls per parcel, hand-offs, `nr_throttled`, CPU counts, errno) are single values. Every value below is extracted by one script (session scratchpad, `s12/extract.py`) and its output is pasted here: value, source and field, runs 1–3 as quoted, run 1/2/3.

| Figure and value | Source and field | Runs 1-3 (as quoted) | Run 1, run 2, run 3 |
|---|---|---|---|
| (filled at S12) | | | |

Deviations from the figure list above are recorded here so the chapters (S13–S15) state them.

## Status

| Step | Status |
|---|---|
| specs and generated files | todo |
| `_data/diagrams.yml` entries | todo |
| chapters embed the figures (S13-S15) | todo |
