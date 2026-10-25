---
title: "Stackful vs stackless: threads and fibers vs event loops and coroutines"
order: 11
part: "Threading & I/O Models"
description: "A parked wait costs a C++ thread 9,245,449 B of address space, a fiber 69,645 B and a coroutine 26 B; a round trip is 18.25-18.33x faster between fibers than between threads, and one 2 ms blocking call lifts the neighbours' p99 wake lateness from 52 us to 1,917-1,952 us, on a bare-metal, untuned host."
duration: 55 minutes
---

## Learning objectives

By the end of this chapter you can:

- Say what a thread, a fiber, a virtual thread and a coroutine each keep while a lookup waits, and read the cost from the resident, address-space and kernel bytes per wait.
- Explain a hand-off as a futex sleep and wake, a user-space context swap or a resume, and read it from voluntary context switches per round trip.
- Predict what one blocking call does to the tasks that share its thread, and why a fiber and an asyncio task fail the same way.
- Name what still pins a Java virtual thread after JEP 491.

## Why this matters

Every scan on the sortation line triggers a sort-plan lookup at the warehouse management system (WMS), and the answer takes about 2 ms. At 10 kHz that's 20 lookups in flight (Little's law, [Chapter 2, *Modelling with Little's Law and Amdahl's Law*]({{ '/docs/02-littles-amdahl/' | relative_url }})). At a hub taking 100,000 scans a second from a slow WMS, it's thousands. Something has to hold each of those waits.

A parcel has 480 ms from scan to divert (1.2 m at 2.5 m/s), so the lookup fits many times over. What the holder costs is memory and CPU per wait, and what a blocking call inside it does to its neighbours.

[Chapter 10, *Lock-free and wait-free synchronization*]({{ '/docs/10-lockfree-waitfree/' | relative_url }}), coordinated the threads. This chapter asks what those threads are. [Chapter 12, *I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core*]({{ '/docs/12-io-engines/' | relative_url }}), covers the engine underneath an event loop.

The code is in `examples/11-stackful-stackless/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="11-who-holds-the-wait" alt="Three lanes, each for 10,000 tasks parked on one 1,000 ms timer. OS threads: each wait owns a kernel stack, 16,380-16,384 B in C++, and a reserved user stack, 8,192 KiB in C++; per wait the RSS and address space are 8,774-8,778 B and 9,245,449 B in C++, 19,228-19,247 B and 9,266,672-9,266,776 B in Python, and 22,805-22,898 B and 1,044,486-1,044,591 B in Java. Fibers and virtual threads: a small stack in user space, 65,536 B reserved per C++ fiber and 2,063-2,105 B of heap per Java virtual thread; the RSS and address space per wait are 4,106 B and 69,645 B in C++ and 2,870-3,260 B and 27,262-34,078 B in Java. Coroutines (amber): no stack, only a heap frame, 208 B in C++ and 1,641 B in Python (tracemalloc); the RSS and address space per wait are 1,009 B and 26 B in C++ and 2,611-2,614 B and 2,569 B in Python." caption="Figure 11.1: What a parked wait owns. The user-space RSS per wait falls from 8,774-8,778 B for a C++ OS thread to 4,106 B for a fiber and 1,009 B for a coroutine, while the reserved address space falls from 9,245,449 B to 69,645 B to 26 B." %}

## Concept

### Who holds the wait

Take one lookup waiting on the WMS. An OS thread holds it with a stack: 8,192 KiB of address space reserved by default, a 16 KiB kernel stack and a thread control block. A fiber (Boost.Fiber) or a virtual thread holds it with a stack too, but one the library allocates in user space and sizes itself: 64 KiB in the C++ example, about 2 KB of heap in the JDK. Both are stackful: the task can suspend from any call depth, because its whole call stack goes with it.

A C++23 coroutine or an asyncio task is stackless. It keeps one heap frame holding the variables that live across its suspension points, and it suspends only at a `co_await` or `await` in its own body. A caller that wants to wait for it must be a coroutine too, so the suspension point shows in every signature up the chain. That's the function-colouring problem, seen from the code: the stackful task pays in stack bytes, the stackless one in signatures.

A fiber scheduler and an event loop are both cooperative: they run one task until it suspends. A call that blocks the thread instead takes every other task on it along. Nothing in the type system warns you, since `std::this_thread::sleep_for` in a fiber and `time.sleep` in a coroutine look like any other call.

A virtual thread is the JDK's answer: it parks instead of blocking and frees its carrier thread. JEP 491 (JDK 24) removed the case of blocking inside `synchronized`. Blocking under a native frame still pins the carrier, as does blocking in a class initializer.

Python has no standard-library stackful coroutine (greenlet and gevent are third-party), and Java has no stackless one, so those lanes are absent.

### The hand-off

A finished lookup hands its result to the next stage. The ping-pong reduces that to two tasks passing a turn. Between OS threads the waiter sleeps on a futex and the other thread wakes it through the kernel: two voluntary context switches per round trip. Between fibers, a scheduler swaps stacks in user space. Between C++ coroutines, symmetric transfer lets one `await_suspend` return the other's handle, and the compiler turns the resume into a tail call.

## How the code works

### The wait

An OS thread (#A) parks in a condition variable until its deadline, while the coroutine (#B) holds a timer in its frame and suspends at `co_await`. A fiber sits between them: `boost::fibers::fiber` takes a `protected_fixedsize_stack` of 64 KiB (`kFiberStackBytes`) and parks in `boost::this_fiber::sleep_until`.

```cpp
        std::mutex m;
        std::condition_variable_any cv;
        std::unique_lock lock{m};
        cv.wait_until(lock, stop, when, [] { return false; });  // parked until the deadline or a stop request
        woke[i] = now_ns();
