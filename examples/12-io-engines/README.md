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
  thread holds the wait. `worker-pool`: `@Blocking` and `Thread.sleep(2)` on a worker pool fixed at 8 threads.
  `virtual-thread`: `@RunOnVirtualThread` and `Thread.sleep(2)`, which parks the virtual thread and frees its carrier.
  And the defect `blocking-on-event-loop`: the same `Thread.sleep(2)` on the event loop, which holds one of its few
  threads for the whole wait. The load exceeds the pool. By Little's law (Ch2), 5 kHz x 2 ms is 10 requests in
  flight, and a pool of 8 can't hold them.
- **(d) Python.** `asyncio-datagram` (`loop.create_datagram_endpoint`, the selector loop) against `blocking-thread` (one
  thread per socket, under the GIL and under the free-threaded build) against `uvloop` (GIL build only).

Where the code leaves the ordinary idiom, it says why. `epoll_wait` plus `recvmsg` written out by hand, beside the
idiom, is there to show the system calls; Boost.Asio's reactor runs this loop for you. The spin-waiting hand-off workers
and the pinned threads exist to expose the mechanism; they're not advice for general code.

## Workload

- **(a) and (b) the receive path.** Four simulator instances as four tunnel cameras, the simulator unchanged, on the flat
  80-byte `parcel-v1` wire (`--wire flat`: no protobuf parse, so the receive path is what is measured). Each receiver
  decodes `seq` and `intended_emit_ns` at fixed offsets, checks the sequence, looks up the lane for the SSCC and records
  `now - intended_emit_ns` into an HdrHistogram. UDP ports 47320 to 47335, one per camera.
  - **Line.** 2.5 kHz per camera x 20 s: 200,000 parcels.
  - **Saturation.** A rate per camera for each lane, set where the mechanism shows and nothing drops (`dropped = 0` is
    asserted for every saturation run). The rates are variables at the top of `verify.sh`. `DECIDE_NS` (3 us) is the
    decide work this example doesn't build (the tracker lookup and the divert command's encode), modelled as a busy-wait
    per parcel. Without it one receive thread has a capacity the four simulators can't exceed, and nothing saturates. The
    three single-thread engines run at 60 kHz per camera: 240 kHz offered, 3 us of decide work each, so the thread is
    about 72 percent busy.
  - **The layout pair.** `thread-per-core` and `acceptor-pool` run at 52 kHz per camera (208 kHz offered) with
    `RECEIVE_NS_LAYOUT` (3.5 us) of modelled receive-side work per datagram, done by whichever thread received it. That's
    the serial receive stage: the validation a real camera frame carries (a checksum, a framing check) that this flat
    wire doesn't have, and the part of the work a single acceptor can't spread over cores. At that rate the acceptor is on
    a CPU for about 80 to 85 percent of its receive window (the run measures it with the thread's CPU time and checks it
    stays inside a guard band), while each of the four receivers is about 40 percent busy. Push the rate higher and the
    acceptor overloads: the sockets' buffers fill, parcels drop, and the p99 is a backlog growing for the length of the
    run, not a property of the layout. So the tail ratio is observed, and the exact hand-off counts carry the claim. The
    input is a model, like `DECIDE_NS`, and both are printed in each report's notes. Without the receive-side work both
    layouts keep up until the simulators themselves fall behind (around 150 kHz per camera on this host).
  - The commands keep their own channel (Ch10): this example measures the receive and decide path and sends no divert
    command.
- **(c) the service.** `GET /plan/<variant>/<sscc>` over HTTP/1.1 on loopback (TCP 47336), 2 ms downstream wait. The open-loop
  client (plain JDK: virtual threads and `java.net.http.HttpClient`) sends request `i` at `start + i / rate` whatever
  happened to the earlier ones, and measures from that intended time. It runs 3 s of warm-up and then `Q_SECONDS` of
  measurement at `Q_RATE` (5 kHz): the Little's-law in-flight number, `Q_RATE x 2 ms` = 10 against a pool of 8, is printed and
  recorded in the report's `model` block. The plan's example was 12 kHz against 16; a JDK HTTP/1.1 client and a four-core
  Quarkus service on this host fall behind in every variant above about 6 kHz, the pool or not, so the pool shrank to 8 and
  the rate to 5 kHz to keep `lambda x W` above it. The defect variant runs at `DEFECT_RATE` (1.85 kHz): four event loops each
  blocked for 2 ms carry at most 2 kHz, so it is driven below that and the queue it shows is the loop's, not the client's. The `event-loop` variant runs at the same rate in every alternation as the control for it. The client records its own lateness (a second report, variant `client-lateness`) and counts the
  requests it started more than a millisecond late; the JDK client opens a connection for every request that finds none
  idle, so a request never waits for a connection, and `max_in_flight` is the evidence.
  HTTP/1.1 on loopback is a harness, not a transport recommendation (Part 6).

