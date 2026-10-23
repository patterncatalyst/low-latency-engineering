---
title: "Lock-free and wait-free synchronization"
order: 10
part: "Accelerating Code"
description: "At p99 a mutex claim costs 6.10-6.45x a fetch-add claim in C++ and 14.13-15.23x in Java, and a seqlock lowers the writer's p99 by 205.5-231.0x and 34.5-37.1x, on a bare-metal, untuned host; under release/acquire two stations both read the other's flag as 0 in 2.3-9.9 million of 10 million C++ trials."
duration: 55 minutes
---

## Learning objectives

By the end of this chapter you can:

- Say which operation a progress guarantee describes, and why a wait-free claim doesn't stop a consumer from waiting.
- Claim a slot with a mutex, a CAS loop and `fetch_add`, and read the cost from retries and voluntary context switches.
- Predict the induction-gap outcome under release/acquire and `seq_cst`, and map the orders to `VarHandle` modes.
- Write a seqlock over `std::atomic_ref` in C++ and use `StampedLock.tryOptimisticRead` in Java.

## Why this matters

Four of the tunnel's cameras each read every parcel, and every read lands in one tracker log. Each camera thread takes the next slot number, writes its scan there and publishes it. If the thread holding the lock is descheduled, three cameras wait while the belt keeps moving. A parcel has 480 ms from scan to divert (1.2 m at 2.5 m/s), and a stall charges every parcel behind it (Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*).

Two more places wait. Two induction stations feed one gap on the belt, and exactly one of them may take it. And the diverter reads a parcel's state while the tracker rewrites it 1,000,000 times a second.

[Chapter 7, *Off-heap and lock-free Java: Chronicle, Agrona, the Disruptor, thread affinity*]({{ '/docs/07-offheap-lockfree/' | relative_url }}), built single-producer rings, and [Chapter 9, *Eliminating work: allocation, cache locality, false sharing*]({{ '/docs/09-eliminating-work/' | relative_url }}), priced a shared cache line. This chapter takes the waiting out of many-writer coordination.

