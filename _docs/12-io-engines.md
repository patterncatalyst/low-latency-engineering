---
title: "I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core"
order: 12
part: "Threading & I/O Models"
description: "In C++ at saturation, epoll makes 1.379-1.417 system calls per parcel and io_uring 0.062-0.068, with 14.7-16.2 completions per io_uring_enter; thread-per-core makes 0 hand-offs per parcel against 1; and in a Quarkus service where 5 kHz x 2 ms puts 10 requests in flight, an 8-thread worker pool has a p99 162.85-223.10x that of virtual threads, on a bare-metal, untuned host."
duration: 55 minutes
---

## Learning objectives

By the end of this chapter you can:

- Say what a readiness engine and a completion engine each ask the kernel, and read the cost from system calls per parcel.
- Write a receive loop with `epoll`, then with a multishot `io_uring` receive and a provided buffer ring, and say what each counter means.
- Choose between one receive thread plus a hand-off and one socket per pinned thread, and count the hand-offs.
- Predict which Quarkus variant queues when the load exceeds the worker pool, and name the call that stalls an event loop.

## Why this matters

The hub concentrator takes the four tunnel cameras' UDP feeds, one socket each. For every datagram, something has to tell a thread there's work: a readiness event ("this socket has data, come and get it") or a completion ("this receive finished, here's the data"). The choice sets how many times the thread crosses into the kernel per parcel, and the thread count sets how many times a parcel changes cores before it's decided.

One tier up, the sort-plan service waits 2 ms on the warehouse management system for every scan. At 5 kHz that's 10 waits at once: by Little's law, the number in flight is the arrival rate times the time each one waits. Something holds each wait, a thread or virtual thread blocked in the call or a callback that an event loop runs when the answer comes. This chapter asks what wakes the holder, and how many holders there should be.

The code is in `examples/12-io-engines/`. Its `README.md` covers what it does and how to drive it. HTTP/1.1 on loopback in the service lane is a harness, not a transport recommendation.

## Diagram

{% include excalidraw.html file="12-readiness-vs-completion" alt="Two panels. Left, readiness: the UDP socket queue (kernel) makes epoll_wait return that the socket is ready, and recvmsg then takes one datagram; each step is a kernel crossing (amber). At saturation in C++, epoll makes 1.379-1.417 system calls per parcel (recvmsg 1, epoll_wait 0.379-0.417) and recvmmsg makes 0.573-0.614. Right, completion: one multishot recvmsg per socket stays armed and is re-armed when the kernel ends it, the kernel picks a buffer from a provided buffer ring for each datagram and posts a completion queue entry, and the program reaps the queued entries, calling io_uring_enter only to wait. io_uring makes 0.062-0.068 io_uring_enter calls per parcel, with 14.7-16.2 completions per io_uring_enter. The saturation runs are 60 kHz x 4 cameras for 3 s, and the counts depend on load." caption="Figure 12.1: The ring turns a system call per parcel into one call per 14.7-16.2 completions. At saturation, C++ epoll makes 1.379-1.417 system calls per parcel and io_uring 0.062-0.068." %}

## Concept

### Readiness or completion

Take the hub's `epoll` loop. `epoll_wait` returns the sockets that have data, and `recvmsg` takes one datagram from each. The engine registers `EPOLLIN` and nothing else, so a socket that still holds data is reported again at the next wait. A wake-up that finds three sockets ready costs one `epoll_wait` and three `recvmsg` calls, and the in-program counters read `recvmsg` at exactly 1.000 per parcel and `epoll_wait` at 0.379-0.417, so 1.379-1.417 system calls per parcel at saturation. Not two: the wait is shared. `recvmmsg` keeps the readiness model and takes up to 32 datagrams per call, and makes 0.573-0.614.

