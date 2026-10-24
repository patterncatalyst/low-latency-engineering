---
title: "r04 plan: threading and I/O models"
render_with_liquid: false
description: "Relay plan for r04: Part 4, Ch11–13 (stackful vs stackless execution, I/O engines and thread-per-core, where the code runs: bare metal, VM, container) on the sortation line, in C++23, Python 3.14 and Java 25. Step status is kept current so a fresh session can resume."
---

Planned by Opus on 2026-10-23 on `release/r04` (cut from main at `dc0f967`, r03.x merged in #6). Status column is updated as steps land. The open decisions in §6 are answered in S1 before execution.

## 0. Facts that shape the plan (host read-only probes 2026-10-23; S0 re-checks and pins)

- **io_uring on the host:** `kernel.io_uring_disabled` = 0 and `io_uring_group` = -1, so unprivileged `io_uring_setup` is allowed. We read the value and never change it. Ch12's io_uring numbers can come from the host.
- **Host scheduling:** `ulimit -r` 0 (no SCHED_FIFO), `ptrace_scope` 0 (`strace -f -c` on our own children works, unprivileged), `perf_event_paranoid` 2 (unchanged; `:u` events and `--control` FIFOs work, r03 S0). `sched_setaffinity` of our own threads is allowed (r03 Q1).
- **C++ toolchain:** GCC 16.2.1 with `-std=c++23` compiles `std::generator` (`__cpp_lib_generator`), `std::print`, `std::expected`, `std::move_only_function` and deducing `this`. `__cpp_lib_senders` is undefined, so `std::execution` (P2300, C++26) isn't available and isn't used. Floor: `CMAKE_CXX_STANDARD 23` with `CMAKE_CXX_STANDARD_REQUIRED ON` (already in `examples/CMakeLists.txt`); `cxx_std_23` on every target.
- **System packages present but not the pin source:** `boost-devel` 1.90.0 and `liburing-devel` 2.13 are installed on the host. Neither is in the guest or the CI `fedora:44` container unless installed there, and the repo rule (protobuf) is latest upstream, pinned, not the distro build. Pins come from `examples/cmake/deps.cmake` (FetchContent with SHA256) per D1/D3.
- **Docker:** Engine 29.9.1 on the host (user in `docker`); Docker Engine + Compose plugin in the guest (cloud-init). No podman.
- **Lab VM:** `lowlat-target` shut off; snapshots `lab-ready` (stock kernel, Docker, no Temurin), `lab-ready-rt` (RT kernel), `lab-ready-iso` (RT + `isolcpus=3` + vcpupin + Temurin). Nothing matches "an ordinary cloud VM" (stock kernel, unpinned, no isolation, with Temurin). S5 makes one (D8). r02 example 07 has the VM driver pattern to copy: `vm/run.sh`, `vm/guest-run.sh`, `deploy-to-vm.sh`, guest `profile.json`, `vm/LABEL`.
- **Kit gaps:** `scripts/profile.sh` records `virt.type` from `systemd-detect-virt` only: no container detection, no cgroup `cpu.max`/`cpuset.cpus.effective`/`cpu.stat`. It needs `jq`, which a UBI minimal image doesn't have. `validate.py vm-runs` knows only `*vm-run*` dirs with `virt.type == kvm`. Ch13 needs both extended, additively (S2, S17).
- **Python:** `examples/.python-version` = `3.14+gil` (r03 lesson: uv would otherwise pick the free-threaded build). Free-threaded lane `UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft uv run --python 3.14t`. `pyhdrh` re-enables the GIL, so the measured free-threaded process writes raw samples and never imports `lowlat_measure`.
- **Java:** parent `examples/pom.xml` sets `maven.compiler.release` 25 and manages JUnit 6.1.3, Jackson 3.2.4, JNA 5.19.1, Agrona, JMH, jcstress. Quarkus 3.x imports its own BOM with JUnit 5 and Jackson 2, so a Quarkus module that inherits this parent would have the parent's managed versions override the imported BOM (D5).
- **Sibling projects (the user's own, reused and cited as companions, not ported from a reference):**
  - `~/Dev/cpp-concurrency-and-parallelism` (main 6326ab3). The examples are C++20 with Conan Boost 1.84 and fmt. Adapt them up to C++23 per the user standard.
    - `11-coroutines-in-depth`: Generator/Task with symmetric transfer and HALO probes. Becomes `std::generator` plus one minimal `Task`.
    - `12-asio-strand`: raw epoll, `io_context`, work guard, strand.
    - `13-fiber-worker-pool`: Boost.Fiber, `protected_fixedsize_stack`.
    - `32-concurrency-in-containers`: `cgroup_probe.cpp`, quota vs cpuset. Its "hardware_concurrency() lies" wording isn't carried over (variant-names/voice rule).
  - `~/Dev/quarkus-optimization` (main b27767f; Quarkus 3.33.1, Java 25): demo-02 (`@RunOnVirtualThread`, `newVirtualThreadPerTaskExecutor`, carrier count), demo-05 (Mutiny `Uni`/`Multi`), demo-06 (G1/ZGC p99 under load in compose).
  - `~/Dev/spring-boot-optimization` (twin; cited only).
- **Shared code not to touch:** `examples/common/line-simulator/**` and the three consumers. r04 kit changes are additive (schema fields, `profile.sh` fields, `lib.sh` helpers). If any step changes the shared receive path, examples 00–10 are re-measured.
- **Release rule:** merged PR + `r04.x` tag + notes-only GitHub release; no tarball.

## 1. Approach

Part 4 asks one question of the decide path: **who holds the wait, and what wakes it?** C++ leads, because it can show each mechanism bare. Java and Python follow in their idiom, and where a language has no equivalent, that divergence is the lesson:
- Python has no stdlib stackful coroutine or io_uring.
- Java has no stackless coroutine and no io_uring in the JDK.
- Python's `os.cpu_count()` and Java's `availableProcessors()` see a container differently.

**One arc on the scan-to-divert path** (480 ms budget, 1.2 m at 2.5 m/s):
- **Ch11 (the wait):** every scan triggers a sort-plan lookup at the warehouse management system (WMS), modelled as a 2 ms wait. By Little's law (Ch2), 10 kHz x 2 ms is 20 in flight per line and a hub at 100 kHz with a 50 ms WMS tail is 5,000. Ch11 compares who holds each wait: OS threads, stackful fibers and virtual threads, or stackless coroutines and event-loop tasks. It measures memory per waiting task, hand-off cost, and what one blocking call does to its neighbours.
- **Ch12 (the wake):**
  - What wakes the receive thread for each datagram: epoll readiness against io_uring completion, measured as system calls per parcel.
  - Shared-nothing thread-per-core against a hand-off pool.
  - For the Java service tier, virtual threads against a reactive event loop against a worker pool, on Quarkus.
- **Ch13 (the place):** the same decide binary and the same Quarkus service on bare metal, in the lab VM, and in Docker containers in that VM (bridge vs host network, CPU quota vs cpuset, default seccomp). It ends with when not to use a container on the hot path (§7a).

Each technique is measured twice, as in r03: at saturation, where the mechanism shows, and on the line, where the budget is the question. Expect again that most differences fit 480 ms many times over at line rate. They matter at hub scale, at saturation and under a CPU quota.

**Criteria** (carried over):
- **Mechanism counters first:** exact frame bytes, syscalls per parcel, voluntary context switches, `nr_throttled`, CPU counts, `errno` from `io_uring_setup`. Then latency.
- **Within-run comparisons only:** latency is compared within one `verify.sh` run. Variants alternate A B A B A B (`interleave`), judged on the median of 3 alternations. p50 is never compared across runs.
- **Margins:** every asserted bound clears 2x in all three calibration runs (S10). Exact counters are exempt and labelled "exact". A margin under 2x is stated in prose, and any bound change goes to the user.
- **No-regression claims** only from a committed interleaved A/B worded "no shift detected".

**Run locations:**
- Ch11 and Ch12 run on the host: bare metal, untuned (`powersave`, `balanced`), serial under the host lock, VM down, threads pinned to distinct physical cores other than CPU 0 where placement is the subject.
- Ch13 runs three lanes in one `verify.sh`, interleaved H V C x3:
  - `host`: bare metal, with the VM booted and idle; the label says so.
  - `vm`: native in the guest.
  - `container`: Docker in the same guest.
- Every report carries `runtime.environment` and the guest profile. The prose states what the VM can and can't show (D9).

**Library choices:**
- C++: Boost.Asio (`awaitable`, `co_spawn`, `steady_timer`) and Boost.Fiber/Boost.Context from one pinned upstream Boost (D1); liburing pinned upstream (D3); `std::generator` for the parcel stream; one minimal hand-rolled `Task<T>` with symmetric transfer, only for the coroutine ping-pong (no std task type before C++26 `std::execution`; said in prose).
- Java: `Thread.ofVirtual`, `Executors.newVirtualThreadPerTaskExecutor`, NIO `Selector`/`DatagramChannel` for the plain-JDK micro lane; Quarkus (latest stable, pinned) for the service tier (`@RunOnVirtualThread`, `@Blocking`, Mutiny `Uni` on the Vert.x event loop) (D5).
- Python: `threading` (GIL and free-threaded), `asyncio` (`DatagramProtocol`, tasks), uvloop if a cp314 wheel exists (D11).

**Rejected:**
- Hand-rolled `Generator<T>` (sibling style): `std::generator` is C++23 and ships in GCC 16.
- Hand-rolled fibers on `ucontext`: deprecated POSIX; Boost.Context is the maintained route.
- cppcoro or libcoro: unmaintained, or adds a second coroutine vocabulary next to Asio's.
- Boost.Cobalt: a third model; named in prose only.
- Netty, Reactor or RxJava as the Java reactive lane: Quarkus (Vert.x and Mutiny) is the idiomatic framework, reuses the user's code, and Vert.x is Netty underneath. Reactor and Netty appear in prose only.
- A Netty io_uring transport lane: scope; the JDK has no io_uring, and that's the divergence.
- `std::execution` (P2300): C++26, not in GCC 16.
- Containers on the host Docker Engine: the quota/cpuset/seccomp lanes create cgroups and bridge veths on the host; all container runs go in the VM.
- minikube or CRC: Kubernetes adds nothing measurable beyond the cgroup and network mechanisms Docker exposes. QoS classes and the CPU Manager static policy are named in prose.
- A VM lane for Ch11 and Ch12: placement and counters on the host answer them.
- io_uring numbers from the VM: the host allows it unprivileged, and VM numbers would mix in virtio.
- Python io_uring through a third-party binding: immature; divergence stated.
- wrk2 as the HTTP load generator: unmaintained; the kit's open-loop client keeps coordinated-omission handling consistent (D6).
- Committing `strace` output, JFR files or container logs raw: summaries only.

## 2. Per chapter

### Ch11: `examples/11-stackful-stackless/` (host)

- **Technique:**
  - (a) Memory per waiting task: 10,000 parked tasks per variant.
  - (b) Hand-off cost: ping-pong between two tasks.
  - (c) The blocking call inside a stackful or stackless task, and what it does to its neighbours (function colouring).
  - (d) The line: one lookup task per parcel with a 2 ms WMS wait.
- **Workload:**
  - (a) 10,000 tasks each waiting on a 1 s timer; RSS and bytes measured after all are parked (start gate: `std::latch`/`CountDownLatch`/`threading.Barrier`, handshake asserted).
  - (b) 1,000,000 round trips in batches of 1,000, two tasks on one OS thread for fibers and coroutines, two pinned OS threads for threads.
  - (c) 1,000 tasks on 2 ms timers; one task makes a blocking 2 ms call; wake lateness of the others.
  - (d) Line 10 kHz x 20 s, UDP 47310 to 47314 per variant, lookup wait 2 ms (timer in-process; no network dependency), decide after the wait; command channel separate from the data path.
- **C++ (C++23):**
  - Variants:
    - `os-thread`: `std::jthread` + `std::stop_token`, `std::binary_semaphore` hand-off.
    - `fiber`: Boost.Fiber `round_robin`, `protected_fixedsize_stack(64 KiB)`, `buffered_channel`.
    - `coroutine`: Asio `awaitable` + `steady_timer` for waits; minimal `Task<T>` with symmetric transfer for the ping-pong.
  - Measurement details:
    - Frame bytes: promise `operator new` counter (exact for the frames it sees; HALO probe adapted from the sibling). S0 probe: GCC 16 `-O2` did not elide a non-escaping frame, but HALO is allowed, so frames must escape (stored and parked) in the probe.
    - `std::generator<ParcelEvent>` feeds the parcels.
    - `std::expected` for parse and setup errors; `std::print` output.
    - External-linkage sink or `benchmark::DoNotOptimize` in every bench loop, with objdump of the loop in S9.
    - Defect variant `--blocking-sleep-in-fiber` (`std::this_thread::sleep_for` inside a fiber).
- **Java:**
  - Variants: `platform-thread` (`Thread.ofPlatform`) against `virtual-thread` (`Thread.ofVirtual`, `Executors.newVirtualThreadPerTaskExecutor`).
  - Measurements:
    - Heap per parked VT: `MemoryMXBean` after a forced GC, observed; RSS for platform threads.
    - Hand-off: `SynchronousQueue` ping-pong, VT carriers at `-Djdk.virtualThreadScheduler.parallelism=1` for the one-carrier case, recorded in `build.flags`.
    - Pinning: JFR `jdk.VirtualThreadPinned` count for a `synchronized` wait (S0 verifies JEP 491 behaviour in 25: expected 0) and for a native-frame case (observed).
  - Whole measured loop warmed (r03 lesson).
- **Python** (both builds):
  - `threads` against `asyncio` tasks.
  - Bytes per task: measured by `tracemalloc` for tasks (it counts blocks from Python's allocators, with no exactness claim), RSS for threads.
  - Hand-off: `asyncio.Future` against `threading.Event`/`queue.SimpleQueue`.
  - Defect `--blocking-sleep-in-coroutine` (`time.sleep` in a coroutine): loop lateness, plus asyncio debug `slow_callback_duration` warning count (exact).
  - No stdlib stackful coroutine: greenlet/gevent named in prose as third-party, not measured.
  - Free-threaded measured process writes raw `int64` samples (`array('q').tofile`) and asserts `sys._is_gil_enabled()` is False after its imports. A GIL process converts the samples (`lowlat-report from-samples`).
- **Measured:**
  - bytes per parked task;
  - RSS for 10,000 tasks;
  - round-trip p50/p99/p99.9;
  - voluntary and involuntary context switches per round trip;
  - neighbour wake lateness p50/p99 with and without the blocking call;
  - line end-to-end p50/p99/p99.9 per variant.
- **Asserts (provisional; S10 decides):**
  1. (exact) C++ coroutine frame bytes ≤ 1,024 per waiting task and ≥ 1 allocation per frame; Python asyncio task bytes ≤ 1/10 of the per-thread RSS increment (S10); Java VT heap per parked task ≤ 1/10 of the platform thread RSS increment (S10).
  2. RSS for 10,000 parked tasks: `os-thread` ≥ 10x `fiber` ≥ 10x `coroutine` (C++); `platform-thread` ≥ 10x `virtual-thread` (Java). S10 confirms margins; RSS is a counter, not a latency.
  3. (exact-ish) Voluntary context switches per round trip: `os-thread` ≥ 0.9, `fiber` and `coroutine` ≤ 0.001 (same OS thread).
  4. Round-trip p50, same run, median of 3 alternations: `os-thread` ≥ 5x `fiber` and ≥ 5x `coroutine` (C++); `platform-thread` ≥ 2x `virtual-thread` (Java). Bounds provisional.
  5. Defect variants: neighbour wake lateness p99 ≥ 1 ms for a 2 ms blocking call. 2x by construction, stated as such. C++ fiber, Python coroutine.
  6. Line: count 200,000, `dropped=0`, all commands received, `check`; end-to-end percentiles observed.
  7. Every report: `build.flags` (Java), `runtime.placement` where pinned, `runtime.python_build`.
- **Observed:** fiber vs coroutine round trip; Java VT pinning counts; Python free-threaded hand-off; tails; line percentiles ("every variant fits 480 ms by orders of magnitude").
- **Figures:** 11.1 `11-who-holds-the-wait`, 11.2 `11-switch-path`, 11.3 `11-blocking-in-a-fiber` (optional).

### Ch12: `examples/12-io-engines/` (host)

- **Technique:**
  - (a) Readiness against completion on the UDP receive path.
  - (b) Thread-per-core (shared-nothing, `SO_REUSEPORT`) against an acceptor plus a hand-off pool.
  - (c) The Java service tier: virtual threads against a reactive event loop against a worker pool, with a blocking dependency.
  - (d) Python: asyncio and threads.
- **Workload:**
  - (a) and (b): four simulator instances as four tunnel cameras (Ch10 pattern, no simulator change). Line at 2.5 kHz each x 20 s; saturation at a rate S10 calibrates (target: the highest rate with `dropped=0` for the slowest variant). Ports 47320 to 47335.
  - (c) The sort-plan lookup service over HTTP/1.1 on loopback, 2 ms downstream wait. Open-loop client at λ chosen so λW exceeds the worker pool. Example: 12 kHz x 2 ms = 24 in flight against a pool of 16 (pool fixed in config, S0 records Quarkus's default). The hand-off from the receive path stays the data path; commands keep their own channel.
- **C++:**
  - `epoll`: raw `epoll_wait` + `recvmsg`, shown once; the Asio reactor is the idiomatic form.
  - `recvmmsg` batch.
  - `io-uring`: liburing multishot `recvmsg` with a provided buffer ring.
  - `asio-io-uring`: Asio built with its io_uring backend, if S0 confirms sockets are supported on it (D16), observed.
  - Thread-per-core: 4 receive threads pinned to distinct cores, each with its own `SO_REUSEPORT` socket and ring, against 1 receive thread + Ch10's MPSC hand-off to 4 workers.
  - In-program exact counters: system calls (each `epoll_wait`/`recvmsg`/`recvmmsg`/`io_uring_enter` call counted), CQEs per enter, cross-thread hand-offs per parcel. `strace -f -c` on the host cross-checks the syscall counts (observed; summary committed, not raw).
  - Shared counters `alignas(std::hardware_destructive_interference_size)` (r03 lesson).
- **Java:**
  - Plain-JDK micro lane: `selector` (NIO `Selector` + non-blocking `DatagramChannel`) against `virtual-thread-blocking` (blocking `DatagramChannel.receive` in a VT; the JDK's poller is epoll underneath), against thread-per-core with `StandardSocketOptions.SO_REUSEPORT`. No io_uring in the JDK: divergence.
  - Quarkus service (`examples/12-io-engines/quarkus/`, standalone module, D5):
    - `event-loop`: `Uni` with a non-blocking 2 ms delay on the Vert.x event loop.
    - `worker-pool`: `@Blocking`, `Thread.sleep(2)`, pool size fixed.
    - `virtual-thread`: `@RunOnVirtualThread`, `Thread.sleep(2)`.
    - Defect `blocking-on-event-loop`: `Thread.sleep(2)` on the event loop, with `quarkus.vertx.max-event-loop-execute-time=1ms` and a short `quarkus.vertx.warning-exception-time` set for this variant only (the 2 s defaults would log nothing for a 2 ms block).
  - Client: plain-JDK open-loop driver (VTs + `HttpClient`, intended start times, HdrHistogram, `lowlat-report/1`) in the parent reactor (D6).
  - Exact counters: Vert.x blocked-thread warnings (log count), carrier thread count, worker pool active max.
- **Python:**
  - `asyncio-datagram` (`loop.create_datagram_endpoint`, epoll selector) against `blocking-thread` (one thread per socket; GIL and free-threaded) against `uvloop` (GIL only, if D11).
  - System calls per parcel observed through `strace -c` summary.
  - No stdlib io_uring: divergence.
- **Measured:**
  - syscalls per parcel (exact);
  - CQEs per enter;
  - receive p50/p99/p99.9 at line rate and at saturation;
  - hand-offs per parcel;
  - service p50/p99/p99.9 per variant at the calibrated λ;
  - blocked-thread warnings;
  - carrier count;
  - `dropped`.
- **Asserts (provisional; S10):**
  1. (exact) At saturation: `io-uring` `io_uring_enter` calls per parcel ≤ 1/4 of `epoll` syscalls per parcel (`epoll_wait` + `recvmsg`, ≥ 2 per parcel by construction when one datagram is ready per wake); `recvmmsg` syscalls per parcel < 1.
  2. (exact) Thread-per-core cross-thread hand-offs per parcel = 0; pool = 1.
  3. Saturation receive p99, same run, median of 3: thread-per-core ≤ 1/2 of acceptor-pool (C++). `io-uring` vs `epoll` p99 observed unless S10 shows ≥ 2x margin.
  4. Quarkus at λW > pool: `worker-pool` p99 ≥ 3x `virtual-thread` p99 (same run, median of 3); `event-loop` vs `virtual-thread` observed.
  5. Defect `blocking-on-event-loop`: blocked-thread warnings ≥ 1 (exact) and p99 ≥ 2 ms. Vert.x warns only after `quarkus.vertx.max-event-loop-execute-time`, which defaults to 2 s, so at defaults a 2 ms block gives 0 warnings. The defect config therefore sets `quarkus.vertx.max-event-loop-execute-time=1ms` (below the 2 ms block) and a short `quarkus.vertx.warning-exception-time` (for example `1ms`), which `VertxCoreRecorder` also uses as the blocked-thread-checker period, so at least one warning is reachable in the run. Keys and units are cited in `dependency-pins.md` (r04 pins); S7 confirms the count.
  6. Line: 200,000 parcels, `dropped=0` per camera, `check`; percentiles observed (all fit 480 ms).
  7. Every report: `build.flags`, `runtime.placement`, `runtime.counters`.
- **Observed:** `asio-io-uring`, Python lanes, uvloop, JDK selector vs VT, `strace` cross-check, event-loop vs VT tails.
- **Figures:** 12.1 `12-readiness-vs-completion`, 12.2 `12-thread-per-core`, 12.3 `12-vt-vs-event-loop`.

### Ch13: `examples/13-where-code-runs/` (host + VM + container in the VM)

- **Technique:**
  - (a) The jitter floor and the decide path in three places.
  - (b) Container networking: bridge veth against host network.
  - (c) CPU quota (CFS bandwidth throttling) against cpuset.
  - (d) What each runtime thinks it has: CPU count and pool sizing under quota and cpuset.
  - (e) Default seccomp and io_uring.
  - (f) When not to use a container.
- **Workload:**
  - Line 10 kHz x 20 s per lane: simulator and C++ consumer in the same environment (clock-domain rule). For `bridge`, the simulator runs in the guest and the consumer in the container, so the datagram crosses the veth.
  - A pool of 4 busy decide workers under `--cpus=2` against `--cpuset-cpus=2,3`.
  - The Quarkus service from Ch12 as a container under quota against cpuset, driven by the Ch12 client in the guest.
  - Interleaved per run: `host`, `vm`, `container-host-net`, `container-bridge`, `container-cpu-quota`, `container-cpuset`, x3 alternations.
- **C++:**
  - The Ch12 receive consumer and the line simulator, built once in a UBI 10 builder image (D10), so the same binary runs on the host, in the guest and in the container.
  - `cgroup_probe` adapted to C++23 from the sibling Ch32: reads `cpu.max`, `cpuset.cpus.effective` and `cpu.stat`, with `std::expected` errors. Reports `std::thread::hardware_concurrency()` and the derived pool size.
  - `io_uring_setup` probe (`errno`).
- **Java:** the Quarkus container (UBI 10 minimal + pinned Temurin). Records `availableProcessors()`, Vert.x event-loop count (`max(2, min(heap MiB / 10, CPUs))`, so it depends on the heap limit as well as the CPU limit), VT scheduler parallelism and GC thread count at startup (exact), and service p99 under quota vs cpuset.
- **Python:** `os.cpu_count()`, `os.process_cpu_count()` and `len(os.sched_getaffinity(0))` under quota and cpuset (exact); no latency lane.
- **Measured:**
  - simulator emit lateness p50/p99/p99.9 per environment (jitter floor);
  - consumer end-to-end p50/p99/p99.9;
  - guest steal ticks (`/proc/stat`), observed;
  - `nr_throttled` and `throttled_usec` (exact);
  - CPU counts (exact);
  - `io_uring_setup` errno (exact);
  - Quarkus p99.
- **Asserts (provisional; S10; the comparison wording is D9):**
  1. (exact) `container-cpu-quota` `nr_throttled` ≥ 1 during the run; `container-cpuset` `nr_throttled` = 0.
  2. (exact) On the 4-vCPU guest, S0 settled the expected values from docs and source (S5 confirms in the guest before they become asserts). C++ `hardware_concurrency()` = online CPUs (glibc `get_nprocs` reads `/sys/devices/system/cpu/online`) = 4 under both `--cpus=2` and `--cpuset-cpus=2,3`; in a container that sysfs file is not namespaced, so it shows the guest's CPUs. Python `os.process_cpu_count()` follows the affinity mask: 4 under the quota, 2 under the cpuset; `os.cpu_count()` = 4 in both. Java `availableProcessors()` = 2 in both (cpuset via affinity, quota via ceil(quota/period)).
  3. (exact) `io_uring_setup` in a container under Docker's default seccomp returns `EPERM` (if S0 confirms with the guest's Docker version; otherwise observed). The same binary in the guest outside a container succeeds.
  4. `container-cpu-quota` consumer p99.9 ≥ 2x `container-cpuset` (same boot, median of 3); S10 decides asserted or observed.
  5. Every lane: count, `dropped=0`, `check`, `runtime.environment.kind` matching its directory, guest profile recorded.
- **Observed:**
  - host vs VM jitter floor and end-to-end percentiles (labelled, same run, D9);
  - bridge vs host network;
  - steal time;
  - Quarkus p99 quota vs cpuset;
  - Java ergonomics under quota (GC threads, event loops).
- **What the VM can't show (in the chapter):**
  - a production hypervisor;
  - dedicated or isolated host cores (Part 5);
  - SR-IOV or passthrough NICs;
  - a quiet host (the laptop host is untuned and shared).
  - Container costs are measured relative to the VM-native lane in the same guest, so they're container-in-VM costs, not container-on-bare-metal.
- **Figures:** 13.1 `13-three-places`, 13.2 `13-quota-vs-cpuset`, 13.3 `13-cpu-count-views` (optional).

## 3. Steps

Model: `sonnet` executes, `opus` plans and validates. MAIN means run in the main session (measurement, lab lifecycle, user gates). One checkpoint commit per step (scopes `r04.x`, `demo-11`, `demo-12`, `demo-13`, `§11`, `§12`, `§13`). Stage exact paths; never `git --autostash`; never `git reset --hard` with uncommitted edits. Host runs are serial under `flock` on the session's `host-bench.lock` (path kept out of the repo).

| id | Title | Files touched | Depends on | Model | Status |
|---|---|---|---|---|---|
| S0 | Upstream survey, exact pins, read-only probes | `_plans/dependency-pins.md` ("r04 pins"), `versions.env` (only if a tarball or image is pinned there) | – | sonnet (opus validates) | done |
| S1 | Record D1–D17 answers; iteration-plan status (r03 complete, #6, `r03.x`; r04 in progress); commit this plan, `r04-chapters.md`, `r04-figures.md` | `_plans/iteration-plan.md`, `_plans/r04-*.md`, `CLAUDE.md` only if D9 changes a rule | user answers | opus (MAIN) | done |
| S2 | Report and profile contract, additive in `lowlat-report/1` | `contracts/measurement/latency-report.schema.json`, `contracts/measurement/examples/`, `examples/common/measure-{py,cpp,java}/**`, `examples/common/measure-fixtures/`, `scripts/profile.sh`, `scripts/scrub-host-ids.py` | S0 | sonnet | todo |
| S3 | `lib.sh` helpers: lanes, containers, raw-sample conversion | `examples/_lib/lib.sh`, `examples/_lib/tests/`, `examples/common/measure-py/**` | S2 | sonnet | todo |
| S4 | Build wiring: Boost, liburing, C++23 floor, Maven modules, Quarkus module, uv packages, CI | `examples/cmake/deps.cmake`, `examples/CMakeLists.txt`, `examples/1[1-3]-*/cpp/CMakeLists.txt`, `examples/pom.xml`, `examples/1[1-3]-*/java/pom.xml`, `examples/12-io-engines/quarkus/pom.xml`, `examples/pyproject.toml`, `examples/1[1-3]-*/*-py/pyproject.toml`, `.github/workflows/ci.yml` | S0, S2 | sonnet | done (pending validation) |
| S5 | Lab: guest profile `stock-unpinned`, snapshot `lab-ready-r04`, images built and digest-pinned in the guest | `scripts/lab/guest-profiles/stock-unpinned.conf`, `scripts/lab/README.md`, `scripts/lab/install-guest-tools.sh` (liburing/strace if needed), `scripts/check-prereqs.sh` (`--vm` r04 checks), `examples/13-where-code-runs/containers/{cpp,java,python}/Containerfile`, `examples/13-where-code-runs/compose.yaml` | S0, S4 | opus (MAIN) | todo |
| S6 | Example 11 (C++, Java, Python both builds) + `verify.sh` + README | `examples/11-stackful-stackless/**` | S3, S4 | sonnet | todo |
| S7 | Example 12 (C++, plain-JDK Java, Quarkus service + open-loop client, Python) + `verify.sh` + README | `examples/12-io-engines/**` | S3, S4 | sonnet | todo |
| S8 | Example 13 (host, VM, container lanes) + `verify.sh` + `vm/run.sh` + `vm/guest-run.sh` + README | `examples/13-where-code-runs/**` | S3, S5, S7 | sonnet (VM runs by MAIN) | todo |
| S9 | Idiom review before calibration (`lgtm-idiomatic-review`) on 11–13 and kit diffs; r03 lesson checks; fix now | all r04 code | S6, S7, S8 | opus + sonnet fixes | todo |
| S10 | Calibration gate: 3 quiet dry runs each into `results/latest`; margin table; user decides asserted vs observed | READMEs, this file's Follow-ups | S9 | opus (MAIN) | todo |
| S11 | Measurement `r04-run{1,2,3}` for 11, 12 (host) and 13 (host+VM+container), serial, one recorded commit | `examples/1[1-3]-*/results/r04-run*/` | S10 | opus (MAIN) | todo |
| S12 | Figures 11.1–11.3, 12.1–12.3, 13.1–13.3; value table from S11 only | `_plans/r04-figures.md`, `diagrams/1[1-3]-*.py`, `assets/diagrams/`, `_data/diagrams.yml` | S11 | sonnet | todo |
| S13 | Ch11 prose | `_docs/11-stackful-stackless.md`, `_plans/r04-chapters.md` (claims table) | S12 | sonnet | todo |
| S14 | Ch12 prose | `_docs/12-io-engines.md`, `_plans/r04-chapters.md` | S12 | sonnet | todo |
| S15 | Ch13 prose | `_docs/13-where-code-runs.md`, `_plans/r04-chapters.md` | S12 | sonnet | todo |
| S16 | Wiring: example pages, outline links, forward links, reconciliation, iteration plan | `_example_pages/1[1-3]-*.md`, `_docs/00-outline.md`, `_docs/10-lockfree-waitfree.md` and any doc naming Ch11–13, `examples/README.md`, `_plans/reconciliation-plan.md`, `_plans/iteration-plan.md` | S13–S15 | sonnet | todo |
| S17 | `validate.py` new checks + `--self-test` planted cases + CI | `scripts/validate.py`, `.github/workflows/ci.yml` | S4, S16 | sonnet | todo |
| S18 | Prose fact check + house-voice pass with stats | `_docs/1[1-3]-*.md`, READMEs 11–13, `_data/diagrams.yml`, `_plans/r04-*` | S17 | opus + sonnet | todo |
| S19 | Re-measure gate | results, chapters, figures, reconciliation | S18 | opus (MAIN) | todo |
| S20 | Opus validation | – | S19 | opus (MAIN) | todo |
| S21 | Ship: PR `release/r04` → main, `ci-ok` green, squash-merge (user OK), delete branch, tag `r04.x`, notes-only release | – | S20 | opus (MAIN) | todo |

### Step contents and acceptance criteria

**S0 survey + probes** (read-only; nothing installed on the host; user-local uv/Maven caches allowed as in r03)
- Pins with version, licence, source, date and hold reason:
  - Boost latest stable (GitHub `boostorg/boost` releases; the `boost-1.N.0-cmake.tar.xz` asset and SHA256);
  - liburing latest tag (`axboe/liburing`);
  - Quarkus latest stable and latest LTS (Maven Central `io.quarkus.platform:quarkus-bom` metadata; the quarkus.io LTS page). The sibling uses 3.33.1, so record whether it's still current;
  - uvloop latest plus whether a cp314 wheel and a cp314t wheel exist (PyPI JSON);
  - UBI images, newest first, exact tags plus digests: `registry.access.redhat.com/ubi10/ubi`, `ubi10/ubi-minimal`, `ubi10/openjdk-25-runtime` (does it exist?), `ubi10/python-314` (does it exist?), with ubi9 fallbacks;
  - Docker Engine version in the guest (recorded);
  - CPython 3.14.9 hold re-check; uv hold re-check.
- Probes (record works/fallback):
  - GCC 16 C++23 features above (again, with the CMake preset);
  - RHEL 10 GCC version in the `ubi10/ubi` builder and whether it compiles the same C++23 features (`<generator>`, `<print>`; needs GCC 14+);
  - `io_uring_disabled` in the guest (read);
  - in the guest: `docker run --rm <ubi10 image>` with the probe binary, `io_uring_setup` errno under the default seccomp profile;
  - Boost.Asio io_uring backend: docs for `BOOST_ASIO_HAS_IO_URING`, `BOOST_ASIO_DISABLE_EPOLL` and whether sockets use it (D16);
  - JDK 25 JEP 491 (synchronized no longer pins; which cases still pin) from the JEP text;
  - `availableProcessors()` under a CPU quota (JDK container support docs); Python `os.process_cpu_count()` docs (3.13+, affinity); glibc `get_nprocs`/`sched_getaffinity` behaviour for `hardware_concurrency`;
  - Quarkus defaults: worker pool max size, event-loop count, `@RunOnVirtualThread` requirements;
  - asyncio on the free-threaded 3.14 build (docs);
  - guest vPMU present (`perf stat -e cycles:u true` in the guest), observed only.
- Acceptance:
  - every new dependency and image has an exact version (images: tag + digest), licence, source and date; no ranges, `latest` or EA;
  - every probe has a recorded result;
  - every runtime fact later asserted in §2 has a doc citation or a probe result in `dependency-pins.md`.

**S1** Acceptance:
- §6 answers in Follow-ups with dates;
- `iteration-plan.md` shows r03 complete (#6, `r03.x`) and r04 in progress;
- the three plan files committed (`docs(r04.x): plan`).

**S2 contract**
- Additive report fields:
  - `runtime.environment` {`kind` ∈ `host`|`vm`|`container`, `guest_profile` (snapshot + profile name, VM and container only), `container` {`runtime`, `image`, `image_digest`, `network`, `cpu_quota`, `cpuset`, `seccomp`}, `cgroup` {`cpu_max`, `cpuset_effective`, `nr_throttled`, `throttled_usec`}};
  - `runtime.counters` reused for syscalls, CQEs, hand-offs and warnings.
- `profile.sh`, additive:
  - `virt.container` (`systemd-detect-virt --container`, falling back to `/.dockerenv`, `/run/.containerenv`, `/proc/1/cgroup`);
  - `cgroup` block from `/sys/fs/cgroup/{cpu.max,cpuset.cpus.effective,cpu.stat}`;
  - `host_label` = `container` inside a container (the container hostname is its ID: never recorded).
- Container profile written by a static path that needs no `jq` in the image: the host-side driver runs `profile.sh` in the guest and merges the container fields read through `docker inspect` and the container's cgroup files. Alternatively a small Python profile writer; S2 picks one, recorded.
- `scrub-host-ids.py` learns container IDs (64-hex and 12-hex) and guest-user home paths.
- Acceptance:
  - a report with `runtime.environment` passes `lowlat-report check`;
  - a planted report with `environment.kind: "container"` and no `container.image_digest` fails;
  - all committed r01–r03 reports still pass `check` (`RECHECK` over every `results/r0[1-3]-*`);
  - `profile.sh | jq .virt` on the host shows `{"type":"none","container":"none"}`;
  - writer goldens updated in `measure-fixtures/`.

**S3 lib.sh**
- `require_quiet_host --lab-idle` (allow `lowlat-target` running idle, record it in `run-start.json`);
- `guest` and `guest_fetch` (from 07's `vm/run.sh`, promoted);
- `container_run NAME -- ARGS` (docker in the guest, refuses `--privileged`, records `docker inspect` digest/network/cpus/cpuset/seccomp);
- `cgroup_stat CONTAINER` (`nr_throttled`, `throttled_usec`);
- `interleave_env N LANES...`;
- `strace_summary OUT -- CMD` (`strace -f -c -o`, scrubbed, summary only);
- `from_samples` (`lowlat-report from-samples` for free-threaded raw samples).
- Acceptance:
  - `examples/_lib/tests/` covers each helper (container helpers with a fake `docker` on PATH);
  - `bash -n` and shellcheck pass;
  - `from-samples` round-trips a known sample set to the same percentiles as `lowlat_measure` (identity test);
  - 07's `vm/run.sh` re-pointed to the promoted helpers with `RECHECK=results/r02-vm-run{1,2,3}` exit 0 (no re-measure), or left untouched (S3 decides, recorded).

**S4 build wiring**
- Boost per D1: FetchContent of the pinned `boost-1.N.0-cmake.tar.xz` with SHA256, `BOOST_INCLUDE_LIBRARIES "asio;fiber;context"`, static.
- liburing per D3: `ExternalProject_Add` with configure/make into the build tree, static `liburing.a`, imported target `lowlat::uring`.
- C++23 guard in `examples/CMakeLists.txt`: `if(CMAKE_CXX_STANDARD LESS 23) message(FATAL_ERROR ...)`. No target may set `cxx_std_20` or lower, or `-std=c++20`.
- Maven modules `11-stackful-stackless/java`, `12-io-engines/java` (micro lane + open-loop client), `13-where-code-runs/java` (CPU-count probe) in `examples/pom.xml`.
- Quarkus per D5: `examples/12-io-engines/quarkus/` with no `<parent>`, importing `quarkus-bom`, `maven.compiler.release` 25, enforcer (Java [25,), Maven [3.9,), `dependencyConvergence`). Listed in the aggregator `<modules>`, so one `mvn -f examples/pom.xml verify` builds it.
- uv packages `lowlat-tasks` (`11-*/tasks-py`), `lowlat-io` (`12-*/io-py`), `lowlat-place` (`13-*/place-py`); `requires-python >=3.14`.
- CI: C++ and Java build + deterministic unit tests for 11–13; io_uring tests skip with a recorded reason on `EPERM`/`ENOSYS` (GitHub runners' Docker seccomp); Quarkus `@QuarkusTest` smoke only.
- Acceptance:
  - `cmake --preset release && cmake --build --preset release` and `ctest` pass;
  - `mvn -B -f examples/pom.xml verify` passes with the enforcer and `-Xlint:all -Werror` (Quarkus module included);
  - `uv sync` and `ruff check`/`ruff format --check` pass;
  - `uv run python -c 'import sys; assert sys._is_gil_enabled()'` passes in `examples/` (the `+gil` lesson);
  - `grep -rnE 'cxx_std_(1[147]|20)|std=c\+\+(1[147]|2a|20)|CMAKE_CXX_STANDARD +(1[147]|20)' examples/ --include=CMakeLists.txt --include='*.cmake' --include=Containerfile` prints nothing;
  - `mvn help:evaluate -Dexpression=maven.compiler.release` returns 25 for every module including Quarkus;
  - one wiring test per new target.

**S5 lab** (MAIN; guest only; host unchanged)
- `revert-vm.sh lowlat-target lab-ready`, `lab-up.sh`, `install-guest-tools.sh` (Temurin pin, `stress-ng`, plus `strace` and `perf` if absent).
- `scripts/lab/guest-profiles/stock-unpinned.conf` documents the profile: stock Fedora 44 kernel 7.2, 4 vCPU unpinned, no `isolcpus`, guest tuned profile recorded, Docker Engine version, `io_uring_disabled` value.
- Build images in the guest from the Containerfiles (UBI 10 per D10, exact tags), record digests in `examples/13-where-code-runs/containers/IMAGES.lock`.
- `snapshot-vm.sh lowlat-target lab-ready-r04`; `lab-down.sh`.
- Acceptance:
  - `virsh snapshot-list lowlat-target` lists `lab-ready-r04`;
  - `check-prereqs.sh --vm` passes with the r04 checks (Temurin version, Docker up, images present with the locked digests, stock kernel, no `isolcpus` in `/proc/cmdline`);
  - `profile.sh` diff of the host before and after S5 shows no change other than `captured_at`/`load`;
  - `ebpf-*` and `systems-*` domains untouched (`virsh list --all` state unchanged).

**S6 / S7 / S8 examples**
- Each example: `verify.sh` asserts its §2 criteria; README states technique, workload, expected effect, observation surfaces (terminal output; Grafana "no panel by design", Part 7) and licences (Boost BSL-1.0, liburing MIT/LGPL dual per its COPYING, Quarkus Apache-2.0, uvloop MIT/Apache-2.0).
- r03 lessons built in:
  - start gates (`std::latch`, `CountDownLatch`, `threading.Barrier`) with a recorded start skew asserted under 1 ms;
  - Java warms the whole measured loop;
  - bench loops end in an external-linkage sink;
  - shared counters padded with `alignas(std::hardware_destructive_interference_size)`;
  - the free-threaded process asserts the GIL stayed off and imports no `lowlat_measure`;
  - `verify.sh` clears `*.log` at start, so the driver logs go outside the results dir and are moved in at the end.
- S8 adds `vm/run.sh` (host driver, reverts `lab-ready-r04` before the run, `--lab-idle` host lane) and `vm/guest-run.sh` (VM-native and container lanes).
- Acceptance:
  - each `verify.sh` exits 0 on the host (and, for 13, with the guest up);
  - variant names only from §2 (`validate.py variant-names`);
  - placement asserted per pinned thread;
  - the Ch13 container lanes record `runtime.environment.container.image_digest` equal to `IMAGES.lock`.

**S9 idiom review (before calibration, r03 lesson)**
- `lgtm-idiomatic-review` scan + read on 11–13 C++, Java (plain + Quarkus), Python and the kit diff.
- Specific checks:
  - every hand-rolled construct is justified in the README (the minimal `Task<T>`, the raw epoll loop shown beside Asio);
  - no `std::thread` where `std::jthread` + `stop_token` fits;
  - `std::print` over iostream in new code;
  - `std::expected` over sentinel returns;
  - Quarkus idioms (`@RunOnVirtualThread` on REST endpoints only, no `Uni.await()` on the event loop, config in `application.properties`);
  - asyncio idioms (`asyncio.run`, `TaskGroup`, no `get_event_loop()`);
  - objdump shows each bench loop survives;
  - no false sharing in any shared counter (`alignas` audit).
- Acceptance: scanner ban-tier 0 after triage; findings fixed in this step; any change to a measured path is recorded so S10 runs on the final code.

**S10 calibration gate** (MAIN)
- 3 quiet dry runs of 11, 12 and 13 into `results/latest` (uncommitted).
- Margin table per asserted non-exact criterion; tuned parameters (saturation rate, λ, pool size, task counts) into READMEs.
- Acceptance:
  - margin table committed in Follow-ups;
  - every asserted bound clears ≥ 2x in all 3 dry runs, or a recorded user decision moves it to observed;
  - exact counters labelled.

**S11 measurement** (MAIN)
- 11 and 12: host, VM down, `require_quiet_host`, load1 ≤ 2 at start, under the host flock.
- 13: guest reverted to `lab-ready-r04` before each run, `--lab-idle` host lane, VM down after.
- Each run dir gets `run-start.json` (example, run, UTC start, load1, commit, virt, lab VM state, driver, guest snapshot for 13).
- Driver logs written outside the results dir, moved in after `verify.sh` exits, piped through `scrub-host-ids.py --filter`.
- Acceptance:
  - every report passes `check` and carries `profile.virt`, `loadavg`, `runtime.placement` (pinned) and `runtime.environment` (13);
  - every `verify.log` ends with all criteria passing;
  - `validate.py host-ids` passes;
  - r04 results ≤ 25 MB total;
  - `git diff --stat main -- examples/common/line-simulator` empty, or 00–10 re-measured.

**S12 figures**
- Acceptance:
  - ≥ 2 `_data/diagrams.yml` entries per chapter (target 3);
  - every SVG/`.excalidraw` regenerates byte-identically from `diagrams/*.py`;
  - captions `Figure N.x: …` with a colon, no em dash;
  - every number is a parameter, a code constant or an S11 range in `r04-figures.md`.

**S13 / S14 / S15 prose**
- Acceptance:
  - 1,900–2,500 words (`scripts/wordcount.sh`);
  - `part: "Threading & I/O Models"`;
  - full spine: Learning objectives, Why this matters, Diagram, Concept, How the code works with before/after pairs and `#A`/`#B` callouts, Measure, Cross-check, What you learned, For deeper coverage, verification-status footer;
  - every number traceable to a committed S11 file and profile-labelled (Ch13 labels each lane `host`/`vm`/`container`);
  - no mean; p50 only within a run; sub-2x margins stated; `listings` and `codetabs` pass;
  - "For deeper coverage" uses only hub-verified books (Williams; Grimm; Bobrov; Tanenbaum *Modern Operating Systems*; *Optimizing Cloud Native Java*; Andrist & Sehr *C++ High Performance*; Ghosh; Enberg; *Kubernetes Patterns*; Rice *Container Security*) and companion sites (cpp-concurrency-and-parallelism Ch11/12/13/32; linux-systems-programming 09/10/32/34/35/55; quarkus-optimization; spring-boot-optimization; cpp-container-optimization-tutorial);
  - house voice from the first draft: `scan.sh --tier ban` 0, `scan.sh --stats` no em dash/`stiff`/`uniform`, triad candidates triaged, sections open on a line object.

**S16 wiring**
- Acceptance:
  - examples page lists 00–13;
  - outline Ch11–13 linked with `relative_url`;
  - Ch10's "Chapter 11 … Chapter 12" bullet becomes links;
  - reconciliation 11.x/12.x/13.x rows plus the runs rows (host, VM, container profiles);
  - site chrome links only to reader content (no `/plans/`).

**S17 validate.py + CI**
- New checks:
  - **`env-labels`** (generalizes `vm-runs`): every report under `results/r04-*` or later of chapter 13 has `runtime.environment.kind` equal to its lane directory (`host/`, `vm/`, `container-*/`). `vm` and `container` reports have `profile.virt.type` `kvm` and a non-empty `guest_profile`. `container` reports have `image` with an exact tag and an `image_digest` `sha256:…` matching `IMAGES.lock`. The old `vm-runs` behaviour is kept for `*vm-run*`.
  - **`lang-floor`**: no CMake/Containerfile/compile flag below C++23; every `pom.xml` (including any with no parent) resolves `maven.compiler.release` ≥ 25; every `pyproject.toml` `requires-python` floor ≥ 3.14; every Containerfile base runtime is JDK ≥ 25 / Python ≥ 3.14 where it names one.
  - **`image-pins`**: no `FROM … :latest` or tagless `FROM`; tag + digest for every base image.
  - **`no-privileged`**: no `--privileged`, `--cap-add=ALL` or `seccomp=unconfined` in tracked scripts, except a named allow-list entry if D-something needs a custom seccomp file (a file, never `unconfined`).
  - **`ft-reports`**: every report with `runtime.python_build` `free-threaded` also records `gil_enabled: false`.
  - `java-flags` extended to chapters 5–13; `placement` extended to chapters 11–12 with an UNPINNED list for the single-thread micro benches.
- Acceptance: each new check fails on its planted case under `--self-test` and passes on the tree; `ci-ok` green.

**S18 prose fact check + voice pass**
- Opus reads every factual sentence about kernels, runtimes and tools (io_uring, epoll, seccomp default profile, CFS bandwidth, JEP 491, Quarkus defaults, asyncio, `os.process_cpu_count`, glibc) and ties each to a doc citation from S0 or a committed run. A false or unsupported claim is fixed now (r03 lesson).
- Then `lgtm-professional-voice` on `_docs/11-13`, READMEs 11–13, `_data/diagrams.yml` r04 entries and `_plans/r04-*`.
- Acceptance:
  - before/after `scan.sh --stats` table committed in Follow-ups;
  - ban-tier 0, no em dash anywhere (captions included), no `stiff`/`uniform` flag, triads triaged;
  - no honest/lie framing (including anything adapted from the sibling Ch32);
  - a script compares numbers, inline code, fences, includes and link targets before and after as multisets: identical.

**S19 re-measure gate**
- Any S17/S18 change to measured code or a `verify.sh` invalidates S11: re-run `r04-run1..3` and re-quote.
- Otherwise record "no re-measure needed" with the diff stat (and objdump/javap identity where code changed outside measured loops, as r03 S15).

**S20 Opus validation**
- Acceptance:
  - every quoted number recomputed from committed files by a script;
  - all §3 criteria hold;
  - Jekyll builds in `ruby:4.0.7` with 0 warnings;
  - `python3 scripts/validate.py` and `--self-test` pass;
  - `wordcount.sh` in range for Ch11–13;
  - figures byte-identical;
  - host-ids clean;
  - after merge, GitHub Pages deploy succeeds and the three chapter URLs return 200.

**S21 ship** (user OK required for the merge)
- Acceptance: PR squash-merged, branch deleted, tag `r04.x` on main, notes-only release published, no tarball.

## 4. Risks

| Risk | Detection |
|---|---|
| uv picks the free-threaded interpreter for the default env | S4 assert `sys._is_gil_enabled()` in `examples/`; every report records `runtime.python_build` |
| `pyhdrh` silently re-enables the GIL in the free-threaded lane | measured process imports no `lowlat_measure` and asserts GIL off after imports; `validate.py ft-reports` |
| Compiler deletes a ping-pong or receive bench loop | external-linkage sink; S9 objdump of each loop; round-trip counts asserted equal to the configured count |
| False sharing between per-thread counters skews the thread-per-core or hand-off result | `alignas(std::hardware_destructive_interference_size)` audit in S9; L1 misses per parcel observed |
| Thread start skew (r03's 400 ms gate stall) | gate with `std::latch`/`CountDownLatch`/`Barrier`; start skew recorded and asserted < 1 ms |
| Java JIT artefacts from a partly warmed loop | whole measured loop warmed; `build.flags` recorded |
| Simulators can't reach the saturation rate on a powersave laptop, so "saturation" is the sender's limit | simulator emit-lateness recorded per run; S10 picks the rate where emit-lateness p99 stays under the receive p99; `dropped` per camera |
| io_uring blocked or behaving differently in CI/containers | io_uring tests skip on `EPERM`/`ENOSYS` with a printed reason; Ch13 turns the seccomp block into a measured fact |
| Asio io_uring backend doesn't cover sockets as assumed | S0 doc check; lane is observed only (D16) or dropped |
| Quarkus BOM conflicts with parent-managed JUnit 6/Jackson 3 | standalone module without `<parent>` (D5); `dependencyConvergence` passes; S4 acceptance |
| Quarkus framework overhead hides the VT vs event-loop mechanism | plain-JDK micro lane alongside; λ chosen so λW > pool makes the queueing mechanism dominate; Little's-law in-flight count printed |
| Open-loop HTTP client becomes closed-loop (connection pool waits hide queueing) | latency measured from intended start; client's own lateness recorded; enough connections that none waits (asserted from client counters) |
| Host lane in Ch13 perturbed by the booted VM | VM idle during the host lane (no guest load; guest load1 recorded); `run-start.json` records `lab_vm: up (idle)`; prose labels it |
| Host vs VM numbers read as a portable verdict | D9 wording; every quoted number lane-labelled; `env-labels` check; chapter section "what the VM can't show" |
| Container lanes differ from VM-native by toolchain, not by isolation | one binary built in the UBI 10 builder runs in all lanes (D10); same Temurin and CPython builds; `image_digest` recorded |
| UBI 10 GCC can't compile the C++23 used | S0 probe; fallback ubi9 + gcc-toolset, or a static build recorded as a hold |
| `nr_throttled` stays 0 because the pool doesn't exceed the quota | pool of 4 busy workers vs `--cpus=2` by design; S10 confirms; exact counter asserted ≥ 1 |
| Container or guest output leaks IDs (container IDs, guest home path, image paths with the account) | `scrub-host-ids.py` extended in S2; `scrub_results` on exit; `validate.py host-ids` |
| Host changed by accident (Docker on host creating cgroups/veths, sysctl reads mistaken for writes) | containers only via `container_run` in the guest; `lib.sh` never calls sudo or `docker` on the host for Ch13 lanes; host `profile.sh` diff before/after S5 and S11 |
| Other projects' VMs touched | lab name guard (`LAB_GUARD_PREFIX`); `virsh list --all` state recorded before and after |
| Snapshot drift between runs | revert to `lab-ready-r04` before each Ch13 run; `guest_profile` recorded per report |
| Runtime facts in prose wrong (JEP 491 scope, seccomp default, availableProcessors under quota) | S0 citations; S18 Opus fact check against docs or a run |
| Ch12 too big for 2,500 words | Python and `asio-io-uring` lanes observed with one paragraph; if still over at S14, the user decides what moves to observed or to an example README |
| Overlap with Ch7 (affinity), Ch10 (MPSC), Ch15 (isolation), Ch18 (rollout) and the sibling sites | boundaries in `r04-chapters.md`; checked in S20 |
| Results bloat (strace, JFR, container logs) | summaries only; `.gitignore`; S11 size check |

## 5. S10 margin table

Filled in at S10 in the r03 form: Example | Criterion | Measured | Bound | Margin.

## 6. Open decisions (answered in S1)

- **D1 Boost (fibers, context, Asio):**
  - (a) FetchContent of the latest stable upstream `boost-1.N.0-cmake.tar.xz` (SHA256), with `BOOST_INCLUDE_LIBRARIES "asio;fiber;context"`, static;
  - (b) Fedora `boost-devel` 1.90, already on the host but not in the guest or CI image, distro-floating, against the pin rule;
  - (c) standalone Asio (`chriskohlhoff/asio`) and no fibers (Java VTs as the only stackful lane).
  - **Rec: (a).** One pinned dependency in the existing FetchContent pattern, the same in host, guest and CI, latest upstream (not the sibling's 1.84). Build cost is bounded by building only those libraries.
- **D2 C++ coroutine approach:**
  - (a) Asio `awaitable`/`co_spawn` for all waits and I/O, `std::generator` for the parcel stream, plus one minimal hand-rolled `Task<T>` (symmetric transfer) only for the ping-pong microbench, justified in prose (no std task type until C++26 `std::execution`);
  - (b) hand-rolled everything (sibling style);
  - (c) Boost.Cobalt.
  - **Rec: (a).**
- **D3 liburing:**
  - (a) latest upstream tag pinned, built static by `ExternalProject_Add` (configure/make) in `deps.cmake`;
  - (b) Fedora `liburing-devel` 2.13 (present on the host only).
  - **Rec: (a).**
- **D4 Where io_uring numbers come from:**
  - (a) host, since `io_uring_disabled` = 0 allows it unprivileged (read, never changed);
  - (b) the VM.
  - **Rec: (a)** for Ch12. The VM and containers supply only Ch13's seccomp fact.
- **D5 Java reactive comparison:**
  - (a) Quarkus, latest stable pinned (check 3.33.x LTS against newer), as Ch12's service tier, reusing quarkus-optimization demo-02/05 patterns: Mutiny `Uni` on the Vert.x event loop vs `@Blocking` worker pool vs `@RunOnVirtualThread`. Plus a plain-JDK micro lane (NIO `Selector` vs blocking `DatagramChannel` on VTs) for the UDP receive path. The Quarkus module is standalone (no `<parent>`, imports `quarkus-bom`, release 25, same enforcer rules) and listed in the aggregator.
  - (b) plain JDK only;
  - (c) Netty or Reactor.
  - **Rec: (a)** (user preference; idiomatic framework; the micro lane keeps the mechanism visible). Netty and Reactor appear in prose only. The Quarkus container is also Ch13's Java subject.
- **D6 HTTP load generator:**
  - (a) a plain-JDK open-loop client in the kit style (VTs + `HttpClient`, intended start times, HdrHistogram, `lowlat-report/1`);
  - (b) Hyperfoil (OSS, open-loop);
  - (c) wrk2 (unmaintained).
  - **Rec: (a)**, with Hyperfoil named in prose.
- **D7 Where Ch13's containers run:**
  - (a) all in the lab VM (Docker Engine in the guest);
  - (b) also on the host's Docker Engine.
  - **Rec: (a).** Quota, cpuset, bridge networking and seccomp lanes create host cgroups and veths, so they're not clearly harmless. The container cost is then measured against VM-native in the same boot. No host container lane, not even `--network host`, to keep the host untouched and the comparison clean.
- **D8 Guest profile:**
  - (a) new `stock-unpinned` profile and snapshot `lab-ready-r04`: stock Fedora 7.2 kernel, 4 vCPU unpinned, no isolation, Temurin, Docker, images. This is the "ordinary VM";
  - (b) `lab-ready-iso` (RT, isolated, pinned);
  - (c) both.
  - **Rec: (a).** Isolation is Part 5; one observed sentence points to Ch15.
- **D9 Host vs VM comparison wording:** CLAUDE.md says VM and bare-metal numbers are not comparable.
  - (a) Ch13 compares lanes only within one interleaved run on this machine, every number lane-labelled, worded as "on this laptop's KVM, in this run". Asserted claims are limited to mechanism counters and container-vs-VM-native (same guest); host vs VM is observed only. A short "what the VM can't show" section. The rule in CLAUDE.md gets a Ch13 carve-out sentence.
  - (b) no cross-environment comparison at all; each lane's distribution stands alone.
  - **Rec: (a).** It's the chapter's subject, and the interleave plus labels keep it truthful.
- **D10 Container images:**
  - (a) UBI 10 newest first, exact tag + digest. C++ built in a `ubi10/ubi` builder stage (RHEL 10 GCC, C++23 checked in S0) and that one binary is used in every lane. Java on `ubi10/ubi-minimal` + the pinned Temurin tarball (same JDK as host and guest). Python on `ubi10/ubi-minimal` + uv-managed CPython 3.14.8 (same release as the other lanes). ubi9 equivalents are the fallback.
  - (b) Red Hat runtime images (`ubi10/openjdk-25-runtime`, `ubi10/python-3xx`) as is; they're more idiomatic for production, but the JDK and Python builds differ from the other lanes.
  - **Rec: (a)** for measured lanes, with (b) named in the README as the production idiom. If the S0 GCC probe fails, the C++ fallback is a builder on ubi9 + gcc-toolset, recorded as a hold.
- **D11 uvloop:**
  - (a) pin the latest if a cp314 wheel exists; GIL lane only, observed;
  - (b) none.
  - **Rec: (a)** if the wheel exists, else (b), with the reason recorded.
- **D12 New validate.py checks:** `env-labels` (VM/container provenance), `lang-floor` (C++23 / JDK 25 / Python 3.14 in CMake, POMs including the parentless Quarkus module, pyproject, Containerfiles), `image-pins`, `no-privileged`, `ft-reports`, `java-flags` and `placement` extended to 11–13. **Rec: all.**
- **D13 Slugs:** `11-stackful-stackless`, `12-io-engines`, `13-where-code-runs` (permalinks `/docs/NN-slug/`). **Rec: accept.**
- **D14 Free-threaded lane scope:** Python threads lanes in Ch11 and Ch12 under both builds; Ch13 GIL only. **Rec: accept.**
- **D15 Netty io_uring transport for Java:** **Rec: no.** Prose only: the JDK has no io_uring and that's the divergence.
- **D16 Asio io_uring backend lane:** **Rec: include as observed if S0 confirms socket support;** otherwise the raw liburing lane alone.
- **D17 Sibling reuse:** adapt the user's cpp-concurrency-and-parallelism code up to C++23 (`std::generator`, `std::print`, `std::expected`, `std::jthread`/`stop_token`, `std::move_only_function` where a callback is stored) and the quarkus-optimization patterns. Each source file carries a one-line provenance comment naming the companion project. The chapters cite the sibling sites in "For deeper coverage" and don't repeat their depth: they're the concurrency and JVM deep dives, ours is the latency view. **Rec: accept.**

## Follow-ups

| Item | Decision |
|---|---|
| D1–D17 (user, 2026-10-23) | All accepted as recommended. Asked directly: D9 compare within one interleaved run, lane-labelled, host vs VM observed (CLAUDE.md exception added); D7 containers only in the lab VM; D5 Quarkus service tier plus a plain-JDK micro lane; D1/D3 Boost and liburing pinned upstream in CMake. |
| Language floor (user, 2026-10-23) | At least C++23, JDK 25, Python 3.14 everywhere, including the parentless Quarkus module and every image; sibling C++20 code adapted up. Recorded in CLAUDE.md. |
| Sibling sources (user, 2026-10-23) | Reuse cpp-concurrency-and-parallelism (11, 12, 13, 32) and quarkus-optimization (demo-02, 05, 06), cited as companion projects. |
| Container profile route (S2, 2026-10-23) | Route (a): the host-side driver (S3 `lib.sh`) runs `profile.sh` in the guest, which gives the guest profile with `virt.container` and `cgroup` for the guest itself, and merges the container fields read through `docker inspect` (image, digest, network mode, `NanoCpus` and `CpusetCpus`, seccomp) and the container's own cgroup files (`cpu.max`, `cpuset.cpus.effective`, `cpu.stat`, read from the host side of the container's cgroup) into `runtime.environment`. No `jq` or Python is needed inside any of the three images. The schema carries `environment.container` and `environment.cgroup`, and `profile.sh` run inside a container (where `jq` exists) reports `host_label` "container" and never the container hostname. The merge helper itself is S3. |
| S4 build wiring (2026-10-24) | Done on CPython 3.14.8, pending validation. Boost 1.92.0 (FetchContent, asio;fiber;context, static; pulls atomic, container, date_time, filesystem as dependencies) and liburing 2.15 (ExternalProject, `lowlat::uring`, static, build tree only) are wired behind `LOWLAT_BUILD_R04` (default ON; OFF skips the Boost download and liburing fetch). Skeleton targets in 11, 12, 13 (cpp, java, `*-py`), the standalone Quarkus module (listed in the aggregator, enforcer, `-Xlint:all -Werror` applied and passing; the plugin's code generation is bytecode, not javac sources). **CPython 3.14.9 blocked on uv:** uv 0.13.0 lists no 3.14.9 (`No download found for request: cpython-3.14.9-linux-x86_64-gnu`; `uv self update --dry-run` offers 0.13.5); `.python-version` stays `3.14+gil` (resolves to 3.14.8). Re-run the promotion after `uv self update`. |
