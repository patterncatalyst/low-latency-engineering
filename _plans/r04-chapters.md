---
title: "r04 chapters (S13–S15)"
layout: plan
render_with_liquid: false
---

# r04 chapters: S13–S15

One chapter per example, written from the example's code and its committed S11 (or S19) results. Shape, numbers, voice, Liquid and listing rules follow [r03-chapters.md](r03-chapters.md) unless this brief changes them. Each executor edits only its own chapter file; `_data/diagrams.yml`, READMEs, the outline and `_example_pages/` are S16's.

## Files

| Step | File | `order` | `part` | Title | Example |
|---|---|---|---|---|---|
| S13 | `_docs/11-stackful-stackless.md` | 11 | `Threading & I/O Models` | Stackful vs stackless: threads and fibers vs event loops and coroutines | `examples/11-stackful-stackless/` |
| S14 | `_docs/12-io-engines.md` | 12 | `Threading & I/O Models` | I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core | `examples/12-io-engines/` |
| S15 | `_docs/13-where-code-runs.md` | 13 | `Threading & I/O Models` | Where the code runs: bare metal, VMs and containers, and when not to use containers | `examples/13-where-code-runs/` |

`duration`: `55 minutes` each. Commits: `docs(§11): Ch11 Stackful vs stackless (S13)`, `docs(§12): Ch12 I/O engines (S14)`, `docs(§13): Ch13 Where the code runs (S15)`.

## What changes from r03

- **Code tabs:** `langs="C++|Python|Java"` explicitly, or a subset where a language has no equivalent, said in one sentence:
  - Ch11: no Python stackful lane (greenlet is third-party), no Java stackless lane.
  - Ch12: no JDK or Python io_uring.
  - Ch13: Python CPU counts only.
- **Before/after pairs:** each technique gets a before/after code pair with `#A`/`#B` callouts (for example, `os-thread` against `coroutine`, `epoll` against `io-uring`, `@Blocking` against `@RunOnVirtualThread`, `--cpus` against `--cpuset-cpus`).
- **Profile line:** Ch11 and Ch12 use `r04-run1/profile.json` plus placement ("threads placed on distinct physical cores by `sched_setaffinity`, an experiment control, not isolation"). Ch13 gives one profile line per lane:
  - host: bare metal, VM booted and idle;
  - vm: `lowlat-target`, guest profile `stock-unpinned`, snapshot `lab-ready-r04`, 4 vCPU unpinned, stock kernel 7.2;
  - container: image tag + digest, network, `--cpus`/`--cpuset-cpus`, default seccomp.
  - Never the CPU part, the host kernel build or a container ID.
- **Comparisons:** within one run, median of 3 alternations; never p50 across runs; sub-2x margins stated where the claim is made. Ch13's host vs VM lines are observed and worded "on this machine, in this run" (D9); container lanes are compared with VM-native in the same guest.
- **Runtime facts:** every sentence about a kernel, runtime or tool behaviour (io_uring, epoll, seccomp default, CFS bandwidth, JEP 491, Quarkus pool defaults, asyncio, `os.process_cpu_count`) cites the S0 source in `dependency-pins.md` or a committed run. S18 checks each one.
- **Companion projects:** the user's cpp-concurrency-and-parallelism (Ch11, Ch12, Ch13, Ch32), linux-systems-programming (09 epoll, 10 io_uring, 32 namespaces and cgroups, 34 containers, 35 KVM, 55 Boost.Asio), quarkus-optimization and spring-boot-optimization are cited in "For deeper coverage" as companion sites, not re-taught. Their wording isn't carried over where it breaks house rules (no "lies" framing).
- **House voice from the first draft** (lgtm-professional-voice, Geewax model). Paste the rubric into the executor prompt:
  - open each section on a concrete line object (the WMS lookup, a tunnel camera's socket, the controller PC, the hub's VM farm, a pod);
  - contractions; varied sentence length; no rhetorical triads;
  - captions `Figure N.x: …`, no em dash anywhere.
  - Before hand-back: `scan.sh --tier ban` 0 and `scan.sh --stats` clean.

## Ch11: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Hook | Every scan asks the WMS for a sort plan, and the answer takes about 2 ms. At 10 kHz that's 20 parcels waiting at once (Ch2); at a hub with a slow WMS it's thousands. Something has to hold each wait. |
| Who holds the wait | OS thread (`std::jthread`, platform thread, `threading.Thread`), stackful (Boost.Fiber, virtual thread), stackless (C++23 coroutine on Asio, asyncio task) -> 10,000 parked tasks -> bytes per wait fall by orders of magnitude from thread to fiber to coroutine -> frame bytes (exact), RSS ratios, Python bytes (exact) |
| The hand-off | Ping-pong between two tasks -> 1,000,000 round trips -> a futex sleep and wake per switch against a user-space context swap against a resume -> voluntary switches per round trip (exact-ish), same-run p50 ratio |
| The blocking call | One `sleep_for` inside a fiber, one `time.sleep` inside a coroutine -> neighbours on the same carrier wait -> wake lateness ≥ 1 ms for a 2 ms call (2x by construction); Java: JEP 491 and what still pins (JFR count, observed). Function colouring explained from the code, not as a slogan |
| Python | No stdlib stackful coroutine; asyncio is stackless; threads under the GIL against free-threaded (observed); the measured free-threaded process imports no `lowlat_measure` |
| Line | 10 kHz x 20 s with a 2 ms lookup wait per parcel -> all variants fit 480 ms; the saving is memory and CPU per wait, said without a latency claim |
| Cross-check | RSS against the configured stack sizes (`ulimit -s`, `protected_fixedsize_stack`) and the promise allocation count; `/proc` context switches against the round-trip histogram |