Placement is unprivileged `sched_setaffinity` on our own threads (`pthread_setaffinity_np`, OpenHFT `Affinity.setAffinity`,
`os.sched_setaffinity`) on one logical CPU per physical core from `distinct_cores`, CPU 0 left out. The simulators and the
open-loop client run on the CPUs of the cores that are left over, so they never share a core with a thread under test, and
the Quarkus server gets four of the pinned cores (so the JVM reports 4 processors and Quarkus starts 4 event loops).
It's an experiment control, not isolation; isolation is Part 5. Each run records `runtime.placement`, and `verify.sh`
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
| Quarkus | `worker-pool` | `@Blocking`, `Thread.sleep(2)` on a worker pool fixed at 8 |
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
and don't depend on a tracer; `strace -f -c` is the cross-check. The ring is an RAII `Ring` over liburing, with an
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
With four cameras at four fixed source ports the kernel's hash over the 4-tuple can't balance four flows over four
sockets reliably (two flows can share a socket while another socket idles), so the lane steers by port instead: one port
per camera, one socket per core. That's the thread-per-core pattern with the balancing decided by the sender, which is
how an ingest tier with one port per feed would run.

`asio-io-uring` is a separate executable, `io-receive-asio`, compiled with `BOOST_ASIO_HAS_IO_URING` and
`BOOST_ASIO_DISABLE_EPOLL` as private compile definitions of that one target, so they reach no other. The first alone
sends file I/O through io_uring and keeps epoll for sockets; both together put sockets on io_uring too (Boost 1.92 docs,
`overview/implementation`). Asio owns its ring, so the program can't count the calls; the strace summary shows them.

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
there's no completion variant: that's the divergence from C++.

The Java call counters (`receive_calls`, `select_calls`) count calls in Java, not system calls; `selector` counts the
`receive` that returns null at the end of each drain. The system calls come from `strace -f -c` (observed). The whole
measured loop is warmed first: the same receive code runs a pass of 6,000 parcels per camera on its own threads and sockets, fed in process and
thrown away, so JIT compilation isn't in the numbers. Each receive thread allocates its own counters, so two threads are
unlikely to share a cache line (Java has no `alignas`; the allocations come from separate thread-local allocation buffers,
which makes separate lines likely, not guaranteed).
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
| `quarkus.thread-pool.max-threads` | run time | unset: the greater of 8 x CPUs and 200 | fixed at 8 |
| `quarkus.thread-pool.core-threads` | run time | 1 | 8, so the pool is 8 from the first request |
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
Under the GIL the four threads take turns; under the free-threaded `3.14.9+freethreaded` (a user-local
`uv python install 3.14.9t`) they run in parallel. `uvloop` is the same protocols on libuv's loop; a cp314t wheel exists
but it wasn't tested for keeping the GIL off, so the lane runs it under the GIL build only.

The measuring process imports neither `lowlat_measure` (its `pyhdrh` extension doesn't declare free-threading support,
and importing it turns the GIL back on) nor `uvloop` outside the one function that needs it. It writes the raw samples
as little-endian `int64` nanoseconds and a JSON sidecar (`build.compiler` is its own `sys.version`, `build.gil_enabled` its own
`sys._is_gil_enabled()` at the end of the run, `runtime.python_build`, counters and placement). `from_samples` in `lib.sh`
converts them with `lowlat-report from-samples` in the GIL environment, and the converter refuses a free-threaded report
with the GIL on. The measuring command refuses to run, or to finish, with the GIL on in the free-threaded build.

## Hand-rolled constructs, and why

Idiom first: Asio runs the `asio-io-uring` lane, `std::jthread` carries the C++ threads and joins them at scope end,
`std::print` and `std::expected` are used throughout, Quarkus gets `@RunOnVirtualThread`, `@Blocking` and Mutiny `Uni`, the
Java client uses `HttpClient` on virtual threads, and the Python lane uses `asyncio.run` and `create_datagram_endpoint`.
What is written by hand, and the reason:

- **`epoll_wait` plus `recvmsg` loop (C++).** The point is to count the system calls; Asio's reactor runs the same loop and
  hides the calls. It's shown once, beside the idiom.