The code is in `examples/10-lockfree-waitfree/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="10-progress-guarantees" alt="Three bands, one per progress guarantee, each with the claim variant, its mechanism and its measurements across four producers claiming 1,000,000 slots each. Blocking: mutex, where a loser parks on a futex; claim p99 of 2,633-2,985 ns in C++ and 8,187-8,383 ns in Java, and 5,406-9,746 (C++) and 47,556-61,712 (Java) voluntary context switches for the least-switching producer. Lock-free: cas-loop, a compare-and-swap retry loop; claim p99 of 478-502 ns in C++ and 1,409-1,837 ns in Java, and a largest retry count in one claim of 7-10 and 27-55. Wait-free claim step (amber): fetch-add, one lock xadd and exactly 1 step per claim; claim p99 of 400-468 ns in C++ and 516-584 ns in Java, and at most 1 (C++) and 1-3 (Java) voluntary switches for the most-switching producer." caption="Figure 10.1: Wait-free bounds the steps of a claim, not the time it takes. At p99 the mutex claim is 6.10-6.45x the fetch-add claim in C++ and 14.13-15.23x in Java, and the CAS loop sits between them." %}

## Concept

### A guarantee belongs to an operation

Take the camera threads claiming slots. With a `mutex` around the counter, a thread that finds it locked parks on a futex until the kernel wakes it. That's blocking: one descheduled holder stops everyone. With a compare-and-swap (CAS) loop, a camera reads the counter, tries to swap in `seen + 1`, and retries if another camera got there first. That's lock-free: some camera always completes, but one can lose again and again, and nothing bounds its retries. With `fetch_add`, the claim is a single `lock xadd` on x86-64. Every camera finishes in one step, which is wait-free.

Platform matters: on a load-linked/store-conditional machine (AArch64 without the ARMv8.1 LSE atomics, for example) `fetch_add` compiles to a retry loop, and "wait-free" stops being true of the same source line. And wait-free bounds steps, not time: a step can wait for a cache line another core owns. It covers the claim only. Claiming a slot and publishing it are two steps, and the consumer reads in order.

If the camera that claimed slot 42 sleeps before it publishes, slots 43 and 44 can be full and the tracker still waits at 42 (Figure 10.4, in Measure, draws it). The operation with the guarantee is the claim; the log's read blocks at a stalled producer.

A monotonic 64-bit sequence sidesteps two classic traps. A number is never reused, so a CAS can't succeed against a value that went away and came back (ABA), and nothing is freed. A structure that recycles nodes needs hazard pointers or epochs in C++; C++26 specifies `<hazard_pointer>` and `<rcu>`, but libstdc++ (GCC 16.2, also used by Clang 22.1 here) doesn't ship them. In Java the collector frees a node only when no thread can reach it, which is that work done for you. In Python, reference counting frees objects and the interpreter keeps the counts consistent.

### Memory order: two stations, one gap

Each induction station stores its own flag, then loads the other's. If both read 0, both induct into the one gap.

{% include excalidraw.html file="10-store-buffer" alt="Two induction stations, each with its own store buffer, one gap. Station A stores flagA and loads flagB; station B stores flagB and loads flagA. Each store (amber arrow) goes into the station's store buffer, where flag = 1 is pending, and drains later (dashed) to shared memory, which still holds flagA = 0 and flagB = 0. Each load reads shared memory and sees 0. Under release/acquire both stations read 0 in 2,306,475-9,888,040 of 10,000,000 trials in C++ and in 85.0-98.6 million jcstress samples in Java. Under seq_cst, and Java volatile, both-zero occurs 0 times in 10,000,000 C++ trials and in 0 Java samples." caption="Figure 10.2: Release/acquire lets both stations read the other's flag as 0 while their own store sits in the buffer; seq_cst and volatile forbid it, and the measured count is 0." %}

A store doesn't reach shared memory at once. It waits in its core's store buffer while the same core's next load runs ahead, so each station can read the other's flag before the other's store drains. Release/acquire doesn't forbid that: it orders in one direction, and a store followed by a load is the case it leaves open. On x86-64 both compile to a plain `mov`. `seq_cst` puts all four operations in one total order that respects each station's program order; whichever load comes last follows both stores and reads 1. A `seq_cst` store compiles to `xchg`, which drains the buffer first.

Java names the same orders. `VarHandle.setRelease` and `getAcquire` map to release and acquire; a `volatile` field and `setVolatile` are sequentially consistent, and `getOpaque`/`setOpaque` are close to relaxed. jcstress, OpenJDK's concurrency stress harness, runs the pair as a test.

Python has no memory-order or seqlock lane: CPython 3.14 has no public atomics API, so there's no ordering to choose.

### The read side: a seqlock

The diverter reads a parcel's state, eight 64-bit words, the last a checksum of the other seven, while the tracker rewrites it. A shared mutex makes the write wait for the readers.

{% include excalidraw.html file="10-seqlock" alt="Two lanes. In the seqlock lane (amber) the writer bumps the sequence to odd, writes the fields, a snapshot with a checksum, and bumps the sequence to even; the writer p99 is 25-32 ns in C++ and 206-234 ns in Java with StampedLock, with 0 torn snapshots. Readers read the sequence s1, copy the data, read the sequence s2, and retry (dashed) if s1 is odd or s1 differs from s2. In the shared-mutex lane the writer takes an exclusive lock, which waits for three readers holding the shared lock, writes the fields and unlocks; the writer p99 is 5,979-6,603 ns in C++ and 8,083-8,287 ns in Java with a ReentrantReadWriteLock." caption="Figure 10.3: Readers retry instead of blocking the writer. The writer p99 is 205.5-231.0x lower with a seqlock in C++ and 34.5-37.1x lower with StampedLock in Java, and no reader sees a torn snapshot." %}

A seqlock inverts that. The writer bumps a sequence number to odd, stores the words, and bumps it to even. A reader reads the sequence, copies the words, reads the sequence again, and keeps the copy only if the first value was even and matches the second. The writer never looks at the readers.

In C++ a seqlock over plain fields is a data race, which is undefined behaviour even when the reader throws the copy away. So the words go through `std::atomic_ref<std::uint64_t>` with relaxed order, ordinary `mov`s on x86-64, and a pair of fences supplies the ordering. Java's idiom is `StampedLock.tryOptimisticRead`, the JDK's own seqlock: `validate` rejects the racy copy.

## How the code works

### The claim

`claim.hpp` holds the three C++ claims behind one `SequenceClaim` concept. `ClaimStats` counts steps, CAS failures and the largest retry count of one claim, one instance per producer so counting costs no shared write. `SequenceClaim.java` has the same three as a sealed interface. Python's `claims.py` has a lock and `next()` on a shared `itertools.count`.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
class CasLoopClaim {
 public:
  std::uint64_t claim(ClaimStats& stats) noexcept {
    ++stats.claims;
    std::uint64_t seen = next_.load(std::memory_order_relaxed);
    std::uint64_t retries = 0;
    for (;;) {
      ++stats.steps;
      // On failure compare_exchange_weak reloads `seen`, so the loop body needs no second load.
      if (next_.compare_exchange_weak(seen, seen + 1, std::memory_order_relaxed)) break;
      ++stats.cas_failures;
      ++retries;
    }
    stats.max_retries = std::max(stats.max_retries, retries);
    return seen;
  }

 private:
  std::atomic<std::uint64_t> next_{0};
};

// ...

class FetchAddClaim {
 public:
  std::uint64_t claim(ClaimStats& stats) noexcept {
    ++stats.claims;
    ++stats.steps;
    return next_.fetch_add(1, std::memory_order_relaxed);
  }

 private:
  std::atomic<std::uint64_t> next_{0};
};
```

