---
title: "Measuring correctly: clocks, percentiles and coordinated omission"
order: 3
part: "Understanding & Measuring Latency"
description: "Where a latency clock starts decides what it can see. One 200 ms consumer stall, recorded four ways in C++, Python and Java, shows which timers hide it and which charge for it."
duration: 45 minutes
---

## Learning objectives

By the end of this chapter you can:

- Choose a clock for latency work, measure its own cost, and keep one clock domain across processes.
- Place the start of a measurement at the belt's schedule (intended time) instead of at the moment your code receives the work.
- Explain why a closed-loop benchmark under-reports a stall, and repair the record with `record_corrected` or `recordValueWithExpectedInterval`.
- Configure an HdrHistogram with a fixed range and precision, and read its percentiles without computing a mean.
- Name the one place where the C, Python and Java ports of HdrHistogram can disagree by a bucket.

## Why this matters

The belt never waits. The simulator in this book emits a parcel every millisecond at 1 kHz, on a schedule fixed before the run starts, and a consumer that stops for 200 ms does not slow the belt: 200 parcels pile up behind it, and each one reaches the diverter late. Each of those parcels spent part of the scan-to-divert budget waiting in a socket buffer.

A timer that starts when the consumer picks up a parcel cannot see that wait. Neither can a benchmark that sends its next request only after the previous one returns. Both report a healthy service while the line mis-sorts 200 parcels. This is coordinated omission: the measuring system coordinates with the system under test, so the samples the stall would have produced are never taken.

Chapter 1 showed that latency is a distribution; this chapter keeps the samples of that distribution intact, starting with the clock and the histogram underneath.

The code is in `examples/03-coordinated-omission/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="03-three-clocks" alt="A timeline of intended emit, actual send, dequeue and done, with three bars below ending at done: intended-time (amber) starts at the belt's schedule, closed-loop at the send of its own request, receipt-time at dequeue." caption="Figure 3.1 — Three clocks on one parcel. Only intended-time starts at the belt's schedule, so only it is charged for the wait." %}

## Clocks

Every latency is a difference of two clock reads, so the clock sets the floor.

**Monotonic, not wall.** A wall clock (`CLOCK_REALTIME`) can step backwards when NTP or an operator corrects it, which makes a duration negative. `CLOCK_MONOTONIC` only moves forward and is the right source for durations. The line simulator documents this as a contract: every `*_ns` field on the wire is `CLOCK_MONOTONIC` in integer nanoseconds. The simulator calls `clock_gettime` directly rather than `std::chrono::steady_clock`, because the wire contract promises `CLOCK_MONOTONIC` and the C++ standard does not promise that for `steady_clock`. Python's `time.monotonic_ns()` is `CLOCK_MONOTONIC` on Linux, and so is the JVM's `System.nanoTime()` on this platform.

**One clock domain.** The experiment subtracts a timestamp written by the simulator process (`intended_emit_ns`) from one read in the consumer process. That subtraction is valid only because both read the same kernel clock on the same host. The value is not wall time and means nothing on another machine.

**The cost of a read.** Two back-to-back reads and the difference between them give the price of one read. That price is the floor under any timing around sub-microsecond work. The probe takes 1,000,000 pairs per clock.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
void run_clock_probe(std::uint64_t calls, ClockProbe& probe) {
  // Two reads back to back: the difference is the cost of one read.
  for (std::uint64_t i = 0; i < calls; ++i) {
    const std::int64_t a = monotonic_ns();
    const std::int64_t b = monotonic_ns();
    probe.line_monotonic_ns.record(b - a);
  }
  for (std::uint64_t i = 0; i < calls; ++i) {
    const auto a = std::chrono::steady_clock::now();
    const auto b = std::chrono::steady_clock::now();
    probe.steady_clock.record(std::chrono::duration_cast<std::chrono::nanoseconds>(b - a));
  }
}
```

```python
# Probe variant -> (clock name for the report notes, the clock).
CLOCKS: dict[str, tuple[str, Callable[[], int]]] = {
    "clock-read": ("time.monotonic_ns", time.monotonic_ns),
    "clock-read-perf_counter_ns": ("time.perf_counter_ns", time.perf_counter_ns),
}

# ...

def clock_probe(calls: int) -> dict[str, Recorder]:
    """Cost of one clock read: two back-to-back reads, the difference recorded."""
    out: dict[str, Recorder] = {}
    for variant, (_, clock) in CLOCKS.items():
        rec = Recorder(EXAMPLE, variant)
        record = rec.record
        for _ in range(calls):
            a = clock()
            b = clock()
            record(b - a)
        out[variant] = rec
    return out
```

