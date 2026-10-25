# 11-stackful-stackless

Chapter 11: who holds the wait. Every scan on the sortation line triggers a sort-plan lookup at the warehouse management
system (WMS), and the answer takes about 2 ms. By Little's law (Ch2) a line at 10 kHz has 20 lookups in flight, and a hub at
100 kHz with a slow WMS has thousands. Something has to hold each of those waits: a thread or fiber that keeps a stack of its own,
or a coroutine or event-loop task that keeps only a frame. This example measures what each costs
in memory and in a hand-off, and what happens when one task makes a blocking call.

C++ leads each technique, because it can show each mechanism bare. Java and Python follow in their own idiom. Java has no
stackless coroutine and Python has no standard-library stackful one (greenlet and gevent are third-party and aren't
measured), so those gaps are the lesson, not something to paper over.

## Technique

- **(a) Memory per waiting task.** 10,000 tasks, each waiting on one shared 1 s timer. An OS thread keeps a stack, a kernel
  stack and a thread control block. A Boost.Fiber keeps a 64 KiB `protected_fixedsize_stack` (a guard page and 64 KiB of
  address space, of which the touched page or two is resident). A C++ coroutine keeps a heap-allocated frame of the
  variables that live across its suspension points, and nothing else. The frame's size is counted, not estimated: the
  `Task<T>` promise's `operator new` counts every allocation and the bytes requested.
- **(b) Hand-off.** Two tasks pass a turn back and forth. Between OS threads the waiter sleeps in the kernel (a futex)
  and the other thread wakes it. Between fibers it's a user-space context switch through the scheduler. Between
  coroutines it's symmetric transfer, where one coroutine's `await_suspend` returns the other's handle and the compiler
  turns the resume into a tail call.
- **(c) The blocking call.** 1,000 tasks wake every 2 ms. One task makes one blocking call of 2 ms. In a fiber that's
  `std::this_thread::sleep_for`, in a coroutine `time.sleep`, and the whole OS thread that carries the other tasks stops.
  That's the function-colouring problem seen from the code: a fiber or coroutine scheduler is cooperative, so a call that
  blocks instead of suspending takes every neighbour with it. A virtual thread is the JDK's answer, and JEP 491 (JDK 24)
  removed the `synchronized` case; a blocking call under a native frame still pins the carrier.
- **(d) The line.** One lookup task per parcel, each holding a 2 ms wait, then deciding the lane.

## Workload

- **(a) Parked.** 10,000 tasks each wait on one absolute deadline, 1 s after the start gate opens. The start gate is
  `std::latch` (C++), `CountDownLatch` (Java) or `threading.Barrier` (Python): every task counts down before it waits, and
  the coordinator asserts that all 10,000 arrived. The process's memory counters (RSS, address space, page tables) and the system's kernel-stack bytes are read
  from `/proc` before the tasks start and again 500 ms into the wait, when every task is parked. The sample is each task's
  wake lateness. `parked` for the C++ coroutine variant also parks `Task` coroutines with a `steady_timer` in the frame, in a
  vector, so no frame can be elided, and counts the frames. Java reads the heap with `MemoryMXBean` after `System.gc()`.
  Python reads the bytes of 10,000 asyncio tasks with `tracemalloc` in a second pass, and says so: the figure is "measured by
  tracemalloc", a count of blocks from Python's own allocators, not an exact byte count.
- **(b) Ping-pong.** 1,000,000 round trips in batches of 1,000. A sample is the batch's time divided by 1,000. Two pinned OS
  threads for `os-thread` and `platform-thread`; two tasks on one pinned OS thread for `fiber`, `coroutine`, Java's
  `virtual-thread` (one carrier, `-Djdk.virtualThreadScheduler.parallelism=1`, recorded in `build.flags`) and Python's
  `asyncio-tasks`. Each side does a warm-up of 20 batches first; Java warms the whole measured loop in a discarded pass.
  The payload round-trips through a padded slot and is summed, and the sum is checked against the closed form, so no loop
  is dead code.
- **(c) Neighbours.** 1,000 tasks on 2 ms timers, staggered across the period, 500 iterations (one second), recording how late
  each wake was. With `--blocking-sleep-in-fiber` (C++) or `--blocking-sleep-in-coroutine` (Python), task 0 makes one 2 ms
  blocking call every tenth iteration, 50 in all. The Python lane runs 50 tasks on the same 2 ms timers: an asyncio loop wakes
  about 75,000 tasks a second at most, and 1,000 tasks every 2 ms is 500,000, so with 1,000 the loop falls behind by seconds
  and the run measures overload, not the blocking call. The Python debug run switches asyncio's debug mode on after the tasks
  exist, with `slow_callback_duration` at 1 ms, and counts the `Executing <...> took N seconds` warnings.