- **`io_uring` multishot `recvmsg` over a provided-buffer ring (C++).** liburing has no higher-level API for this; the
  `Ring` and `BufRing` wrappers are RAII over its calls. Asio's backend can't expose the call counts.
- **`spin_work` (C++, Java) and the spinning hand-off workers.** The busy-wait stands in for decide work this example
  doesn't build. The workers spin on Ch10's `ClaimLog` so the hand-off is a cache-line transfer and not a futex
  wake-up. At line rate the acceptor-pool tail came out no worse than thread-per-core's (p99 97 against 106 us in one run), so
  the hand-off cost is small there; the exact hand-off counts are what the example asserts. Neither is advice for general code.
- **`SpinStart` and the start gate.** A futex barrier can wake threads a millisecond apart on an idle core; the spin brings
  them to one instant so the recorded start skew means something. `std::latch` and `CountDownLatch` do the coarse gate.
- **`EngineCounters` padded to twice `std::hardware_destructive_interference_size`.** Per-thread counters written on every
  datagram would otherwise share a line. The doubling is for the L2 spatial prefetcher.
- **The open-loop dispatcher (Java).** `HttpClient` has no open-loop mode; the dispatcher computes each intended send time
  and measures from it (Ch3). It parks until close to the time and then spins, because a late wake-up costs the schedule.

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
`RECHECK=results/<run-id>` (evaluate the criteria on committed reports; the placement checks need a live run),
`SMOKE=1 RESULTS_DIR=DIR` (small workloads, a check of the script: every criterion is printed, none enforced, and the
output is no result) and `ONLY=cpp,java,python,quarkus` (a development aid). The workload variables at the top of
`verify.sh` (`SAT_RATE_CPP`, `SAT_RATE_LAYOUT`, `DECIDE_NS`, `Q_RATE`, `DEFECT_RATE`) can be overridden from the
environment. Run it as `flock -o "$LOCK" ./verify.sh` when another example measures on this host: `-o` keeps the lock
descriptor out of the script and everything it starts, and the script stops its whole process tree on TERM or INT. The
open-loop client also ends on its own when the service is gone: every request has a timeout, the dispatcher stops after
1,000 errors, and a daemon watchdog halts the JVM at a hard deadline (`Runtime.halt` runs no shutdown hook, so nothing can
hold it up). A full run takes about 15 minutes, a clean build included.

If io_uring is blocked (a seccomp profile, `kernel.io_uring_disabled`, an old kernel), `io-receive --probe-uring` exits 77,
the io_uring parts are skipped with the reason written to `uring-skipped.txt`, and the C++ unit test skips itself. The
host's setting is read, never changed.

The Python lane under each build, by hand, from `examples/`:

```bash
# GIL build (the default workspace environment)
uv run python -m lowlat_io receive --variant asyncio-datagram --cpus 1 --out /tmp/py-gil
uv run lowlat-report from-samples /tmp/py-gil/samples.bin /tmp/py-gil/sidecar.json /tmp/py-gil.json

# free-threaded build: a separate environment, .venv-ft (ignored by git)
UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft uv run --python 3.14.9t --package lowlat-io \
    python -m lowlat_io receive --variant blocking-thread --cpus 1,2,3,4 --out /tmp/py-ft

# unit tests under both builds
uv run pytest 12-io-engines/io-py
LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft \
    uv run --python 3.14.9t --all-packages pytest 12-io-engines/io-py
```

The service by hand (`mvn -B -f examples/12-io-engines/quarkus/pom.xml verify`, then):

```bash
java -Xms512m -Xmx512m -Dquarkus.http.port=47336 -jar examples/12-io-engines/quarkus/target/quarkus-app/quarkus-run.jar
java -cp examples/12-io-engines/java/target/io-engines-java.jar io.patterncatalyst.lowlat.ch12.Main client \
    --variant virtual-thread --base-url http://127.0.0.1:47336 --rate 5000 --seconds 5 --report /tmp/vt.json
```

Reports land in `results/latest/`: `cpp/<variant>-sat-alt<N>.json`, `cpp/<variant>-line.json`, the same under `java/`,
`python/<build>-<variant>-line.json` and `-sat.json`, `quarkus/<variant>-alt<N>.json` (with `-lateness` beside each),
`strace/*.txt` (the `strace -f -c` summaries; the raw output is removed), the unit-test logs and the machine profile.

## Expected effect and criteria

`verify.sh` evaluates every criterion, prints its measured value, bound and margin, and exits non-zero if any failed.
Latency ratios compare variants within one run, alternating A B C A B C A B C and taking the median of the three
per-alternation ratios; a p50 is never compared across runs. Counters marked exact are deterministic. All bounds are
provisional until the S10 calibration (`_plans/r04-plan.md`).

