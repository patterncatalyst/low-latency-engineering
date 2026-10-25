---
title: "r04 figures (S12)"
layout: plan
render_with_liquid: false
---

# r04 figures: S12

Two or more figures per chapter for Ch11-Ch13 (Part 4). One spec per figure in `diagrams/NN-slug.py`, generated into `assets/diagrams/NN-slug.{svg,excalidraw}` by `scripts/generate_diagram.py`; never hand-edited.

Visual grammar as [r01-figures.md](r01-figures.md):
- canvas 880 wide, 300-460 high;
- headline note at `x` 440, `y` 28, size 14, bold, `#b8650a`;
- at most one takeaway;
- edges end on box edges;
- languages in the order C++, Python, Java;
- ASCII; no mean;
- captions `Figure N.x: ...` with a colon.

Ch13 figures label every measured value with its lane (`host`, `vm`, `container`).

## Figures

| Name | Fig | Chapter | Shows |
|---|---|---|---|
| `11-who-holds-the-wait` | 11.1 | Ch11 | Three lanes of 10,000 waiting lookups: OS threads each with a kernel stack and a reserved user stack, fibers and virtual threads with a small user-space stack (fiber stack size, VT stack chunk on the heap), coroutines with a heap frame of measured bytes; bytes per wait and RSS for 10,000, from S11 |
| `11-switch-path` | 11.2 | Ch11 | One round trip three ways: thread A futex-wake, kernel schedule, thread B (amber kernel crossing); fiber context swap in user space; coroutine resume by symmetric transfer; voluntary switches per round trip and round-trip p50 |
| `11-blocking-in-a-fiber` | 11.3 (optional) | Ch11 | One carrier thread running several fibers; one makes a blocking 2 ms call and every other fiber's wake slides right; the asyncio twin as a ghost row; neighbour wake lateness |
| `12-readiness-vs-completion` | 12.1 | Ch12 | Left: `epoll_wait` returns "ready", then `recvmsg` per datagram (two crossings per parcel). Right: io_uring submission and completion rings with a multishot `recvmsg` and a provided buffer ring, one `io_uring_enter` reaping many CQEs; syscalls per parcel |
| `12-thread-per-core` | 12.2 | Ch12 | Four cameras into four `SO_REUSEPORT` sockets, each owned by one pinned thread with its own ring (shared nothing), against one receive thread fanning out through the Ch10 MPSC queue to four workers; hand-offs per parcel and saturation p99 |
| `12-vt-vs-event-loop` | 12.3 | Ch12 | Quarkus service at lambda with a 2 ms dependency: event-loop threads with a non-blocking timer; a worker pool of 16 with a queue building in front when lambda x W > 16 (Little's law, Ch2); virtual threads mounted on carriers and unmounted while sleeping; the `blocking-on-event-loop` defect as an amber stall; p99 per variant |
| `13-three-places` | 13.1 | Ch13 | Nested bands: bare-metal host holding the KVM guest holding a Docker container; what each layer adds on the path from simulator to decide (VM exits and steal, veth and bridge, cgroup controllers, seccomp filter); jitter floor and end-to-end p99 per lane, labelled |
| `13-quota-vs-cpuset` | 13.2 | Ch13 | Timeline of 100 ms CFS periods: four workers under `--cpus=2` burn the quota early and the cgroup is throttled to the period edge (amber gaps, `nr_throttled`), against `--cpuset-cpus=2,3` with no budget and no gaps; consumer p99.9 per lane. An original drawing, not the companion site's Figure 32.1 |
| `13-cpu-count-views` | 13.3 (optional) | Ch13 | One container, three answers: `hardware_concurrency()`, `os.process_cpu_count()`, `availableProcessors()` under quota and under cpuset, and the pool sizes each runtime derives |

## Values the figures may quote

Parameters:
- 10,000 parked tasks;
- 1,000,000 round trips in batches of 1,000;
- 2 ms lookup wait;
- 10 kHz x 20 s;
- four cameras at 2.5 kHz x 20 s and the S10 saturation rate;
- worker pool 16 and the S10 lambda;
- `--cpus=2`, `--cpuset-cpus=2,3`, 4 vCPU guest;
- 100 ms CFS period (Docker default, S0 citation).

Code constants, not measurements:
- fiber stack 64 KiB (`protected_fixedsize_stack`);
- `ulimit -s` from the profile;
- image tags and digests from `IMAGES.lock`.

Measured values come only from the committed runs `examples/11-stackful-stackless/results/r04-run{1,2,3}/`, `examples/12-io-engines/results/r04-run{1,2,3}/` and `examples/13-where-code-runs/results/r04-run{1,2,3}/{host,vm,container-*}/`. Each figure quotes a range across the three runs; no mean. A ratio is the run's median over its 3 alternations, quoted as the range of the three runs' medians. Exact counters (frame bytes, syscalls per parcel, hand-offs, `nr_throttled`, CPU counts, errno) are single values. Rounding rule for the book: percentile times in us, ms and s truncate, as HdrHistogram reports a value and `verify.log` prints it; ratios, per-parcel rates and byte counts round to the digits shown. Figures and chapters follow the same rule. Every value below is extracted by one script (session scratchpad, `s12/extract.py`) and its output is pasted here: value, source and field, runs 1-3 as quoted, run 1/2/3.

| Figure and value | Source and field | Runs 1-3 (as quoted) | Run 1, run 2, run 3 |
|---|---|---|---|
| Fig 11.1 C++ os-thread: RSS per task (B) | `cpp-parked-os-thread.json runtime.counters.rss_bytes_per_task` | 8,774-8,778 | 8,774, 8,778, 8,774 |
| Fig 11.1 C++ os-thread: address space per task (B) | `cpp-parked-os-thread.json runtime.counters.vm_size_bytes_per_task` | 9,245,449 | 9,245,449, 9,245,449, 9,245,449 |
| Fig 11.1 C++ os-thread: kernel stack per task (B) | `cpp-parked-os-thread.json runtime.counters.kernel_stack_delta_kib * 1024 / tasks` | 16,380-16,384 | 16,384, 16,380, 16,381 |
| Fig 11.1 C++ os-thread: RSS + page tables + kernel stack per task (B) | `cpp-parked-os-thread.json runtime.counters.rss_page_tables_kernel_stack_bytes_per_task` | 29,356-29,360 | 29,359, 29,360, 29,356 |
| Fig 11.1 C++ fiber: RSS per task (B) | `cpp-parked-fiber.json runtime.counters.rss_bytes_per_task` | 4,106 | 4,106, 4,106, 4,106 |
| Fig 11.1 C++ fiber: address space per task (B) | `cpp-parked-fiber.json runtime.counters.vm_size_bytes_per_task` | 69,645 | 69,645, 69,645, 69,645 |
| Fig 11.1 C++ fiber: RSS + page tables + kernel stack per task (B) | `cpp-parked-fiber.json runtime.counters.rss_page_tables_kernel_stack_bytes_per_task` | 4,242-4,256 | 4,256, 4,242, 4,242 |
| Fig 11.1 C++ coroutine: RSS per task (B) | `cpp-parked-coroutine.json runtime.counters.rss_bytes_per_task` | 1,009 | 1,009, 1,009, 1,009 |
| Fig 11.1 C++ coroutine: address space per task (B) | `cpp-parked-coroutine.json runtime.counters.vm_size_bytes_per_task` | 26 | 26, 26, 26 |
| Fig 11.1 Java platform-thread: RSS per task (B) | `java-parked-platform-thread.json runtime.counters.rss_bytes_per_task` | 22,805-22,898 | 22,805, 22,898, 22,816 |
| Fig 11.1 Java platform-thread: address space per task (B) | `java-parked-platform-thread.json runtime.counters.vm_size_bytes_per_task` | 1,044,486-1,044,591 | 1,044,486, 1,044,591, 1,044,591 |
| Fig 11.1 Java platform-thread: kernel stack per task (B) | `java-parked-platform-thread.json runtime.counters.kernel_stack_delta_kib * 1024 / tasks` | 16,343-16,386 | 16,382, 16,386, 16,343 |
| Fig 11.1 Java platform-thread: RSS + page tables + kernel stack per task (B) | `java-parked-platform-thread.json runtime.counters.rss_page_tables_kernel_stack_bytes_per_task` | 41,204-41,322 | 41,232, 41,322, 41,204 |
| Fig 11.1 Java virtual-thread: RSS per task (B) | `java-parked-virtual-thread.json runtime.counters.rss_bytes_per_task` | 2,870-3,260 | 2,870, 3,260, 3,073 |
| Fig 11.1 Java virtual-thread: address space per task (B) | `java-parked-virtual-thread.json runtime.counters.vm_size_bytes_per_task` | 27,262-34,078 | 34,078, 27,262, 27,262 |
| Fig 11.1 Java virtual-thread: RSS + page tables + kernel stack per task (B) | `java-parked-virtual-thread.json runtime.counters.rss_page_tables_kernel_stack_bytes_per_task` | 2,888-3,276 | 2,888, 3,276, 3,088 |
| Fig 11.1 C++ fiber: stack (B) | `cpp-parked-fiber.json runtime.counters.fiber_stack_bytes (code constant kFiberStackBytes)` | 65,536 | 65,536, 65,536, 65,536 |
| Fig 11.1 parked tasks per run (exact) | `cpp-parked-fiber.json runtime.counters.tasks_armed` | 10,000 | 10,000, 10,000, 10,000 |
| Fig 11.1 shared timer wait (ms); parsed from the notes string because the report has no numeric field for it | `cpp-parked-fiber.json notes (wait_ms=N)` | 1,000 | 1,000, 1,000, 1,000 |
| Fig 11.1 C++ coroutine: heap frame per task (B) | `cpp-parked-coroutine.json runtime.counters.frame_bytes_per_task` | 208 | 208, 208, 208 |
| Fig 11.1 Java virtual-thread: heap per task (B) | `java-parked-virtual-thread.json runtime.counters.heap_bytes_per_task` | 2,063-2,105 | 2,082, 2,105, 2,063 |
| Fig 11.1 Java platform-thread: heap per task (B) | `java-parked-platform-thread.json runtime.counters.heap_bytes_per_task` | 276 | 276, 276, 276 |
| Fig 11.1 Python (gil build) threads: RSS per task (B) | `python/python-gil-parked-threads.json runtime.counters.rss_bytes_per_task` | 19,228-19,247 | 19,228, 19,247, 19,237 |
| Fig 11.1 Python (gil build) threads: address space per task (B) | `python/python-gil-parked-threads.json runtime.counters.vm_size_bytes_per_task` | 9,266,672-9,266,776 | 9,266,685, 9,266,672, 9,266,776 |
| Fig 11.1 Python (gil build) asyncio tasks: RSS per task (B) | `python/python-gil-parked-asyncio-tasks.json runtime.counters.rss_bytes_per_task` | 2,611-2,614 | 2,611, 2,614, 2,612 |
| Fig 11.1 Python (gil build) asyncio tasks: address space per task (B) | `python/python-gil-parked-asyncio-tasks.json runtime.counters.vm_size_bytes_per_task` | 2,569 | 2,569, 2,569, 2,569 |
| Fig 11.1 Python (gil build) asyncio tasks: tracemalloc per task (B) | `python/python-gil-parked-asyncio-tasks.json runtime.counters.tracemalloc_bytes_per_task` | 1,641 | 1,641, 1,641, 1,641 |
| Fig 11.1 C++ os-thread: default user stack reserved (KiB) | `cpp-parked-os-thread.json notes (stack=default (N KiB virtual)); parsed from the notes string, the ulimit -s value the run recorded` | 8,192 | 8,192, 8,192, 8,192 |
| Fig 11.2 C++ os-thread: round-trip p50 (ns), per-run median of 3 alternations | `cpp-pingpong-os-thread-alt{1,2,3}.json percentiles.p50` | 3,755-3,777 | 3,755, 3,777, 3,757 |
| Fig 11.2 C++ fiber: round-trip p50 (ns), per-run median of 3 alternations | `cpp-pingpong-fiber-alt{1,2,3}.json percentiles.p50` | 205-207 | 205, 206, 207 |
| Fig 11.2 C++ coroutine: round-trip p50 (ns), per-run median of 3 alternations | `cpp-pingpong-coroutine-alt{1,2,3}.json percentiles.p50` | 7-18 | 7, 8, 18 |
| Fig 11.2 Java platform-thread: round-trip p50 (ns), per-run median of 3 alternations | `java-pingpong-platform-thread-alt{1,2,3}.json percentiles.p50` | 4,115-4,175 | 4,115, 4,175, 4,167 |
| Fig 11.2 Java virtual-thread: round-trip p50 (ns), per-run median of 3 alternations | `java-pingpong-virtual-thread-alt{1,2,3}.json percentiles.p50` | 399-404 | 399, 400, 404 |
| Fig 11.2 Python (gil build) threads: round-trip p50 (ns), one measurement per run | `python/python-gil-pingpong-threads.json percentiles.p50` | 4,011-4,029 | 4,025, 4,011, 4,029 |
| Fig 11.2 Python (gil build) asyncio tasks: round-trip p50 (ns), one measurement per run | `python/python-gil-pingpong-asyncio-tasks.json percentiles.p50` | 3,785-3,819 | 3,819, 3,785, 3,807 |
| Fig 11.2 C++ os-thread: voluntary switches per round trip, lowest of 3 alternations | `cpp-pingpong-os-thread-alt{1,2,3}.json runtime.ctx_switches.voluntary / runtime.counters.round_trips_served` | 2.000 | 2.000, 2.000, 2.000 |
| Fig 11.2 Java platform-thread: voluntary switches per round trip, lowest of 3 alternations | `java-pingpong-platform-thread-alt{1,2,3}.json runtime.ctx_switches.voluntary / runtime.counters.round_trips_served` | 2.000 | 2.000, 2.000, 2.000 |
| Fig 11.2 C++ fiber: voluntary switches in 1,020,000 round trips, highest of 3 alternations (exact) | `cpp-pingpong-fiber-alt{1,2,3}.json runtime.ctx_switches.voluntary` | 0 | 0, 0, 0 |
| Fig 11.2 C++ coroutine: voluntary switches in 1,020,000 round trips, highest of 3 alternations (exact) | `cpp-pingpong-coroutine-alt{1,2,3}.json runtime.ctx_switches.voluntary` | 0 | 0, 0, 0 |
| Fig 11.2 Java virtual-thread: voluntary switches in 1,020,000 round trips, highest of 3 alternations (exact) | `java-pingpong-virtual-thread-alt{1,2,3}.json runtime.ctx_switches.voluntary` | 2-6 (varies; flagged) | 2, 6, 5 |
| Fig 11.2 C++ round-trip p50 ratio, os-thread over fiber (per-run median of 3 per-alternation ratios) | `cpp-pingpong-{os-thread,fiber}-alt{1,2,3}.json percentiles.p50` | 18.25-18.33x | 18.28x, 18.33x, 18.25x |
| Fig 11.2 Java round-trip p50 ratio, platform-thread over virtual-thread (per-run median of 3 per-alternation ratios) | `java-pingpong-{platform-thread,virtual-thread}-alt{1,2,3}.json percentiles.p50` | 10.28-10.48x | 10.29x, 10.48x, 10.28x |
| Fig 11.3 C++ os-thread: neighbours' wake lateness p99 (us), per-run median of 3 alternations | `cpp-neighbours-os-thread-alt{1,2,3}.json percentiles.p99` | 63 | 63, 63, 63 |
| Fig 11.3 C++ fiber, no blocking call: neighbours' wake lateness p99 (us), per-run median of 3 alternations | `cpp-neighbours-fiber-alt{1,2,3}.json percentiles.p99` | 52 | 52, 52, 52 |
| Fig 11.3 C++ fiber, 2 ms blocking call: neighbours' wake lateness p99 (us), per-run median of 3 alternations | `cpp-neighbours-fiber-blocking-alt{1,2,3}.json percentiles.p99` | 1,917-1,952 | 1,951, 1,917, 1,952 |
| Fig 11.3 C++ coroutine: neighbours' wake lateness p99 (us), per-run median of 3 alternations | `cpp-neighbours-coroutine-alt{1,2,3}.json percentiles.p99` | 4-5 | 4, 4, 5 |
| Fig 11.3 C++ fiber, 2 ms blocking call: wake lateness p99 (us), lowest of 3 alternations (the verify.sh criterion 5 statistic) | `cpp-neighbours-fiber-blocking-alt{1,2,3}.json percentiles.p99` | 1,902-1,937 | 1,914, 1,902, 1,937 |
| Fig 11.3 C++ fiber, 2 ms blocking call: blocking calls per run (exact) | `cpp-neighbours-fiber-blocking-alt{1,2,3}.json runtime.counters.blocking_calls` | 50 | 50, 50, 50 |
| Fig 11.3 C++ fiber, 2 ms blocking call: blocking call length (us) | `cpp-neighbours-fiber-blocking-alt{1,2,3}.json runtime.counters.blocking_call_us` | 2,000 | 2,000, 2,000, 2,000 |
| Fig 11.3 C++ neighbours: tasks per run (exact) | `cpp-neighbours-fiber-blocking-alt{1,2,3}.json runtime.counters.tasks` | 1,000 | 1,000, 1,000, 1,000 |
| Fig 11.3 Python (gil build) asyncio, no blocking call: wake lateness p99 (us), one measurement per run | `python/python-gil-neighbours-asyncio-tasks.json percentiles.p99` | 1,305-1,308 | 1,308, 1,307, 1,305 |
| Fig 11.3 Python (gil build) asyncio, 2 ms blocking call: wake lateness p99 (us), one measurement per run | `python/python-gil-neighbours-asyncio-tasks-blocking.json percentiles.p99` | 2,672-2,859 | 2,727, 2,859, 2,672 |
| Fig 11.3 Python asyncio neighbours: tasks per run (exact) | `python/python-gil-neighbours-asyncio-tasks-blocking.json runtime.counters.tasks` | 50 | 50, 50, 50 |
| Fig 12.1 epoll: system calls per parcel (load-dependent; per-run median of 3 alternations) | `cpp/epoll-sat-alt{1,2,3}.json runtime.counters.syscalls / parcels` | 1.379-1.417 | 1.379, 1.417, 1.403 |
| Fig 12.1 epoll: epoll_wait calls per parcel | `cpp/epoll-sat-alt{1,2,3}.json runtime.counters.epoll_wait_calls / parcels` | 0.379-0.417 | 0.379, 0.417, 0.403 |
| Fig 12.1 epoll: recvmsg calls per parcel (exact) | `cpp/epoll-sat-alt{1,2,3}.json runtime.counters.recvmsg_calls / parcels` | 1.000 | 1.000, 1.000, 1.000 |
| Fig 12.1 recvmmsg: system calls per parcel (load-dependent) | `cpp/recvmmsg-sat-alt{1,2,3}.json runtime.counters.syscalls / parcels` | 0.573-0.614 | 0.573, 0.613, 0.614 |
| Fig 12.1 io-uring: io_uring_enter calls per parcel (load-dependent) | `cpp/io-uring-sat-alt{1,2,3}.json runtime.counters.io_uring_enter_calls / parcels` | 0.062-0.068 | 0.065, 0.062, 0.068 |
| Fig 12.1 io-uring: system calls per parcel (load-dependent) | `cpp/io-uring-sat-alt{1,2,3}.json runtime.counters.syscalls / parcels` | 0.062-0.068 | 0.065, 0.062, 0.068 |
| Fig 12.1 io-uring: completions (CQEs) per io_uring_enter (load-dependent) | `cpp/io-uring-sat-alt{1,2,3}.json runtime.counters.cqes / io_uring_enter_calls` | 14.7-16.2 | 15.4, 16.2, 14.7 |
| Fig 12.1 io-uring: parcels per run (exact; 60 kHz x 4 cameras x 3 s) | `cpp/io-uring-sat-alt{1,2,3}.json runtime.counters.parcels` | 720,000 | 720,000, 720,000, 720,000 |
| Fig 12.2 thread-per-core: hand-offs per parcel (exact) | `cpp/thread-per-core-sat-alt{1,2,3}.json runtime.counters.handoffs / parcels` | 0 | 0, 0, 0 |
| Fig 12.2 acceptor-pool: hand-offs per parcel (exact) | `cpp/acceptor-pool-sat-alt{1,2,3}.json runtime.counters.handoffs / parcels` | 1 | 1, 1, 1 |
| Fig 12.2 thread-per-core: saturation p99 (us), per-run median of 3 alternations (observed) | `cpp/thread-per-core-sat-alt{1,2,3}.json percentiles.p99` | 68-69 | 69, 68, 68 |
| Fig 12.2 acceptor-pool: saturation p99 (us), per-run median of 3 alternations (observed) | `cpp/acceptor-pool-sat-alt{1,2,3}.json percentiles.p99` | 84-90 | 90, 89, 84 |
| Fig 12.2 saturation p99 ratio, thread-per-core over acceptor-pool (per-run median of 3 per-alternation ratios; observed, not asserted) | `cpp/{thread-per-core,acceptor-pool}-sat-alt{1,2,3}.json percentiles.p99` | 0.77-0.82x | 0.77x, 0.77x, 0.82x |
| Fig 12.2 acceptor thread busy share of its receive window (permille; the layout guard, 750-900), per-run median of 3 alternations | `cpp/acceptor-pool-sat-alt{1,2,3}.json runtime.counters.receiver_busy_permille_max` | 820-822 | 822, 821, 820 |
| Fig 12.2 thread-per-core busiest receiver busy share (permille), per-run median of 3 alternations | `cpp/thread-per-core-sat-alt{1,2,3}.json runtime.counters.receiver_busy_permille_max` | 384 | 384, 384, 384 |
| Fig 12.2 thread-per-core: receiver threads (exact) | `cpp/thread-per-core-sat-alt{1,2,3}.json runtime.counters.threads` | 4 | 4, 4, 4 |
| Fig 12.2 acceptor-pool: pinned threads, 1 acceptor + 4 workers (exact) | `cpp/acceptor-pool-sat-alt{1,2,3}.json runtime.counters.threads` | 5 | 5, 5, 5 |
| Fig 12.2 thread-per-core: line-rate p99 (us), 2.5 kHz x 4 cameras (observed, one measurement per run) | `cpp/thread-per-core-line.json percentiles.p99` | 98-115 | 112, 98, 115 |
| Fig 12.2 acceptor-pool: line-rate p99 (us), 2.5 kHz x 4 cameras (observed, one measurement per run) | `cpp/acceptor-pool-line.json percentiles.p99` | 91-113 | 91, 113, 93 |
| Fig 12.3 event-loop: p99 (ms), per-run median of 3 alternations | `quarkus/event-loop-alt{1,2,3}.json percentiles.p99` | 9.0-10.3 | 9.0, 10.3, 9.5 |
| Fig 12.3 worker-pool (8 workers): p99 (ms), per-run median of 3 alternations | `quarkus/worker-pool-alt{1,2,3}.json percentiles.p99` | 1453.3-1455.4 | 1455.4, 1453.3, 1453.3 |
| Fig 12.3 virtual-thread: p99 (ms), per-run median of 3 alternations | `quarkus/virtual-thread-alt{1,2,3}.json percentiles.p99` | 6.5-8.9 | 8.9, 7.1, 6.5 |
| Fig 12.3 blocking-on-event-loop at 1850 Hz: p99 (ms), per-run median of 3 alternations | `quarkus/blocking-on-event-loop-alt{1,2,3}.json percentiles.p99` | 8.1-8.5 | 8.1, 8.3, 8.5 |
| Fig 12.3 event-loop control at 1850 Hz: p99 (ms), per-run median of 3 alternations | `quarkus/event-loop-ctl-alt{1,2,3}.json percentiles.p99` | 3.3 | 3.3, 3.3, 3.3 |
| Fig 12.3 p99 ratio, worker-pool over virtual-thread (per-run median of 3 per-alternation ratios) | `quarkus/{worker-pool,virtual-thread}-alt{1,2,3}.json percentiles.p99` | 162.85-223.10x | 162.85x, 203.10x, 223.10x |
| Fig 12.3 p99 ratio, blocking-on-event-loop over event-loop control (per-run median of 3 per-alternation ratios; observed) | `quarkus/{blocking-on-event-loop,event-loop-ctl}-alt{1,2,3}.json percentiles.p99` | 2.44-2.61x | 2.44x, 2.50x, 2.61x |
| Fig 12.3 worker pool threads (exact) | `quarkus/worker-pool-alt{1,2,3}.json runtime.counters.worker_pool_threads (also model.worker_pool_threads)` | 8 | 8, 8, 8 |
| Fig 12.3 worker-pool: workers active at once, maximum (exact) | `quarkus/worker-pool-alt{1,2,3}.json runtime.counters.worker_active_max` | 8 | 8, 8, 8 |
| Fig 12.3 worker-pool: client requests in flight, maximum (load-dependent; per-run median of 3 alternations) | `quarkus/worker-pool-alt{1,2,3}.json runtime.counters.max_in_flight` | 5,661-5,677 | 5,667, 5,661, 5,677 |
| Fig 12.3 Little's law in flight at 5 kHz x 2 ms (parameter check) | `quarkus/worker-pool-alt{1,2,3}.json model.littles_law_in_flight` | 10.0 | 10.0, 10.0, 10.0 |
| Fig 12.3 event-loop: event-loop threads (exact) | `quarkus/event-loop-alt{1,2,3}.json runtime.counters.event_loop_threads_seen` | 4 | 4, 4, 4 |
| Fig 12.3 virtual-thread: carrier threads (exact) | `quarkus/virtual-thread-alt{1,2,3}.json runtime.counters.carrier_threads` | 4 | 4, 4, 4 |
| Fig 12.3 blocking-on-event-loop: requests in a handler at once, maximum (exact) | `quarkus/blocking-on-event-loop-alt{1,2,3}.json runtime.counters.service_in_handler_max` | 4 | 4, 4, 4 |
| Fig 12.3 blocking-on-event-loop: blocked-thread warnings during the measured run (counted in process) | `quarkus/blocking-on-event-loop-alt{1,2,3}.json runtime.counters.blocked_thread_warnings_in_run` | 990-1,030 (varies; flagged) | 994-1,005, 993-1,009, 990-1,030 |
| Fig 12.3 event-loop control: requests in a handler at once, maximum | `quarkus/event-loop-ctl-alt{1,2,3}.json runtime.counters.service_in_handler_max` | 13-16 (varies; flagged) | 14-16, 13-16, 13-14 |
| Fig 13.1 lane host: simulator emit lateness p99 (us), per-run median of 3 alternations (the jitter floor) | `host/alt{1,2,3}/cpp/lateness.json percentiles.p99` | 62-64 | 63, 62, 64 |
| Fig 13.1 lane host: consumer p99 (us), per-run median of 3 alternations | `host/alt{1,2,3}/cpp/consumer.json percentiles.p99` | 97-98 | 98, 98, 97 |
| Fig 13.1 lane vm: simulator emit lateness p99 (us), per-run median of 3 alternations (the jitter floor) | `vm/alt{1,2,3}/cpp/lateness.json percentiles.p99` | 80-83 | 81, 83, 80 |
| Fig 13.1 lane vm: consumer p99 (us), per-run median of 3 alternations | `vm/alt{1,2,3}/cpp/consumer.json percentiles.p99` | 99-101 | 101, 101, 99 |
| Fig 13.1 lane container-host-net: simulator emit lateness p99 (us), per-run median of 3 alternations (the jitter floor) | `container-host-net/alt{1,2,3}/cpp/lateness.json percentiles.p99` | 81-89 | 81, 84, 89 |
| Fig 13.1 lane container-host-net: consumer p99 (us), per-run median of 3 alternations | `container-host-net/alt{1,2,3}/cpp/consumer.json percentiles.p99` | 101-104 | 101, 104, 102 |
| Fig 13.1 lane container-bridge: simulator emit lateness p99 (us), per-run median of 3 alternations (the jitter floor) | `container-bridge/alt{1,2,3}/cpp/lateness.json percentiles.p99` | 85-103 | 103, 91, 85 |
| Fig 13.1 lane container-bridge: consumer p99 (us), per-run median of 3 alternations | `container-bridge/alt{1,2,3}/cpp/consumer.json percentiles.p99` | 105-140 | 140, 109, 105 |
| Fig 13.1 lane vm: steal ticks over the lane (exact counter) | `vm/alt{1,2,3}/steal.json steal_ticks` | 0-1 (varies; flagged) | 0-1, 1, 1 |
| Fig 13.1 lane vm: guest ticks over the lane (denominator of the steal ticks) | `vm/alt{1,2,3}/steal.json total_ticks` | 8,848-9,886 (varies; flagged) | 8,867-9,886, 8,848-9,355, 9,343-9,870 |
| Fig 13.1 lane vm: io_uring_setup errno (exact; 1 is EPERM) | `vm/alt{1,2,3}/cpp/probe-cpp.json io_uring.setup_errno` | 0 | 0, 0, 0 |
| Fig 13.1 lane container-host-net: io_uring_setup errno (exact; 1 is EPERM) | `container-host-net/alt{1,2,3}/cpp/probe-cpp.json io_uring.setup_errno` | 1 | 1, 1, 1 |
| Fig 13.1 lane container-bridge: io_uring_setup errno (exact; 1 is EPERM) | `container-bridge/alt{1,2,3}/cpp/probe-cpp.json io_uring.setup_errno` | 1 | 1, 1, 1 |
| Fig 13.1 lane container-cpu-quota: io_uring_setup errno (exact; 1 is EPERM) | `container-cpu-quota/alt{1,2,3}/cpp/probe-cpp.json io_uring.setup_errno` | 1 | 1, 1, 1 |
| Fig 13.1 lane container-cpuset: io_uring_setup errno (exact; 1 is EPERM) | `container-cpuset/alt{1,2,3}/cpp/probe-cpp.json io_uring.setup_errno` | 1 | 1, 1, 1 |
| Fig 13.1 lane vm: vCPUs (the guest; exact) | `vm/alt{1,2,3}/cpp/probe-cpp.json cpus.online_count` | 4 | 4, 4, 4 |
| Fig 13.2 lane container-cpu-quota: consumer p99.9 (us), per-run median of 3 alternations | `container-cpu-quota/alt{1,2,3}/cpp/consumer.json percentiles.p99_9` | 53,411-55,574 | 55,574, 53,510, 53,411 |
| Fig 13.2 lane container-cpu-quota: consumer p99 (us), per-run median of 3 alternations | `container-cpu-quota/alt{1,2,3}/cpp/consumer.json percentiles.p99` | 50,462-51,642 | 51,642, 50,462, 51,183 |
| Fig 13.2 lane container-cpu-quota: nr_throttled at the end of the run (exact counter) | `container-cpu-quota/alt{1,2,3}/cpp/consumer.json runtime.environment.cgroup.nr_throttled` | 206-207 (varies; flagged) | 207, 206-207, 206-207 |
| Fig 13.2 lane container-cpu-quota: throttled time at the end of the run (s), summed over the guest's 4 CPUs | `container-cpu-quota/alt{1,2,3}/cpp/consumer.json runtime.environment.cgroup.throttled_usec / 1e6` | 37.7-40.6 | 40.5-40.6, 37.7-40.6, 38.5-40.6 |
| Fig 13.2 lane container-cpu-quota: busy-pool workers (exact) | `container-cpu-quota/alt{1,2,3}/cpp/pool.json workers` | 4 | 4, 4, 4 |
| Fig 13.2 lane container-cpuset: consumer p99.9 (us), per-run median of 3 alternations | `container-cpuset/alt{1,2,3}/cpp/consumer.json percentiles.p99_9` | 2,912-4,067 | 2,953, 4,067, 2,912 |
| Fig 13.2 lane container-cpuset: consumer p99 (us), per-run median of 3 alternations | `container-cpuset/alt{1,2,3}/cpp/consumer.json percentiles.p99` | 2,085-3,043 | 2,129, 3,043, 2,085 |
| Fig 13.2 lane container-cpuset: nr_throttled at the end of the run (exact counter) | `container-cpuset/alt{1,2,3}/cpp/consumer.json runtime.environment.cgroup.nr_throttled` | 0 | 0, 0, 0 |
| Fig 13.2 lane container-cpuset: throttled time at the end of the run (s), summed over the guest's 4 CPUs | `container-cpuset/alt{1,2,3}/cpp/consumer.json runtime.environment.cgroup.throttled_usec / 1e6` | 0.0 | 0.0, 0.0, 0.0 |
| Fig 13.2 lane container-cpuset: busy-pool workers (exact) | `container-cpuset/alt{1,2,3}/cpp/pool.json workers` | 4 | 4, 4, 4 |
| Fig 13.2 ratio of consumer p99.9, container-cpu-quota over container-cpuset (per-run median of 3 per-alternation ratios) | `container-cpu-quota,container-cpuset/alt{1,2,3}/cpp/consumer.json percentiles.p99_9` | 13.16-18.91x | 18.91x, 13.16x, 18.34x |
| Fig 13.2 lane container-cpuset: cpuset.cpus.effective CPU count (exact) | `container-cpuset/alt{1,2,3}/cpp/probe-cpp.json cgroup.cpuset_count` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpu-quota: C++ hardware_concurrency() (exact) | `container-cpu-quota/alt{1,2,3}/cpp/probe-cpp.json cpus.hardware_concurrency` | 4 | 4, 4, 4 |
| Fig 13.3 lane container-cpu-quota: C++ affinity mask CPUs (exact) | `container-cpu-quota/alt{1,2,3}/cpp/probe-cpp.json cpus.affinity_count` | 4 | 4, 4, 4 |
| Fig 13.3 lane container-cpu-quota: C++ cgroup-aware pool size (exact) | `container-cpu-quota/alt{1,2,3}/cpp/probe-cpp.json pool_size.cgroup_aware` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpu-quota: C++ pool size by hardware_concurrency (exact) | `container-cpu-quota/alt{1,2,3}/cpp/probe-cpp.json pool_size.by_hardware_concurrency` | 4 | 4, 4, 4 |
| Fig 13.3 lane container-cpu-quota: Python os.cpu_count() (exact) | `container-cpu-quota/alt{1,2,3}/python/probe-python.json python.cpu_count` | 4 | 4, 4, 4 |
| Fig 13.3 lane container-cpu-quota: Python os.process_cpu_count() (exact) | `container-cpu-quota/alt{1,2,3}/python/probe-python.json python.process_cpu_count` | 4 | 4, 4, 4 |
| Fig 13.3 lane container-cpu-quota: Java availableProcessors() (exact) | `container-cpu-quota/alt{1,2,3}/java/probe-java.json java.available_processors` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpu-quota: Java virtual-thread scheduler parallelism (exact) | `container-cpu-quota/alt{1,2,3}/java/probe-java.json java.virtual_thread_parallelism` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpu-quota: Java parallel GC threads (exact) | `container-cpu-quota/alt{1,2,3}/java/probe-java.json java.parallel_gc_threads` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpu-quota: Quarkus event-loop threads running (exact; observed, the default floor of 2 equals the CPU view here) | `container-cpu-quota/alt{1,2,3}/quarkus/service.json service.event_loop_threads` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpu-quota: Quarkus worker threads (exact; fixed in application.properties, not derived from the CPU view) | `container-cpu-quota/alt{1,2,3}/quarkus/service.json service.executor_threads` | 8 | 8, 8, 8 |
| Fig 13.3 lane container-cpuset: C++ hardware_concurrency() (exact) | `container-cpuset/alt{1,2,3}/cpp/probe-cpp.json cpus.hardware_concurrency` | 4 | 4, 4, 4 |
| Fig 13.3 lane container-cpuset: C++ affinity mask CPUs (exact) | `container-cpuset/alt{1,2,3}/cpp/probe-cpp.json cpus.affinity_count` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpuset: C++ cgroup-aware pool size (exact) | `container-cpuset/alt{1,2,3}/cpp/probe-cpp.json pool_size.cgroup_aware` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpuset: C++ pool size by hardware_concurrency (exact) | `container-cpuset/alt{1,2,3}/cpp/probe-cpp.json pool_size.by_hardware_concurrency` | 4 | 4, 4, 4 |
| Fig 13.3 lane container-cpuset: Python os.cpu_count() (exact) | `container-cpuset/alt{1,2,3}/python/probe-python.json python.cpu_count` | 4 | 4, 4, 4 |
| Fig 13.3 lane container-cpuset: Python os.process_cpu_count() (exact) | `container-cpuset/alt{1,2,3}/python/probe-python.json python.process_cpu_count` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpuset: Java availableProcessors() (exact) | `container-cpuset/alt{1,2,3}/java/probe-java.json java.available_processors` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpuset: Java virtual-thread scheduler parallelism (exact) | `container-cpuset/alt{1,2,3}/java/probe-java.json java.virtual_thread_parallelism` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpuset: Java parallel GC threads (exact) | `container-cpuset/alt{1,2,3}/java/probe-java.json java.parallel_gc_threads` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpuset: Quarkus event-loop threads running (exact; observed, the default floor of 2 equals the CPU view here) | `container-cpuset/alt{1,2,3}/quarkus/service.json service.event_loop_threads` | 2 | 2, 2, 2 |
| Fig 13.3 lane container-cpuset: Quarkus worker threads (exact; fixed in application.properties, not derived from the CPU view) | `container-cpuset/alt{1,2,3}/quarkus/service.json service.executor_threads` | 8 | 8, 8, 8 |
| Fig 13.3 lane vm: C++ hardware_concurrency() (exact) | `vm/alt{1,2,3}/cpp/probe-cpp.json cpus.hardware_concurrency` | 4 | 4, 4, 4 |
| Fig 13.3 lane vm: Python os.process_cpu_count() (exact) | `vm/alt{1,2,3}/python/probe-python.json python.process_cpu_count` | 4 | 4, 4, 4 |
| Fig 13.3 lane vm: Java availableProcessors() (exact) | `vm/alt{1,2,3}/java/probe-java.json java.available_processors` | 4 | 4, 4, 4 |

Deviations from the figure list above are recorded here so the chapters (S13-S15) state them.

- 11.1: the parked wait is a shared 1,000 ms timer (`wait_ms`), not a 2 ms lookup. The plan's 10x RSS gap does not appear (C++ OS thread 8,774-8,778 B, fiber 4,106 B, coroutine 1,009 B per wait; Java platform thread 22,805-22,898 B, virtual thread 2,870-3,260 B), so the figure draws bytes per wait and address space and makes no 10x claim; what differs by orders of magnitude is the reserved address space (9,245,449 B, 69,645 B, 26 B in C++). The fiber stack is the code constant `kFiberStackBytes` (64 KiB, 65,536 B, also in `runtime.counters.fiber_stack_bytes`). Python (threads, asyncio tasks) is added so every lane shows C++, Python, Java where each exists; Java's virtual-thread stack is the heap per task, 2,063-2,105 B.
- 11.2: Python threads and asyncio tasks are added (one measurement per run, no alternations). The C++ coroutine p50 (7-18 ns) moves a good deal between runs because the per-batch time is a handful of nanoseconds; the figure quotes the range as measured. The voluntary-switch count for the Java virtual thread (2-6 in 1,020,000 round trips) differs across runs and is quoted as a range.
- 11.3: the blocking-fiber neighbours' p99 lateness is 1,917-1,952 us, about the 2 ms sleep itself; the verify.sh criterion is "2x by construction" and its margin is under 2x. The figure shows the measured range, not the margin. The asyncio twin runs 50 tasks, the fiber run 1,000, and the figure says so.
- 11.2: the Python asyncio row is a ghost lane, not a coroutine resume by symmetric transfer: it goes through the event loop (an `epoll_wait(0)` per loop pass). The coroutine lane is labelled "a resume without a thread switch".
- 12.1: C++ only (Java and Python have no io_uring engine here). System calls per parcel are load-dependent counters, quoted as per-run medians of the 3 alternations and flagged as such; only `recvmsg` per parcel (1) is exact.
- 12.2: the acceptor hands off through one Ch10 log per worker, round robin (the example README's wording "multi-producer log"), not a single "MPSC queue"; each camera has its own port (`base_port + c`), so `SO_REUSEPORT` is set but steers nothing. The saturation p99 ratio is observed, not asserted: 0.77-0.82x at S11 (0.43-0.86 at S10), and the figure says so. The layout pair runs at `SAT_RATE_LAYOUT` (52 kHz per camera, 3,500 ns of receive work), where the acceptor is 820-822 permille busy (per-run medians) (the plan's 80-85 percent). At line rate (2.5 kHz per camera) the p99 ranges overlap (98-115 us thread-per-core, 91-113 us acceptor and pool, one measurement per run); the figure shows that too, so it is not a guaranteed win.
- 12.3: the worker pool is 8 (not 16) at 5,000 Hz with a 2 ms dependency: 10 in flight (Little's law) against 8 workers; the defect runs at `DEFECT_RATE` 1,850 Hz against an event-loop control at the same rate. The defect-over-control p99 ratio (2.44-2.61x) is observed, not asserted. The p99 of the three 5,000 Hz variants is the per-run median of 3 alternations.
- 13.1: "bare-metal host", never "laptop" or a hardware model (the example README and verify.log still say "laptop"; the chapter must not repeat that). Layers show only measured lanes (host, vm, container-host-net, container-bridge); the cgroup controllers are drawn in 13.2. Host against vm is labelled and not compared as a claim (D9).
- 13.2: the quota-over-cpuset consumer p99.9 ratio is recomputed from the JSON as 13.16-18.91x (per-run medians), matching verify.log. `nr_throttled` is 206-207 (not the single 207 that verify.log prints for alternation 1) and throttled time 37.7-40.6 s (summed over the guest's 4 CPUs), so both are quoted as ranges.
- 13.3: the Quarkus 8 workers are fixed in `application.properties`. The 2 event-loop threads are observed; the event-loop default is the larger of 2 and `availableProcessors()` (capped by heap), which is 2 under either limit, so the run can't tell the CPU view from the floor. The pool sizes each runtime derives are drawn as the counts the probes report (C++ cgroup-aware pool 2 against 4 by `hardware_concurrency()`, Java scheduler 2, Java GC threads 2); the vm lane (4 vCPUs, no limit) is quoted as the reference.
- Extraction: the default user stack (8,192 KiB) and the 1,000 ms wait are parsed from the reports' `notes` strings because the reports have no numeric field for them; the plan's "64 KiB" is verified in source and in `fiber_stack_bytes`. No value is parsed from `verify.log`.

## Status

| Step | Status |
|---|---|
| specs and generated files | done |
| `_data/diagrams.yml` entries | done |
| chapters embed the figures (S13-S15) | todo |