- **Line.** One simulator instance at 10 kHz x 20 s (200,000 parcels) to UDP 47310 (C++ `os-thread`), 47311 (`fiber`), 47312
  (`coroutine`), 47313 (`platform-thread`) and 47314 (`virtual-thread`). The receive thread decodes each datagram and starts
  a lookup task. The task waits 2 ms on a timer in this process (no network dependency), decides the lane, sends the divert
  command on a separate UDP socket and completes the parcel. The command path shares nothing with the data path. The line
  simulator and the shared consumers are unchanged. There's no Python line lane: the Python comparison is (a) to (c).

Placement is unprivileged `sched_setaffinity` on our own threads (`pthread_setaffinity_np`, OpenHFT `Affinity.setAffinity`,
`os.sched_setaffinity`), on CPUs from `distinct_cores` in `examples/_lib/lib.sh`, leaving CPU 0 out as examples 09 and 10 do. It's an
experiment control and not isolation (Part 5). Tasks that are threads float: a thread started from a pinned thread inherits
its mask, so each lookup thread restores the process's original mask first (`sched_setaffinity` in C++,
`resetToBaseAffinity` in Java). Every pinned run records `runtime.placement`, and `verify.sh` checks each thread's last CPU
in `/proc/<pid>/task/<tid>/stat` while the run holds at its start gate. The gate prints `pinned pid=P tid=T cpu=C role=R`
per thread and `placement-ready`, holds for 500 ms, prints `released` and lets the threads go. Each pinned thread stamps the
clock as it leaves the gate; the spread is `start_skew_ns`, and `verify.sh` asserts it's under 1 ms.

## Variants

| Language | Variant | What it is |
|---|---|---|
| C++ | `os-thread` | `std::jthread` and `std::stop_token`; the parked threads wait in `condition_variable_any::wait_until` with the token; the hand-off waits on a `std::condition_variable` |
| C++ | `fiber` | Boost.Fiber on the default `round_robin` scheduler, `protected_fixedsize_stack(64 KiB)`, `buffered_channel` for the hand-off and the line's feed |
| C++ | `coroutine` | Asio `awaitable`, `co_spawn` and `steady_timer` for the waits; a minimal `Task<T>` with symmetric transfer for the ping-pong and the frame probes |
| C++ | `--blocking-sleep-in-fiber` | the defect: `std::this_thread::sleep_for(2 ms)` inside a fiber |
| C++ | `--handoff semaphore` | observed: the `os-thread` ping-pong on `std::binary_semaphore` |
| Java | `platform-thread`, `virtual-thread` | `Thread.ofPlatform()` against `Thread.ofVirtual()`; the line uses `Executors.newThreadPerTaskExecutor` against `newVirtualThreadPerTaskExecutor` |
| Java | pinning | JFR `jdk.VirtualThreadPinned` counts for a `synchronized` block and for a blocking upcall under a native frame (`qsort`) |
| Python | `threads`, `asyncio-tasks` | `threading.Thread` and `Event.wait` against asyncio tasks; `queue.SimpleQueue` against `asyncio.Future` for the hand-off |
| Python | `--blocking-sleep-in-coroutine` | the defect: `time.sleep` inside a coroutine; `--debug` counts asyncio's slow-callback warnings |

### C++

`tasks-bench` runs the three micro workloads and `tasks-line` the line run; both share `lowlat::tasks`. The standard library
supplies what it has. `std::generator<ParcelEvent>` produces the parcels, `std::expected` carries parse and setup errors,
`std::print` writes the output, and `std::jthread` with `std::stop_token` stops the parked threads.
There's no standard task type to put a coroutine in before C++26's `std::execution`, which GCC 16 doesn't ship, and Asio's
`awaitable` keeps its frames in its own recycling allocator where a counter can't see them. So `frames.hpp` has one minimal
`Task<T>`: lazy, move-only, and its `final_suspend` and its `Transfer` awaiter both return the next coroutine's handle for
symmetric transfer. It carries the ping-pong and the frame probes, nothing else; the waits are Asio's.

