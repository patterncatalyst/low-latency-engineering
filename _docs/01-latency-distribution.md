---
title: "Latency vs bandwidth: latency is a distribution"
order: 1
part: "Understanding & Measuring Latency"
description: "On a bare-metal, untuned host, equal throughput can hide an 82x to 180x difference in median latency, and one slow parcel in a hundred moves p99 up by 11 to 30 times while the median stays in the fast mode. Measure the distribution, never one number."
duration: 45 minutes
---

## Learning objectives

By the end of this chapter you can:

- Explain why throughput and latency answer different questions, using a per-parcel and a batch-of-32 consumer at the same 1 kHz.
- Read p50, p90, p99, p99.9 and max from a report, and say what each one is for.
- Build a bimodal workload with a calibrated busy loop and show that the median stays in the fast mode while p99 lands in the slow mode.
- Tie the scan-to-divert budget to a tail percentile instead of the median.
- Write a handler for a shared receive loop, including one that completes parcels later.
- Check a claim within one run, because a median on an untuned host moves between runs.

## Why this matters

A parcel passes the barcode scanner and the controller has until the parcel reaches the diverter to pick a lane. The belt doesn't wait: at the line's speed the budget is `1.2 m / 2.5 m/s = 480 ms`, minus encoder jitter and actuation time. A parcel whose decision arrives after the diverter has fired goes down the wrong lane. A controller that is fast for most parcels and slow for a few is a controller that mis-sorts those few.

So "how fast is it?" is incomplete in two ways. A design can raise the parcels handled per second while making each parcel wait longer. A handler can be fast for 99 parcels and slow for the hundredth, so one summary number describes neither group.

The code is in `examples/01-latency-distribution/`. Its `README.md` covers the run script.