```python
class LockClaim:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._next = 0

    def claim(self) -> int:
        with self._lock:
            seq = self._next
            self._next += 1
            return seq


# ...


class CountClaim:
    def __init__(self) -> None:
        self._count = itertools.count()

    def claim(self) -> int:
        return next(self._count)
```

```java
    /** Lock-free: {@link AtomicLong#compareAndSet} in a loop. */
    final class CasLoop implements SequenceClaim {
        private final AtomicLong next = new AtomicLong();

        @Override
        public long claim(ClaimStats stats) {
            stats.claims++;
            long retries = 0;
            long seen;
            do {
                seen = next.get();
                stats.steps++;
                if (next.compareAndSet(seen, seen + 1)) {
                    break;
                }
                stats.casFailures++;
                retries++;
            } while (true);
            stats.maxRetries = Math.max(stats.maxRetries, retries);
            return seen;
        }
    }

    // ...

    /** Wait-free on x86-64: {@link AtomicLong#getAndIncrement}. */
    final class FetchAdd implements SequenceClaim {
        private final AtomicLong next = new AtomicLong();

        @Override
        public long claim(ClaimStats stats) {
            stats.claims++;
            stats.steps++;
            return next.getAndIncrement();
        }
    }
```

The claim uses relaxed order: it hands out a unique number and publishes nothing. Visibility is the log's job (`claim_log.hpp`): a producer waits for room if the ring is full, writes the payload into slot `seq & mask`, then release-stores `seq + 1` into the slot's stamp, and the consumer's acquire load of the stamp makes the payload visible. The consumer spins at the first slot not yet published; Figure 10.4's wait is measured there.

The two Python classes differ in what the documentation promises. `threading.Lock` gives exactly-once. `next()` on a shared `itertools.count` isn't documented as thread-safe, and the free-threading howto warns of duplicate or missing elements, so the lane reports what it saw and asserts nothing.

### The induction-gap test

`litmus.hpp` templates the station on its store and load orders, so release/acquire and `seq_cst` are the same code with different template arguments. Two threads on distinct cores meet at a spin barrier each trial, and each result goes into the station's own array, read after `join()`, so the harness has no race of its own.

{% include codetabs.html langs="C++|Java" %}

