---
title: "Off-heap and lock-free Java: Chronicle, Agrona, the Disruptor, thread affinity"
order: 7
part: "The Managed-Runtime Question"
description: "Swapping a parking queue for a spinning ring cuts the decide thread's voluntary context switches from 199,383-199,582 to 38-47 per 200,000 parcels and its steady hand-off p99 from 10,455-11,743 ns to 572-674 ns (bare-metal, untuned host); pinning to an isolated vCPU keeps the spinner's tail short in a VM."
duration: 55 minutes
---

## Learning objectives

By the end of this chapter you can:

- Read a parking and a spinning consumer from the decide thread's context-switch counters, and say what spinning costs.
- Write a hand-off over an Agrona `OneToOneRingBuffer` or a Disruptor ring, and map a sequence to a slot with a mask.
- Keep the divert command off the data queue, and append an audit journal through a memory-mapped Chronicle Queue.
- Move a million-entry manifest off the Java heap with Chronicle Map, and state what the lookup costs.
- Pin a thread with OpenHFT Affinity, and say what guest isolation and a vCPU pin do and do not promise.

## Why this matters

A parcel travels 1.2 m at 2.5 m/s from the scanner to the diverter, which leaves 480 ms from scan to divert. The receive thread hands each scan to a decide thread, and the belt does not wait: a stall charges every parcel behind it, as Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*, showed. At 10 kHz, 4,800 parcels are in flight inside the budget (Chapter 2, *Modelling with Little's Law and Amdahl's Law*), so a consumer that wakes late has thousands of parcels behind it.

A `BlockingQueue` is the idiomatic hand-off. This chapter measures what it costs against spinning rings, a memory-mapped audit journal, an off-heap manifest and a pinned thread. None of this is a default: a spinning consumer holds a core at 100 %.

The code is in `examples/07-offheap-lockfree/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="07-handoff-topology" alt="A receive thread passes parcels through a hand-off of 65,536 slots (amber) to the decide thread, which sends divert commands on a separate command channel. A dashed path to an audit journal marks that only the chronicle-journal and write-per-parcel variants append to it. Three hand-off variants can be swapped in (dashed): blocking-queue, an ArrayBlockingQueue that parks, with 199,383-199,582 voluntary context switches over 200,000 parcels; agrona-spsc, whose idle strategy busy-spins, with 38-47; and disruptor with BusySpinWaitStrategy, with 23-31." caption="Figure 7.1: A spinning idle strategy keeps the decide thread running: 38-47 voluntary context switches for Agrona and 23-31 for the Disruptor, against almost one per parcel for a blocking queue." %}

## Concept

### Parking and spinning

A `BlockingQueue` consumer in `take()` parks when the queue is empty, and the next `offer` wakes it through the kernel. At 10 kHz the queue is empty nearly every time a parcel arrives, so nearly every parcel pays a park and a wake. A spinning consumer polls in a loop and never blocks. That removes the wake-up and costs a core whether parcels arrive or not, so it belongs on a dedicated, pinned thread.

### Libraries and the ring

Agrona's `OneToOneRingBuffer` sits over an `UnsafeBuffer` on a direct `ByteBuffer`. The scan is written as bytes outside the heap (`tryClaim`, write, `commit`), so a publish allocates under 1 B and the collector never sees the records. The consumer polls with an `IdleStrategy`; `BusySpinIdleStrategy` spins. The LMAX Disruptor uses a ring of preallocated `Slot` objects: claim a sequence, overwrite the slot, publish. Its `BusySpinWaitStrategy` spins and its `BlockingWaitStrategy` waits on a monitor (`synchronized` and `Object.wait`).

Both use the idea in Figure 7.2. A sequence only grows, and the slot is the sequence masked with `slots - 1`, which is why the slot count (`--slots`, 65,536) is a power of two. Each side writes only its own cursor, so neither takes a lock, and each cursor sits on its own cache line.

{% include excalidraw.html file="07-ring-sequences" alt="A ring of eight slots, drawn as an illustration of the 65,536-slot ring, holds sequences 5 to 10 in slots 5, 6, 7, 0, 1 and 2. The producer, with its cursor on its own cache line, publishes sequence 11 into slot 3 (amber arrow); the consumer reads sequence 5 from slot 5. The slot is the sequence masked with slots minus one, which works because the slot count is a power of two. A dashed ghost box marks a full ring, where the producer would have to wait." caption="Figure 7.2: A sequence only grows; masking maps it to a slot, and each side writes only its own cursor, so neither takes a lock." %}

The minimum ordering is a release store by the writer and an acquire load by the reader, which `VarHandle` `setRelease` and `getAcquire` express in Java. [Chapter 10, *Lock-free and wait-free synchronization*]({{ '/docs/10-lockfree-waitfree/' | relative_url }}) (Part 3), treats memory orders in full.

## How the code works

### The hand-off

`RingHandOff.java` sizes the ring at 64 bytes a record (an 8-byte header and the 56-byte scan) over a direct buffer. `publish` resolves the barcode before it claims, because a throw after `tryClaim` would leave a claim open. In `consume`, the idle strategy decides from `read`'s count whether to spin, yield or park. The C++ lane, `spsc_ring.hpp`, makes the same ideas explicit.

{% include codetabs.html langs="Java|C++" %}

```java
    RingHandOff(int records, Supplier<IdleStrategy> idleStrategy) {
        int bytes = records * 64;
        this.ring = new OneToOneRingBuffer(
                new UnsafeBuffer(ByteBuffer.allocateDirect(bytes + RingBufferDescriptor.TRAILER_LENGTH)));
        this.idleStrategy = idleStrategy;
    }

    // ...

    @Override
    public boolean publish(ParcelEvent event, long rxNs) {
        long serial = Barcode.serial(event.getBarcode()); // before the claim: a throw must not leave one open
        int index = ring.tryClaim(MESSAGE_TYPE, RingScan.LENGTH);
        if (index < 0) {
            return false;
        }
        RingScan.write(ring.buffer(), index, event, rxNs, serial);
        ring.commit(index);
        return true;
    }

    // ...

    private void consume(ScanSink sink) {
        RingScan view = new RingScan();
        MessageHandler handler = (type, buffer, index, length) ->
                sink.onScan(view.wrap(buffer, index), System.nanoTime());
        IdleStrategy idle = idleStrategy.get();
        sink.onStart();
        while (running) {
            idle.idle(ring.read(handler));
        }
    }
