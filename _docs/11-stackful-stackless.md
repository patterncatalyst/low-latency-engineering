---
title: "Stackful vs stackless: threads and fibers vs event loops and coroutines"
order: 11
part: "Threading & I/O Models"
description: "A parked wait costs a C++ thread 9,245,449 B of address space and a fiber 69,645 B, while a coroutine needs only its counted 208 B frame; a round trip is 18.25-18.33x faster between fibers than between threads, and one 2 ms blocking call lifts the neighbours' p99 wake lateness from 52 us to 1,917-1,952 us, on a bare-metal, untuned host."
duration: 55 minutes
---

## Learning objectives

By the end of this chapter you can:

- Say what a thread, a fiber, a virtual thread and a coroutine each keep while a lookup waits, and read the cost from the bytes per wait.
- Explain a hand-off as a futex sleep and wake, a user-space swap or a resume, and read it from voluntary context switches.
- Predict what one blocking call does to the tasks that share its thread, and why a fiber and an asyncio task fail the same way.
- Name what still pins a Java virtual thread after JEP 491.

## Why this matters

Every scan on the sortation line triggers a sort-plan lookup at the warehouse management system (WMS), and the answer takes about 2 ms. At 10 kHz that's 20 lookups in flight (Little's law, [Chapter 2, *Modelling with Little's Law and Amdahl's Law*]({{ '/docs/02-littles-amdahl/' | relative_url }})). At a hub taking 100,000 scans a second from a WMS that answers in 20 ms, it's 2,000. Something has to hold each of those waits.

A parcel has 480 ms from scan to divert (1.2 m at 2.5 m/s), so the lookup fits many times over. What matters is memory per wait, the cost of each hand-off, and what a blocking call does to its neighbours.

[Chapter 10, *Lock-free and wait-free synchronization*]({{ '/docs/10-lockfree-waitfree/' | relative_url }}), coordinated the threads; this chapter asks what they are. [Chapter 12, *I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core*]({{ '/docs/12-io-engines/' | relative_url }}), covers the engine under an event loop.

The code is in `examples/11-stackful-stackless/`; its `README.md` covers how to drive it.

## Diagram

{% include excalidraw.html file="11-who-holds-the-wait" alt="Three lanes, each for 10,000 tasks parked on one 1,000 ms timer. OS threads: each wait owns a kernel stack, 16,380-16,384 B in C++, and a reserved user stack, 8,192 KiB in C++; per wait the RSS and address space are 8,774-8,778 B and 9,245,449 B in C++, 19,228-19,247 B and 9,266,672-9,266,776 B in Python, and 22,805-22,898 B and 1,044,486-1,044,591 B in Java. Fibers and virtual threads: a small stack in user space, 65,536 B reserved per C++ fiber and 2,063-2,105 B of heap per Java virtual thread; the RSS and address space per wait are 4,106 B and 69,645 B in C++, and the RSS is 2,870-3,260 B in Java, whose address space grew in steps of about 64 MiB (likely the carriers' malloc arenas), so it is not a per-task cost. Coroutines (amber): no stack, only a heap frame, 208 B in C++ and 1,641 B in Python (tracemalloc); the RSS per wait is 1,009 B in C++ (address space barely grew, since frames land in heap already mapped) and the RSS and address space are 2,611-2,614 B and 2,569 B in Python." caption="Figure 11.1: What a parked wait owns. The user-space RSS per wait falls from 8,774-8,778 B for a C++ OS thread to 4,106 B for a fiber and 1,009 B for a coroutine, while the reserved address space falls from 9,245,449 B for a thread to 69,645 B for a fiber; a coroutine needs only its counted 208 B frame." %}

## Concept

### Who holds the wait

One lookup waits on the WMS. An OS thread holds it with a stack: 8,192 KiB of address space reserved by default in C++ and Python (about 1 MiB in Java), a 16 KiB kernel stack and a thread control block. A fiber (Boost.Fiber) or a virtual thread holds it with a stack the library allocates in user space: 64 KiB in the C++ example, about 2 KB of heap in the JDK. Both are stackful: the task can suspend from any call depth, because its call stack goes with it.