Every number here carries one profile: bare-metal host, an 8-core, 16-thread Intel laptop CPU (SMT on, `intel_pstate`), Fedora 44 kernel 7.2 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`.

## Diagram

{% include excalidraw.html file="01-batch-vs-per-parcel" alt="Two lanes of parcels arriving at 1 kHz: the per-parcel lane handles each parcel on arrival, with p50 85-188 us; the batch lane gathers parcels 1 to 32 into one handling step, and an amber arrow marks the first parcel's ~31 ms wait, with p50 15.2-15.4 ms." caption="Figure 1.1: Batching leaves throughput unchanged but moves the p50 from 85-188 us to 15.2-15.4 ms, because the first parcel waits for 31 others." %}

## Concept

**Latency** is the time one parcel spends between its intended emission and the moment the consumer finishes handling it. **Bandwidth**, or throughput, is how many parcels per second the consumer completes.

A consumer that collects 32 parcels and handles them together amortises per-call overhead. At 1 kHz the 32nd parcel arrives 31 ms after the first, so the first parcel waits 31 ms. The batch variant completes parcels at the per-parcel rate, yet the typical parcel is 82 to 180 times later.

The second effect is a bimodal workload. One parcel in 100 is a scanner no-read, the barcode couldn't be decoded, and the controller runs a slower re-lookup that takes about 2 ms. The other 99 take the fast path. The median sits inside the large fast population. The slow path delays every parcel that arrives behind it while the core is busy, so p99 sits in the slow one.

{% include excalidraw.html file="01-bimodal-tail" alt="Parcels 98 to 104 in a row, with parcel 100 drawn wide as an amber ~2 ms slow path that holds the core and parcel 101 queued behind it; p50 points to a fast-mode box (p50 95-232 us) and p99 to a slow-mode box (p99 2.1-6.8 ms), and a ghost box says one summary number describes neither group." caption="Figure 1.2: The median stays in the fast mode while p99 lands in the slow mode, among the slow parcel and those queued behind it. One summary number describes neither group." %}

### Percentiles

Each report carries a distribution, summarised by five points:

| Point | Meaning | What it answers |
|---|---|---|
| p50 | half the parcels were faster | the typical parcel |
| p90 | 9 in 10 were faster | the shoulder of the distribution |
| p99 | 99 in 100 were faster | the tail that one parcel in a hundred reaches |
| p99.9 | 999 in 1,000 were faster | the rare outliers |
| max | the slowest parcel | the worst case in this run |

A run of 10,000 parcels puts 100 above p99, 10 above p99.9 and one at the max. Deeper percentiles rest on fewer samples.

### Why the report never carries a mean

A mean collapses a distribution into one value. In the bimodal workload it would fall between the two modes and describe neither group. It would also move whenever the slow fraction moved. Every report in this book therefore holds percentiles and a maximum. A time-average appears only in Chapter 2, labelled as a modelling input for Little's Law.

### The budget is a tail requirement

The scan-to-divert deadline applies to every parcel. A median well inside the budget says nothing about the parcels past it. The requirement has the form "p99.9 of scan-to-divert is below the deadline minus margin", and the percentile is set by how many mis-sorts the operation tolerates. At 1 kHz, one parcel in 1,000 is one mis-sort per second. The median works as a health indicator. As a requirement it's poor.

## How the code works

Each language has one executable with three variants selected by `--variant`: `per-parcel`, `batch-32` and `bimodal-1pct`. They share one receive path and differ only in the handler.

### The handler hook

The common line consumer owns the receive path: it binds a UDP socket, parses each `ParcelEvent`, tracks sequence gaps and records latency. Between "received" and "done" it calls one function, the handler, for every new parcel. The handler does the variant's work and reports the parcel done through a `Completion`, which records `done - intended_emit` when called. The simulator stamps `intended_emit_ns` with the scheduled time, so a late send doesn't hide a late handling.

A handler may report a parcel done inside the call or later. That's the whole contract: one loop serves a consumer that handles parcels one by one and one that holds them. The listings are `consumer.hpp`, `loop.py`, `EventHandler.java` and `EventReceiver.java` under `examples/common/line-simulator/consumers/`.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
/// The per-parcel hook: `handler(const v1::ParcelEvent&, Completion&)`, called
/// once per new (in-order or after a gap) parcel, after the loop has parsed and
/// sequence-checked it. The handler must call `done.complete(...)` for every
/// parcel, now or later. If it also has `drain(Completion&)` the loop calls it
/// once when the run ends, to complete what it still holds.
template <class H>
concept ParcelHandler = requires(H& h, const v1::ParcelEvent& ev, Completion& done) { h(ev, done); };
```

```python
type Handler = Callable[[ParcelEvent, Completion], None]
"""The per-parcel hook: called once per new parcel with the (reused, so do not keep it)
event and the ``Completion``. It must complete every parcel, now or later."""

type Drain = Callable[[Completion], None]
"""Optional: called once when the run ends, to complete the parcels a handler still holds."""
```

```java
public interface EventHandler<E> {
    // ...
    void onParcel(E event, Completion done);
    // ...
    default void drain(Completion done) {
    }
}
```

C++ states the contract as the `ParcelHandler` concept, Python as the `Handler` and `Drain` type aliases, Java as `ParcelHandler`, which extends `EventHandler<ParcelEvent>`, whose `drain` default holds nothing. The end-of-run hook serves a handler holding parcels.

The loop (`EventReceiver.java` in Java) calls the handler right after it parses the datagram and checks the sequence number:

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
    done.begin(ev.seq());
    handler(static_cast<const v1::ParcelEvent&>(ev), done);
  }
  if constexpr (requires { handler.drain(done); }) handler.drain(done);
```

```python
        done.seq = event.seq
        handler(event, done)
    if drain is not None:
        drain(done)
```

```java
            Completion.begin(seqCell, seq);
            handler.onParcel(event, completion);