```

```cpp
  [[nodiscard]] bool try_push(const T& value) noexcept {
    const Index tail = tail_.load(std::memory_order_relaxed);  // ours: no ordering needed
    if (tail - cached_head_ == Capacity) {
      cached_head_ = head_.load(std::memory_order_acquire);  // the consumer's frees, now visible
      if (tail - cached_head_ == Capacity) return false;
    }
    slots_[tail & kMask] = value;
    tail_.store(tail + 1, std::memory_order_release);  // publishes the slot write above
    return true;
  }

  /// Consumer only. Empty optional when the ring is empty.
  [[nodiscard]] std::optional<T> try_pop() noexcept {
    const Index head = head_.load(std::memory_order_relaxed);
    if (head == cached_tail_) {
      cached_tail_ = tail_.load(std::memory_order_acquire);  // the producer's slot writes, now visible
      if (head == cached_tail_) return std::nullopt;
    }
    T value = slots_[head & kMask];
    head_.store(head + 1, std::memory_order_release);  // frees the slot for the producer
    return value;
  }

  // ...

  alignas(kFalseSharingRange) std::atomic<Index> tail_{0};  // written by the producer
  Index cached_head_ = 0;                                   // producer's last look at head_
  alignas(kFalseSharingRange) std::atomic<Index> head_{0};  // written by the consumer
  Index cached_tail_ = 0;                                   // consumer's last look at tail_
  alignas(kFalseSharingRange) std::array<T, Capacity> slots_{};