Frame bytes come from the promise's `operator new`, which is exact for the frames it sees. The probe parks the
coroutines in a vector so every frame escapes the function that created it, because HALO (heap allocation elision) is
allowed to remove the allocation of a frame the compiler can show doesn't outlive its caller. A control loop creates, runs and
destroys 1,000 coroutines in one function and reports how many reached `operator new`. That number is observed: it
depends on the compiler, and `verify.sh` doesn't assert it.

Every bench loop ends in an external-linkage sink or a checked sum (`sink.cpp`), and every shared slot and counter is
`alignas(2 * std::hardware_destructive_interference_size)`, twice the line because the L2 spatial prefetcher on recent Intel
cores pulls adjacent line pairs.

`std::binary_semaphore` isn't the `os-thread` hand-off. libstdc++'s semaphore spins and yields briefly before it waits on a
futex, so two pinned threads handing a turn back and forth can complete a round trip without either entering the kernel;
`r04-run1..3` counted 266, 164 and 181 voluntary switches in 1,020,000 round trips (observed, and it varies). A `std::condition_variable` goes straight to the futex, so
each hand-off is a sleep and a wake, which is the mechanism the chapter is about. The semaphore run is kept as an observed
result.

### Java

`Run.Kind` selects `Thread.ofPlatform()` or `Thread.ofVirtual()`; every workload takes the builder from it, so the two
variants run the same task body. Ping-pong passes a turn through two `SynchronousQueue`s. The pinning run uses the FFM API to
call libc `qsort` with an upcall that sleeps, so a native frame sits between the virtual thread and its carrier, and a
Flight Recorder recording (`jdk.VirtualThreadPinned`, threshold 0) in a temporary file that's read back and deleted. Only the
counts are kept. The JFR file never lands in the tree.

Pinning of a virtual thread is the carrier's: a call to `Affinity.setAffinity` from a virtual thread lands on the carrier
thread that's running it. With one carrier, both ping-pong threads print the same tid and CPU, and `verify.sh` checks both lines.
The virtual-thread run's context-switch count is read by the ping thread from `/proc/thread-self`, which is the carrier that thread is
on when it reads. With `parallelism=1` there is one carrier, unless the JDK compensates for the blocking `/proc` read itself by adding
one (a file read from a virtual thread can do that); the ping-pong's queue operations never block a carrier. A second carrier would
split the count, and nothing in the report would show it.

### Python

Both builds run the same code: the default GIL build and the free-threaded `3.14.9+freethreaded` (a user-local
`uv python install 3.14.9t`). The measuring process, `tasks-py measure`, imports nothing from `lowlat_measure`: that package's
HdrHistogram extension doesn't declare free-threading support, so importing it turns the GIL back on, and the run would measure
a free-threaded interpreter that has a GIL. The process asserts `sys._is_gil_enabled()` is false right after its imports and
again at the end, and exits otherwise. It writes the samples with `array('q').tofile` and a sidecar with `build.compiler`
(its own `sys.version`), `build.gil_enabled` and `runtime.python_build`. `verify.sh` converts them with
`lowlat-report from-samples` in the GIL environment, for both builds, so the two paths are the same.

asyncio rounds its epoll timeout up to a whole millisecond (`selectors.EpollSelector.select` in CPython 3.14), so an asyncio
timer fires up to 1 ms late whatever else happens. That sets the floor of the Python neighbour lateness, and it's why the
blocking-call result is stated as a p99 against 1 ms and the baseline is printed beside it.

## Layout

| Path | Contents |
|---|---|
| `cpp/` | library `lowlat::tasks`; executables `tasks-bench` (`parked`, `pingpong`, `neighbours`) and `tasks-line`; `tasks-test` |
| `java/` | Maven module `stackful-stackless-java`: `stackful-stackless-java.jar`, main class `io.patterncatalyst.lowlat.ch11.Main` (`parked`, `pingpong`, `pinning`, `line`) |
| `tasks-py/` | Python package `lowlat_tasks`, console script `tasks-py`, uv workspace member `lowlat-tasks` |
| `verify.sh` | runs everything and asserts the criteria |

## Run

```bash
examples/11-stackful-stackless/verify.sh
```

Environment (from `examples/_lib/lib.sh`): `ALLOW_BUSY=1`, `SKIP_BUILD=1`, `RESULTS_DIR`, `LOWLAT_BUILD`; also
`RECHECK=results/<run-id>` (evaluate the criteria on committed reports; the placement checks need a live run) and
Run it as `flock -o "$LOCK" ./verify.sh` when another example measures on the host: `-o` keeps the lock descriptor out of the script and everything it starts, and the script stops its whole process tree on TERM or INT. A full run takes about 12 minutes, a clean
build included. The 10,000-thread runs need the process and map limits of an ordinary desktop session.