```

The thread's wait (#A) is one stack and one kernel thread. The coroutine's wait (#B) is one heap frame. In Java the same body runs on a platform or a virtual thread, and Python's asyncio task is the stackless twin.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
asio::awaitable<void> parked_waiter(std::int64_t when, std::int64_t* woke, std::size_t* armed) {
  asio::steady_timer timer{co_await asio::this_coro::executor, at(when)};
  ++*armed;
  co_await timer.async_wait(asio::use_awaitable);
  *woke = now_ns();
}
```

```python
    async def waiter(index: int) -> None:
        await barrier.wait()
        await asyncio.sleep(max((deadline[0] - time.monotonic_ns()) / NS, 0.0))
        woke[index] = time.monotonic_ns()
```

```java
        Thread.Builder builder = kind.builder();

        // ...

                threads[i] = builder.unstarted(() -> {
                    armed.countDown();
                    awaitUninterruptibly(go);
                    long remaining;
                    while ((remaining = deadline[0] - System.nanoTime()) > 0) {
                        LockSupport.parkNanos(remaining);
                    }
                    woke[index] = System.nanoTime();
                    woken.countDown();
                });
                threads[i].start();
```

The coroutine probe parks its `Task<T>` frames in a vector, so no frame can be elided, and the promise's counting `operator new` sees each one. Java's two variants differ only in `Thread.ofPlatform()` against `Thread.ofVirtual()`.

### The hand-off