```

In C++ the producer owns `tail_` and the consumer owns `head_`. `try_push` reads its own index relaxed, publishes with a release store, and reloads the consumer's index with an acquire load only when its cached copy says the ring is full. `tail & kMask` is the slot arithmetic of Figure 7.2, and `alignas(kFalseSharingRange)` puts each index in its own 128-byte range, because this Intel CPU's L2 spatial prefetcher pulls 128-byte line pairs. The indices are 32-bit: libstdc++ waits on a 4-byte atomic directly on a futex; an 8-byte one goes through a shared proxy table. Java has no `alignas` for a field, so the libraries pad their cursors themselves.

`DisruptorHandOff.java` claims a sequence, writes the preallocated `Slot` and publishes.

```java
    @Override
    public boolean publish(ParcelEvent event, long rxNs) {
        long sequence;
        try {
            sequence = ring.tryNext();
        } catch (InsufficientCapacityException full) {
            return false;
        }
        try {
            ring.get(sequence).fill(event, rxNs);
        } finally {
            ring.publish(sequence); // always: an unpublished claim would stall the consumer
        }
        return true;
    }
```

`tryNext` claims a sequence, or throws `InsufficientCapacityException` when the ring is full; the run counts an overflow and criteria require none. The `finally` matters: a claim that is never published would stall the consumer. The C++ lane's parking consumer calls `std::atomic::wait` in `wait_for_data`, which futex-sleeps after a short spin.

```cpp
  /// Producer only: wake a consumer parked in wait_for_data(). The wake-up costs a system call
  /// when a consumer is parked and is a cheap check when none is.
  void notify_consumer() noexcept { tail_.notify_one(); }

  /// Consumer only: block until the producer has published something, without spinning. The wait
  /// parks the thread in the kernel on a futex (the index is a 4-byte atomic) once the library's
  /// short user-space spin is over.
  void wait_for_data() noexcept {
    const Index head = head_.load(std::memory_order_relaxed);
    const Index tail = tail_.load(std::memory_order_acquire);
    if (tail == head) tail_.wait(tail, std::memory_order_acquire);  // returns once tail_ != tail
  }
```

### The command path

The decide thread sends a `DivertCommand` on its own UDP socket (port 47271). It never passes through the hand-off, so a flood of scans cannot queue ahead of a command and a slow listener cannot back up the scans.

### The audit journal

After the command has gone out, each scan event is appended to a journal. `ChronicleJournal.java` appends to a Chronicle Queue, a memory-mapped file: the appender copies a record into pages the operating system writes back later, with no system call per record.

```java
    static {
        ChronicleAnalytics.disable(); // before Chronicle builds its first queue
    }

    // ...

    ChronicleJournal(Path directory) {
        this.queue = ChronicleQueue.singleBuilder(directory)
                .writeBufferMode(BufferMode.None)
                .readBufferMode(BufferMode.None)
                .build();
    }

    // ...

    @Override
    public void append(ScanView scan, long decidedNs, int lane) {
        try (DocumentContext document = appender.writingDocument()) {
            Wire wire = document.wire();
            wire.write("seq").int64(scan.seq());
            wire.write("intended_ns").int64(scan.intendedNs());
            wire.write("decided_ns").int64(decidedNs);
            wire.write("serial").int64(scan.serial());
            wire.write("lane").int32(lane);
        }
    }
