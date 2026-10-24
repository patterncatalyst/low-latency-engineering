# 12-io-engines

Chapter 12: what wakes the thread. Ch11 asked who holds a wait. This chapter asks what tells a thread that its wait is over,
and how many threads there should be. A hub concentrator takes four scan tunnels' UDP feeds. For each datagram something
has to tell a receive thread there is work: a readiness event ("this socket has data, come and get it") or a completion
("this receive finished, here is the data"). The same question comes back one tier up, in the sort-plan service: when
every lookup waits 2 ms on the warehouse management system (WMS), a worker thread, a virtual thread or an event-loop
callback holds that wait.

C++ leads each technique, because it can show each mechanism bare. Java and Python follow in their own idiom. Where one has
no equivalent, the divergence is the lesson: the JDK has no io_uring, and neither has the Python standard library.

## Technique

- **(a) Readiness against completion on the UDP receive path.** `epoll` is readiness: `epoll_wait` says which socket has
  data and `recvmsg` takes one datagram from it, so every parcel costs at least one system call and usually
  more. `recvmmsg` keeps the readiness model and takes a batch: after the wake-up one call collects what is queued, up to
  32 datagrams. `io-uring` is completion: one multishot `recvmsg` per socket stays armed in the kernel, the kernel picks
  a buffer from a provided-buffer ring for each datagram and posts a completion, and the program reaps every completion
  already queued with no system call at all. One `io_uring_enter` waits for the next one. The measure is system calls per
  parcel, counted exactly in the program. `asio-io-uring` is Boost.Asio built on its io_uring backend, observed.
- **(b) Thread-per-core against an acceptor and a pool.** `thread-per-core` is shared nothing: four receive threads
  pinned to four physical cores, each with its own `SO_REUSEPORT` socket and its own ring, decoding and deciding where the
  datagram landed. `acceptor-pool` is one receive thread that decodes, then hands each parcel to one of four decide
  workers through Ch10's multi-producer log. The measure is cross-thread hand-offs per parcel, counted exactly: 0 against 1.
- **(c) The Java service tier.** The sort-plan lookup over HTTP/1.1 on loopback waits 2 ms for its downstream. The
  Quarkus service answers it four ways. `event-loop`: a Mutiny `Uni` completed by a non-blocking Vert.x timer, so no
  thread holds the wait. `worker-pool`: `@Blocking` and `Thread.sleep(2)` on a worker pool fixed at 16 threads.
  `virtual-thread`: `@RunOnVirtualThread` and `Thread.sleep(2)`, which parks the virtual thread and frees its carrier.
  And the defect `blocking-on-event-loop`: the same `Thread.sleep(2)` on the event loop, which holds one of its few
  threads for the whole wait. The load exceeds the pool on purpose. By Little's law (Ch2), 10 kHz x 2 ms is 20 requests in
  flight, and a pool of 16 cannot hold them.
- **(d) Python.** `asyncio-datagram` (`loop.create_datagram_endpoint`, the selector loop) against `blocking-thread` (one
  thread per socket, under the GIL and under the free-threaded build) against `uvloop` (GIL build only).

Where the code leaves the ordinary idiom, it says why. `epoll_wait` plus `recvmsg` written out by hand, beside the
idiom, is there to show the system calls; Boost.Asio's reactor runs this loop for you. The spin-waiting hand-off workers
and the pinned threads exist to expose the mechanism; they are not advice for general code.

## Workload