A completion engine inverts the order. One multishot `recvmsg` per socket is armed once. The kernel picks a buffer from a provided buffer ring for each datagram and posts a completion. The program reaps what's already queued with no system call, and calls `io_uring_enter` only to wait for the next one: 0.062-0.068 per parcel, 14.7-16.2 completions per call. The kernel can end a multishot receive, and the loop re-arms it and counts it: 0 to 20 re-arms in 720,000 parcels.

Both counts depend on load. The ratio of epoll's system calls to io_uring's is 20.1-22.9x (per-run median of three alternations), and it exists because completions queue while the thread works. The Cross-check section shows the same engine at a lighter load.

### Thread-per-core

{% include excalidraw.html file="12-thread-per-core" alt="Two panels. Left, thread-per-core: four cameras send to four ports, one per camera, each with its own socket (SO_REUSEPORT set) owned by one pinned thread with its own ring, so nothing is shared. Right, acceptor and pool: one receive thread decodes and hands each parcel off through one lock-free log per worker, round robin, to one of four decide workers. Hand-offs per parcel are 0 and 1, exact. At saturation, 52 kHz x 4 cameras with 3,500 ns of modelled receive work, the C++ p99 is 68-69 us thread-per-core and 84-90 us acceptor and pool, a ratio of 0.77-0.82x that is observed and not asserted; the busiest thread-per-core receiver is 384 permille busy and the acceptor 820-822 permille (per-run medians of 3 alternations). At line rate, 2.5 kHz per camera, with one measurement per run, the p99 is 98-115 us thread-per-core and 91-113 us acceptor and pool." caption="Figure 12.2: Shared nothing makes 0 hand-offs per parcel and the acceptor makes 1. At the saturation load the thread-per-core p99, 68-69 us, was 0.77-0.82x the acceptor's, an observed ratio and not a guarantee; at line rate the p99 ranges overlap, 98-115 us against 91-113 us." %}

Each camera's datagram lands on one core. Thread-per-core decides it there: each camera gets its own socket and ring on one pinned thread, so nothing is shared. `SO_REUSEPORT` is set on every socket, but it steers nothing here. Each camera has its own port (`base_port + c`), so the sender picks the socket. The acceptor and pool layout has one receive thread that decodes and hands each parcel to one of four decide workers, round robin, through one lock-free log per worker: a ring the receive thread writes and the worker spins on. The hand-off's cost is the cache lines that move between the two cores and the worker's wake from its spin.

### Who holds the 2 ms wait

{% include excalidraw.html file="12-vt-vs-event-loop" alt="Four rows for the Quarkus service with a 2 ms dependency, all Java. Event loop at 5,000 Hz: a non-blocking timer callback holds the wait, 4 event-loop threads and no thread waiting; p99 9.0-10.3 ms. Worker pool at 5,000 Hz: 8 workers, all active, against 10 requests in flight by Little's law (5,000 Hz x 2 ms); a queue builds in front, with the client holding up to 5,661-5,677 requests in flight, and the p99 is 1,453.3-1,455.4 ms. Virtual thread at 5,000 Hz: 4 carrier threads, and the sleeping virtual thread unmounts; p99 6.5-8.9 ms. The defect, blocking-on-event-loop at 1,850 Hz (amber): Thread.sleep(2) on the event loop keeps at most 4 requests in a handler; p99 8.1-8.5 ms against 3.3 ms for the event-loop control at the same rate, a ratio of 2.44-2.61x that is observed." caption="Figure 12.3: Ten requests in flight do not fit in 8 workers: the worker-pool p99 is 1,453.3-1,455.4 ms against 6.5-8.9 ms for virtual threads, about 160-220x. Sleeping on the event loop lifts the p99 to 8.1-8.5 ms at 1,850 Hz, 2.44-2.61x the control (observed)." %}