The Python lane under each build, by hand, from `examples/`:

```bash
# GIL build (the default workspace environment)
uv run tasks-py measure pingpong --variant threads --cpus 1,2 --out /tmp/pp-gil
uv run lowlat-report from-samples /tmp/pp-gil/samples.bin /tmp/pp-gil/sidecar.json /tmp/python-gil-pingpong-threads.json

# free-threaded build: a separate environment, .venv-ft (ignored by git)
UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft uv run --python 3.14.9t --package lowlat-tasks \
    tasks-py measure parked --variant asyncio-tasks --out /tmp/parked-ft
uv run lowlat-report from-samples /tmp/parked-ft/samples.bin /tmp/parked-ft/sidecar.json /tmp/python-ft-parked.json

# unit tests under both builds
uv run pytest 11-stackful-stackless/tasks-py
LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$PWD/.venv-ft \
    uv run --python 3.14.9t --all-packages pytest 11-stackful-stackless/tasks-py
```

The C++ and Java programs by hand (`LOWLAT_PROFILE` from `scripts/profile.sh --out`; CPUs from `distinct_cores 3` in `lib.sh`, without the first):

```bash
build=examples/build/release/11-stackful-stackless/cpp
$build/tasks-bench parked --variant fiber --cpus 1 --report /tmp/parked-fiber.json
$build/tasks-bench neighbours --variant fiber --blocking-sleep-in-fiber --cpus 1 --report /tmp/neighbours.json
java --enable-native-access=ALL-UNNAMED -Djdk.virtualThreadScheduler.parallelism=1 \
    -jar examples/11-stackful-stackless/java/target/stackful-stackless-java.jar \
    pingpong --variant virtual-thread --cpus 1 --report /tmp/vt.json
```

Reports land in `results/latest/`: `cpp-<workload>-<variant>[-alt<N>].json`, `java-...`, `*-line-<variant>.json` (with `-divert`),
`python/python-<build>-<workload>-<variant>.json`, and the machine profile. The driver logs are moved in at the end of the run.

## Expected effect and criteria

`verify.sh` evaluates every criterion, prints each measured value beside its bound and margin, and exits non-zero on any miss.
Latency ratios compare variants within one run, alternating A B C A B C A B C and taking the median of the three
per-alternation ratios; a p50 is never compared across runs. Counters marked exact are deterministic. The bounds sit in variables at the top of `verify.sh`, set from quiet-host dry runs before the measured runs.

1. **Memory per waiting task, on the quantity that shows the gap.** C++ `os-thread` over `fiber` on address space per task
   (`VmSize` growth over the 10,000 tasks) at least 10x; C++ fiber address space per task (measured `VmSize` growth, about 68 KiB) over the counted coroutine frame
   bytes at least 10x; the coroutine frame itself at most 1,024 bytes (exact: the promise's counting `operator new`, on frames
   that escape into a vector) with one allocation per frame (exact). Java `platform-thread` full resident cost per task (RSS, page tables and
   kernel stack, measured the same way on both sides) over `virtual-thread`'s at least 5x. The `VmSize` ratio, platform RSS over
   virtual RSS, and platform RSS over virtual-thread heap (`MemoryMXBean` after a forced collection) are printed as observed. A
   virtual thread's `VmSize` growth is not a per-task cost: it is 0 at 300 tasks and about 34 KB per task at 10,000, which is
   about five steps of 64 MiB, most likely the malloc arenas of new carrier threads, so it's reported and not asserted.
   Python thread RSS over asyncio task
   bytes (measured by `tracemalloc`, not exact) at least 5x, in each build.
2. **Parked tasks armed, and RSS observed.** For the C++ `fiber` and `coroutine` variants, the number of tasks that had reached
   their wait when the memory was read equals 10,000 (exact). In the other parked runs the start gate opens only when every task
   has arrived, so the count can't differ and `verify.sh` doesn't count it as a criterion. RSS ratios are printed, not asserted,
   and a 10x reference is printed beside them. A parked thread's resident cost is a touched stack page or two plus its thread
   block, and a fiber's is one touched stack page, so resident memory separates them by 2x to 4x. What differs by orders of
   magnitude is address space (about 9 MB for a thread, 68 KiB for a fiber, 26 bytes for a coroutine) and the kernel's side of a
   thread (page tables and a 16 KiB kernel stack: 29 KiB in all against 4 KiB for the fiber).