- **(a) and (b) the receive path.** Four simulator instances as four tunnel cameras, the simulator unchanged, on the flat
  80-byte `parcel-v1` wire (`--wire flat`: no protobuf parse, so the receive path is what is measured). Each receiver
  decodes `seq` and `intended_emit_ns` at fixed offsets, checks the sequence, looks up the lane for the SSCC and records
  `now - intended_emit_ns` into an HdrHistogram. UDP ports 47320 to 47335, one per camera.
  - **Line.** 2.5 kHz per camera x 20 s: 200,000 parcels.
  - **Saturation.** A rate per camera, picked as the highest with `dropped = 0` for the slowest variant of the lane.
    It is a variable at the top of `verify.sh` (`SAT_RATE_CPP`, `SAT_RATE_JAVA`, `SAT_RATE_PY`), provisional until the
    S10 calibration. `DECIDE_NS` is the decide work this example does not build (the tracker lookup and the divert
    command's encode), modelled as a busy-wait of that many nanoseconds per parcel. Without it one receive thread has a
    capacity the four simulators cannot exceed, and nothing saturates. The same value applies to every C++ variant.
  - The commands keep their own channel (Ch10): this example measures the receive and decide path and sends no divert
    command.
- **(c) the service.** `GET /plan/<variant>/<sscc>` over HTTP/1.1 on loopback (TCP 47336), 2 ms downstream wait. The open-loop
  client (plain JDK: virtual threads and `java.net.http.HttpClient`) sends request `i` at `start + i / rate` whatever
  happened to the earlier ones, and measures from that intended time. It runs 3 s of warm-up and then `Q_SECONDS` of
  measurement at `Q_RATE` (10 kHz): the Little's-law in-flight number, `Q_RATE x 2 ms`, is printed and recorded in the
  report's `model` block. The client records its own lateness (a second report, variant `client-lateness`) and counts the
  requests it started more than a millisecond late; the JDK client opens a connection for every request that finds none
  idle, so a request never waits for a connection, and `max_in_flight` is the evidence.
  HTTP/1.1 on loopback is a harness, not a transport recommendation (Part 6).

Placement is unprivileged `sched_setaffinity` on our own threads (`pthread_setaffinity_np`, OpenHFT `Affinity.setAffinity`,
`os.sched_setaffinity`) on one logical CPU per physical core from `distinct_cores`, CPU 0 left out. The simulators and the
open-loop client run on the CPUs of the cores that are left over, so they never share a core with a thread under test, and
the Quarkus server gets four of the pinned cores (so the JVM reports 4 processors and Quarkus starts 4 event loops).
It is an experiment control, not isolation; isolation is Part 5. Each run records `runtime.placement`, and `verify.sh`
checks every pinned thread's last CPU in `/proc/<pid>/task/<tid>/stat` while the run holds at its start gate.

The start gate has the handshake of Ch10: each pinned thread pins itself and waits, the coordinator prints one
`pinned pid=P tid=T cpu=C role=R` line per thread and `placement-ready`, holds 500 ms while `verify.sh` checks the pins,
prints `released` and lets the threads go. The simulators start on `released`. After the gate every thread arrives at a
spin barrier and reads the clock; the spread of those reads is the recorded `start_skew_ns`, asserted under 1 ms.

## Variants

| Language | Variant | What it is |
|---|---|---|
| C++ | `epoll` | one thread, four sockets: `epoll_wait` + `recvmsg` (readiness) |
| C++ | `recvmmsg` | one thread, four sockets: `epoll_wait` + `recvmmsg` batch of up to 32 (readiness, batched) |
| C++ | `io-uring` | one thread, four sockets: liburing multishot `recvmsg`, provided-buffer ring (completion) |
| C++ | `asio-io-uring` | one thread, four sockets: Boost.Asio on `BOOST_ASIO_HAS_IO_URING` + `BOOST_ASIO_DISABLE_EPOLL` (observed) |
| C++ | `thread-per-core` | four threads, each its own `SO_REUSEPORT` socket and its own ring |
| C++ | `acceptor-pool` | one `io-uring` thread hands parcels to four decide workers through the Ch10 multi-producer log |
| Java | `selector` | one platform thread, NIO `Selector` over four non-blocking `DatagramChannel`s |
| Java | `virtual-thread-blocking` | four virtual threads in a blocking `DatagramChannel.receive`, one carrier thread |
| Java | `thread-per-core` | four pinned platform threads, each its own `SO_REUSEPORT` channel and a blocking `receive` |
| Quarkus | `event-loop` | `Uni` completed by a Vert.x timer: no thread holds the 2 ms |
| Quarkus | `worker-pool` | `@Blocking`, `Thread.sleep(2)` on a worker pool fixed at 16 |
| Quarkus | `virtual-thread` | `@RunOnVirtualThread`, `Thread.sleep(2)` |
| Quarkus | `blocking-on-event-loop` | the defect: `Thread.sleep(2)` on the event loop |
| Python | `asyncio-datagram` | `loop.create_datagram_endpoint`, one thread, default selector loop |
| Python | `blocking-thread` | one thread per socket in a blocking `recv`, under the GIL and under the free-threaded build |
| Python | `uvloop` | the same protocols on uvloop's libuv loop, GIL build only (observed) |

### C++

The three engines live in `engines.hpp` as templates over the per-datagram handler, so the loop is resolved at compile
time, as in the Ch0 consumer. Each counts every system call it makes in a per-thread `EngineCounters`, padded to
`2 * std::hardware_destructive_interference_size` (the L2 spatial prefetcher pulls line pairs): `epoll_wait`,
`recvmsg`, `recvmmsg` and `io_uring_enter` calls, completions reaped, multishot re-arms and hand-offs. The counts are exact
and do not depend on a tracer; `strace -f -c` is the cross-check. The ring is an RAII `Ring` over liburing, with an
RAII `BufRing` for the provided buffers (`ring.hpp`).

`io-uring` reaps in two steps. It first walks the completions already in the ring with `io_uring_for_each_cqe`, which makes
no system call, and only when there is none does it call `io_uring_submit_and_wait_timeout`, which submits any re-armed
receive and waits for the next completion. So at a rate where parcels queue up behind each other it makes far fewer
enters than parcels, and at a rate where each parcel finds an empty ring it makes about one per parcel; the effect is a
property of the load, and the saturation run is where it shows. The multishot receive ends when the kernel runs out of
buffers; the loop re-arms it and counts the re-arm. Buffers return to the ring after each batch.

`acceptor-pool` uses `lowlat::lockfree::ClaimLog` from Ch10 (`examples/10-lockfree-waitfree`): one log per worker, the receive
thread the single producer, parcels dealt out in turn. That makes this lane depend on example 10's library; the dependency
is in `cpp/CMakeLists.txt`. The workers busy-spin on their log, as Ch10's consumer does, so the hand-off pool uses five
cores against `thread-per-core`'s four.

`SO_REUSEPORT` is set on every socket, and `Sockets.TwoSocketsShareAPortWithReusePort` shows two sockets binding one port.
With four cameras at four fixed source ports the kernel's hash over the 4-tuple cannot balance four flows over four
sockets reliably (two flows can share a socket while another socket idles), so the lane steers by port instead: one port
per camera, one socket per core. That is the thread-per-core pattern with the balancing decided by the sender, which is
how an ingest tier with one port per feed would run.

`asio-io-uring` is a separate executable, `io-receive-asio`, compiled with `BOOST_ASIO_HAS_IO_URING` and
`BOOST_ASIO_DISABLE_EPOLL` as private compile definitions of that one target, so they reach no other. The first alone
sends file I/O through io_uring and keeps epoll for sockets; both together put sockets on io_uring too (Boost 1.92 docs,
`overview/implementation`). Asio owns its ring, so the program cannot count the calls; the strace summary shows them.

Provenance: the raw epoll loop and the pinned-thread start protocol follow `12-asio-strand` of the companion project
cpp-concurrency-and-parallelism, adapted up to C++23 (`std::print`, `std::expected`, `std::jthread`, concepts). The
companion project is the deep dive on Asio and epoll; this chapter is the latency view.

### Java

The plain-JDK micro lane (`ReceiveRun`) has three variants. `selector` is the NIO idiom: `Selector.select(Consumer, timeout)`
and a drain loop on each ready channel. `virtual-thread-blocking` is the Loom idiom: write the loop as if the receive
blocked, and let the JDK park the virtual thread on its poller, which is epoll underneath (the strace summary shows the
poller's `epoll_wait`). One carrier thread (`-Djdk.virtualThreadScheduler.parallelism=1`, `maxPoolSize=1`) lets the pin
land on a thread the harness can name: the pin is applied from inside a virtual thread and takes effect on the carrier it is
mounted on. `thread-per-core` is four pinned platform threads, each in a blocking `receive`. The JDK has no io_uring, so
there is no completion variant: that is the divergence from C++.

The Java call counters (`receive_calls`, `select_calls`) count calls in Java, not system calls; `selector` counts the
`receive` that returns null at the end of each drain. The system calls come from `strace -f -c` (observed). The whole
measured loop is warmed first: the same threads and sockets run a pass of 6,000 parcels per camera, fed in process and
thrown away, so JIT compilation is not in the numbers. Each receive thread allocates its own counters, so two threads do
not share a cache line (Java has no `alignas`; the allocations come from separate thread-local allocation buffers).
`DatagramChannel.receive` allocates an `InetSocketAddress` per call; with a fixed, pre-touched 1 GiB heap no collection
starts inside a run, and the JDK offers no allocation-free receive on an unconnected channel.

The open-loop client (`OpenLoopClient`) is in the same module, in the plain-JDK lane. It uses the kit's Java recorder
(HdrHistogram) and writes `lowlat-report/1`.

### Quarkus

`examples/12-io-engines/quarkus` is a standalone module (no `<parent>`; it imports `quarkus-bom` 3.40.1.1, the 3.40 LTS)
that runs on the plain JVM as a fast-jar, never native. One `@QuarkusTest` per variant is a smoke test: the answer is
right, and a thread of the expected kind served it (the defect test also needs the blocked-thread warning to appear).

Configuration keys, verified in the 3.40.1.1 config model (`META-INF/quarkus-config-doc` in the extension jars, the source
of the `all-config` guide):

| Key | Phase | Default | Used for |
|---|---|---|---|
| `quarkus.thread-pool.max-threads` | run time | unset: the greater of 8 x CPUs and 200 | fixed at 16 |
| `quarkus.thread-pool.core-threads` | run time | 1 | 16, so the pool is 16 from the first request |
| `quarkus.thread-pool.prefill` | run time | true | left on |
| `quarkus.vertx.event-loops-pool-size` | run time | unset: `max(2, min(heap / 10 MiB, CPUs))` | not set; the count is recorded |
| `quarkus.vertx.max-event-loop-execute-time` | run time | 2 s (a bare number is seconds, `1ms` parses as one millisecond) | `1ms` in `%defect` |
| `quarkus.vertx.warning-exception-time` | run time | 2 s | `10ms` in `%defect`; also the blocked-thread checker's period (`setBlockedThreadCheckInterval`) |

At the defaults a 2 ms block on the event loop logs nothing: the limit is 2 s. The `%defect` profile (started with
`-Dquarkus.profile=defect`) sets the limit below the block and the checker period short, so the warnings are reachable.
The service counts them in process, with a handler on the `io.vertx.core.impl.BlockedThreadChecker` logger, and `verify.sh`
checks that count against the `has been blocked for` lines of the server log.

`ServiceStats` (`GET /stats`, `POST /stats/reset` after the warm-up) is the exact evidence: requests served, the most
requests inside a handler at once, the worker pool's active maximum, the distinct worker, event-loop and carrier threads
seen, and the blocked-thread warnings. The open-loop client copies them into the run's report.

Provenance: the `@RunOnVirtualThread` pattern and the carrier-thread count come from the companion project
quarkus-optimization (`quarkus-demo-02-gc-monitoring`, `GcMonitoringResource`), and the Mutiny `Uni` from
`quarkus-demo-05-grpc`. Those projects are the JVM deep dives; this chapter is the latency view.

### Python

CPython 3.14 has no io_uring in the standard library, and no mature third-party binding exists, so the lane compares what
the language offers. `asyncio-datagram` is the idiom: a `DatagramProtocol` per camera on the default selector loop, which
calls `epoll_wait` and one `recvfrom` per ready socket. `blocking-thread` is one thread per socket in a blocking `recv`.
Under the GIL the four threads take turns; under the free-threaded `3.14.8+freethreaded` (a user-local
`uv python install 3.14t`) they run in parallel. `uvloop` is the same protocols on libuv's loop; a cp314t wheel exists
but it was not tested for keeping the GIL off, so the lane runs it under the GIL build only.

The measuring process imports neither `lowlat_measure` (its `pyhdrh` extension does not declare free-threading support,
and importing it turns the GIL back on) nor `uvloop` outside the one function that needs it. It writes the raw samples
as little-endian `int64` nanoseconds and a JSON sidecar (`build.compiler` is its own `sys.version`, `build.gil_enabled` its own
`sys._is_gil_enabled()` at the end of the run, `runtime.python_build`, counters and placement). `from_samples` in `lib.sh`
converts them with `lowlat-report from-samples` in the GIL environment, and the converter refuses a free-threaded report
with the GIL on. The measuring command refuses to run, or to finish, with the GIL on in the free-threaded build.

## Layout

| Path | Contents |
|---|---|
| `cpp/` | library `lowlat::io` (engines, work, hand-off, sockets, `Ring`); executables `io-receive` and `io-receive-asio`; `io-test` |
| `java/` | Maven module `io-engines-java`: the receive lane (`ReceiveRun`), the open-loop client (`OpenLoopClient`), `io-engines-java.jar` |
| `quarkus/` | standalone Maven module `io-engines-quarkus`: the sort-plan service and its `@QuarkusTest`s |
| `io-py/` | Python package `lowlat_io`, uv workspace member `lowlat-io` |
| `verify.sh` | runs everything and asserts the criteria |

## Run

```bash
examples/12-io-engines/verify.sh
```

Environment (from `examples/_lib/lib.sh`): `ALLOW_BUSY=1`, `SKIP_BUILD=1`, `RESULTS_DIR`, `LOWLAT_BUILD`; also
`RECHECK=results/<run-id>` (evaluate the criteria on committed reports; the placement checks need a live run) and
`ONLY=cpp,java,python,quarkus` (a development aid). The workload variables at the top of `verify.sh` (`SAT_RATE_CPP`,
`DECIDE_NS`, `Q_RATE`, `POOL`) can be overridden from the environment. Run it under the host benchmark lock when another
example measures on this host. A full run takes about 20 minutes, a clean build included.

If io_uring is blocked (a seccomp profile, `kernel.io_uring_disabled`, an old kernel), `io-receive --probe-uring` exits 77,
the io_uring parts are skipped with the reason written to `uring-skipped.txt`, and the C++ unit test skips itself. The
host's setting is read, never changed.

The Python lane under each build, by hand, from `examples/`:

```bash
# GIL build (the default workspace environment)
uv run python -m lowlat_io receive --variant asyncio-datagram --cpus 1 --out /tmp/py-gil
uv run lowlat-report from-samples /tmp/py-gil/samples.bin /tmp/py-gil/sidecar.json /tmp/py-gil.json

# free-threaded build: a separate environment, .venv-ft (ignored by git)
UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft uv run --python 3.14t --package lowlat-io \
    python -m lowlat_io receive --variant blocking-thread --cpus 1,2,3,4 --out /tmp/py-ft

# unit tests under both builds
uv run pytest 12-io-engines/io-py
LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft \
    uv run --python 3.14t --all-packages pytest 12-io-engines/io-py
```

The service by hand (`mvn -B -f examples/12-io-engines/quarkus/pom.xml verify`, then):

```bash
java -Xms512m -Xmx512m -Dquarkus.http.port=47336 -jar examples/12-io-engines/quarkus/target/quarkus-app/quarkus-run.jar
java -cp examples/12-io-engines/java/target/io-engines-java.jar io.patterncatalyst.lowlat.ch12.Main client \
    --variant virtual-thread --base-url http://127.0.0.1:47336 --rate 10000 --seconds 5 --report /tmp/vt.json
```

Reports land in `results/latest/`: `cpp/<variant>-sat-alt<N>.json`, `cpp/<variant>-line.json`, the same under `java/`,
`python/<build>-<variant>-line.json` and `-sat.json`, `quarkus/<variant>-alt<N>.json` (with `-lateness` beside each),
`strace/*.txt` (the `strace -f -c` summaries; the raw output is removed), the unit-test logs and the machine profile.

## Expected effect and criteria

`verify.sh` evaluates every criterion, prints its measured value, bound and margin, and exits non-zero if any failed.
Latency ratios compare variants within one run, alternating A B C A B C A B C and taking the median of the three
per-alternation ratios; a p50 is never compared across runs. Counters marked exact are deterministic. All bounds are
provisional until the S10 calibration (`_plans/r04-plan.md`).

1. **System calls per parcel at saturation, C++ (exact).** `io-uring`'s `io_uring_enter` calls per parcel are at most 1/4
   of `epoll`'s system calls per parcel (`epoll_wait` + `recvmsg`); `recvmmsg` makes fewer than 1 system call per parcel.
   The CQEs per enter are printed.
2. **Hand-offs per parcel (exact).** `thread-per-core` 0, `acceptor-pool` 1.
3. **Receive tail at saturation, C++.** `thread-per-core` p99 is at most 1/2 of `acceptor-pool`'s, median of 3.
   `io-uring` against `epoll` p99 is observed.
4. **Quarkus at 10 kHz x 2 ms > 16.** `worker-pool` p99 is at least 3x `virtual-thread` p99, median of 3. `event-loop`
   against `virtual-thread` is observed.
5. **The defect.** `blocking-on-event-loop` logs at least one blocked-thread warning (exact; the in-process count must equal
   the log's) and its p99 is at least 2 ms.
6. **Line.** 200,000 parcels counted and `dropped` 0 for every C++, plain-JDK and Python variant. Percentiles are
   observed: at 2.5 kHz per camera everything fits 480 ms many times over.
7. **Reports.** Every report passes `lowlat-report check`, carries `runtime.counters`, `build.flags` (C++ and Java),
   `runtime.placement` (pinned runs) or `runtime.python_build` (Python), and the free-threaded runs kept the GIL off.
8. **Start gates.** The recorded start skew of every multi-thread run is under 1 ms; every pinned thread is on its CPU.
9. **The service (exact counters).** The worker pool's active maximum equals the fixed pool size; the event-loop and
   virtual-thread variants use no worker thread; the client saw no error, answered every request and started (almost) none
   of them late.

Observed, not asserted: `asio-io-uring`; `io-uring` against `epoll` tails; the plain-JDK variants against each other;
every Python variant; `uvloop`; `event-loop` against `virtual-thread`; the `strace -f -c` cross-check. The summaries are
committed and the raw strace output never is. `verify.sh` flags any asserted bound that clears with under 2x margin.

## Observation surfaces

| Surface | What it shows |
|---|---|
| Terminal output of `verify.sh` | each criterion's value, bound and margin; the observed items |
| `runtime.counters` in each report | exact counts: system calls by kind, completions, hand-offs, start skew; for the service the worker pool's active maximum, the thread counts and the blocked-thread warnings |
| `strace/*.txt` | `strace -f -c` summaries, the independent count of system calls |
| `runtime.placement`, `/proc/<pid>/task/<tid>/stat` | where each pinned thread ran |
| `model` in the service reports | the Little's-law in-flight number the load was chosen for |

Grafana: no panel by design. The evidence is exact counts and distributions in the reports; live observability of the
receive path is Part 7.

## Licences

| Component | Version | Licence | Used for |
|---|---|---|---|
| liburing | 2.15 | LGPL-2.1-or-later OR MIT (the library; the kernel uapi header is GPL-2.0-only WITH Linux-syscall-note OR MIT) | io_uring from C++, linked statically |
| Boost (Asio) | 1.92.0 | BSL-1.0 | `asio-io-uring`; Asio's other libraries are not linked |
| Quarkus | 3.40.1.1 | Apache-2.0 | the service tier |
| uvloop | 0.23.0 | MIT OR Apache-2.0 | the `uvloop` variant |
| OpenHFT Affinity (chronicle-bom 2026.26) | 2026.2 | Apache-2.0 | thread pinning in Java |
| HdrHistogram | per `versions.env` | BSD-2-Clause / CC0 | latency histograms (C, Java, Python) |
| GoogleTest | v1.18.0 | BSD-3-Clause | C++ tests |
| nlohmann/json | v3.12.0 | MIT | C++ reports |
| JUnit | 6.1.3 (Quarkus module: the platform's) | EPL-2.0 | Java tests |
| pytest | 9.1.1 | MIT | Python tests |
| CPython | 3.14.8 and 3.14.8+freethreaded | PSF-2.0 | the Python lanes |

Example 12 also builds on example 10's `lowlat::lockfree` library (the multi-producer log and the start gate).

## Verification status

Unverified. The code builds and its unit tests pass, but no `verify.sh` run is committed yet. The three recorded runs
(`r04-run1..3`) and the calibrated bounds come with S10 and S11; until then every bound above is provisional and this section
carries no measured numbers.