```

`FileJournal.java` makes one `FileChannel.write` per event.

```java
    @Override
    public void append(ScanView scan, long decidedNs, int lane) {
        record.clear();
        record.putLong(scan.seq()).putLong(scan.intendedNs()).putLong(decidedNs).putLong(scan.serial())
                .putLong(lane);
        record.flip();
        try {
            while (record.hasRemaining()) {
                channel.write(record);
            }
            appended += RECORD_BYTES;
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
```

Only the open-source line is used: Queue 2026.7, Map 2026.1, Bytes 2026.4 and Affinity 2026.2, all Apache-2.0. The commercial features (asynchronous buffers, pre-toucher, replication, encryption) are not used; Appendix F surveys them. `BufferMode.None` is the only open-source buffer mode.

Chronicle Core posts usage analytics unless `chronicle.analytics.disable` is `true`. This example disables them in code (`ChronicleAnalytics.disable()`, above), in `java/pom.xml` and in `verify.sh`; `ChronicleAnalyticsTest` checks it, and `scripts/validate.py` fails a Chronicle source without it. In your own program, set it before the first queue or map is built.

The open-source pre-toucher hook is a stub that calls itself until `StackOverflowError` (confirmed with `javap`). The code never calls it. Do not call it.

The open-source queue does not `fsync` on append; no claim here depends on durability.

### The manifest and the heap

The shift manifest maps a barcode serial to a destination for 1,000,000 entries. A `HashMap` keeps a node, a boxed key and a `String` per entry in the old generation for the life of the program. A Chronicle Map keeps the entries in native memory and leaves far less on the heap. Its lookup costs more than the `HashMap`'s; what it buys is heap footprint.

### Placement

`ThreadPlacement.java` is an enum; each constant has its own `wrap`. `UNPINNED` is the scheduler's choice and the only host placement: pinning proves nothing without an isolated CPU, and isolating one would change the machine. `PINNED_ISOLATED` wraps the decide thread's body in an OpenHFT Affinity lock.

```java
    PINNED_ISOLATED("pinned-isolated") {
        @Override
        public Runnable wrap(Runnable body) {
            requireIsolatedCpu(Path.of("/proc/cmdline"), ISOLATED_CPU);
            return () -> {
                try (AffinityLock lock = AffinityLock.acquireLock(ISOLATED_CPU)) {
                    int cpu = Affinity.getCpu();
                    if (cpu != ISOLATED_CPU || lock.cpuId() != ISOLATED_CPU || !lock.isBound()) {
                        String why = "the lock is on CPU " + lock.cpuId() + " (bound " + lock.isBound() + "), the thread runs on CPU " + cpu
                                + ", wanted CPU " + ISOLATED_CPU;
                        System.err.println("placement failed: " + why);
                        throw new IllegalStateException("pinned-isolated: " + why);
                    }
                    body.run();
                }
            };
        }
    };
```

`requireIsolatedCpu` refuses to start unless `/proc/cmdline` has `isolcpus=3`. The lock is held until the body returns, and the thread throws if it missed CPU 3, so a failed placement is loud, not silently measured.

## Measure

Run from the repository root:

```bash
examples/07-offheap-lockfree/verify.sh
```

It runs twelve 20 s runs, then JMH. `ALLOW_BUSY=1` measures on a loaded host. `RECHECK=results/<run-id>` evaluates the criteria on committed reports without running anything. The workload is the line simulator at 10 kHz for 20 s (200,000 parcels, seed 42), windows split at parcel 20,000. Every Java run uses `-Xms1g -Xmx1g -XX:+AlwaysPreTouch -XX:+UseG1GC -Dchronicle.analytics.disable=true` plus the Chronicle `--add-opens` and `--add-exports` list, the `chronicle.jvmArgs` property in `java/pom.xml`. Chronicle, through its `jffi` native-call dependency, and the JMH harness call `sun.misc.Unsafe` memory-access methods; JDK 25 warns at first use (JEP 471, JDK 23, deprecated them for removal; JEP 498, JDK 24, made the warning the default), and the warnings stay on.

Profile for every number below: bare-metal host, an 8-core, 16-thread Intel laptop CPU (SMT on, `intel_pstate`), Fedora 44 kernel 7.2 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`, Temurin 25.0.5+8. Ranges span the committed runs `r02-run1` to `r02-run3`.

**Context switches (criterion 1).** Voluntary switches of the decide thread over 200,000 parcels: `blocking-queue` 199,383-199,582, `agrona-spsc` 38-47 and `disruptor` 23-31. The bounds are at most 1 % of the parcels for the spinners and at least 25 % for the queue. `linked-queue` and `disruptor-blocking-wait` park too (observed), at 199,489-199,577. `agrona-spsc-backoff` (observed) spins, yields, then parks, and the park phase returns the switches: 358,518-358,735.

**Hand-off latency (criterion 2).** Steady-window hand-off p99: `blocking-queue` 10,455-11,743 ns, `agrona-spsc` 572-674 ns and `disruptor` 674-731 ns. The bound is one fifth of `blocking-queue`'s in the same run. All three runs passed, with Disruptor margins (bound over observed) of 3.48, 2.86 and 3.38. Run 1 of an earlier set (git history, d419992) hit a Disruptor p99 of 2,117 ns, a margin of 1.01. It did not recur here, and no cause was measured. A spinner on an unisolated host is at the scheduler's mercy, which motivates the VM part.

**Allocation (criterion 3).** JMH `-prof gc` bytes per publish: Agrona 0.0004 B/op and Disruptor 0.0007-0.0009 B/op (both under 1 B/op), `linked-queue` 96.7-96.9 B/op. `blocking-queue`, observed, allocates 93.4-98.5 B/op for the immutable `Scan` record. Chapter 5, *What the JVM costs: allocation, escape analysis, JIT warmup vs AOT*, covers what an allocation costs.

**Journal (criterion 4).** The tailer reads back 200,000 events in order for both journals. The Chronicle decide thread makes 0 write system calls and `write-per-parcel` 200,000. The append removes the system call and not the first-touch page fault: Chronicle's decide thread takes 1,442-1,457 minor faults against 68-73 for `write-per-parcel`. The journal is 15,002,633 to 15,002,637 B on btrfs (block size 64 MiB, roll cycle `FAST_DAILY`) in 3,662 pages, so the faults are 39 % of the page count, consistent with the kernel mapping several cached pages per fault. Steady-window append latency is observed only, as the journal's file system sets it: Chronicle p50 311-316 ns, p99 813-1,211 ns, p99.9 4,619-5,263 ns; `write-per-parcel` p50 1,054-1,080 ns, p99 2,643-3,177 ns, p99.9 5,831-7,971 ns.

**Heap (criterion 5).** After a full collection the old generation holds 14.42-14.43 MB with `chronicle-map-manifest` against 137.51-137.52 MB with `on-heap-manifest`, from a 3.8 MB baseline. Observed whole-run lookup p50 and p99 (200,000 lookups): Chronicle Map 279-297 and 1,293-1,373 ns, `HashMap` 33-40 and 477-487 ns. Observed: the `on-heap-manifest` hand-off p99.9 is 218-347 us against 1.1-2.9 us for `chronicle-map-manifest`; each run's `on-heap-manifest` G1 log records one young pause in the run, 22.6 to 22.8 ms, at 14.1 to 15.5 s. Chapter 6, *GC for tails: Generational ZGC and Shenandoah*, covers the collectors.

**The C++ lane (observed).** `atomic-spsc` hand-off p50, p99 and p99.9 are 129-132, 330-336 and 509-599 ns with 0 voluntary switches. `atomic-wait` is 1,823-1,958, 8,187-9,471 and 53,855-67,583 ns with 199,859-199,899 voluntary switches.

**Every run (criterion 6).** Count 200,000, dropped 0, no overflow, every divert command received, every report passes `check`.

### The VM part: pinning to an isolated vCPU

The isolation lives in a lab guest restored from a snapshot; the host is not changed.

```bash
scripts/lab/revert-vm.sh lowlat-target lab-ready-iso && scripts/lab/lab-up.sh
VM=1 examples/07-offheap-lockfree/verify.sh
scripts/lab/lab-down.sh
```

VM profile: lab guest `lowlat-target`, 4 vCPUs on the same Intel host, PREEMPT_RT kernel 7.2.11-200.lowlatrt.fc44.x86_64+rt, guest command line `isolcpus=3 nohz_full=3 rcu_nocbs=3`, guest vCPU 3 pinned to host CPU 13 by libvirt (a pin, not host isolation), tuned `virtual-guest`, clocksource `kvm-clock`, `stress-ng --cpu 3` on guest CPUs 0-2, Temurin 25.0.5+8. Label `vm`; ranges across `r02-vm-run1` to `r02-vm-run3`, each from the snapshot `lab-ready-iso`. Never compared with the host numbers.

{% include excalidraw.html file="07-affinity-vm" alt="Inside the host, the guest lowlat-target boots with isolcpus=3 nohz_full=3 rcu_nocbs=3. stress-ng runs on guest CPUs 0-2, which are vCPUs 0-2, unpinned on the host. An unpinned decide thread shares them and records 119,779-360,310 involuntary context switches across nine alternations and a steady-window hand-off p99.9 of 0.43-1.56 ms (median of 3 alternations per run). A pinned decide thread (AffinityLock 3, amber) runs on the isolated vCPU 3, which libvirt pins to host CPU 13, and records 0-5 involuntary switches and a p99.9 of 54-55 us (same median). All figures are from the VM." caption="Figure 7.3: Pinned to an isolated vCPU, the decide thread is no longer preempted by the stress load. These are VM figures, never compared with the host runs." %}

The guest profile, versioned in `scripts/lab/guest-profiles/isolate-cpu3.conf`, is applied inside the guest only:

```text
PROFILE_NAME="isolate-cpu3"
PROFILE_ARGS="isolcpus=3 nohz_full=3 rcu_nocbs=3"
```

Each run does the 10 kHz, 20 s workload unpinned and pinned, alternated three times inside one boot, with `agrona-spsc`.

**Involuntary switches (criterion 1).** Per 200,000-parcel run, the unpinned decide thread was preempted 119,779-360,310 times and the pinned one 0-5 times, in all nine alternations of each. Bounds: pinned at most 10, unpinned at least 100.

**Tail (criterion 2).** Steady-window hand-off p99.9, the median of three alternations in each run: unpinned 0.43-1.56 ms (1,036,799, 432,895 and 1,558,527 ns), pinned 54-55 us (54,655, 54,047 and 54,047 ns). Bound: pinned at most half of unpinned.

**Placement (criterion 3).** The pinned thread's `Cpus_allowed_list` was CPU 3 and `/proc` showed it on CPU 3. The unpinned thread was allowed on CPUs 0-3 and seen on CPUs 0-2.

Pinned p99.9 stays at tens of microseconds because the pin narrows the tail and does not remove the host's share of it. The host kernel may still run other work on CPU 13 and its hyperthread sibling CPU 5, and a host interrupt can still land there; the guest sees such a stall only as lost time. Chapter 15, *CPU partitioning and the noisy-neighbour problem*, and Chapter 18, *Latency config as code* (Part 5), own isolation, and Chapter 14, *PREEMPT_RT: what real-time Linux does and doesn't promise*, covers the real-time kernel.

## Cross-check

The decide thread's switches (read from `/proc/<pid>/task/<tid>/status`) and the in-process percentiles agree: the blocking queue shows nearly one voluntary switch per parcel and a p99 well above the rings'. The `syscw` from `/proc/<pid>/task/<tid>/io` is 200,000 for `write-per-parcel`, matching its readback count, and 0 for Chronicle. The C++ lane reproduces the park and spin split. In the VM, `Cpus_allowed_list` and `/proc` showing CPU 3 confirm the placement.

## What you learned

- A parking consumer pays a kernel wake per parcel, visible as about one voluntary switch each; a spinning consumer pays a core instead and belongs on a pinned, dedicated thread.
- Agrona and Disruptor rings publish under 1 B/op (0.0004 and 0.0007 to 0.0009) and map a sequence to a slot with a mask.
- The divert command travels on its own socket and never shares a queue with the scans.
- A memory-mapped journal removes the system call, not the first-touch fault; a Chronicle Map trims the heap at the price of a slower lookup.
- A pin to an isolated vCPU removed the preemption in the VM; it narrows the tail and is not host isolation.

The next chapter, *Zero-copy and flat data: Panama (FFM), Valhalla value objects, and the C++ comparison*, removes most of the allocation from the decode that feeds this hand-off.

## For deeper coverage

- Enberg, *Latency* (Manning), as further reading.
- [Chapter 10, *Lock-free and wait-free synchronization*]({{ '/docs/10-lockfree-waitfree/' | relative_url }}), in Part 3, for memory orders in full.
- Chapter 15, *CPU partitioning and the noisy-neighbour problem*, and Chapter 18, *Latency config as code: CI/CD, deployment, and rollouts gated on a latency and jitter SLO*, in Part 5, for isolation as versioned deployment config.
- `examples/common/MEASUREMENT.md` for the report format.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. On the host, `verify.sh` asserts the context-switch bounds, the hand-off p99 ratio, the publish allocation bounds, the journal readback, system-call and fault criteria, the old-generation ratio and the per-run conditions. Observed only: `agrona-spsc-backoff`, `disruptor-blocking-wait`, append latencies, manifest lookup cost, the `on-heap-manifest` tail and the C++ lane. It held on `r02-run1` to `r02-run3`. The VM part asserts the involuntary-switch bounds, the pinned p99.9 ratio and the placement, and held on `r02-vm-run1` to `r02-vm-run3`, labelled VM.*