3. **Voluntary context switches per round trip (exact counts from `/proc`).** C++ `os-thread` at least 0.9 (the run counts
   both threads, so two per round trip when each hand-off sleeps), `fiber` and `coroutine` at most 0.001.
4. **Round-trip p50, same run, median of 3 alternations.** C++ `os-thread` at least 5x `fiber` and at least 5x `coroutine`;
   Java `platform-thread` at least 2x `virtual-thread`.
5. **The blocking call.** With `--blocking-sleep-in-fiber`, the neighbours' wake-lateness p99 is at least 1 ms for a 2 ms call
   (C++, the lowest of 3 alternations; 2x by construction). In Python, asyncio's debug mode logs exactly one
   `Executing <...> took N seconds` warning per blocking call (exact; `slow_callback_duration` 1 ms). A p99 of 1 ms doesn't
   separate a blocked asyncio loop from a healthy one: asyncio rounds its epoll timeout up to a whole millisecond
   (`selectors.EpollSelector.select`), so even the baseline p99 sits at or over 1 ms. The Python p99, its ratio to the baseline,
   and the fraction of wakes later than 1.5 ms (blocking against baseline) are printed. The fraction of wakes later than 1.5 ms is asserted at 2x, blocking against baseline (a floor of one late wake stands in for a baseline with none).
6. **Line.** 200,000 parcels counted, `dropped` 0, every divert command received, for the five line variants. End-to-end
   percentiles are observed: every variant sits at the 2 ms lookup plus the scheduling noise around it, orders of magnitude
   inside the 480 ms budget, so the saving is memory and CPU per wait, not latency.
7. **Reports and gates.** Every report passes `lowlat-report check`, with count above 0, `dropped` 0, `build.flags` (C++ and
   Java), `runtime.placement` for pinned runs and `runtime.python_build` for Python; every run that records a start gate has a
   skew under 1 ms (a timing bound), except the single-carrier virtual-thread ping-pong: one carrier serializes its two threads, so
   the second leaves the gate only after the first parks, and its skew is printed; every ping-pong served exactly the configured round trips with its payload intact (exact);
   free-threaded runs kept the GIL off.

Observed, not asserted: how the other lanes' neighbours wake with no blocking call, `std::binary_semaphore` against
`condition_variable` (the semaphore spins first, so its hand-off rarely reaches the kernel), HALO on a coroutine that
doesn't escape (clang 22 at `-O2` still reached `operator new` for all 1,000 coroutines of the control loop), Java's
`jdk.VirtualThreadPinned` counts (a `synchronized` block 0 under JEP 491, a native frame one per blocked task), and the Python
hand-off in each build. The address space and kernel bytes each task costs are printed beside the asserted ratios, and so are the line percentiles. `verify.sh` flags any asserted
bound that clears with under 2x margin.

## Observation surfaces

| Surface | What it shows |
|---|---|
| Terminal output of `verify.sh` | each criterion's value, bound and margin; the observed items |
| `runtime.counters` in each report | exact counts: frames and their bytes, tasks armed, round trips served, voluntary switches, pinned events, slow-callback warnings, RSS and address-space readings |
| `runtime.placement`, `/proc/<pid>/task/<tid>/stat` | where each pinned thread ran |
| `runtime.ctx_switches` | the measured threads' voluntary and involuntary context switches |
| `runtime.python_build`, `build.gil_enabled` | which CPython build measured, and that the GIL stayed off |
| `build.flags` (Java) | the JVM options, `-Djdk.virtualThreadScheduler.parallelism=1` included |

Grafana: no panel by design. The evidence here comes from short microbenchmarks and a 20 s line run, and it's exact counts and
distributions in the reports. Live observability of the lookup tasks is Part 7.

## Licences