1. **System calls per parcel at saturation, C++.** `io-uring`'s `io_uring_enter` calls per parcel are at most 1/4 of
   `epoll`'s system calls per parcel (`epoll_wait` + `recvmsg`). Both counts are read in the program, but the ratio
   depends on how many completions queue up behind each other, so it's a property of the load, not a constant. At 240 kHz
   `epoll` makes about 1.4 calls per parcel (level-triggered wake-ups find several sockets ready, so the plan's "at least
   2" doesn't hold) and `io-uring` about 0.06. `recvmmsg`'s calls per parcel and the CQEs per enter are printed, with the
   margin under 1 call per parcel, and not bounded.
2. **Hand-offs per parcel (exact).** `thread-per-core` 0, `acceptor-pool` 1.
3. **The layout pair at a loaded acceptor.** At 52 kHz per camera with the modelled receive-side work, `dropped` is 0
   for both layouts in every alternation (exact), and the acceptor's CPU share of its receive window sits inside a
   750 to 900 per-thousand guard band (the workload check). The p99 ratio, `thread-per-core` over `acceptor-pool`, median of 3,
   is observed: the plan's bound of 1/2 is asserted only when the ratio clears it twice over in every calibration run.
   The hand-off cost at line rate is observed too.
4. **Quarkus at 5 kHz x 2 ms > 8.** `worker-pool` p99 is at least 3x `virtual-thread` p99, median of 3. `event-loop`
   against `virtual-thread` is observed.
5. **The defect.** At 1.85 kHz, `blocking-on-event-loop` logs at least one blocked-thread warning during the measured run
   (exact; the in-process count and the log's `has been blocked for` lines are two views of the same log records and must
   agree), and requests in a handler at once never exceed the event-loop threads (exact), while the `event-loop` control at the same rate has more than that (13 to 16 against 4), so the signature discriminates. Its p99 against `event-loop` driven at the same
   1.85 kHz in the same alternation is observed unless it clears the bound twice over. The defect's p99 against 2 ms is
   observed: the sleep alone meets it.
6. **Line.** 200,000 parcels counted and `dropped` 0 for every C++, plain-JDK and Python variant. Percentiles are
   observed: at 2.5 kHz per camera everything fits 480 ms many times over.
7. **Reports.** Every report passes `lowlat-report check`, carries `runtime.counters`, `build.flags` (C++ and Java),
   `runtime.placement` (pinned runs) or `runtime.python_build` (Python), and the free-threaded runs kept the GIL off.
8. **Start gates.** The recorded start skew of every multi-thread run is under 1 ms, except the single-carrier
   `virtual-thread-blocking` receive: one carrier runs the four virtual threads one after the other, so its skew is the
   carrier serializing them (as in Ch11's single-carrier ping-pong) and is printed, not bounded. Every pinned thread is
   on its CPU.
9. **The service (exact counters).** The worker pool's active maximum equals the fixed pool size; the event-loop and
   virtual-thread variants use no worker thread; the client saw no error and answered every request. How many requests
   the client started more than 1 ms late is printed, not bounded: the overloaded `worker-pool` run holds thousands of
   connections open in the client, and the latency is measured from the intended time anyway, so a late start shows in the
   percentiles instead of hiding.

A run is complete only if every variant x alternation report exists and every saturation run received its full count
with `dropped` 0; a missing report fails the run, and so does `ONLY=` (a lane left out), which ends non-zero as partial.

Observed, not asserted: `asio-io-uring`; `io-uring` against `epoll` tails; `recvmmsg`'s calls per parcel; the p99 ratio of the layout pair and of the defect against its control; the plain-JDK variants against each other;
every Python variant; `uvloop`; `event-loop` against `virtual-thread`; the `strace -f -c` cross-check. The summaries are
committed and the raw strace output never is. `verify.sh` prints a note beside any asserted bound that clears with under 2x margin.

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
| CPython | 3.14.9 and 3.14.9+freethreaded | PSF-2.0 | the Python lanes |

Example 12 also builds on example 10's `lowlat::lockfree` library (the multi-producer log and the start gate).

## Verification status

Unverified until S11. The code builds, its unit tests pass and `verify.sh` completes on a quiet host, but no run is committed
yet. The recorded runs and the calibration of the bounds come with S10 and S11 (`_plans/r04-plan.md`); until then every
bound above is provisional and this section carries no measured numbers.