First cut (#A), `CondvarToken` between two pinned threads, then the coroutine's `Transfer` awaiter (#B):

```cpp
  void post() {
    {
      const std::scoped_lock lock{m};
      ready = true;
    }
    cv.notify_one();
  }
  void wait() {
    std::unique_lock lock{m};
    cv.wait(lock, [this] { return ready; });
    ready = false;
  }
};
```

```cpp
  std::coroutine_handle<> await_suspend(std::coroutine_handle<> me) const noexcept {
    self = me;
    return peer;
  }
```

In #A, `wait` goes straight to a futex and `notify_one` wakes it, so every hand-off is a sleep and a wake. In #B, `await_suspend` stores the suspended handle in `self` and returns `peer`; the compiler resumes the peer without a scheduler or a system call.

`std::binary_semaphore` isn't the thread hand-off: libstdc++ spins before it waits, so two hot threads can finish a round trip without entering the kernel.

### The blocking call

One task in 1,000 makes a 2 ms blocking call every tenth iteration. The fiber (#A) calls `std::this_thread::sleep_for`; the asyncio twin (#B) calls `time.sleep`. Both are ordinary calls.

{% include codetabs.html langs="C++|Python" %}

```cpp
          // The defect: a blocking call inside a fiber blocks the whole OS thread, so every fiber on it waits.
          if (blocks_now(p, i, k)) std::this_thread::sleep_for(p.block);
```

```python
            # The defect: time.sleep in a coroutine blocks the event loop, so every task waits.
            if blocking and i == 0 and k % 10 == 9:
                time.sleep(block_ns / NS)
```

The Python twin runs 50 tasks, not 1,000: an asyncio loop wakes about 75,000 tasks a second at most, and 1,000 tasks every 2 ms is 500,000, so the run would measure overload.

## Measure

Run from the repository root:

```bash
examples/11-stackful-stackless/verify.sh
```

`ALLOW_BUSY=1` measures on a loaded host; `RECHECK=results/<run-id>` re-evaluates committed reports. A latency ratio is the median of three alternations inside one run.

Profile for every number below: bare-metal host, an 8-core, 16-thread Intel CPU (SMT on, `intel_pstate`), Fedora 44 kernel 7.2 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`, Temurin 25.0.5+8, GCC 16.2, Boost 1.92.0, Python 3.14.9 (GIL and free-threaded builds). Threads sit on distinct physical cores other than CPU 0, placed with `sched_setaffinity`: an experiment control, not isolation, which Chapter 15, *CPU partitioning and the noisy-neighbour problem*, covers. The lookup threads of the parked and line runs float. Ranges span the committed runs `r04-run1` to `r04-run3`; a ratio is the run's median over its three alternations.

### Ten thousand parked waits

10,000 tasks wait on one 1,000 ms timer. In the fiber and coroutine runs 10,000 had reached their wait when the memory was read (exact); in the other runs a latch opens only when every task has arrived.

| Per parked wait | Address space | RSS | RSS + page tables + kernel stack |
|---|---|---|---|
| C++ `os-thread` | 9,245,449 B | 8,774-8,778 B | 29,356-29,360 B |
| C++ `fiber` | 69,645 B | 4,106 B | 4,242-4,256 B |
| C++ `coroutine` | 26 B | 1,009 B | 1,010 B |
| Java `platform-thread` | 1,044,486-1,044,591 B | 22,805-22,898 B | 41,204-41,322 B |
| Java `virtual-thread` | 27,262-34,078 B | 2,870-3,260 B | 2,888-3,276 B |

The asserted ratios are on the quantity that separates the models. A thread's address space is 132.75x a fiber's (bound 10x), and a fiber's is 334.83x the counted coroutine frame of 208 B, one allocation per frame (exact). In Java, platform over virtual thread on the full resident cost is 12.61-14.28x (bound 5x, worst margin 2.52x). In Python on the GIL build, thread RSS over asyncio task bytes is 11.72-11.73x (bound 5x, margin 2.34x, tracemalloc, so not an exact byte count), and 148.43-148.44x free-threaded.

Resident memory alone doesn't show the orders of magnitude expected. C++ thread RSS over fiber RSS is 2.14x and fiber over coroutine 4.07x, against a planned 10x (observed). A parked thread touches a stack page or two: address space is what it reserves, RSS what it uses. What does differ by a large factor is the kernel's side: 29,356-29,360 B per thread against 4,242-4,256 B per fiber, about 6.9x.

### The hand-off

{% include excalidraw.html file="11-switch-path" alt="Three lanes, one round trip each. OS threads: thread A wakes thread B with a futex wake and the kernel schedules it (amber crossings), with 2.000 voluntary context switches per round trip in C++ and in Java; the round-trip p50 is 3,755-3,777 ns in C++, 4,011-4,029 ns in Python and 4,115-4,175 ns in Java. Fibers and virtual threads: a context swap in user space; the p50 is 205-207 ns for a C++ fiber and 399-404 ns for a Java virtual thread, with 0 voluntary switches in 1,020,000 round trips in C++ and 2-6 in Java. Coroutines: a resume without a thread switch; in C++ it is a symmetric transfer, with a p50 of 7-18 ns and 0 voluntary switches. A ghost row shows a Python asyncio task, which resumes through the event loop (an epoll_wait(0) per loop pass), with a p50 of 3,785-3,819 ns. The thread over fiber ratio is 18.25-18.33x in C++ and the platform thread over virtual thread ratio 10.28-10.48x in Java." caption="Figure 11.2: A switch that stays in user space skips the kernel wake and schedule. The C++ round-trip p50 is 3,755-3,777 ns between two OS threads, 205-207 ns between two fibers and 7-18 ns by symmetric transfer; Python asyncio, which goes through its event loop (an epoll_wait per loop pass), takes 3,785-3,819 ns; Java goes from 4,115-4,175 ns to 399-404 ns with virtual threads." %}

A C++ round trip took 3,755-3,777 ns between threads, 205-207 ns between fibers and 7-18 ns by symmetric transfer. Threads made 2 voluntary context switches per round trip (1.999 as `verify.log` prints it), fibers and coroutines 0 in 1,020,000 round trips (exact). The p50 ratio of thread over fiber is 18.25-18.33x (bound 5x, margin 3.65x). Thread over coroutine is 208.72-535.28x, asserted at 5x; a 7-18 ns p50 is near the clock's resolution, so that ratio moves between runs and the fiber ratio is the one to quote.

In Java the platform-thread round trip took 4,115-4,175 ns and the virtual-thread one 399-404 ns: 10.28-10.48x (bound 2x, margin 5.14x). The virtual threads made 2-6 voluntary switches in 1,020,000 round trips; the platform threads made 2 per round trip.

Python is observed only. Threads took 4,011-4,029 ns and asyncio tasks 3,785-3,819 ns on the GIL build, 4,055-4,083 and 4,119-4,159 ns free-threaded. An asyncio hand-off goes through the event loop and costs no less than a thread's here. The `std::binary_semaphore` variant made 164-266 voluntary switches in 1,020,000 round trips, because it spins first (observed).

### The blocking call

{% include excalidraw.html file="11-blocking-in-a-fiber" alt="Two lanes. In the C++ lane one carrier thread runs 1,000 fibers; one fiber makes a blocking call, std::this_thread::sleep_for for 2,000 us, 50 times in a run (amber), and the carrier is blocked, so the neighbour fibers wake late. The neighbours' wake lateness p99 is 52 us without the call and 1,917-1,952 us with it. In the ghost lane the Python asyncio twin (gil build, 50 tasks) calls time.sleep for 2 ms in one coroutine and the event loop stalls the same way: the p99 is 1,305-1,308 us without the call and 2,672-2,859 us with it." caption="Figure 11.3: A blocking call stops the carrier, not only the caller. The neighbour fibers' p99 wake lateness goes from 52 us to 1,917-1,952 us, close to the 2 ms sleep itself; the asyncio twin goes from 1,305-1,308 us to 2,672-2,859 us." %}

With one fiber blocking for 2 ms, the neighbours' wake-lateness p99 was 1,917-1,952 us, against 52 us without the call. The asserted statistic is the lowest of three alternations (1,902-1,937 us) against a 1 ms bound; with a 2 ms call that's under 2x by construction, with a margin of 1.90-1.94x, so verify.sh flags it. The blocked carrier delays every wake behind it for almost the full call. Threads, which the kernel schedules separately, had a p99 of 63 us, and the coroutines 4-5 us (observed).

The asyncio twin (50 tasks, GIL build) is observed, with an assertion that fits it. Without the call, the Python p99 is 1,305-1,308 us, because asyncio rounds its epoll timeout up to a whole millisecond (`selectors.EpollSelector.select` in CPython 3.14), so a p99 above 1 ms can't separate a blocked loop from a healthy one. With it the p99 is 2,672-2,859 us, 2.05-2.19x the baseline in the same run. The assertion is on the wakes later than 1.5 ms: 1,822-2,199 of 25,000 against 0, and asyncio's debug mode logged exactly 50 slow-callback warnings for 50 blocking calls (exact).

Java's virtual threads show what still pins. With JFR's `jdk.VirtualThreadPinned` at threshold 0, 100 virtual threads blocking 5 ms in a `synchronized` block produced 0 events (JEP 491), and 100 blocking under a native `qsort` frame produced 100 (observed).

### Python, both builds

Per parked thread, RSS is 19,228-19,247 B on the GIL build and 254,263-254,271 B free-threaded (observed; the cause isn't isolated here), against asyncio tasks at 2,611-2,614 B and 2,052 B. The measured process imports no `lowlat_measure`: that package's `pyhdrh` extension doesn't declare free-threading support, so importing it turns the GIL back on, and the run would measure a free-threaded build with a GIL. `tasks-py measure` writes raw samples and asserts the GIL stayed off from the imports to the end, which it did in every run. Appendix E, *Free-threaded Python vs the GIL*, treats the build in full.

### The line

A simulator at 10 kHz for 20 s sends 200,000 parcels. One lookup task per parcel waits 2 ms on a timer in this process, then decides the lane. The divert command goes out on its own socket. All five variants counted 200,000 parcels, dropped none and received every command. End-to-end p99 (observed) is 2.15-2.16 ms for C++ threads and fibers, 2.09 ms for coroutines, 2.91-3.06 ms for Java platform threads and 2.17 ms for virtual threads. Every variant sits at the 2 ms lookup plus scheduling noise, far inside 480 ms. The saving is memory and CPU per wait, not latency.

## Cross-check

The stack sizes account for the memory. A fiber's 65,536 B stack plus one 4,096 B guard page is 69,632 B, and the run measured 69,645 B. A thread's 8,192 KiB default stack, the `ulimit -s` the run recorded, is 8,388,608 of the 9,245,449 B it reserved. The coroutine's 208 B frame and the 10,000 allocations the promise's `operator new` counted agree with one frame per task. A coroutine that doesn't escape still reached `operator new` for 1,000 of 1,000 frames, so HALO (heap allocation elision) can't be assumed.

The `/proc` context-switch counts explain the round-trip histogram. A thread round trip is two sleeps and two wakes, 2 voluntary switches in about 3.8 us. The fiber and coroutine round trips never left user space, and their counters read 0.

## What you learned

- A wait costs a stack or a frame. In C++ the address space per wait falls from 9,245,449 B (thread) to 69,645 B (fiber) to 26 B (coroutine), while RSS falls 2.14x and then 4.07x.
- A switch that stays in user space skips the futex sleep and the kernel wake: 205-207 ns between fibers against 3,755-3,777 ns between threads.
- One blocking call in a cooperative scheduler stalls its neighbours for about the call's length: a fiber's p99 went from 52 us to 1,917-1,952 us.
- After JEP 491 a `synchronized` block no longer pins a virtual thread; a native frame still does.
- On the line all variants fit 480 ms, so the choice is memory and CPU per wait.

The next chapter, *I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core* (Part 4), asks how a thread learns that data has arrived.

## For deeper coverage

- Williams, *C++ Concurrency in Action* (Manning), and Grimm, *Concurrency with Modern C++* (Leanpub), for threads and coroutines in C++.
- Andrist and Sehr, *C++ High Performance* (Packt), for coroutines and allocation cost.
- Tanenbaum and Bos, *Modern Operating Systems* (Pearson), for thread stacks and context switches.
- Bobrov, *Grokking Concurrency* (Manning), for the thread and task models in a language-agnostic form.
- Evans and Gough, *Optimizing Cloud Native Java* (O'Reilly), for the JVM side.
- Ghosh, *Building Low Latency Applications with C++* (Packt), and Enberg, *Latency* (Manning), as further reading.
- Companion sites cpp-concurrency-and-parallelism, [Chapter 11, *Coroutines in Depth*](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/docs/11-coroutines-in-depth/), [Chapter 12, *Async Runtimes and Event Loops*](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/docs/12-async-runtimes-and-event-loops/) and [Chapter 13, *Fibers and Stackful Coroutines*](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/docs/13-fibers-and-stackful-coroutines/), and linux-systems-programming, [*Event loops: epoll and inotify*](https://patterncatalyst.github.io/linux-systems-programming/docs/09-event-loops-epoll-inotify/).
- [Chapter 10, *Lock-free and wait-free synchronization*]({{ '/docs/10-lockfree-waitfree/' | relative_url }}), for the MPSC hand-off and memory orders; Chapter 12, *I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core* (Part 4).
- Appendix E, *Free-threaded Python vs the GIL*.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts the address-space and resident-cost ratios, the counted coroutine frame, 10,000 tasks armed, voluntary switches per round trip, the round-trip p50 ratios (5x in C++, 2x in Java), the fiber's blocking-call lateness (1 ms, under 2x margin by construction), asyncio's late-wake fraction and slow-callback warnings, the line counts and the report contents. Observed only: RSS ratios, the Python hand-off and baseline tails, the semaphore hand-off, the pinning counts, HALO and the line percentiles. It held on `r04-run1` to `r04-run3`, bare-metal and untuned.*