```

`begin` and `done.seq` tell `Completion` which sequence number is in flight, for its negative-latency error. Java's `begin` is static and takes a seq cell cached once, so the receive thread never touches the owner's counters. After the loop ends, C++ calls `drain` only if the handler type has one (`if constexpr`), Python calls the `drain` argument unless it is `None`, and Java's `run` calls `handler.drain`.

The C++ and Python loops reuse one event object per datagram, so a handler that holds parcels must copy what it keeps. Java parses a fresh event.

### The three handlers

The per-parcel handler is a lane lookup followed by `done.complete(ev)` (Python passes the intended time and `now()`); the clock is read after the work. The batch and bimodal handlers are in `examples/01-latency-distribution/`: `cpp/src/latdist.cpp`, `latdist-py/src/lowlat_latdist/handlers.py` and `java/src/main/java/io/patterncatalyst/lowlat/latdist/Latdist.java`.

**Batch-32 and deferred completion.**

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
// Holds parcels until `size` have arrived, then completes them all at one done time.
class Batch {
 public:
  explicit Batch(std::size_t size) : size_(size) { pending_.reserve(size); }

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    const std::string& barcode = ev.barcode();
    Pending p{.intended_ns = ev.intended_emit_ns(), .barcode = {}};
    if (barcode.size() != p.barcode.size()) throw std::invalid_argument("SSCC must be 18 ASCII digits");
    std::ranges::copy(barcode, p.barcode.begin());  // fixed buffer: no allocation per parcel
    pending_.push_back(p);
    if (pending_.size() >= size_) flush(done);
  }
  void drain(line::Completion& done) { flush(done); }  // a partial last batch still gets handled
  [[nodiscard]] std::string notes() const { return std::format("; batch={}", size_); }

  unsigned lane_sink = 0;

 private:
  struct Pending {
    std::int64_t intended_ns;
    std::array<char, 18> barcode;  // an SSCC-18: exactly 18 digits, held in place
  };

  void flush(line::Completion& done) {
    for (const auto& p : pending_) lane_sink += line::lane_for(std::string_view{p.barcode});
    const auto done_ns = monotonic_ns();  // one completion time for the whole batch
    for (const auto& p : pending_) done.complete(p.intended_ns, done_ns);
    pending_.clear();
  }

  std::size_t size_;
  std::vector<Pending> pending_;
};
```

```python
class Batch:
    """Hold parcels until ``size`` have arrived, then handle and complete them together."""

    def __init__(self, size: int) -> None:
        self.size = size
        self._pending: list[tuple[int, str]] = []  # (intended_emit_ns, barcode)

    def __call__(self, event: ParcelEvent, complete: Completion) -> None:
        self._pending.append((event.intended_emit_ns, event.barcode))
        if len(self._pending) >= self.size:
            self.drain(complete)

    def drain(self, complete: Completion) -> None:
        """Complete what is held; also the loop's end-of-run hook for a partial last batch."""
        for _, barcode in self._pending:
            lane_for(barcode)
        done_ns = now()  # one completion time for the whole batch
        for intended_ns, _ in self._pending:
            complete(intended_ns, done_ns)
        self._pending.clear()

    def notes(self) -> str:
        return f"; batch={self.size}"
```

```java
    /** Hold parcels until {@code size} have arrived, then complete them together. */
    private static final class Batch extends Policy {
        private record Pending(long intendedNs, String barcode) {
        }

        private final int size;
        private final List<Pending> pending;

        Batch(int size) {
            this.size = size;
            this.pending = new ArrayList<>(size);
        }

        @Override
        public void onParcel(ParcelEvent event, Completion done) {
            pending.add(new Pending(event.getIntendedEmitNs(), event.getBarcode()));
            if (pending.size() >= size) {
                flush(done);
            }
        }

        @Override
        public void drain(Completion done) { // a partial last batch still gets handled
            flush(done);
        }

        private void flush(Completion done) {
            for (Pending p : pending) {
                laneSink += Lanes.laneOf(p.barcode());
            }
            long doneNs = System.nanoTime(); // one completion time for the whole batch
            for (Pending p : pending) {
                done.complete(p.intendedNs(), doneNs);
            }
            pending.clear();
        }

        @Override
        String notes() {
            return "; batch=" + size;
        }
    }
```