| Component | Version | Licence | Used for |
|---|---|---|---|
| Boost (Asio, Fiber, Context) | 1.92.0 | BSL-1.0 | C++ coroutine waits, fibers and their stacks |
| OpenHFT Affinity (chronicle-bom 2026.26) | 2026.2 | Apache-2.0 | thread pinning |
| JNA | 5.19.1 | LGPL-2.1-or-later OR Apache-2.0 | Affinity's native calls (version managed for convergence) |
| HdrHistogram | per `versions.env` | BSD-2-Clause / CC0 | latency histograms (C, Java, Python) |
| GoogleTest | v1.18.0 | BSD-3-Clause | C++ tests |
| protobuf | per `versions.env` | BSD-3-Clause | the line's wire format and divert commands |
| nlohmann/json | v3.12.0 | MIT | C++ reports |
| pytest | 9.1.1 | MIT | Python tests |
| Jackson (`jackson-databind`, `jackson-core`) | 3.2.4 (`jackson-annotations` 2.22) | Apache-2.0 | JSON reports in the Java measurement kit |
| slf4j-api | 2.0.17 | MIT | logging facade, pulled in by Affinity |
| JUnit | 6.1.3 | EPL-2.0 | Java tests |
| CPython | 3.14.9 and 3.14.9+freethreaded | PSF-2.0 | the Python lanes (GIL and free-threaded builds) |

Java Flight Recorder and the FFM API ship with the OpenJDK (GPL-2.0-only WITH Classpath-exception-2.0); nothing links them
on a hot path.

## Provenance

The `Task<T>` and the promise-level frame counter in `cpp/include/lowlat/tasks/frames.hpp` are adapted from the companion
project cpp-concurrency-and-parallelism, example `11-coroutines-in-depth` (a `Generator<T>` and `Task<T>` with symmetric
transfer, and a HALO probe), brought up from C++20 to C++23: `std::generator` replaces its hand-rolled `Generator`. The fiber
setup in `cpp/src/workloads.cpp` (Boost.Fiber on `protected_fixedsize_stack`, a `buffered_channel` hand-off) is adapted from its
example `13-fiber-worker-pool`. Example 10 supplied the thread-placement gate and the option parser, and the divert-command path.
Each adapted file says so in its first lines.

## Verification status

Behavioural. `verify.sh` asserts the seven criteria above, and all of them held on the host runs `r04-run1..3` (bare-metal
host, untuned: governor `powersave`, tuned `balanced`, clocksource `tsc`, kernel 7.2, Temurin 25.0.5+8, Clang 22.1.8,
Python 3.14.9 in both builds; lab VM down; commit 4434ed1; load average at most 2 at each start). The free-threaded
measurements kept the GIL off from imports to the end. Ranges over the three runs; a ratio is the range of each run's
median over its 3 alternations.

| Quantity | Range |
|---|---|
| Address space per parked wait, C++ thread / fiber (bound 10x) | 9,245,449 B / 69,645 B, ratio 132.75x |
| Coroutine frame (bound at most 1,024 B) and allocations, 10,000 tasks (exact) | 208 B, 10,000 |
| Full resident cost per wait, Java platform / virtual (bound 5x) | ratio 12.61x to 14.28x |
| Python GIL thread RSS / `asyncio` `tracemalloc` (bound 5x) | 11.72x to 11.73x |
| Tasks armed, fiber and coroutine (exact) | 10,000 of 10,000 |
| Voluntary switches per round trip, C++ thread (exact) | 2 |
| Voluntary switches in 1,020,000 round trips, fiber / coroutine (exact) | 0 / 0 |
| Round-trip p50, thread / fiber (bound 5x), C++ | ratio 18.25x to 18.33x (3,755 to 3,777 / 205 to 207 ns) |
| Round-trip p50, platform / virtual (bound 2x), Java | ratio 10.28x to 10.48x (4,115 to 4,175 / 399 to 404 ns) |
| Neighbours' p99 with a 2 ms blocking call in a fiber (bound 1 ms) | 1,917 to 1,952 us against 52 us without |
| `asyncio` slow-callback warnings for 50 blocking calls (exact) | 50 |
| Line runs, five variants | 200,000 parcels counted, none dropped, every divert command received |
| Reports | 55 pass `lowlat-report check` in each run |
| Observed: Python `asyncio` p99 with and without the blocking call | 2.05x to 2.19x (1,305 to 1,308 us without) |
| Observed: `jdk.VirtualThreadPinned` events, `synchronized` / native frame | 0 / 100 of 100 |
| Observed: coroutine frames that reached `operator new` in the HALO control | 1,000 of 1,000 non-escaping frames |

Outliers and failures: none. The one asserted bound cleared by under 2x is the fiber's blocking-call lateness (1.90x to
1.94x of the 1 ms bound), which is set by construction since the call lasts 2 ms. Resident-size ratios, Java switch
counts, the semaphore hand-off, the pinning counts and the line percentiles are observed and not asserted.