```cpp
      mine.value.store(1, StoreOrder);
      result[i] = static_cast<std::uint8_t>(theirs.value.load(LoadOrder));
```

```java
    @Actor
    public void stationA(II_Result r) {
        A.setRelease(this, 1);
        r.r1 = (int) B.getAcquire(this);
    }

    @Actor
    public void stationB(II_Result r) {
        B.setRelease(this, 1);
        r.r2 = (int) A.getAcquire(this);
    }
```

The Java excerpt is `StoreBufferAcquireRelease`, which marks `0, 0` `ACCEPTABLE_INTERESTING`. Its sibling `StoreBufferVolatile` uses `volatile` fields and marks it `FORBIDDEN`.

### The seqlock against the shared mutex

First cut (#A), `SharedMutexCell::write`, then the seqlock (#B), `Seqlock::write` and `try_read`:

```cpp
  void write(const ParcelSnapshot& s) {
    const std::unique_lock lock{mutex_};
    value_ = s;
  }
```

```cpp
  void write(const ParcelSnapshot& s) noexcept {
    const std::uint64_t seq = sequence_.load(std::memory_order_relaxed);
    sequence_.store(seq + 1, std::memory_order_relaxed);  // odd: a write is in progress
    std::atomic_thread_fence(std::memory_order_release);  // the odd value is visible before any field store
    for (std::size_t i = 0; i < ParcelSnapshot::kWords; ++i) {
      std::atomic_ref<std::uint64_t>{words_[i]}.store(s.word[i], std::memory_order_relaxed);
    }
    sequence_.store(seq + 2, std::memory_order_release);  // even: the fields are visible before this
  }

  // ...

  [[nodiscard]] bool try_read(ParcelSnapshot& out) const noexcept {
    const std::uint64_t before = sequence_.load(std::memory_order_acquire);
    if (before & 1U) return false;
    for (std::size_t i = 0; i < ParcelSnapshot::kWords; ++i) {
      out.word[i] = std::atomic_ref<std::uint64_t>{words_[i]}.load(std::memory_order_relaxed);
    }
    std::atomic_thread_fence(std::memory_order_acquire);  // the field loads happen before the re-check
    return sequence_.load(std::memory_order_relaxed) == before;
  }
```

In #A the exclusive lock waits for every reader holding the shared lock. In #B the writer takes no lock: the release fence makes the odd sequence visible before any word changes, and the final release store makes the words visible before the even sequence. The reader's acquire fence keeps its loads ahead of the re-check. A copy mixing two updates fails `consistent()`, because the last word is a checksum of the others.

Java's reader is the same loop with the JDK's bookkeeping:

```java
        @Override
        public int read(long[] out) {
            int failed = 0;
            while (true) {
                long stamp = lock.tryOptimisticRead();
                if (stamp != 0) {
                    System.arraycopy(words, 0, out, 0, WORDS);
                    if (lock.validate(stamp)) {
                        return failed;
                    }
                }
                failed++;
                // ...
                Thread.onSpinWait();
            }
        }
```

## Measure

Run from the repository root:

```bash
examples/10-lockfree-waitfree/verify.sh
```

`ALLOW_BUSY=1` measures on a loaded host; `RECHECK=results/<run-id>` re-evaluates committed reports. A latency ratio is the median of three alternations inside one run.

Profile for every number below: bare-metal host, an 8-core, 16-thread Intel laptop CPU (SMT on, `intel_pstate`), Fedora 44 kernel 7.2 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`, Temurin 25.0.5+8, GCC 16.2, Python 3.14.8. Threads sit on distinct physical cores other than CPU 0 (jcstress picks its own CPUs), placed with `sched_setaffinity`: an experiment control, not isolation, which Chapter 15, *CPU partitioning and the noisy-neighbour problem*, covers. Ranges span the committed runs `r03-run1` to `r03-run3`; a p99 in ns is the first of three alternations.

### Claims

Four producers claim 1,000,000 slots each. Every synchronised variant handed out each sequence exactly once (exact). `fetch-add` took 1 step per claim (exact). `cas-loop` failed at least 2.71 million CAS attempts in 4 million claims in C++ and 3.82 million in Java (exact counts, the least contended of three runs), with a largest retry count in one claim of 7-10 and 27-55.

Voluntary context switches count the futex sleeps. The least-switching `mutex` producer made 5,406-9,746 in C++ and 47,556-61,712 in Java; the most-switching `fetch-add` producer made 1 and 1-3.

| Claim p99 | C++ | Java |
|---|---|---|
| `mutex` | 2,633-2,985 ns | 8,187-8,383 ns |
| `cas-loop` | 478-502 ns | 1,409-1,837 ns |
| `fetch-add` | 400-468 ns | 516-584 ns |

The asserted ratio is `mutex` over `fetch-add` at p99: 6.10-6.45x in C++ (bound 2.5x) and 14.13-15.23x in Java (bound 3x). At p99.9 the ratios are 5.64-5.92x and 6.24-6.40x, observed only, not asserted. `cas-loop` against `fetch-add` is observed too, and lock-free isn't faster than wait-free in the table.

### The stalled producer

{% include excalidraw.html file="10-stalled-producer" alt="A fetch-add log of slots, drawn with slot numbers 41 to 44 for illustration. Slot 41 is published and read; a producer claims slot 42 and then sleeps for 1 ms, so it stays claimed but unpublished (amber); slots 43 and 44 are published and waiting. The consumer is stopped at slot 42 and waits 1.05-1.07 ms in C++ and 1.11-1.14 ms in Java." caption="Figure 10.4: A claim by fetch-add is wait-free, but the consumer is not: with one producer asleep for 1 ms between claim and publish, it waits 1.05-1.07 ms in C++ and 1.11-1.14 ms in Java at that slot." %}

With one producer sleeping 1 ms between claim and publish, the consumer waited 1.05-1.07 ms in C++ and 1.11-1.14 ms in Java at that sequence (bound 0.5 ms). The sleep guarantees at least 1 ms, so the 2x margin is by construction. Unstalled, the consumer's largest wait was 105-145 microseconds in C++ and 0.67-0.84 ms in Java (observed).

### The induction gap

In 10,000,000 trials, C++ release/acquire read both flags as 0 in 2,306,475-9,888,040, and `seq_cst` in 0 (exact). The count varies by run; the assertion is at least 1. jcstress, in quick mode, saw `0, 0` for `setRelease`/`getAcquire` in 85.0-98.6 million samples and 0 times for `volatile`.

Per-store cost is observed: p50 rounds to 0 ns for a C++ release store and 4 ns for `seq_cst`, and Java's `setRelease` and `volatile` store show the same (Google Benchmark, JMH).

### The seqlock

One writer updates at 1 MHz for 2 s against three spinning readers. Torn snapshots: 0 in every variant (exact), against 2.44-2.62 billion C++ reads and 1.22-1.30 billion Java reads. The checksum detects a mix of two updates, and the reader retries show the overlap happening: 4.9-26.7 million in C++ and 6.1-6.4 million in Java (observed).

| Writer p99 | C++ | Java |
|---|---|---|
| shared lock (`shared_mutex`, `ReentrantReadWriteLock`) | 5,979-6,603 ns | 8,083-8,287 ns |
| seqlock (`Seqlock`, `StampedLock`) | 25-32 ns | 206-234 ns |

The asserted ratio is 205.5-231.0x in C++ and 34.5-37.1x in Java (bound 3x). The p99.9 ratio is 4.44-5.17x and 2.60-3.01x (observed only).

### Python, both builds

Four threads claim 400,000 slots. `threading.Lock` lost or duplicated 0 claims in the GIL build and in the free-threaded build (3.14.8+freethreaded, GIL off from start to end); `itertools.count` lost 0 in both (observed). Without the lock, `value = n; n += 1` loses 0 claims under the GIL and 97,002-116,017 of 400,000 free-threaded (exact, asserted at least 1). The GIL doesn't make the read-modify-write atomic; it makes a switch inside it rare, because the interpreter switches threads every 5 ms (`sys.getswitchinterval()`). The lock's p99 is 664-686 ns under the GIL and 13.0-13.4 microseconds free-threaded (observed).

The measured process can't import the measurement kit: its `pyhdrh` extension doesn't declare free-threading support, so importing it turns the GIL back on, and the run would measure a free-threaded build with a GIL. `sync-py measure` writes raw samples and refuses to finish with the GIL on; a separate step converts them. Appendix E, *Free-threaded Python vs the GIL*, treats the build in full.

### The line

The line run uses four simulator instances as four cameras, 2.5 kHz and 20 s each. One receive thread per camera publishes into a multi-producer hand-off (`mutex` or `fetch-add` in C++, `ArrayBlockingQueue` or Agrona's `ManyToOneConcurrentArrayQueue` in Java), and the tracker sends divert commands on their own socket, never through the data queue. The simulators start only when the consumer's start gate opens, so no parcel waits in a socket buffer.

On the line all four variants counted 200,000 parcels, dropped none, and received every command. End-to-end p99 sits near 0.1 ms (observed): 100,479-107,967 ns for the C++ `mutex` and 93,951-116,159 ns for `fetch-add`, 127,423-162,175 ns for the Java blocking queue and 109,503-113,471 ns for Agrona. At 2.5 kHz per camera an uncontended lock costs nanoseconds against a 480 ms budget; only the saturated claim benchmark separates them.

## Cross-check

jcstress and the C++ harness run the same store-buffering test independently, under different memory models and tooling, and agree on both orderings in all three runs.

Context-switch counters explain the claim tails: the `mutex` producers sleep thousands of times, the `fetch-add` producers at most three, and the `mutex` p99 sits 6x to 15x above `fetch-add`'s.

With C2's default loop unrolling, adjacent volatile stores in the JMH loop share one fence and the benchmark under-reports the cost, so `StoreBenchmark` runs with `-XX:LoopUnrollLimit=1`; the 4 ns above is one fence per store.

## What you learned

- A progress guarantee belongs to an operation. A `fetch_add` claim is one step, and the consumer still waited 1.05-1.07 ms (C++) and 1.11-1.14 ms (Java) behind a producer asleep for 1 ms.
- Wait-free bounds steps, not time.
- Release/acquire lets both induction stations read 0; `seq_cst` and `volatile` forbid it, at about 4 ns a store here.
- A seqlock's writer never waits: p99 205.5-231.0x lower in C++, 34.5-37.1x in Java, 0 torn snapshots.
- A monotonic sequence avoids ABA and reclamation; the GIL build hides a race the free-threaded build shows.

The next chapter, *Stackful vs stackless: threads and fibers vs event loops and coroutines* (Part 4), asks what runs the threads these structures coordinate.

## For deeper coverage

- Williams, *C++ Concurrency in Action* (Manning), and Grimm, *Concurrency with Modern C++* (Leanpub), for atomics and memory orders.
- Enberg, *Latency* (Manning), as further reading.
- [Chapter 7, *Off-heap and lock-free Java: Chronicle, Agrona, the Disruptor, thread affinity*]({{ '/docs/07-offheap-lockfree/' | relative_url }}), for SPSC rings and padding, and [Chapter 9, *Eliminating work: allocation, cache locality, false sharing*]({{ '/docs/09-eliminating-work/' | relative_url }}), for false sharing.
- Chapter 11, *Stackful vs stackless: threads and fibers vs event loops and coroutines*, and Chapter 12, *I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core* (Part 4).
- Appendix E, *Free-threaded Python vs the GIL*.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts exactly-once claims, 1 step per `fetch-add` claim, the context-switch bounds, the claim p99 ratio (2.5x in C++, 3x in Java), the stalled-producer wait, the litmus outcomes, 0 torn snapshots, the writer p99 ratio, the line counts and the report contents. Observed only: p99.9 ratios, `cas-loop` against `fetch-add`, per-store cost, reader retries, the Python tails and `itertools.count`, and the line percentiles. It held on `r03-run1` to `r03-run3`, bare-metal and untuned, at commit 20664bd.*