```java
final class ClockProbe {

    private ClockProbe() {
    }

    static void run(long calls, LatencyRecorder nanoTime) {
        for (long i = 0; i < calls; i++) {
            long a = System.nanoTime();
            long b = System.nanoTime();
            nanoTime.record(b - a);
        }
    }
}
```

The Python probe binds `rec.record` to a local name before the loop, which removes one attribute lookup per iteration from the measured path. The C++ probe reads two clocks because the standard library clock and the raw `clock_gettime` wrapper are both common choices.

## The three measurement methods

The consumer receives each parcel as a UDP datagram, handles it, and records a latency. The methods differ only in where the clock starts.

- **Intended time** starts at `intended_emit_ns`, the instant the belt's schedule says the parcel is emitted. It is charged for everything after that: the simulator waking late, the loopback hop, the wait in the socket buffer, and the handling.
- **Receipt time** starts when the consumer dequeues the datagram. It is what a service-side timer reports. It measures handling only.
- **Closed loop** is a client that issues the next request only after the previous one completes, one request per millisecond, with the same 200 ms stall. Each request is timed from its own start. Recorded as is, it is the naive variant. Recorded through the histogram's correction call it is the corrected variant.

{% include excalidraw.html file="03-coordinated-omission" alt="Two bands: in the UDP run a stalled consumer feeds receipt-time (C++ p99 5.1-5.4 us) and intended-time (p99 100.3-100.5 ms C++, 100.8-101.5 ms Java); in the closed-loop run a client feeds naive (p99 1.0 us C++, 6.9-7.0 us Java) and, through a dashed back-fill edge, corrected (p99 98.2 ms C++, 99.1-99.3 ms Java)." caption="Figure 3.2 — A 200 ms stall is invisible to receipt-time and to the naive closed loop, and visible to the schedule clock and to the back-filled correction. Numbers: bare-metal, untuned host (Intel Core i7-11800H, Fedora 44 kernel 7.2.11-200.fc44, governor `powersave`), runs r02-run1..3." %}

The first two variants come from the same datagrams in the same run. Parcel 5000 triggers the stall. During those 200 ms the simulator keeps emitting, so about 200 parcels wait in the socket. The consumer then drains them back to back, so receipt time records 200 fast samples. Intended time records the same 200 parcels with waits that fall from about 200 ms to near zero. The third and fourth variants come from a separate closed-loop phase in the same process.

## HdrHistogram

All percentiles in this book come from HdrHistogram, never from sorting samples or hand-written percentile code. The kits in `examples/common/MEASUREMENT.md` use the same parameters in all three languages: values in nanoseconds, lowest discernible value 1, highest trackable value 3,600,000,000,000 (one hour), 3 significant digits. The range is fixed at construction, so recording never allocates and costs the same on every call. Three significant digits means each recorded value is held to within 0.1 percent, whether it is 100 ns or 100 ms. Because the parameters are identical, a histogram encoded by one kit decodes in the other two.

Each kit's `record_corrected(value, expected_interval)` calls the library's correction, `hdr_record_corrected_value` in C, `record_corrected_value` in Python and `recordValueWithExpectedInterval` in Java, which records the value and then back-fills. If a request took 200 ms and the client was supposed to issue one every 1 ms, the call also records the values 199 ms, 198 ms and so on down to 1 ms: the latencies of the requests that a client on schedule would have issued during the stall and that would have waited behind it. A 200 ms sample becomes 200 samples, which is why the C and Java corrected count is 10,199 rather than 10,000. The Python port's loop takes one more step: after the last back-filled value of at least one interval it also records the remainder below the interval, 0.10 to 0.24 ms, so Python counts 10,200. That value sits at the bottom of the ramp, far below p99.

Java also offers `copyCorrectedForCoordinatedOmission` for a finished histogram. Post-hoc correction gives the same total count as inline but may place a percentile one bucket apart, because the copy back-fills from bucketed values. The experiment corrects inline.