The sort-plan service answers one lookup four ways. On the event loop, a `Uni` (Mutiny's lazy single-value type) completes from a non-blocking timer, so no thread holds the wait. On the worker pool, `Thread.sleep(2)` holds one of 8 workers. On a virtual thread, the same sleep parks the virtual thread and frees its carrier. And `blocking-on-event-loop`, the defect, sleeps on one of the few loop threads.

The JDK parks a virtual thread that finds no datagram on its poller, which is `epoll` on Linux. The plain-JDK selector loop waits in the same call: its `strace` shows `epoll_wait` too. A virtual thread is written as blocking code, but it waits on the same readiness mechanism.

## How the code works

### Readiness against completion

First cut (#A), `run_epoll` and its `make_epoll` registration in `engines.hpp`; then the completion engine (#B), `UringReceiver`:

```cpp
    epoll_event ev{};
    ev.events = EPOLLIN;
// ...
    const int n = ::epoll_wait(ep.get(), events.data(), static_cast<int>(events.size()), cfg.tick_ms);
    ++counters.epoll_waits;
// ...
    for (int e = 0; e < n; ++e) {
      const std::uint32_t index = events[static_cast<std::size_t>(e)].data.u32;
      iovec iov{buffer.data(), buffer.size()};
      msghdr msg{};
      msg.msg_iov = &iov;
      msg.msg_iovlen = 1;
      const ssize_t got = ::recvmsg(cameras[index].fd, &msg, MSG_DONTWAIT);
      ++counters.recvmsgs;
```

```cpp
    io_uring_prep_recvmsg_multishot(sqe, cameras_[index].fd, &msgs_[index], 0);
    sqe->flags |= IOSQE_BUFFER_SELECT;
    sqe->buf_group = static_cast<std::uint16_t>(kBufferGroup);
// ...
      io_uring_for_each_cqe(ring_.get(), head, cqe) {
        reap(*cqe, handle, counters, idle);
        ++reaped;
      }
      if (reaped > 0) {
        io_uring_cq_advance(ring_.get(), reaped);
        bufs_->advance(static_cast<int>(returned_));
// ...
      io_uring_cqe* first = nullptr;
      const int rc = io_uring_submit_and_wait_timeout(ring_.get(), &first, 1, const_cast<__kernel_timespec*>(&tick), nullptr);
      ++counters.enters;
// ...
    if ((cqe.flags & IORING_CQE_F_MORE) == 0) {  // the kernel ended this multishot: arm it again
      ++counters.rearms;
      arm(index);
    }
```

Boost.Asio's reactor runs the #A loop for you; it's written out here to count the calls. In #A every datagram is a system call the program issues, and `EPOLLIN` without `EPOLLET` is the level-triggered registration. In #B `IOSQE_BUFFER_SELECT` lets the kernel pick the buffer, `io_uring_for_each_cqe` walks the completion ring in user space, `reap` hands each buffer back with `bufs_->add`, and `bufs_->advance` publishes the batch to the kernel. A completion without `IORING_CQE_F_MORE` means the receive ended and must be armed again; a multishot can end at any completion, and the loop treats `-ENOBUFS` and `-ECANCELED` as an end to re-arm, not an error. The `io_uring_submit_and_wait_timeout` call is the only system call on this path: the loop calls it only when no completion is queued, and it submits any re-armed receive and waits.

The JDK and CPython have no `io_uring` in the standard library, so the other two languages show the readiness idiom only. Python's `receive.py` hands each socket to `asyncio`'s datagram endpoint; Java's `ReceiveRun.java` uses an NIO `Selector`:

{% include codetabs.html langs="Python|Java" %}

```python
    def datagram_received(self, data: bytes, addr: object) -> None:
        self._stats.calls += 1
        handle(data, self._cam, self._stats)
# ...
        transport, _ = await loop.create_datagram_endpoint(
            lambda cam=cam: _CameraProtocol(cam, stats), sock=cam.sock
        )
```

```java
                selector.select(key -> {
                    int camera = (Integer) key.attachment();
                    try {
                        // Readiness says "something is there": take everything until the socket says "nothing".
                        while (true) {
                            buf.clear();
                            c.receives++;
                            if (channels[camera].receive(buf) == null) {
                                break;
                            }
```

Python's `asyncio-datagram`, `blocking-thread` (one thread per socket) and `uvloop` variants take the same four-camera feed.

### Hand-off against shared nothing

In `receive_main.cpp` the handler either passes the parcel on (#A, the acceptor) or decides it where it landed (#B, a thread-per-core receiver):

```cpp
          if (pool) {
            pool->send(*parcel, counters);
          } else {
            io::decide(*parcel, counters, recorder, work_ns);
          }
```

`pool->send` publishes to a worker's log and counts one hand-off. The #B branch counts none.

### Worker pool against virtual thread

First cut (#A), `@Blocking` on a pool fixed at 8 in `application.properties`; then `@RunOnVirtualThread` (#B). Both are in `PlanResource.java`:

```java
    @Blocking
    public String workerPool(@RestPath String sscc) throws InterruptedException {
```

```java
    @RunOnVirtualThread
    public String virtualThread(@RestPath String sscc) throws InterruptedException {
```

The bodies are the same `Thread.sleep(SortPlan.WAIT_MS)`. In #A the sleep holds a worker for 2 ms, so 8 workers carry at most 4,000 requests a second. In #B it parks a virtual thread. The defect carries `@NonBlocking` on a method that sleeps. Left at its defaults the loop would log nothing for a 2 ms block (the limit is 2 s), so the `%defect` profile sets `quarkus.vertx.max-event-loop-execute-time` to `1ms` and `quarkus.vertx.warning-exception-time` to `10ms`, which is also the checker's period, so it samples each loop 100 times a second.

## Measure

Run from the repository root:

```bash
examples/12-io-engines/verify.sh
```

`ALLOW_BUSY=1` measures on a loaded host; `RECHECK=results/<run-id>` re-evaluates committed reports. A latency ratio is the median of three alternations inside one run, and a p50 is never compared across runs.

Profile for every number below: bare-metal host, untuned: `powersave` governor, `balanced` profile, kernel 7.2; an Intel 8-core, 16-thread CPU; Temurin 25.0.5+8, Clang 22.1.8 on GCC 16.2's libstdc++, Python 3.14.9 (GIL and free-threaded builds), Quarkus 3.40.1.1. Threads placed on distinct physical cores by `sched_setaffinity`, an experiment control, not isolation. Ranges span the committed runs `r04-run1` to `r04-run3`.

### System calls per parcel

Four simulators send 60 kHz each for 3 s: 720,000 parcels, dropped 0 in every run. Each parcel carries 3 us of modelled decide work. The counters are exact for a run but load-dependent.

| C++ at saturation | system calls per parcel | notes |
|---|---|---|
| `epoll` | 1.379-1.417 | `recvmsg` 1.000, `epoll_wait` 0.379-0.417 |
| `recvmmsg` | 0.573-0.614 | up to 32 datagrams per call |
| `io-uring` | 0.062-0.068 | 14.7-16.2 completions per `io_uring_enter` |

The asserted bound is io_uring's enters per parcel at most a quarter of epoll's system calls per parcel; the smallest margin was 4.38x. The tail doesn't follow the counters. The saturation p99 of `io-uring` over `epoll` is 0.81-1.01x, within a factor of 2 and observed only. Fewer crossings freed CPU: the receive thread was busy 833-842 permille of its window with `io-uring` against 888-890 with `epoll` (per-run medians, observed, under 2x). This load doesn't show a tail benefit. `asio-io-uring`, Boost.Asio on its io_uring backend, is in the reports as an observed lane.

### Hand-offs and the layout

At 52 kHz per camera with 3,500 ns of modelled receive work per datagram, the acceptor was on a CPU for 820-822 permille of its receive window (a guard band of 750-900 holds) and the busiest thread-per-core receiver for 384. Thread-per-core made 0 hand-offs per parcel and the acceptor and pool 1 (exact). Dropped was 0 for both.

The saturation p99 was 68-69 us for thread-per-core and 84-90 us for the acceptor and pool, a ratio of 0.77-0.82x. That's observed, not asserted: the margin is under 2x, and a hotter acceptor would drop parcels, so its p99 would measure a backlog. At line rate (2.5 kHz per camera, one measurement per run) the p99 is 98-115 us against 91-113 us, and the ranges overlap.

### The service

The open-loop client sends request `i` at `start + i / 5,000` s whatever happened to the earlier ones and measures from that intended time. By Little's law, 5,000 Hz x 2 ms is 10 requests in flight against 8 workers.

| Quarkus at 5 kHz | p99 | evidence |
|---|---|---|
| `event-loop` | 9.0-10.3 ms | 4 loop threads, 0 workers |
| `worker-pool` | 1,453-1,455 ms | 8 workers, all active |
| `virtual-thread` | 6.5-8.9 ms | 4 carriers, 0 workers |

The asserted ratio is `worker-pool` over `virtual-thread`: 162.85-223.10x against a bound of 3x. Eight workers drain 4,000 requests a second against 5,000 offered, so the queue grows for the run, and the client held 5,661-5,677 requests in flight at the peak (per-run median). That p99 is a backlog, not a service time. `event-loop` against `virtual-thread` is 0.96-1.41x, observed, and the order changes between runs.

The defect runs at 1,850 Hz, because four loops each blocked for 2 ms carry at most 2 kHz. Its p99 is 8.1-8.5 ms against 3.3 ms for the event-loop control at the same rate: 2.44-2.61x. That's above the 2x bound, but the margin over it is under 2x, so the ratio is printed as observed rather than asserted. The exact evidence is in the counters: Vert.x logged about 1,000 blocked-thread warnings in the measured run (990-1,030 across the nine alternations), and at most 4 requests were inside a handler at once, one per loop. The control had 13-16 (across alternations).

### Python

`asyncio-datagram` (one thread, the selector loop), `blocking-thread` (one thread per socket, GIL and free-threaded builds) and `uvloop` took the four-camera line, 200,000 parcels each, dropped 0. Line p99 ranges are 99-135 us, 119-170 us and 99-275 us under the GIL, and 86-117 us and 104-482 us for the free-threaded `asyncio-datagram` and `blocking-thread`. They overlap, one measurement per run, so nothing is ordered.

### The line

Four cameras at 2.5 kHz for 20 s: every C++ engine, every plain-JDK variant and every Python variant counted 200,000 parcels and dropped none. The largest p99 anywhere on the line was 482 us against a 480 ms budget (observed). At line rate the engines don't differ in any way the belt can see; saturation shows where they would.

## Cross-check

The in-program counters and `strace -f -c` agree. For `epoll`, `strace` counted 39,966, 39,813 and 32,277 `epoll_wait` calls and 40,000 `recvmsg` calls for 40,000 parcels, the same numbers the program printed; `recvmmsg` matched too. For `io-uring`, `strace` counted 15,198, 28,358 and 39,343 `io_uring_enter` calls against 15,200, 28,359 and 39,343 in the program, a difference of 0-2.

The load differs from saturation. These runs send 2.5 kHz x 4 cameras for 4 s, and the tracer adds work to every call. `epoll` made 1.807-1.999 system calls per parcel there, and `io-uring` made 0.380, 0.709 and 0.984 `io_uring_enter` calls per parcel against 0.062-0.068 at saturation. The saving belongs to a load that queues completions, which is why the counters carry the load beside them.

The Java `virtual-thread-blocking` run shows the poller: 7,813, 8,370 and 9,047 `epoll_wait` calls and 7,998-8,000 `recvfrom` calls for 4,000 parcels, and in every run half of them (3,998-4,000) returned no datagram, after which the virtual thread parked. The Python `blocking-thread` made 1 `recvfrom` per parcel and no `epoll_wait`; `uvloop` made about 2 `recvmsg` calls per parcel.

On the client side, the `worker-pool` run's own lateness p99 (how far past its schedule the client sent; per-run medians) was 12.4-13.5 ms, against a request p99 of 1,453-1,455 ms. The queue wasn't in the client's schedule. The server's counters place it: the workers' active maximum was 8, equal to the pool, and the handler maximum 8, while the client held 5,661-5,677 requests in flight. The `event-loop` run had a lateness p99 of 11-163 us.

## What you learned

- Readiness asks the kernel which socket is ready, and the program takes the data; completion arms a receive once and reaps results. At saturation epoll makes 1.379-1.417 system calls per parcel and io_uring 0.062-0.068.
- The saving depends on load, and the p99 didn't follow at this load (0.81-1.01x).
- Thread-per-core makes 0 hand-offs per parcel against 1; its saturation p99 was 0.77-0.82x the acceptor's, observed.
- When arrival rate times wait (Little's law) exceeds the worker pool, the queue forms at the pool: 162.85-223.10x the virtual-thread p99. An event loop is fine until something blocks it.
- The JDK parks a virtual thread on `epoll`, and neither the JDK nor CPython has an `io_uring` lane.

## For deeper coverage

- Enberg, *Latency* (Manning), for hiding latency with asynchronous I/O.
- Tanenbaum and Bos, *Modern Operating Systems* (Pearson), for I/O software and interrupts; Williams, *C++ Concurrency in Action* (Manning), and Grimm, *Concurrency with Modern C++* (Leanpub), for the threads under a pool.
- Evans and Gough, *Optimizing Cloud Native Java* (O'Reilly), and Andrist and Sehr, *C++ High Performance* (Packt), for the JVM and C++ sides.
- Companion sites: [cpp-concurrency-and-parallelism, async runtimes and event loops](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/docs/12-async-runtimes-and-event-loops/); [linux-systems-programming 09, event loops with `epoll`](https://patterncatalyst.github.io/linux-systems-programming/docs/09-event-loops-epoll-inotify/), [10, `io_uring`](https://patterncatalyst.github.io/linux-systems-programming/docs/10-io-uring/) and [55, Boost.Asio](https://patterncatalyst.github.io/linux-systems-programming/docs/55-boost-asio/); [quarkus-optimization](https://patterncatalyst.github.io/quarkus-optimization/).
- [Chapter 2, *Modelling with Little's Law and Amdahl's Law*]({{ '/docs/02-littles-amdahl/' | relative_url }}), for Little's law, and [Chapter 11, *Stackful vs stackless: threads and fibers vs event loops and coroutines*]({{ '/docs/11-stackful-stackless/' | relative_url }}), for what each model keeps while it waits.
- [Chapter 10, *Lock-free and wait-free synchronization*]({{ '/docs/10-lockfree-waitfree/' | relative_url }}), for the hand-off log, and [Chapter 13, *Where the code runs: bare metal, VMs and containers, and when not to use containers*]({{ '/docs/13-where-code-runs/' | relative_url }}) (Part 4).
- Chapter 15, *CPU partitioning and the noisy-neighbour problem* (Part 5), for isolation, and Part 6, *Transports by Latency Budget*, for transports.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts io_uring enters per parcel at most a quarter of epoll's system calls per parcel, 0 and 1 hand-offs per parcel, dropped 0 and the acceptor's busy share in a guard band, the Quarkus worker-pool p99 at least 3x the virtual-thread p99, the blocked-thread warnings and at most one request per loop thread in the defect, the line counts, the Quarkus pool counters, the start gates and the report contents. Observed only: `asio-io-uring`, `recvmmsg`'s calls per parcel, the line percentiles, the `io-uring` tail against `epoll`, the layout p99 ratio, the defect against its control, `event-loop` against `virtual-thread`, the plain-JDK and Python lanes, and the `strace` summaries. It held on `r04-run1` to `r04-run3`, bare-metal and untuned, at commit 4434ed1.*