A C++20 coroutine or an asyncio task is stackless. It keeps one heap frame holding the variables that live across its suspension points, and it suspends only at a `co_await` or `await` in its own body. `parked_waiter` returns `asio::awaitable<void>` because it contains a `co_await`, and plain code can start it only through `co_spawn`; `waiter` is `async def` for the same reason. That's the function colour: the stackful task pays in stack bytes, the stackless one in signatures.

A fiber scheduler and an event loop are both cooperative: they run one task until it suspends. A call that blocks the thread instead takes every other task on it along. Nothing in the type system warns you: `std::this_thread::sleep_for` in a fiber and `time.sleep` in a coroutine look like any other call.

A virtual thread parks instead of blocking and frees its carrier thread. JEP 491 (JDK 24) removed the pin on blocking inside `synchronized`; blocking under a native frame or in a class initializer still pins the carrier.

Python has no standard-library stackful coroutine (greenlet is third-party) and Java has no stackless one, so those lanes are absent.

### The hand-off

A finished lookup hands its result to the next stage; the ping-pong reduces that to two tasks passing a turn. Between OS threads that's a futex sleep and a kernel wake, between fibers a user-space stack swap, between C++ coroutines a symmetric transfer that the compiler turns into a tail call.

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

The thread's wait (#A) is one stack and one kernel thread; the coroutine's (#B) is one heap frame, and Python's asyncio task is its twin.

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

The 208 B frame comes from the `Task<T>` probe, which parks its frames in a vector so none can be elided; `PromiseBase::operator new` counts each one. The 1,009 B RSS below belongs to the Asio `parked_waiter`, a different coroutine.

```cpp
  static void* operator new(std::size_t n) {
    g_frames.allocations.fetch_add(1, std::memory_order_relaxed);
    g_frames.bytes.fetch_add(n, std::memory_order_relaxed);
    g_frames.last_bytes.store(n, std::memory_order_relaxed);
    return ::operator new(n);
  }
```

Java's two variants differ only in `Thread.ofPlatform()` against `Thread.ofVirtual()`.

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

In #A, `wait` goes straight to a futex and `notify_one` wakes it, so every hand-off is a sleep and a wake. In #B, `await_suspend` stores the suspended handle in `self` and returns `peer`; the compiler resumes the peer without a scheduler or a system call. Java passes the turn through two `SynchronousQueue`s and Python through `queue.SimpleQueue` or an `asyncio.Future`; C++ shows each mechanism bare.

`std::binary_semaphore` isn't the thread hand-off: libstdc++ spins before it waits, so two hot threads can finish a round trip without entering the kernel.

### The blocking call

One task in 1,000 makes a 2 ms blocking call every tenth iteration. #A, `boost::this_fiber::sleep_until`, suspends only this fiber; #B, the defect, `std::this_thread::sleep_for`, blocks the thread, and `time.sleep` does the same in the asyncio twin.

{% include codetabs.html langs="C++|Python" %}

```cpp
          boost::this_fiber::sleep_until(at(d));
          lateness[i * plan.iterations + k] = positive(now_ns() - d);
          // The defect: a blocking call inside a fiber blocks the whole OS thread, so every fiber on it waits.
          if (blocks_now(p, i, k)) std::this_thread::sleep_for(p.block);
```

```python
            await asyncio.sleep(max((d - time.monotonic_ns()) / NS, 0.0))
            lateness[i * iterations + k] = _positive(time.monotonic_ns() - d)
            # The defect: time.sleep in a coroutine blocks the event loop, so every task waits.
            if blocking and i == 0 and k % 10 == 9:
                time.sleep(block_ns / NS)
```

The Python twin runs 50 tasks, not 1,000: an asyncio loop can't wake 1,000 tasks every 2 ms (500,000 a second) on this host, so the run would measure overload.

## Measure

Run from the repository root:

```bash
examples/11-stackful-stackless/verify.sh
```

Profile for every number below: bare-metal host, an 8-core, 16-thread Intel CPU (SMT on, `intel_pstate`), Fedora 44 kernel 7.2 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`, Temurin 25.0.5+8, Clang 22.1.8 with GCC 16.2's libstdc++, Boost 1.92.0, Python 3.14.9 (GIL and free-threaded builds). Threads sit on distinct physical cores other than CPU 0, placed with `sched_setaffinity`: an experiment control, not isolation, which Chapter 15, *CPU partitioning and the noisy-neighbour problem*, covers. The parked and line runs' lookup threads float. Ranges span the committed runs `r04-run1` to `r04-run3`.

### Ten thousand parked waits

10,000 lookups wait on the WMS, each on one 1,000 ms timer. Memory is the `/proc/self/status` delta (RSS, address space, page tables) plus the system-wide `KernelStack` in `/proc/meminfo`, read 500 ms into the wait. In the fiber and coroutine runs all 10,000 had reached their wait (exact); elsewhere a latch guarantees it.

| Per parked wait | Address space | RSS | RSS + page tables + kernel stack |
|---|---|---|---|
| C++ `os-thread` | 9,245,449 B | 8,774-8,778 B | 29,356-29,360 B |
| C++ `fiber` | 69,645 B | 4,106 B | 4,242-4,256 B |
| C++ `coroutine` | 26 B (not per task) | 1,009 B | 1,010 B |
| Java `platform-thread` | 1,044,486-1,044,591 B | 22,805-22,898 B | 41,204-41,322 B |
| Java `virtual-thread` | 27,262-34,078 B (not per task) | 2,870-3,260 B | 2,888-3,276 B |

Java's virtual-thread address space grows in steps of about 64 MiB, likely the carriers' malloc arenas, and is 0 at small task counts, so that cell isn't a per-task cost. Nor is the coroutine's 26 B: its frames land in already-mapped heap.

The asserted ratios are on the quantity that separates the models. A thread's address space is 132.75x a fiber's (bound 10x), and a fiber's is 334.83x the counted coroutine frame of 208 B, one allocation per frame (exact). In Java, platform over virtual thread on the full resident cost is 12.61-14.28x (bound 5x, worst margin 2.52x). In Python on the GIL build, thread RSS over asyncio task bytes is 11.72-11.73x (bound 5x, margin 2.34x, tracemalloc, so not an exact byte count), and 148.43-148.44x free-threaded.

RSS alone doesn't show orders of magnitude: C++ thread over fiber is 2.14x and fiber over coroutine 4.07x, against a planned 10x (observed). A parked thread touches a stack page or two; address space is what it reserves. What does differ by a large factor is what the kernel holds: page tables and kernel stack come to 20,582-20,585 B per thread against 136-150 B per fiber, 137-151x.

### The hand-off

{% include excalidraw.html file="11-switch-path" alt="Three lanes, one round trip each. OS threads: thread A wakes thread B with a futex wake and the kernel schedules it (amber crossings), with 2.000 voluntary context switches per round trip in C++ and in Java; the round-trip p50 is 3,755-3,777 ns in C++, 4,011-4,029 ns in Python and 4,115-4,175 ns in Java. Fibers and virtual threads: a context swap in user space; the p50 is 205-207 ns for a C++ fiber and 399-404 ns for a Java virtual thread, with 0 voluntary switches in 1,020,000 round trips in C++ and 1-6 in Java (every alternation; both virtual threads on one carrier). Coroutines: a resume without a thread switch; in C++ it is a symmetric transfer, with a p50 of 7-18 ns and 0 voluntary switches. A ghost row shows a Python asyncio task, which resumes through the event loop (an epoll_wait(0) per loop pass), with a p50 of 3,785-3,819 ns. The thread over fiber ratio is 18.25-18.33x in C++ and the platform thread over virtual thread ratio 10.28-10.48x in Java." caption="Figure 11.2: A switch that stays in user space skips the kernel wake and schedule. The C++ round-trip p50 is 3,755-3,777 ns between two OS threads, 205-207 ns between two fibers and 7-18 ns by symmetric transfer; Python asyncio, which goes through its event loop (an epoll_wait per loop pass), takes 3,785-3,819 ns; Java goes from 4,115-4,175 ns to 399-404 ns with virtual threads." %}

Each sample is a batch of 1,000 round trips divided by 1,000. A C++ round trip took 3,755-3,777 ns between threads, 205-207 ns between fibers and 7-18 ns by symmetric transfer. Threads made 2 voluntary context switches per round trip, fibers and coroutines 0 in 1,020,000 round trips (exact). Thread over fiber at p50 is 18.25-18.33x (bound 5x, margin 3.65x). Thread over coroutine is 208.72-535.28x, asserted at 5x. The coroutine's p50 moves between 4 and 22 ns across alternations (cause not isolated), so the fiber ratio is the one to quote.

In Java the platform-thread round trip took 4,115-4,175 ns and the virtual-thread one 399-404 ns: 10.28-10.48x (bound 2x, margin 5.14x). Both virtual threads ran on one carrier and made 1-6 voluntary switches in 1,020,000 round trips (every alternation); the platform threads made 2 per round trip.

Python is observed only: threads took 4,011-4,029 ns and asyncio tasks 3,785-3,819 ns on the GIL build, 4,055-4,083 and 4,119-4,159 ns free-threaded. An asyncio hand-off goes through the event loop and costs about what a thread's does here: 5-6 % less on the GIL build, 1-2 % more free-threaded. `std::binary_semaphore` made 164-266 voluntary switches in 1,020,000 round trips, since it spins first (observed).

### The blocking call

{% include excalidraw.html file="11-blocking-in-a-fiber" alt="Two lanes. In the C++ lane one carrier thread runs 1,000 fibers; one fiber makes a blocking call, std::this_thread::sleep_for for 2,000 us, 50 times in a run (amber), and the carrier is blocked, so the neighbour fibers wake late. The neighbours' wake lateness p99 is 52 us without the call and 1,917-1,952 us with it. In the ghost lane the Python asyncio twin (gil build, 50 tasks) calls time.sleep for 2 ms in one coroutine and the event loop stalls the same way: the p99 is 1,305-1,308 us without the call and 2,672-2,859 us with it." caption="Figure 11.3: A blocking call stops the carrier, not only the caller. The neighbour fibers' p99 wake lateness goes from 52 us to 1,917-1,952 us, close to the 2 ms sleep itself; the asyncio twin goes from 1,305-1,308 us to 2,672-2,859 us." %}

With one fiber blocking for 2 ms, the neighbours' wake-lateness p99 was 1,917-1,952 us, against 52 us without the call. The asserted statistic is the lowest of three alternations (1,902-1,937 us) against a 1 ms bound, a 1.90-1.94x margin that is under 2x by construction for a 2 ms call. Threads, which the kernel schedules separately, had a p99 of 63 us, and the coroutines 4-5 us (observed).

The asyncio twin (50 tasks, GIL build) is observed, with an assertion that fits it. Its p99 is 1,305-1,308 us without the call, because asyncio rounds its epoll timeout up to a whole millisecond (`selectors.EpollSelector.select`, CPython 3.14), so a p99 above 1 ms can't separate a blocked loop from a healthy one. With it the p99 is 2,672-2,859 us, 2.05-2.19x the baseline in the same run. The assertion is on the wakes later than 1.5 ms: 1,822-2,199 of 25,000 against 0, and asyncio's debug mode logged exactly 50 slow-callback warnings for 50 blocking calls (exact).

Java's virtual threads show what still pins. JFR's `jdk.VirtualThreadPinned` (threshold 0) counted 0 events for 100 virtual threads blocking 5 ms in `synchronized` (JEP 491) and 100 for those blocking under a native `qsort` frame (observed).

### Python, both builds

A parked thread's RSS is 19,228-19,247 B on the GIL build and 254,263-254,271 B free-threaded (observed, cause not isolated), against 2,611-2,614 B and 2,052 B for an asyncio task. The measured process imports no `lowlat_measure`: its `pyhdrh` extension doesn't declare free-threading support, so importing it would turn the GIL back on. `tasks-py measure` asserts the GIL stayed off from the imports to the end, which it did in every run. Appendix E, *Free-threaded Python vs the GIL*, treats the build in full.

### The line

A simulator at 10 kHz for 20 s sends 200,000 parcels. One lookup task per parcel waits 2 ms on a timer in this process, then decides the lane. The divert command goes out on its own socket. All five variants counted 200,000 parcels, dropped none and received every command. End-to-end p99 (observed) is 2.15-2.16 ms for C++ threads and fibers, 2.09 ms for coroutines, 2.91-3.06 ms for Java platform threads and 2.17 ms for virtual threads. Every variant sits at the 2 ms lookup plus scheduling noise, far inside 480 ms. The saving is memory per wait and the cost of each hand-off, not latency.

## Cross-check

The stack sizes account for the memory. A fiber's 65,536 B stack plus one 4,096 B guard page is 69,632 B; the run measured 69,645 B. A thread's default stack is 8,192 KiB, glibc's default from `ulimit -s`, and it's 8,388,608 of the 9,245,449 B it reserved (the notes print that default; the run doesn't read the limit). The 10,000 allocations `operator new` counted agree with one frame per task. Under Clang, 1,000 of 1,000 non-escaping coroutines still reached `operator new`, while the ping-pong's two frames made 0 allocations in all nine alternations. HALO (heap allocation elision) happens where the compiler can prove the lifetime, so neither outcome can be assumed.

The `/proc` switch counts explain the histogram: a thread round trip is 2 voluntary switches in about 3.8 us, and fiber and coroutine round trips never left user space.

## What you learned

- A wait costs a stack or a frame. In C++ the address space per wait falls from 9,245,449 B (thread) to 69,645 B (fiber), and a coroutine needs only its 208 B frame (its heap was already mapped, so address space grew 26 B per task), while RSS falls 2.14x and then 4.07x.
- A switch that stays in user space skips the futex and the kernel wake: 205-207 ns between fibers against 3,755-3,777 ns between threads.
- One blocking call in a cooperative scheduler stalls its neighbours for about the call's length: a fiber's p99 went from 52 us to 1,917-1,952 us.
- After JEP 491 a `synchronized` block no longer pins a virtual thread; a native frame still does.
- On the line all variants fit 480 ms, so the choice is memory per wait and the cost of each hand-off.

The next chapter, *I/O engines* (Part 4), asks how a thread learns that data has arrived.

## For deeper coverage

- Williams, *C++ Concurrency in Action* (Manning), and Grimm, *Concurrency with Modern C++* (Leanpub), for threads and coroutines.
- Andrist and Sehr, *C++ High Performance* (Packt), for coroutines.
- Tanenbaum and Bos, *Modern Operating Systems* (Pearson), for thread stacks and context switches.
- Bobrov, *Grokking Concurrency* (Manning), for the models in a language-agnostic form.
- Evans and Gough, *Optimizing Cloud Native Java* (O'Reilly), for the JVM side.
- Ghosh, *Building Low Latency Applications with C++* (Packt), and Enberg, *Latency* (Manning).
- Companion sites cpp-concurrency-and-parallelism, [Chapter 11, *Coroutines in Depth*](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/docs/11-coroutines-in-depth/), [Chapter 12, *Async Runtimes and Event Loops*](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/docs/12-async-runtimes-and-event-loops/) and [Chapter 13, *Fibers and Stackful Coroutines*](https://patterncatalyst.github.io/cpp-concurrency-and-parallelism/docs/13-fibers-and-stackful-coroutines/), and linux-systems-programming, [*Event loops: epoll and inotify*](https://patterncatalyst.github.io/linux-systems-programming/docs/09-event-loops-epoll-inotify/).
- [Chapter 10, *Lock-free and wait-free synchronization*]({{ '/docs/10-lockfree-waitfree/' | relative_url }}), for the MPSC hand-off and memory orders.
- Appendix E, *Free-threaded Python vs the GIL*.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts the address-space and resident-cost ratios, the counted coroutine frame, 10,000 tasks armed, C++ voluntary switches per round trip, the round-trip p50 ratios (5x in C++, 2x in Java), the fiber's blocking-call lateness (1 ms, under 2x margin by construction), asyncio's late-wake fraction and slow-callback warnings, the line counts and the report contents. Observed only: RSS ratios, Java switches, the kernel-share ratio, the thread and coroutine neighbour p99s, the Python hand-off and its 2.05-2.19x tail ratio, the semaphore hand-off, the pinning counts, HALO and the line percentiles. It held on `r04-run1` to `r04-run3`, bare-metal and untuned, at commit 4434ed1.*