**Sidebar: a rank convention that differs by port.** The percentile at p over N samples needs the rank `p·N/100`. The C library (0.12.1) and the Python port (0.10.8) round that rank half up. The Java library (2.2.2) rounds it up. With dense data both ranks land in the same bucket. In a sparse tail, such as a handful of back-filled values at the top of a histogram, they can be one bucket apart. The committed fixture `examples/common/measure-fixtures/java-sparse-tail.json` is a Java report of this kind, taken from this experiment's corrected variant. Each kit keeps its library's convention, and `lowlat-report check` recomputes a report with the convention of the language that wrote it. When you compare a percentile across languages, allow one bucket in the extreme tail.

## How the code works

Each language has one program with two subcommands, `run` and `probe`: `experiment.cpp`, `experiment.py`, and `ClockProbe.java` with `Experiment.java`. Every program owns four recorders per run, one per variant, and variant names carry a suffix (`-control` for the run with no stall).

### Timestamping against the intended time

The receive loop does one thing the line consumer does not: it starts a latency clock the instant `recv` returns, before parsing. Parsing a protobuf message takes time that is not queueing.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
    const ssize_t n = ::recv(sock.get(), datagram.data(), datagram.size(), 0);
    // The datagram has just been dequeued: this is where a service-side timer
    // starts its clock, however long the parcel waited in the socket buffer.
    const std::int64_t dequeued_ns = monotonic_ns();
```

```python
        try:
            n = sock.recv_into(buf)
        except TimeoutError:
            if tracker.received and now() - last_rx_ns >= idle_ns:
                break
            continue
        # Just dequeued: this is where a service-side timer starts its clock, however
        # long the parcel waited in the socket buffer.
        dequeued_ns = now()
```

```java
            // Just dequeued: this is where a service-side timer starts its clock, however
            // long the parcel waited in the socket buffer.
            long dequeuedNs = System.nanoTime();
```

`dequeued_ns` is receipt time's start. The intended-time start is already in the message: `ev.intended_emit_ns()`, which the simulator wrote from its schedule. The completion read comes after the handling step, and both variants are recorded against it.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
    g_sink.store(line::lane_for(ev.barcode()), std::memory_order_relaxed);  // the line's "handle" step
    if (cfg.stall_ms > 0 && ev.seq() == cfg.stall_seq) stall_for(std::chrono::milliseconds{cfg.stall_ms});

    const std::int64_t done_ns = monotonic_ns();
    rec.receipt_time.record(done_ns - dequeued_ns);
    rec.intended_time.record(done_ns - ev.intended_emit_ns());
```

```python
        lane_for(event.barcode)
        if stall_ms and event.seq == stall_seq:
            stall(stall_ms)
        done_ns = now()
        rec.receipt_time.record(done_ns - dequeued_ns)
        rec.intended_time.record(done_ns - event.intended_emit_ns)
```

```java
            sink = Lanes.laneOf(event.getBarcode());
            if (o.stallMs() > 0 && event.getSeq() == o.stallSeq()) {
                stall(o.stallMs());
            }
            long doneNs = System.nanoTime();
            rec.receiptTime().record(doneNs - dequeuedNs);
            rec.intendedTime().record(doneNs - event.getIntendedEmitNs());
```

The handling step is the line's lane lookup from the barcode. The C++ and Java versions store its result in a sink (an atomic and a `volatile` field) so the compiler or JIT cannot delete a call whose result is unused. Python needs no sink. Chapter 4 returns to dead-code elimination.

### The stall

The stall is a blocking sleep:

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
void stall_for(std::chrono::milliseconds d) { std::this_thread::sleep_for(d); }
```

```python
def stall(ms: int) -> None:
    """The stall: a blocking sleep, which models a GC pause, a page fault or a lock convoy.

    It is the one place in this example where sleeping is the right tool.
    """
    time.sleep(ms / 1000)