Each call stores the intended emission time and the barcode. The 32nd call runs `flush` (`drain` in Python), which looks up all 32 lanes, reads the clock once and completes every held parcel with that time. The first parcel's latency is its 31 ms wait plus the handling, which is what Figure 1.1 shows. A run of 10,000 parcels is 312 full batches and 16 parcels over, so `drain` matters: without it the last 16 parcels would never be recorded.

**Bimodal and the slow branch.**

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
// Per-parcel, but one in `every` takes the slow path: a busy loop, not a sleep.
class Bimodal {
 public:
  Bimodal(std::uint64_t every, std::int64_t slow_us) : every_(every) {
    iterations_ = calibrate(slow_us);
    const auto t0 = monotonic_ns();
    (void)spin(iterations_);
    measured_ns_ = monotonic_ns() - t0;
    std::println("calibrated slow path: {} iterations = {:.1f} us", iterations_,
                 static_cast<double>(measured_ns_) / 1e3);
  }

  void operator()(const line::v1::ParcelEvent& ev, line::Completion& done) {
    lane_sink += line::lane_for(ev.barcode());
    if (ev.seq() % every_ == 0) {
      lane_sink += static_cast<unsigned>(spin(iterations_));  // the re-lookup: real CPU work
      ++slow_count_;
    }
    done.complete(ev);
  }
  [[nodiscard]] std::string notes() const {
    return std::format("; slow_every={}; slow_parcels={}; slow_path_us={:.1f}; busy loop, not sleep", every_,
                       slow_count_, static_cast<double>(measured_ns_) / 1e3);
  }

  unsigned lane_sink = 0;

 private:
  std::uint64_t every_;
  std::uint64_t iterations_ = 0;
  std::int64_t measured_ns_ = 0;
  std::uint64_t slow_count_ = 0;
};
```

```python
class Bimodal:
    """Per-parcel, but one parcel in ``every`` runs the slow path: a busy loop, not a sleep."""

    def __init__(self, every: int, slow_us: int) -> None:
        self.every = every
        self.slow_count = 0
        self.iterations = calibrate(slow_us)
        t0 = now()
        spin(self.iterations)
        self.measured_ns = now() - t0
        print(
            f"calibrated slow path: {self.iterations} iterations = {self.measured_ns / 1e3:.1f} us",
            flush=True,
        )

    def __call__(self, event: ParcelEvent, complete: Completion) -> None:
        lane_for(event.barcode)
        if event.seq % self.every == 0:
            spin(self.iterations)  # the re-lookup: real CPU work, not a sleep
            self.slow_count += 1
        complete(event.intended_emit_ns, now())

    def notes(self) -> str:
        return (
            f"; slow_every={self.every}; slow_parcels={self.slow_count}; "
            f"slow_path_us={self.measured_ns / 1e3:.1f}; busy loop, not sleep"
        )
```

```java
    /** Per-parcel, but one in {@code every} takes the slow path: a busy loop, not a sleep. */
    private static final class Bimodal extends Policy {
        private final long every;
        private final long iterations;
        private final long measuredNs;
        private long slowCount;

        Bimodal(long every, long slowUs) {
            this.every = every;
            this.iterations = BusyWork.calibrate(slowUs);
            long t0 = System.nanoTime();
            BusyWork.spin(iterations);
            this.measuredNs = System.nanoTime() - t0;
            System.out.printf("calibrated slow path: %d iterations = %.1f us%n", iterations, measuredNs / 1e3);
        }

        @Override
        public void onParcel(ParcelEvent event, Completion done) {
            laneSink += Lanes.laneOf(event.getBarcode());
            if (event.getSeq() % every == 0) {
                laneSink += BusyWork.spin(iterations); // the re-lookup: real CPU work
                slowCount++;
            }
            done.complete(event);
        }

        @Override
        String notes() {
            return "; slow_every=%d; slow_parcels=%d; slow_path_us=%.1f; busy loop, not sleep"
                    .formatted(every, slowCount, measuredNs / 1e3);
        }
    }