Boundaries: MPSC hand-off and memory orders are Ch10 (back-link); the I/O engine under the event loop is Ch12 (forward link); the coroutine-type internals are the companion cpp-concurrency-and-parallelism Ch11 and Ch13 (cross-ref).

## Ch12: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Hook | A hub concentrator takes four scan tunnels' UDP feeds. For each datagram, something tells a thread there's work: a readiness event or a completion. |
| Readiness and completion | `epoll` + `recvmsg` (Asio reactor as the idiom), `recvmmsg`, liburing multishot with a buffer ring -> four cameras at saturation -> syscalls per parcel fall from ≥ 2 to well under 1 -> exact in-program counters, `strace -c` cross-check (observed) |
| Thread-per-core | `SO_REUSEPORT` socket and ring per pinned thread against one receive thread + MPSC hand-off -> same load -> 0 hand-offs per parcel (exact), saturation p99 ratio |
| Virtual threads and the event loop | Quarkus sort-plan service: `Uni` on the event loop, `@Blocking`, `@RunOnVirtualThread`, plus the `blocking-on-event-loop` defect -> open-loop at λW > pool -> worker pool queues (Little's law), VTs don't, the event loop is fine until something blocks it -> same-run p99 ratio, blocked-thread warnings (exact). Plain-JDK lane shows the VT poller is epoll underneath |
| Python | asyncio datagram endpoint against a blocking thread (GIL and free-threaded) and uvloop -> observed; no stdlib io_uring |
| Line | Four cameras at 2.5 kHz -> all fit 480 ms; saturation shows where they'd differ |
| Cross-check | In-program syscall counters against `strace -c`; client lateness against server-side pool counters |

Boundaries: Ch10 owns the MPSC queue; Ch15 owns isolation (pinning here is an experiment control); Part 6 owns transports and protocol design (HTTP/1.1 on loopback is a harness, not a transport recommendation).

## Ch13: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Hook | The same decide service can run on the controller PC under the conveyor, in the hub's VM farm, or as a container in a pod. What moves when it moves? |
| Three places | Host, VM-native, container-in-VM, interleaved in one run -> line 10 kHz x 20 s per lane -> the jitter floor (simulator emit lateness) and the decide percentiles per lane, labelled -> observed (D9); what the VM can't show |
| The network namespace | Bridge veth against host network inside the guest -> observed delta |
| Quota against cpuset | `--cpus=2` against `--cpuset-cpus=2,3`, 4 busy decide workers -> CFS bandwidth throttling stops the whole cgroup until the next period -> `nr_throttled` ≥ 1 vs 0 (exact), p99.9 ratio (S10 decides) |
| What the runtime thinks it has | `hardware_concurrency()`, `availableProcessors()`, `os.process_cpu_count()` under quota and cpuset (exact), and the pool sizes each derives (VT carriers, Vert.x event loops, GC threads); size pools from the cgroup, not the core count |
| Seccomp and io_uring | Default Docker seccomp against the same binary outside -> `EPERM` (exact, if S0 confirms) |
| When not to use a container | Hot path under a CPU quota, or anywhere the I/O engine is filtered: no. Control plane, telemetry, analytics: fine. Kubernetes QoS classes and the CPU Manager static policy in prose (pointer to Ch18 rollout gating and the companion sites) |
| Cross-check | `cpu.stat` against the tail spikes' timing; guest steal ticks against the VM lane's jitter floor |

Boundaries: isolation and RT are Part 5 (Ch14–Ch16); rollout gating is Ch18; the container-sizing deep dive is the companion cpp-concurrency-and-parallelism Ch32; JVM container ergonomics in depth is quarkus-optimization.

## Claims and evidence tables

Filled in at S13–S15 from `r04-run1..3`, in the r03 form (claim | evidence file and field). Ch13 adds a lane column (`host`/`vm`/`container-*`). Report failures and outliers as they are.

### Ch11 claims (S11, `examples/11-stackful-stackless/results/r04-run{1,2,3}/`)

Ranges across the three runs; ratios are the range of each run's median over its 3 alternations; per-run p50/p99 are the median of 3 alternations (figures-table convention) unless noted. Report fields are in `*.json` `percentiles` and `runtime.counters`; printed values in `verify.log`. "Fig table" = `_plans/r04-figures.md` rows.

| Claim | Evidence |
|---|---|
| Per parked wait, C++ thread: address space 9,245,449 B, RSS 8,774-8,778 B, RSS+page tables+kernel stack 29,356-29,360 B, kernel stack 16,380-16,384 B, default stack 8,192 KiB | `cpp-parked-os-thread.json` `runtime.counters.{vm_size_bytes_per_task,rss_bytes_per_task,rss_page_tables_kernel_stack_bytes_per_task}`, `kernel_stack_delta_kib`, `notes`; Fig table |
| C++ fiber: 69,645 B address space, RSS 4,106 B, full 4,242-4,256 B, stack 65,536 B | `cpp-parked-fiber.json` same fields, `fiber_stack_bytes`; Fig table |
| C++ coroutine: frame 208 B (exact), 10,000 allocations (exact), RSS 1,009 B, full 1,010 B, address space 26 B | `cpp-parked-coroutine.json` `frame_bytes_per_task`, `rss_page_tables_kernel_stack_bytes_per_task` (read directly, 1,010 in runs 1-3); `verify.log` criterion 1 |
| Java platform: address space 1,044,486-1,044,591 B, RSS 22,805-22,898 B, full 41,204-41,322 B; virtual: 27,262-34,078 B, 2,870-3,260 B, 2,888-3,276 B; VT heap about 2 KB (2,063-2,105 B) | `java-parked-{platform,virtual}-thread.json` counters; Fig table |
| 10,000 tasks armed (fiber, coroutine; exact); 1,000 ms timer | `verify.log` criterion 2; `cpp-parked-fiber.json` `tasks_armed`, `notes` |
| Address space thread/fiber 132.75x (bound 10x); fiber/frame 334.83x (bound 10x) | `verify.log` criterion 1 |
| Java full resident platform/virtual 12.61-14.28x (bound 5x, worst margin 2.52x) | `verify.log` criterion 1 (14.28, 12.61, 13.34) |
| Python GIL thread RSS / asyncio tracemalloc 11.72-11.73x (bound 5x, margin 2.34x); free-threaded 148.43-148.44x | `verify.log` criterion 1 |
| RSS ratios C++ thread/fiber 2.14x, fiber/coroutine 4.07x (plan 10x), observed | `verify.log` criterion 2 observed line |
| Page tables + kernel stack per wait: thread 20,582-20,585 B, fiber 136-150 B, ratio 137-151x (observed) | computed from `cpp-parked-{os-thread,fiber}.json` `runtime.counters.(page_tables_delta_kib + kernel_stack_delta_kib) * 1024 / 10000` = 20,585.27 / 20,581.99 / 20,582.81 and 150.32 / 135.99 / 135.99; ratios 136.95 / 151.35 / 151.36; rounded per the book rule (bytes and ratios round) |
| Coroutine address space 26 B and Java VT address space 27,262-34,078 B are not per-task costs (already-mapped heap; steps of about 64 MiB, likely carriers' malloc arenas, 0 at small task counts) | `verify.log` criterion 1 observed line; README criteria |
| Python RSS per task: thread 19,228-19,247 B (GIL), 254,263-254,271 B (free-threaded); asyncio 2,611-2,614 B (GIL), 2,052 B (free-threaded) | `python/python-*-parked-*.json` `rss_bytes_per_task`; free-threaded values computed by a session script from the committed JSON (not in the repo) |
| C++ round-trip p50: thread 3,755-3,777, fiber 205-207, coroutine 7-18 ns; Java platform 4,115-4,175, virtual 399-404 ns | `cpp-pingpong-*-alt{1,2,3}.json`, `java-pingpong-*-alt{1,2,3}.json` `percentiles.p50`; Fig table |
| Voluntary switches: thread 2 per round trip (1999 thousandths in verify.log; exact ratio about 1.999-2.000); fiber, coroutine 0 in 1,020,000 round trips (exact); Java VT 1-6 in 1,020,000, every alternation (1,1,2 / 5,4,6 / 3,5,4), both threads on one carrier (`placement.cpus` [1], parallelism=1); Java platform 2 per round trip | `verify.log` criterion 3; `*-pingpong-*-alt*.json` `runtime.ctx_switches.voluntary` / `round_trips_served` |
| p50 ratio thread/fiber 18.25-18.33x (bound 5x, margin 3.65x); thread/coroutine 208.72-535.28x (bound 5x; unstable because coroutine p50 is 7-18 ns); Java 10.28-10.48x (bound 2x, margin 5.14x) | `verify.log` criterion 4 |
| Python hand-off p50 (observed): threads 4,011-4,029, asyncio 3,785-3,819 (GIL); 4,055-4,083, 4,119-4,159 (free-threaded) | `python/python-*-pingpong-*.json` `percentiles.p50`; free-threaded via `extra.py` |
| `binary_semaphore`: 164-266 voluntary switches in 1,020,000 round trips (observed) | `cpp-pingpong-os-thread-semaphore.json` `ctx_switches.voluntary` (266, 164, 181); `verify.log` |
| Neighbours p99: fiber no call 52 us; fiber with 2 ms call 1,917-1,952 us; thread 63 us; coroutine 4-5 us; 50 blocking calls, 1,000 tasks | `cpp-neighbours-*-alt{1,2,3}.json` `percentiles.p99`, `runtime.counters`; Fig table |
| Asserted fiber statistic (lowest of 3 alts) 1,902-1,937 us vs 1 ms bound, margin 1.90-1.94x, under 2x by construction, flagged | `verify.log` criterion 5 |
| Python asyncio (50 tasks, GIL): p99 1,305-1,308 us without, 2,672-2,859 us with; 2.05-2.19x baseline (observed; 2.08, 2.19, 2.05 rounded); wakes over 1.5 ms 1,822-2,199 of 25,000 vs 0 (asserted at 2x); 50 slow-callback warnings for 50 calls (exact) | `verify.log` criterion 5; `python-gil-neighbours-asyncio-tasks-blocking-debug.json` `slow_callback_warnings` |
| JFR `jdk.VirtualThreadPinned`: synchronized 0, native frame 100 of 100 (observed, all 3 runs) | `verify.log` observed line (pinning) |
| asyncio rounds epoll timeout up to 1 ms (`selectors.EpollSelector.select`, CPython 3.14) | `examples/11-stackful-stackless/README.md` (Python section); consistent with Python baseline p99 1,305-1,308 us. Not in `dependency-pins.md`: S18 to check |
| "Each event-loop pass calls epoll_wait" is NOT stated in the chapter text (only in Fig 11.2 alt/caption) | Fig 11.2 alt/caption in `_data/diagrams.yml` |
| JEP 491: synchronized no longer pins (JDK 24); native-frame / class-initializer blocking still pins | `_plans/dependency-pins.md` runtime-facts table, JEP 491 row |
| Free-threaded: GIL off from imports to end in every measurement; `lowlat_measure` not imported because `pyhdrh` does not declare free-threading support | `verify.log` criterion 7; `examples/11-stackful-stackless/README.md` (Python section) |
| Line: 200,000 parcels, 0 dropped, all commands received, 5 variants; end-to-end p99 (observed) C++ thread 2.15-2.16 ms (2,152,447-2,162,687 ns), fiber 2.15-2.16 ms (2,156,543-2,160,639), coroutine 2.09 ms (2,094,079-2,096,127), Java platform 2.91-3.06 ms (2,916,351-3,067,903), virtual 2.17 ms (2,170,879-2,172,927); single run, not a median of alternations | `verify.log` criterion 6 end-to-end lines; `*-line-*.json` |
| Cross-check: fiber 65,536 + 4,096 guard page = 69,632 vs 69,645 measured; thread 8,192 KiB = 8,388,608 of 9,245,449 B | arithmetic on `fiber_stack_bytes`, `vm_size_bytes_per_task`, `notes` (`workloads.cpp` formats a literal 8192; the run does not read `ulimit -s`; glibc default); 4,096 B page size is an assumption (Linux x86-64), not a committed field |
| HALO: 1,000 of 1,000 non-escaping frames reached `operator new` (observed, all 3 runs, Clang); ping-pong `frame_allocations` 0 and `frame_bytes_total` 0 in all 9 alternations | `verify.log` criterion 1 observed line; `cpp-pingpong-coroutine-alt{1,2,3}.json` `runtime.counters` |
| Profile: bare metal, virt none, 8-core/16-thread Intel (generic label), SMT, intel_pstate, kernel 7.2 PREEMPT_DYNAMIC, governor powersave, tuned balanced, clocksource tsc, Temurin 25.0.5+8, Clang 22.1.8 with GCC 16.2 libstdc++ (every C++ report `build.compiler` = clang 22.1.8; `profile.json` `tools.gcc`/`tools.clang`), Python 3.14.9 (reports' `runtime.python_build`, both builds); Boost 1.92.0 from README licence table | `r04-run1/profile.json`; `python/*.json` `runtime.python_build`; note the profile's `tools.python3` reads 3.14.8 (host tool), the measured interpreter is 3.14.9 |
| Outliers/failures: none; asserted margin under 2x: fiber blocking-call p99 only (1.90-1.94x, by construction) | `verify.log` |
| Hub arithmetic: 480 ms = 1.2 m at 2.5 m/s; 10 kHz x 2 ms = 20 in flight; 100,000 scans/s x 20 ms = 2,000 | `_docs/02-littles-amdahl.md`; arithmetic (Little's law L = lambda W); the 100,000/s hub and 20 ms WMS are illustrative figures, not measured |
| 50-task Python twin: 1,000 tasks every 2 ms = 500,000 wakes/s would overload the loop on this host | `python-gil-neighbours-asyncio-tasks*.json` `runtime.counters.tasks` = 50; rationale from README ("sizing"), not a committed measurement; chapter words it as "can't ... on this host" |
| Blocking cadence: task 0 blocks on iterations k % 10 == 9, 50 calls of 2,000 us; 1,000 tasks x 500 iterations | `workloads.cpp` `blocks_now`; `cpp-neighbours-fiber-blocking-alt*.json` `blocking_calls`, `blocking_call_us`, `tasks`, `iterations` |
| Pinning parameters: 100 tasks per case, 5 ms block, JFR threshold 0 ms | `java-pinning-virtual-thread.json` `runtime.counters` (`tasks_per_case` 100, `block_ms` 5, `jfr_threshold_ms` 0) |
| Memory method: `/proc/self/status` VmRSS/VmSize/VmPTE deltas + `/proc/meminfo` KernelStack, snapshot 500 ms into the wait | `procinfo.cpp` lines 26-27; `workloads.cpp` snapshot at `p.wait / 2` |
| Python hand-off vs thread: asyncio 5-6 % lower (GIL: 3,819/4,025, 3,785/4,011, 3,807/4,029), 1-2 % higher free-threaded (4,151/4,055, 4,119/4,083, 4,159/4,077 gives 0.9-2.4 %) | computed from the p50 rows above; worded "about" |

### Ch12 claims (S11, examples/12-io-engines/results/r04-run{1,2,3}/)

Ranges across the three runs; ratios are the range of each run's median over its 3 alternations. Values are as `verify.log` prints them (us and ms truncated). Derived values are computed by a session script from the committed JSON (not in the repo).

| Claim | Evidence |
|---|---|
| Profile: bare-metal, `powersave`, `balanced`, kernel 7.2, Intel 8-core/16-thread CPU; Temurin 25.0.5+8, Clang 22.1.8 on GCC 16.2 libstdc++ (Ch10 precedent; libstdc++ not re-confirmed in build files), Python 3.14.9 for both GIL and free-threaded builds; Quarkus 3.40.1.1 | `r04-run1/profile.json` `tools.*`, `kernel.release`, `cpu.model`; `cpp/*.json` `build.compiler` (clang 22.1.8); `python/*.json` `runtime.python_build.compiler` (3.14.9, both builds); `_plans/dependency-pins.md` |
| Rounded to the digits shown (book rule, r04-figures.md): epoll 1.379-1.417 system calls per parcel at saturation (recvmsg 1.000 exact, epoll_wait 0.379-0.417); recvmmsg 0.573-0.614; io-uring 0.062-0.068 enters per parcel, 14.7-16.2 CQEs per enter | `cpp/{epoll,recvmmsg,io-uring}-sat-alt{1,2,3}.json` `runtime.counters` (syscalls, epoll_wait_calls, recvmsg_calls, io_uring_enter_calls, cqes, parcels); `verify.log` criterion 1 |
| Saturation: 720,000 parcels (60 kHz x 4 x 3 s), dropped 0, in every run | `verify.log` "saturation runs carried their load"; `runtime.counters.parcels`, `dropped` |
| io_uring enters per parcel <= 1/4 of epoll's system calls per parcel, asserted; smallest margin 4.38x (run1 alt2) | `verify.log` criterion 1 |
| epoll over io-uring system calls per parcel 20.1-22.9x (per-run median 20.73, 22.90, 20.12) | derived: `cpp/{epoll,io-uring}-sat-alt{1,2,3}.json` `runtime.counters.syscalls / parcels`; `extra.py` "epoll/io-uring" |
| io-uring saturation p99 over epoll 0.810-1.012x (0.937, 0.810, 1.012), observed | `verify.log` "observed: C++ io-uring over epoll p99"; `extra.py` |
| Multishot re-arms 0 to 20 per saturation run (run1 20, 8, 0; run2 0, 0, 0; run3 0, 0, 8) | `cpp/io-uring-sat-alt*.json` `runtime.counters.multishot_rearms`; `extra.py` |
| Hand-offs per parcel: thread-per-core 0, acceptor-pool 1 (exact); dropped 0 for both | `verify.log` criteria 2 and 3; `runtime.counters.handoffs` |
| Layout load: acceptor 820-822 permille busy (guard 750-900), busiest thread-per-core receiver 384; 52 kHz x 4 cameras, 3,500 ns modelled receive work, 3 us decide | `runtime.counters.receiver_busy_permille_max`; `verify.log` criterion 3; `_plans/r04-figures.md` |
| Saturation p99: thread-per-core 68-69 us, acceptor-pool 84-90 us, ratio 0.77-0.82x (0.769, 0.767, 0.824 in verify.log), observed | `cpp/{thread-per-core,acceptor-pool}-sat-alt*.json` `percentiles.p99`; `verify.log` criterion 3 |
| Layout line p99 (2.5 kHz x 4, one measurement per run): thread-per-core 98-115 us, acceptor-pool 91-113 us, observed | `cpp/{thread-per-core,acceptor-pool}-line.json` |
| Quarkus p99 at 5 kHz: event-loop 9.0-10.3 ms, worker-pool 1,453.3-1,455.4 ms, virtual-thread 6.5-8.9 ms; worker-pool over virtual-thread 162.85-223.10x (rounded; verify.log prints 162.84), asserted >= 3x (smallest margin 54.28x) | `quarkus/{event-loop,worker-pool,virtual-thread}-alt*.json` `percentiles.p99`; `verify.log` criterion 4 |
| event-loop over virtual-thread p99 0.959-1.413x (0.959, 1.413, 1.029), observed | `verify.log` "observed: Quarkus event-loop over virtual-thread"; `extra.py` |
| lambda x W = 5,000 x 2 ms = 10 against a pool of 8 (fixed in application.properties); worker_pool_threads 8, worker_active_max 8, service_in_handler_max 8 in all 9 alternations (exact); capacity 8 / 2 ms = 4,000 per second (arithmetic, not measured) | `model.littles_law_in_flight`; `runtime.counters`; `extra.py` |
| Client max in flight (worker-pool) 5,661-5,677 per-run median (all alternations 5,649-5,776) | `quarkus/worker-pool-alt*.json` `runtime.counters.max_in_flight` |
| event-loop and virtual-thread use 0 worker threads; 4 event-loop threads and 4 carriers (exact) | `verify.log` criterion 9; `runtime.counters` |
| Defect at 1,850 Hz: p99 8.1-8.5 ms against control 3.3 ms, 2.44-2.61x, observed (not twice over the 2x bound); warnings logged in the run 990-1,030 across the nine alternations; in-handler max 4 (exact, = loop threads); control 13-16 | `quarkus/blocking-on-event-loop-alt*.json`, `event-loop-ctl-alt*.json` `runtime.counters.blocked_thread_warnings_in_run`, `service_in_handler_max`; `verify.log` criterion 5 |
| `%defect` sets `quarkus.vertx.max-event-loop-execute-time=1ms` because the default is 2 s | `quarkus/src/main/resources/application.properties`; `_plans/dependency-pins.md` "Quarkus blocked-thread checker" |
| Client lateness p99 per-run median: worker-pool 12.4-13.5 ms (12,410; 13,533; 12,558 us), event-loop 11-163 us | `quarkus/*-lateness.json` `percentiles.p99`; `extra.py` |
| Line: 200,000 parcels, dropped 0, every C++, plain-JDK and Python variant; largest p99 482 us (run1 free-threaded blocking-thread) | `verify.log` criterion 6; `*-line.json` (max over 42 reports, `extra.py` scan) |
| Python line p99: gil asyncio 99-135 us, gil blocking 119-170, gil uvloop 99-275, free-threaded asyncio 86-117, free-threaded blocking 104-482; one measurement per run, observed | `python/*-line.json` `percentiles.p99`; `extra.py` |
| strace epoll_wait 39,966 / 39,813 / 32,277 and recvmsg 40,000 = in-program counts; recvmmsg equal | `strace/cpp-epoll.txt`, `strace/cpp-recvmmsg.txt`; `verify.log` "observed: strace -f -c against the in-program counters" |
| strace io_uring_enter 15,198 / 28,358 / 39,343 against in-program 15,200 / 28,359 / 39,343 (difference 0-2) | `strace/cpp-io-uring.txt`; `cpp/io-uring-strace.json` `runtime.counters.io_uring_enter_calls`; `verify.log` |
| At the strace load (2.5 kHz x 4 x 4 s = 40,000 parcels): epoll 1.807-1.999 system calls per parcel, io-uring 0.380 / 0.709 / 0.984 enters per parcel | `cpp/{epoll,io-uring}-strace.json` `runtime.counters.syscalls / parcels`; `extra.py` |
| Java virtual-thread-blocking (4,000 parcels at 250 Hz): epoll_wait 7,813 / 8,370 / 9,047, recvfrom 8,000 / 7,998 / 8,000, failing (errors column) 4,000 / 3,998 / 4,000 (run1/2/3) | `strace/java-virtual-thread-blocking.txt`; `verify.log` |
| Python strace: blocking-thread 1 recvfrom per parcel and no epoll_wait; uvloop recvmsg 79,919-79,999 for 40,000 parcels (about 2 per parcel) | `strace/python-gil-blocking-thread.txt`, `strace/python-gil-uvloop.txt`; `verify.log` |
| Verified (behavioural) at commit 4434ed1; every criterion holds in all 3 runs | `r04-run{1,2,3}/run-start.json` `commit`; `verify.log` last lines |
| Fewer crossings freed CPU: receiver busy permille, per-run median of 3 alternations, io-uring 842 / 835 / 833 (833-842) against epoll 889 / 890 / 888 (888-890); observed, under 2x | `cpp/{io-uring,epoll}-sat-alt*.json` `runtime.counters.receiver_busy_permille_max`; `extra` inline script |
| Defect profile also sets `quarkus.vertx.warning-exception-time=10ms` (checker period, 100 checks per second per loop) | `application.properties`; `_plans/dependency-pins.md` "Quarkus blocked-thread checker" |
| Selector loop strace shows epoll_wait 2,963 / 3,562 / 3,808 | `strace/java-selector.txt`; `verify.log` |

Unsourced or code/README-only facts used in the prose (S18 to check): epoll registered with EPOLLIN and no EPOLLET reports a still-readable socket again (level-triggered; from `make_epoll` and kernel semantics, no S0 entry); multishot receive and provided buffer rings (from `engines.hpp` and README; no S0 entry); recvmmsg takes up to 32 (`kBatch`); SO_REUSEPORT steers nothing here (per-camera ports, `receive_main.cpp`); JDK and CPython standard library have no io_uring (README; no S0 entry); a hotter acceptor would drop parcels (README calibration note); JDK VT parks on the epoll poller (`dependency-pins.md` "Virtual thread in DatagramChannel.receive"); `@Blocking`/`@RunOnVirtualThread`/`@NonBlocking` semantics (pins "`@Blocking`, `@NonBlocking`, `@RunOnVirtualThread`").

### Ch13 claims (S11, examples/13-where-code-runs/results/r04-run{1,2,3}/)

Ranges are across the three runs; a latency figure is each run's median over its 3 alternations, microseconds truncated as `verify.log` prints them. `<lane>/altN/...` paths are under `r04-runR/`. Values marked (computed) come from a session script from the committed JSON (not in the repo); the rest are in `_plans/r04-figures.md` or `verify.log`. No failure or outlier in any run; every criterion held. Asserted = criteria 1-5 of the example README; everything else is observed.

| Claim | Lane | Evidence file and field |
|---|---|---|
| Every lane and alternation: 200,000 parcels, 0 dropped, environment kind matches lane, guest profile `lab-ready-r04/stock-unpinned`, image digest equals `IMAGES.lock`, consumer on CPU 3 (guest) (exact, asserted, criterion 5) | all | `verify.log` criterion 5 lines; `*/altN/cpp/consumer.json` `count`, `dropped`, `runtime.environment.*` |
| Image refs (tag + digest): place-cpp `sha256:007fe524...de05f`, place-java `sha256:da6684ca...488cc7`, place-py `sha256:276c666a...deed31`; base UBI 10.2 ubi-minimal | container-* | `containers/IMAGES.lock`; `consumer.json` `runtime.environment.container.image_digest` |
| Same four C++ binaries in every lane (checksums bfea59d07806, 1a4aa3c72e96, f7c38dce8846, bf45d5d6cda5) | all | `verify.log` "the host runs the same four binaries"; `*/binaries-*.txt` |
| Bare-metal host, governor `powersave`, tuned `balanced`, kernel 7.2, no virt | host | `r04-run1/profile.json` `virt.type`, `tuned`, `kernel.release`, `power.governor` |
| VM: `stock-unpinned`, snapshot `lab-ready-r04`, 4 vCPU, kernel 7.2, tuned `virtual-guest`, kvm | vm | `r04-run1/guest-profile.json` `cpu.logical_cpus`, `kernel.release`, `tuned`, `virt.type`; `run-start.json` `lab_vm_state` |
| Docker Engine 29.9.2 in the guest (not in the run JSON) | vm | `_plans/dependency-pins.md` "S5 guest results" |
| Guest 3 permille busy across each of the 9 host alternations (computed) | host | `host/altN/guest-idle.json` `busy_permille` |
| Host busy share 22-55 permille across the 9 host alternations (computed); load1 0.97-2.45 | host | `host/altN/host-quiet.json` `busy_permille`, `load1_before/after` |
| Emit lateness p99: host 62-64, vm 80-83, container-host-net 81-89, container-bridge 85-103 us (observed) | each | `<lane>/alt{1,2,3}/cpp/lateness.json` `percentiles.p99`; `_plans/r04-figures.md` Fig 13.1 |
| Consumer p99: host 97-98, vm 99-101, container-host-net 101-104, container-bridge 105-140 us (observed) | each | `<lane>/alt{1,2,3}/cpp/consumer.json` `percentiles.p99` |
| Consumer p99.9: host 195-264, vm 145-161, container-host-net 142-153, container-bridge 167-211 us (computed, observed) | each | `<lane>/alt{1,2,3}/cpp/consumer.json` `percentiles.p99_9`; `verify.log` "lanes side by side" |
| Host vs VM and vm vs container-host-net overlap statements (emit 81-89 vs 80-83; consumer p99 101-104 vs 99-101) | host, vm, container-host-net | same fields as the two rows above |
| container-bridge consumer p99 over container-host-net: 1.39x, 1.04x, 1.03x (rounded, from ns per-run medians 140287/101119, 109183/104511, 105023/102335); gaps 39, 4, 2 us truncated (computed, observed, all under 2x) | container-bridge, container-host-net | `consumer.json` `percentiles.p99`, per-run medians 140/109/105 and 101/104/102; `verify.log` "bridge against host network" |
| `--cpus=2` gives `cpu.max` `200000 100000` | container-cpu-quota | `consumer.json` `runtime.environment.cgroup.cpu_max`; `verify.log` criterion 1 |
| `nr_throttled` 206-207 (quota), 0 (cpuset); `throttled_usec` 37.7-40.6 s (truncated) (quota, summed over 4 vCPUs), 0 (cpuset) (exact, asserted, criterion 1) | container-cpu-quota, container-cpuset | `cpp/consumer.json` `runtime.environment.cgroup.nr_throttled`, `.throttled_usec` |
| Busy pool 4 workers in both limit lanes, none idle (exact) | container-cpu-quota, container-cpuset | `cpp/pool.json` `workers`, `workers_with_no_iterations` |
| Consumer p99.9 quota 53,411-55,574 us vs cpuset 2,912-4,067 us | container-cpu-quota, container-cpuset | `cpp/consumer.json` `percentiles.p99_9` |
| Quota over cpuset p99.9: 18.91x, 13.16x, 18.34x (median of 3 per-alternation ratios); bound 2x asserted; smallest margin 6.58x | container-cpu-quota, container-cpuset | `verify.log` criterion 4 (margins 9.45x, 6.58x, 9.17x) |
| Consumer p50 4,730-4,923 us (quota) vs 60 us (cpuset), same run (computed) | container-cpu-quota, container-cpuset | `consumer.json` `percentiles.p50` |
| Consumer p99 quota 50,462-51,642 us; cpuset 2,085-3,043 us (chapter: 2.0-3.0 ms) | container-cpu-quota, container-cpuset | `consumer.json` `percentiles.p99` |
| Consumer p90 quota 41-42 ms (41,189-42,205 us); cpuset 168-557 us (computed) | container-cpu-quota, container-cpuset | `consumer.json` `percentiles.p90` |
| Throttled time per period per vCPU 45.8-49.2 ms truncated (`throttled_usec / nr_throttled / 4`, computed over 9 alternations); expected 100 - 200/4 = 50 ms (arithmetic) | container-cpu-quota | `consumer.json` `runtime.environment.cgroup.*`; compute.py "throttle arithmetic" |
| Quarkus p99 (median of 3): quota 4.1 / 5.0 / 5.9 ms, cpuset 3.7 / 10.1 / 12.4 ms (observed; order flips; client shares guest CPUs) | container-cpu-quota, container-cpuset | `verify.log` "Quarkus p99 ns, median of 3" (4157439, 5062655, 5939199 vs 3733503, 10166271, 12468223) |
| C++ `hardware_concurrency()` 4 in vm, quota, cpuset (exact, asserted, criterion 2) | vm, container-cpu-quota, container-cpuset | `cpp/probe-cpp.json` `cpus.hardware_concurrency` |
| C++ pool by hardware count 4; cgroup-aware 2 (quota, cpuset), 4 (vm) (exact) | same | `cpp/probe-cpp.json` `pool_size.by_hardware_concurrency`, `pool_size.cgroup_aware` |
| Python `os.cpu_count()` 4 everywhere; `os.process_cpu_count()` 4 (vm, quota), 2 (cpuset) (exact, asserted) | same | `python/probe-python.json` `python.cpu_count`, `python.process_cpu_count` |
| Java `availableProcessors()` 4 (vm), 2 (quota), 2 (cpuset); VT scheduler parallelism 4 / 2 / 2 (exact, asserted) | same | `java/probe-java.json` `java.available_processors`, `java.virtual_thread_parallelism` |
| Java parallel GC threads 4 / 2 / 2 (observed) | same | `java/probe-java.json` `java.parallel_gc_threads` |
| Quarkus: 2 event-loop threads and 8 worker threads in both limit lanes (observed); 8 fixed in `application.properties`; event-loop default max(2, min(heap MiB/10, availableProcessors)) = 2 under either limit, so the run can't separate the CPU view from the floor | container-cpu-quota, container-cpuset | `quarkus/service.json` `service.event_loop_threads`, `service.executor_threads`; `_plans/dependency-pins.md` "Quarkus thread defaults"; `_plans/r04-figures.md` deviation 13.3 |
| `io_uring_setup` errno 1 (EPERM) in all 36 container probes (4 lanes x 3 x 3), 0 in all 9 vm probes (exact, asserted, criterion 3) | container-*, vm | `cpp/probe-cpp.json` `io_uring.setup_errno`; `verify.log` criterion 3 |
| Host `io_uring_setup` 0 (read, never changed; observed) | host | `verify.log` "observed: host alt1 io_uring_setup errno 0" |
| vm steal ticks 0-1 of 8,848-9,886 guest ticks (9 alternations); a tick is 10 ms (`clk_tck` 100) | vm | `vm/altN/steal.json` `steal_ticks`, `total_ticks`, `clk_tck` |
| Container-lane steal ticks up to 10 (container-bridge, run 1, alt 2); host-net 0-8, bridge 0-10, quota 1-5, cpuset 1-7 (computed, observed) | container-* | `<lane>/altN/steal.json` `steal_ticks` |
| Docker default seccomp blocks `io_uring_*` since Engine 25.0; default CFS period 100 ms; `--cpus=N` = `--cpu-period=100000 --cpu-quota=N*100000` | container-* | `_plans/dependency-pins.md` "Docker seccomp and io_uring", "CFS period in Docker" |
| `hardware_concurrency()` reads glibc `get_nprocs()` (online list); `os.process_cpu_count()` follows affinity; `availableProcessors()` = affinity then ceil(quota/period); VT parallelism and GC threads follow it | -- | `_plans/dependency-pins.md` "C++ hardware_concurrency()", "Python CPU count", "JDK 25 container CPU count", "JDK virtual-thread scheduler", "JVM GC threads under a quota" |
| Quarkus event-loop default `max(2, min(heap MiB / 10, availableProcessors))` (not stated in the chapter) | -- | `_plans/dependency-pins.md` "Quarkus thread defaults" |
| Run commit 4434ed1, results committed in cd4a269, runs started 2026-10-25 | all | `r04-run{1,2,3}/run-start.json` `commit`, `started_utc`; git log of `results/` |
| sourced in dependency-pins (Runtime facts for Ch11-13 prose) pins rows from MAIN (sched-bwc.rst, cgroup-v2.rst, Kubernetes QoS/CPU Manager); until then unsourced: CFS bandwidth "stops every thread in the cgroup until the period edge" (supported by the 45.9-49.2 ms arithmetic, not by a pinned doc); Kubernetes QoS class from requests/limits and CPU Manager `static` policy exclusive CPUs for Guaranteed pods with whole-CPU requests; the three companion-site URLs (form `https://patterncatalyst.github.io/<repo>/docs/<page>/`, not checked live) | -- | none |
| Whole host 22-55 permille busy across the 9 host alternations, this lane's simulators and consumer included; guest 3 permille busy in every host alternation | host | `host/altN/host-quiet.json` `busy_permille`; `host/altN/guest-idle.json` `busy_permille`; `lanes.sh` |
| Host placement: consumer on CPU 1, simulators on CPUs 2-7 and 10-15 (outside the consumer's core and CPU 0's core) | host | `host/altN/host-quiet.json` `consumer_cpu`, `simulator_cpus` |
| Up to nine runnable threads in one cgroup on 2 CPUs (4 pool workers + 4 simulators + consumer) | container-cpuset | `cpp/pool.json` `workers`; `examples/13-where-code-runs/README.md` Workload |
| Container online list is the guest's 0-3 (a container doesn't narrow it): `cpus.online` 0-3, `online_count` 4 | container-cpu-quota, container-cpuset | `cpp/probe-cpp.json` `cpus.online`, `cpus.online_count` |
| One set of C++ binary checksums across all lanes (exact, asserted, criterion 5) | all | `verify.log` "one binary"; `*/binaries-*.txt` |
| Guest limits (passt networking, unpinned vCPUs, single-host KVM, no SR-IOV) | vm | `scripts/lab/provision-vm.sh` (passt); `examples/13-where-code-runs/README.md` "What the VM can't show"; `guest-profile.json` |

## Verification status footer

The r03 form, naming the asserted criteria, what's observed only, and the runs (`r04-run1` to `r04-run3`). Ch11 and Ch12: bare-metal host, untuned. Ch13: per lane (host with VM idle; VM `stock-unpinned`; container image digests).