```

```java
    static void stall(long ms) {
        try {
            Thread.sleep(Duration.ofMillis(ms));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
```

A sleep is the correct tool here: it models a thread that is not running, whether from a collection pause, a page fault or a lock convoy. Java restores the interrupt flag rather than swallowing it, which is the idiom for `InterruptedException`. The stall fires once, at parcel `seq` 5000.

### The closed-loop client

The closed loop is the standard benchmark shape: start, work, finish, then issue the next one.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
  for (std::uint64_t i = 0; i < requests; ++i) {
    const std::int64_t start_ns = monotonic_ns();
    g_sink.store(line::lane_for(barcode), std::memory_order_relaxed);
    if (cfg.stall_ms > 0 && i == cfg.stall_seq) stall_for(std::chrono::milliseconds{cfg.stall_ms});
    const std::int64_t latency_ns = monotonic_ns() - start_ns;

    rec.closed_loop_naive.record(latency_ns);
    rec.closed_loop_corrected.record_corrected(latency_ns, interval_ns);

    // Closed loop: the next request is issued only now, at least one interval
    // after this one started. Nothing queues behind the stall, so nothing is
    // measured as having waited.
    (void)line::sleep_until_ns(start_ns + interval_ns);
  }
```

```python
    for i in range(requests):
        start_ns = now()
        lane_for(barcode)
        if stall_ms and i == stall_seq:
            stall(stall_ms)
        latency_ns = now() - start_ns
        rec.closed_loop_naive.record(latency_ns)
        rec.closed_loop_corrected.record_corrected(latency_ns, EXPECTED_INTERVAL_NS)

        # Closed loop: the next request is issued only now. Nothing queues behind the
        # stall, so nothing is measured as having waited.
        wait_ns = start_ns + EXPECTED_INTERVAL_NS - now()
        if wait_ns > 0:
            time.sleep(wait_ns / 1e9)
```

```java
        for (long i = 0; i < requests; i++) {
            long startNs = System.nanoTime();
            sink = Lanes.laneOf(barcode);
            if (o.stallMs() > 0 && i == o.stallSeq()) {
                stall(o.stallMs());
            }
            long latencyNs = System.nanoTime() - startNs;
            rec.closedLoopNaive().record(latencyNs);
            rec.closedLoopCorrected().recordCorrected(latencyNs, EXPECTED_INTERVAL_NS);

            // Closed loop: the next request is issued only now. Nothing queues behind the
            // stall, so nothing is measured as having waited.
            long waitNs = startNs + EXPECTED_INTERVAL_NS - System.nanoTime();
            if (waitNs > 0) {
                try {
                    Thread.sleep(Duration.ofNanos(waitNs));
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
```

Both recorders receive the same `latency_ns`. The corrected one back-fills with an expected interval of 1 ms, the loop's pacing. The pacing differs by language. C++ sleeps to an absolute deadline with `clock_nanosleep(TIMER_ABSTIME)`, which hands the kernel the deadline and needs no remaining-time bookkeeping after a signal. Python and Java compute the remaining time and sleep for that long, because neither exposes an absolute-deadline sleep in its standard library. The clock starts at the request's own `start_ns`, so no request can be charged for time it spent queued. That is the defect.

## Measure

Run the example from the repository root:

```bash
examples/03-coordinated-omission/verify.sh
```

It builds the three programs, runs each for 10 s at 1,000 parcels/s with the stall, runs each again as a control with no stall, runs the clock probe, then asserts the criteria below and runs `lowlat-report check` on every report. It exits non-zero if the effect is absent.

Profile for every number below: bare-metal host, Intel Core i7-11800H, 16 logical CPUs, Fedora 44 kernel 7.2.11-200.fc44 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`. Ranges span the three committed runs, `results/r02-run1` to `r02-run3`. Java and Python run unwarmed.

**Clock read.** `monotonic_ns` through `clock_gettime` costs a p50 of 12 ns in C++ in all three runs, and `std::chrono::steady_clock` costs 13 ns. `System.nanoTime` costs 12 to 13 ns. Python is about 3.5 to 3.9 times higher: `time.monotonic_ns` 44 to 47 ns and `time.perf_counter_ns` 42 to 45 ns. The `tsc` clocksource is read in user space through the vDSO, which is why a read costs tens of nanoseconds and not a syscall. `acpi_pm`, which this host also lists, is not readable through the vDSO, so each read would be a system call. Timing work shorter than a few clock reads measures the clock.

**The stall, four ways (p99).**

| Variant | C++ | Python | Java |
|---|---|---|---|
| receipt-time | 5.1 to 5.4 us | 25.6 to 52.5 us | 32.0 to 48.5 us |
| intended-time | 100.3 to 100.5 ms | 101.4 to 102.3 ms | 100.8 to 101.5 ms |
| closed-loop naive | 1.0 us | 19.2 to 19.8 us | 6.9 to 7.0 us |
| closed-loop corrected | 98.2 ms | 98.1 to 98.3 ms | 99.1 to 99.3 ms |

The receipt-time and closed-loop naive variants stay in microseconds, while intended-time and closed-loop corrected land near 100 ms. The arithmetic explains that. The 200 stalled parcels are 2 percent of 10,000 samples, and their waits fall linearly from about 200 ms to zero. The p99 sits 1 percent from the top, which is the midpoint of that ramp, about 100 ms. The corrected loop has the same shape: 199 back-filled values from 199 ms down to 1 ms plus the 200 ms sample, so its p99 is also near 100 ms.

The maximum cannot separate the methods. Every variant records the stalled sample, so the max is about 200 ms everywhere, including receipt time (C++ 200.3 ms) and the naive closed loop (C++ 200.3 ms). The naive methods hold the stall as one sample. The p99 shows that it hurt 200 parcels.

**The control (no stall).** The correction must add nothing when nothing is late. In the control, closed-loop naive and corrected have the same count, 10,000, and the same p99 in every run: C++ 1.0 us, Python 19.2 to 19.5 us, Java 5.8 to 6.0 us. Control intended-time p99 is 186 to 253 us in C++, 199 to 216 us in Python and 221 to 284 us in Java, while receipt time is 5.2 to 6.8 us in C++. That gap is real latency, not a stall. Intended time includes the simulator waking late to send, the loopback hop and the socket queue; receipt time and the closed loop start after all of that. It is also why the control criterion is a p99 under 1 ms rather than a comparison with the other clocks. Java's control also shows an intended-time p99.9 of 9.4 to 18.0 ms, consistent with the unwarmed start.

**Criteria, per language.** Intended-time p99 is at least 50 ms. Receipt-time p99 is under 1 ms. Corrected p99 is within 2x of intended-time p99. Naive p99 is under 1 ms. In the control, intended-time p99 is under 1 ms and corrected p99 is within 2x of naive p99.

## Cross-check

`lowlat-report check` decodes each report's HdrHistogram, recomputes p50, p90, p99, p99.9 and max from the decoded counts, and asserts they equal the emitted values, using the rank convention of the writing language. The variants also cross-check each other. The corrected loop and the intended-time clock reach their numbers by different mechanisms, a back-filled client and a schedule clock, and still agree: in every run corrected p99 is 2.1 to 2.3 % under intended time in C++, 3.2 to 3.9 in Python and 1.7 to 2.2 in Java. Two independent mechanisms agreeing confirms the back-fill.

## What you learned

- A latency is the difference of two clock reads, and where the first one is taken decides what you can see. Receipt time and the naive closed loop start after the wait and cannot see a stall; intended time starts at the schedule and charges for it.
- Use a monotonic clock for durations, confirm that both timestamps share a clock domain, and measure the cost of the read before timing anything near it.
- Configure the histogram once with a fixed range and precision (1 ns to one hour, 3 significant digits) and use the library's correction call, `record_corrected` or `recordValueWithExpectedInterval`, instead of hand-written percentile or back-fill code.
- Expect post-hoc and inline correction to agree on count and possibly differ by one bucket, and the ports to differ by one bucket in a sparse tail.
- A control run with the stall removed shows what the method itself adds. Here the correction adds nothing.

The next chapter, Benchmark harnesses: Google Benchmark, pyperf and JMH, takes the same discipline into the tools that automate warm-up, repetition and dead-code defence.

## For deeper coverage

- Enberg, *Latency* (Manning), for the broader treatment of measuring and reasoning about latency.
- Chapter 1, *Latency vs bandwidth*, in Part 1, for latency as a distribution and why the book reports p50, p99 and p99.9 and never a mean.
- Chapter 4, *Benchmark harnesses*, in Part 1, for how harnesses handle warm-up and dead-code elimination in the measured loop.
- `examples/common/MEASUREMENT.md` for the histogram parameters, the report format and the correction tests every kit passes.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts, for each of C++, Python and Java, that intended-time p99 is at least 50 ms, receipt-time p99 is under 1 ms, closed-loop-corrected p99 is within 2x of intended-time p99, closed-loop-naive p99 is under 1 ms, the control run's intended-time p99 is under 1 ms and its corrected p99 is within 2x of naive, and that `lowlat-report check` passes on every report. It held on `r02-run1`, `r02-run2` and `r02-run3` on the bare-metal host described above.*