```

The test is `seq % every == 0` with `every` set to 100. The sequence number is deterministic, so exactly 100 of 10,000 parcels are slow (`slow_parcels=100` in the notes). The slow branch runs before `complete` reads the clock, so the slow parcel's latency includes its re-lookup. Parcels that arrive during the spin wait in the socket buffer until the handler returns, and their latency runs from their own intended emission time, so they carry the wait. That's why more than 1 % of parcels are slow in latency terms.

C++ and Java add the lane lookup result to `lane_sink` (`laneSink`) and print it, because an optimiser can remove a lookup nothing reads.

### Why the C++ handler is a template parameter

`consume_with` is declared `template <ParcelHandler Handler>` and takes the handler by reference. A `std::function` or a virtual base class would put an indirect call on every parcel that the compiler cannot inline, and a `std::function` holding a stateful handler such as `Batch` can also allocate. Both costs would fall inside every recorded latency.

With a template parameter the compiler sees the concrete handler type and inlines the call into the loop, so the hook adds no indirect call and no allocation to the measured path. `std::sort` takes its comparator the same way. The price is one loop instantiation per handler type, three here: code size, not latency. Java gets the same result from the JIT, because the call site is monomorphic. Python has no equivalent; dispatch cost is part of the Python column.

### The calibrated busy loop

The slow path, in `cpp/src/latdist.cpp`, `latdist-py/src/lowlat_latdist/work.py` and `java/src/main/java/io/patterncatalyst/lowlat/latdist/BusyWork.java`, is a busy CPU loop, not a sleep. A sleep yields the core, so the cost shows up as scheduler noise. A real re-lookup holds the core and the parcels behind it queue; the loop reproduces that.

{% include codetabs.html langs="C++|Python|Java" %}

```cpp
std::uint64_t spin(std::uint64_t iterations) noexcept {
  std::uint64_t x = 0x9e3779b97f4a7c15ULL;
  for (std::uint64_t i = 0; i < iterations; ++i) {
    x = x * 6364136223846793005ULL + 1442695040888963407ULL;
    asm volatile("" : "+r"(x));
  }
  return x;
}

// Iterations of spin() that take `target_us`. Double the count until a run lasts at
// least 20 ms (long enough to swamp the clock read), then time five more runs and keep
// the fastest: a run that was preempted on a busy host measures the scheduler, not the loop.
std::uint64_t calibrate(std::int64_t target_us) {
  std::uint64_t n = 1 << 12;
  double best_iter_per_ns = 0;
  for (int extra = 0; extra < 5;) {
    const auto t0 = monotonic_ns();
    (void)spin(n);
    const auto took_ns = monotonic_ns() - t0;
    best_iter_per_ns = std::max(best_iter_per_ns, static_cast<double>(n) / static_cast<double>(took_ns));
    if (took_ns < 20'000'000) n *= 2;
    else ++extra;
  }
  return static_cast<std::uint64_t>(best_iter_per_ns * static_cast<double>(target_us) * 1000.0);
}
```

```python
_MASK = (1 << 64) - 1


def spin(iterations: int) -> int:
    """A dependent multiply-add chain: each step needs the previous result."""
    x = 0x9E3779B97F4A7C15
    for _ in range(iterations):
        x = (x * 6364136223846793005 + 1442695040888963407) & _MASK
    return x


def calibrate(target_us: int) -> int:
    """Iterations of ``spin`` taking ``target_us``.

    Double the count until a run lasts 20 ms, then time five more runs and keep the
    fastest: a run preempted on a busy host measures the scheduler, not the loop.
    """
    n = 1 << 12
    best = 0.0  # iterations per ns
    extra = 0
    while extra < 5:
        t0 = time.monotonic_ns()
        spin(n)
        took = time.monotonic_ns() - t0
        best = max(best, n / took)
        if took < 20_000_000:
            n *= 2
        else:
            extra += 1
    return int(best * target_us * 1000)
```

```java
    /** Written by every {@link #spin}; the volatile store makes the loop's result observable to the JIT. */
    private static volatile long sink;

    private BusyWork() {
    }

    /** A dependent multiply-add chain: each step needs the previous result. */
    static long spin(long iterations) {
        long x = 0x9E3779B97F4A7C15L;
        for (long i = 0; i < iterations; i++) {
            x = x * 6364136223846793005L + 1442695040888963407L;
        }
        sink = x;
        return x;
    }

    /**
     * Iterations of {@link #spin} that take {@code targetUs}. Doubles the count until a run lasts
     * 20 ms, then times eight more runs and keeps the fastest: the early runs are interpreted or
     * C1-compiled (the JIT's C2 code is faster), and a run preempted on a busy host measures the
     * scheduler, not the loop.
     */
    static long calibrate(long targetUs) {
        long n = 1 << 12;
        double best = 0; // iterations per ns
        for (int extra = 0; extra < 8;) {
            long t0 = System.nanoTime();
            spin(n);
            long tookNs = System.nanoTime() - t0;
            best = Math.max(best, (double) n / tookNs);
            if (tookNs < 20_000_000L) {
                n *= 2;
            } else {
                extra++;
            }
        }
        return (long) (best * targetUs * 1000);
    }
```

`spin` is a dependent multiply-add chain. Each step needs the previous result, so the CPU can't vectorise it and the compiler can't fold it into a closed form. Keeping the result observable is the one place the three languages diverge. C++ uses an empty `asm volatile("" : "+r"(x))`, which tells the compiler the register is read and modified. Java writes the final value to a `volatile` field, which the JIT must honour. Python needs neither; the `& _MASK` mask keeps the integer at 64 bits so each step costs the same.

`calibrate` doubles `n` until one run lasts 20 ms and then keeps the best rate of further runs, because a preempted run measures the scheduler. Java takes eight extra runs where C++ and Python take five, because its first runs are interpreted or C1-compiled and the C2 code is faster. The handler then times the loop once and writes it to the report's `notes` as `slow_path_us`. That measured value, not the 2,000 us target, is what the verification compares against.

## Measure

Run the example from the repository root:

```bash
examples/01-latency-distribution/verify.sh
```

It builds all three consumers, runs each variant at 1 kHz for 10 s (10,000 parcels), writes nine reports and asserts the criteria. The `README.md` lists the flags.

All numbers below come from the committed runs `r02-run1..3` in `examples/01-latency-distribution/results/`. Ranges are the minimum and maximum across the three runs and the three languages. The earlier failed check comes from git history.

### A. Equal throughput, different median

Throughput stays at about 1,000 parcels per second: per-parcel runs measure 1,000.1 to 1,003.4 per second and batch-32 runs 1,003.1 to 1,003.4. The C++ and Python batch figures are 0.3 % higher because the first completion falls 31 ms into the run, which shortens the measured span; Java's differ by under 0.16 %.

| Variant | p50 across runs and languages |
|---|---|
| per-parcel | 85 to 188 us |
| batch-32 | 15.2 to 15.4 ms |

Against the same language and run, the batch median is 82 to 180 times larger. The batch p99 is 31.1 to 31.2 ms in all nine batch runs, the fill wait plus handling.

### B. One parcel in a hundred

In the bimodal runs the calibrated slow path measured 2.0 to 2.1 ms (`slow_path_us` 1,993.9 to 2,076.8). The medians stayed in the fast mode, 95 to 232 us. The tail didn't: p99 was 2.1 to 6.8 ms, and 2.6 to 6.8 % of bimodal parcels took 1 ms or more, counted from the stored histograms, although only 1 % ran the slow path.

The C++ bimodal row of `r02-run2`, from its stored report, shows the shape. It is also the tightest case for the p99 criterion: p99 is 22 times its own p50 against a bound of 20, a margin of 1.12:

| p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|
| 95.4 us | 165.2 us | 2,140.2 us | 6,012.9 us | 7,110.7 us |

p50 and p90 differ by 69.8 us, p90 and p99 by more than 1.9 ms. p99.9 and max extend past the slow-path length because of queueing.

The Java runs show a second tail effect. Their notes record `JIT not warmed: first parcels included`, and per-parcel p99.9 reaches 8.3 to 23.5 ms while C++ stays below 0.5 ms. Chapter 5, *What the JVM costs: allocation, escape analysis, JIT warmup vs AOT*, treats the cause; p99.9 exposed it and p50 did not.

### The median itself moved

The per-parcel median isn't a constant of the code. It moved between runs of the same binary. C++ per-parcel p50 was 164 us in `r02-run1`, 157 us in `r02-run2` and 160 us in `r02-run3`; Python went 156, 185 and 154 us; Java 112, 188 and 85 us. Nothing in the program changed, yet one binary's median moved by up to 2.2 times. Across the nine per-parcel runs on this untuned host, p50 spread from 85 to 188 us. An interleaved A/B of the trees before and after the last code change, on the Chapter 0 and 5 consumers, found p50 varying alike in both (`examples/05-jvm-costs/results/r02-ab/`); the cause is unidentified.

Variants in one run differ too: in `r02-run2` the C++ per-parcel p50 was 157 us and the bimodal p50, which does strictly more work, 95 us.

That variation decides how a check is written. An earlier set, committed at `1811055`, required the bimodal median to stay under twice the per-parcel median from a different consumer run, and its run 2 failed for C++ (got 158335 ns, need < 147838).

`verify.sh` therefore compares within one run: the bimodal p50 must be under a quarter of the same run's measured `slow_path_us`. In `r02-run1..3` that threshold was 498 to 519 us against bimodal medians of at most 232 us, and each run's `verify.log` records all 12 criteria passing.

## Cross-check

Each criterion pairs the percentiles with an independent measurement. Throughput comes from the span between the first and last completion timestamps, not from the latency percentiles. The slow-path duration comes from timing the loop directly, not from the histogram. Agreement across three languages in three runs shows the effect belongs to the handling policy, not one runtime.

## What you learned

- Throughput and latency are separate. Batching 32 parcels at 1 kHz left throughput within 1 % and moved the median from 85 to 188 us up to 15.2 to 15.4 ms.
- A mixed workload has no single latency. With one slow parcel in 100, p50 stayed at 95 to 232 us, p99 reached 2.1 to 6.8 ms, and 2.6 to 6.8 % of parcels took 1 ms or more.
- Report p50, p90, p99, p99.9 and max, never a mean, and tie the scan-to-divert requirement to a tail percentile.
- A shared receive loop takes a handler that reports each parcel done, now or later. One that holds parcels needs a drain hook. In C++ the handler is a template parameter, so the hook adds no indirect call.
- Simulate a slow path with a calibrated busy loop, not a sleep.
- A median isn't stable on an untuned host. Compare within one run and record the profile.

Chapter 2 models these effects with Little's Law and Amdahl's Law.

## For deeper coverage

- Enberg, *Latency* (Manning), as further reading.
- Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*, in Part 1: how many samples a percentile needs, and coordinated omission.
- Chapter 2 in Part 1: Little's Law and Amdahl's Law as modelling inputs.
- Chapter 5 in Part 2: the Java warm-up tail.
- Part 5: the CPU governor, idle states and tuned profiles behind the median's movement.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` runs all nine consumer runs and asserts `count` 10,000, `dropped` 0 and a passing `lowlat-report check` for every report, and, for each of C++, Python and Java: per-parcel and batch-32 throughput within 1 %; batch-32 p50 at least 10x per-parcel p50; bimodal-1pct p99 at least 20x its own p50; bimodal-1pct p50 under a quarter of the same run's measured slow path. All 12 criteria held in each of `r02-run1..3` (`verify.log`).*
