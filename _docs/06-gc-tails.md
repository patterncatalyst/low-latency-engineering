---
title: "GC for tails: Generational ZGC and Shenandoah"
order: 6
part: "The Managed-Runtime Question"
description: "On a 4 GB heap with a 1.8 GB live set, the maximum GC pause is 158-162 ms under Parallel and 0.020-0.039 ms under Generational ZGC, and a heap at 1.05 times the live set turns ZGC's p99.9 from 0.147-0.149 ms into 50.4-113.0 ms. Bare-metal, untuned host."
duration: 50 minutes
---

## Learning objectives

By the end of this chapter you can:

- Say what each JDK 25 collector stops and read each one's maximum pause from a flight recording.
- Explain why a concurrent collector with too little headroom stalls the allocating thread, and why that stall is not a GC pause.
- Record GC pauses from inside the process, so setup collections are not counted with the run.
- Explain how CPython cycles and `gc.freeze()` change what the collector walks, and how inline and deferred destruction differ in C++.
- Check a pause claim against the flight recording and the unified GC log.

## Why this matters

A parcel is scanned and must be diverted 480 ms later, 1.2 m down the belt at 2.5 m/s. The belt does not wait for the tracker. When the tracker stops, parcels keep arriving at 10 kHz, so every millisecond of pause puts 10 more parcels behind it, each charged for the wait, as Chapter 3 showed. Chapter 5, *What the JVM costs: allocation, escape analysis, JIT warmup vs AOT*, covered the pause a cold JVM adds; the pauses a warm JVM adds at any time are the subject here.

The tracker keeps a 1.8 GB live set and allocates scan history at about 400 MB/s. The same bytecode runs under four collectors; Python and C++ lanes reclaim memory without a tracing collector.

The code is in `examples/06-gc-tails/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="06-collector-pauses" alt="A tracker at 10 kHz for 30 s with a 4 GB pre-touched heap feeds four collectors, each with the maximum GC pause read from JFR: stop-the-world Parallel, where all threads stop and the heap is walked, 158-162 ms; G1 with stop-the-world evacuation, 21.4-22.0 ms; Generational ZGC (amber) with concurrent mark and relocate, 0.020-0.039 ms; and generational Shenandoah with concurrent evacuation, 0.61-0.81 ms." caption="Figure 6.1 — Same bytecode and allocation, different collector: the maximum pause runs from 158-162 ms under Parallel to 0.020-0.039 ms under ZGC." %}

## Concept

### What each collector stops

A collector bounds the tail in two ways: how long it stops the application, and whether it keeps up with the allocation rate.

- **Parallel** (`-XX:+UseParallelGC`) stops every thread for every collection, and a full collection walks the live set. All 13 pauses in the measured window were full collections.
- **G1** (`-XX:+UseG1GC`) marks concurrently and evacuates regions in stop-the-world pauses.
- **Generational ZGC** (`-XX:+UseZGC`) is the only ZGC mode in JDK 25 (JEP 490). Marking, relocation and reference processing run concurrently with the application; only short phase pauses stop it.
- **Generational Shenandoah** (`-XX:+UseShenandoahGC -XX:ShenandoahGCMode=generational`) is a product feature in JDK 25 (JEP 521) and evacuates concurrently.

The shift manifest is a ring: each new parcel overwrites the oldest entry, so the live set stays constant while overwritten entries die in the old generation.

### Headroom

A concurrent collector runs beside the application, and both draw on the same free heap. If the application allocates faster than a cycle frees memory, free heap reaches zero and the allocating thread waits. That is an allocation stall: a pause that does not appear as a GC pause. ZGC reports it as the `jdk.ZAllocationStall` event, which the example counts apart from `jdk.GCPhasePause`. The undersized variant runs ZGC with the heap at 1.05 times the measured live set.

{% include excalidraw.html file="06-headroom-stall" alt="Two lanes with the same handler allocating about 400 MB/s of garbage. With a 4 GB heap and a live set well under it, ZGC cycles stay ahead of the rate: 0 allocation stalls and p99.9 of 0.147-0.149 ms. With the heap at 1.05 times the live set, free memory runs out and an amber path leads to an allocation stall where the thread waits; the run records 530-977 stalls with p99.9 of 50.4-113.0 ms." caption="Figure 6.2 — A concurrent collector needs headroom. At 1.05 times the live set, ZGC stalls the allocating thread 530-977 times and p99.9 rises from 0.147-0.149 ms to 50.4-113.0 ms." %}

The shape came from a sweep: calibration runs on 2026-10-22, one run per row, not committed measurement runs, reproducible with `SWEEP=1 examples/06-gc-tails/verify.sh`. ZGC with a fixed heap gave 0 allocation stalls at 4 GB and down to 1.10 times the live set, 14 stalls (longest 50.5 ms) at 1.075 times, and 884 stalls (longest 98.2 ms) at 1.05 times. At 1.30 times and a doubled allocation rate, ZGC gave 0 stalls and ran more minor collections instead (270 against 162). Headroom, not allocation rate, is the lever, and the transition is sharp.

### Pre-touch and huge pages

Every Java variant pre-touches a fixed heap (`-Xms` = `-Xmx`, with `-XX:+AlwaysPreTouch`), 4 GB except `undersized-heap`: no heap growth, and no first-touch page faults inside the window. The `thp` variant adds `-XX:+UseTransparentHugePages` to ZGC to request huge pages. The OS refused them for ZGC's shared-memory heap, and the JVM logged `Large Page Support: Disabled (OS enforced)` in every run, which `verify.sh` prints as `thp: large pages Disabled (OS enforced) (GC log), shmem_enabled=never`. So `thp` ran on 4 KB pages, effectively a second ZGC run, and the book draws no conclusion about huge pages. Huge pages for ZGC are versioned configuration in Part 5, *The OS, Isolation & the Network Edge*, in the lab VM.

### Reclaiming in C++ and Python

The other two runtimes decide where the frees run.

{% include excalidraw.html file="06-refcount-vs-tracing" alt="Three lanes in the order C++, Python, Java, each with its end-to-end p99.9 latency. C++: the owner frees, so bulk-free destroys a wave on the hot thread (2.13-2.31 ms) while deferred-free hands it to a reclaimer thread (0.139-0.145 ms). Python: refcounts free at once and a generational cycle collector finds cycles; cyclic-garbage runs 9 gen-2 collections (138-141 ms) and frozen, with no cycles and gc.freeze(), runs 0 (0.166-0.170 ms). Java: tracing collectors mark what is live; stop-the-world Parallel is 153-154 ms and ZGC 0.147-0.149 ms." caption="Figure 6.3 — C++ frees where the owner says, CPython frees by reference count and sweeps cycles in generations, and the JVM traces from roots; each has a variant that keeps the reclaim cost off the latency-critical path." %}

CPython frees an object the moment its reference count reaches zero. A reference cycle never does, so a generational cycle collector finds it (CPython 3.14.8 here; 3.14.0 to 3.14.4 shipped an incremental collector that 3.14.5 reverted). In `cyclic-garbage` every parcel's scan history is a cycle: the parcel lists its samples and each sample points back at it. By the time the parcel leaves the belt the cycle is in the oldest generation, so only a generation-2 collection, which walks every tracked object that is not frozen, frees it. The `frozen` variant removes the cycles and calls `gc.freeze()` after setup. It ran 0 collections in every generation: refcounting frees each parcel at once, so generation 0 never reaches its threshold, and the frozen setup objects would be skipped if it did.

C++ has no collector; the cost is `free()`. Destroying a wave of 10,000 manifest entries on the hot thread delays every parcel that arrives meanwhile. `bulk-free` destroys the wave inline, `deferred-free` hands it to a reclaimer thread, and `no-free` keeps dead waves until the run ends, as a control.

## How the code works

### The handler's memory in each runtime

The Java and Python handlers look up the lane, build the scan history, overwrite a manifest entry and update the in-flight table; the C++ handler builds manifest entries in waves. In Java that is `Tracker.track` in `java/src/main/java/io/patterncatalyst/lowlat/gctails/Tracker.java`, shown with the `scan` method that creates the garbage. In C++ the choice is in `Tracker::close_wave` in `cpp/src/tracker.cpp`. In Python it is `Tracker.track` in `gctails-py/src/lowlat_gctails/tracker.py`.

{% include codetabs.html langs="Java|C++|Python" %}

```java
    int track(String barcode, long seq, int weightG) {
        int lane = Lanes.laneOf(barcode);
        ScanSample[] history = scan(seq);
        long checksum = checksum(history);
        manifest[(int) (cursor++ % manifest.length)] = entry(barcode, seq, lane, weightG);
        int keep = Math.min(settings.retainedSamples(), history.length);
        inFlight.put(barcode, new ParcelState(seq, lane, checksum, Arrays.copyOf(history, keep)));
        sink += checksum;
        return lane;
    }
// ...
    private ScanSample[] scan(long seq) {
        ScanSample[] samples = new ScanSample[samplesPerParcel];
        for (int i = 0; i < samples.length; i++) {
            byte[] raw = new byte[Settings.SAMPLE_BYTES];
            raw[0] = (byte) (seq + i);
            raw[raw.length - 1] = (byte) (seq >>> 8);
            samples[i] = new ScanSample(seq * 31 + i, i, raw);
        }
        return samples;
    }
```

```cpp
void Tracker::close_wave() {
  Wave dead = std::move(previous_);
  previous_ = std::move(current_);
  current_ = Wave{};
  current_.reserve(settings_.wave_parcels);
  ++waves_closed_;
  switch (policy_) {
    case Policy::bulk_free:
      destroyed_inline_ += dead.size();  // `dead` is destroyed when this function returns, on this thread
      break;
    case Policy::deferred_free:
      reclaimer_->submit(std::move(dead));
      break;
    case Policy::no_free:
      retained_entries_ += dead.size();
      retained_.push_back(std::move(dead));
      break;
  }
}
```

```python
    def track(self, barcode: str, seq: int) -> int:
        """Handle one parcel: lane lookup, scan history, manifest line, in-flight table."""
        lane = lane_for(barcode)
        state = ParcelState(seq, lane)
        samples = [
            ScanSample(seq * 31 + i, i, bytes(SAMPLE_BYTES))  # a fresh buffer per read
            for i in range(self.settings.samples)
        ]
        if self.cyclic:
            for sample in samples:
                sample.parent = state  # state -> samples -> sample -> state
        state.samples = samples
        self._ring[self._cursor % len(self._ring)] = self._entry(barcode, seq, lane)
        self._cursor += 1
        self._in_flight[barcode] = state
        if len(self._in_flight) > self.settings.in_flight_parcels:
            self._in_flight.popitem(last=False)  # diverted: the eldest leaves the belt
        return lane
```

The Java handler never frees anything. `scan` allocates samples, each with a fresh `byte[]`, and `track` keeps a few in the `ParcelState` that goes into the `LinkedHashMap`; the rest is garbage once `checksum` returns. The manifest write replaces an old `ManifestEntry`. Nothing in the code mentions the collector; the collector decides what it costs.

In Python, `self.cyclic` is the one branch that matters: each sample gets `parent = state`, closing the cycle. Without it, the parcel dies when the table drops it.

In C++, `close_wave` makes the ownership decision. `Wave dead` owns the oldest wave. In `bulk_free` it is destroyed when the function returns, on the receive thread; in `deferred_free` it is moved into the reclaimer's queue and `Reclaimer::run` destroys it on its own thread. There is no collector to configure: ownership is explicit, and so is the place the frees run.

### Measuring pauses without touching the parcel path

C++ has no collector to observe, which is why this group has no C++ tab. In Java, `Flight.during` in `Flight.java` runs the measured work inside a flight recording that the program starts itself. In Python, `GcPauseLog` in `gctails-py/src/lowlat_gctails/pauses.py` is a `gc.callbacks` hook.

{% include codetabs.html langs="Java|Python" %}

```java
    static <T> T during(Path file, Run<T> run) throws IOException {
        Recording recording;
        try {
            recording = new Recording(Configuration.getConfiguration("default"));
        } catch (ParseException e) {
            throw new IOException("cannot read the default JFR settings", e);
        }
        try (recording) {
            recording.setDestination(file);
            recording.start();
            try {
                return run.call();
            } finally {
                recording.stop(); // writes the destination file
            }
        }
    }
```

```python
    def __call__(self, phase: str, info: dict[str, int]) -> None:
        if phase == "start":
            self._started_ns = time.monotonic_ns()
            return
        i = self._count
        self._count = i + 1
        if i < self._capacity:
            self._duration_ns[i] = time.monotonic_ns() - self._started_ns
            self._generation[i] = info["generation"]
            self._collected[i] = info["collected"]
# ...
    def __enter__(self) -> Self:
        gc.callbacks.append(self)
        return self
```

`-XX:StartFlightRecording` records from JVM start, so the manifest build, the warm-up and the forced live-set collection would be counted with the run. `Flight.during` starts the recording after those and stops it in a `finally`, because `stop()` writes the file.

The Python callback does the least it can on the thread that triggers a collection: a clock read and stores into `array` buffers allocated before the run, because a callback that allocated would add to what it measures.

For the frozen variant, setup in `cli.py` ends with a collection and a freeze:

```python
    frozen = args.variant == "frozen"
    tracker = Tracker(settings_from(args), cyclic=not frozen)
    tracker.populate()
    tracker.warm_up(args.warmup)
    gc.collect()  # the setup's garbage is not the run's
    if frozen:
        gc.freeze()  # everything alive now is permanent: later collections never walk it
```

`gc.collect()` clears the setup's garbage, and `gc.freeze()` moves everything alive into a permanent generation that later collections skip. `cyclic-garbage` never freezes, so its collections walk the manifest.

### The flags

`gc_flags` in `verify.sh` maps each variant to its collector, and the heap flags come from the README's by-hand command.

```bash
# gc_flags VARIANT: the JVM's collector flags for a Java variant (GC_FLAGS) and heap in MB (HEAP).
gc_flags() {
  HEAP=$HEAP_MB
  case $1 in
    stop-the-world) GC_FLAGS=(-XX:+UseParallelGC) ;;
    g1) GC_FLAGS=(-XX:+UseG1GC) ;;
    zgc | jfr-off) GC_FLAGS=(-XX:+UseZGC) ;;
    shenandoah-gen) GC_FLAGS=(-XX:+UseShenandoahGC -XX:ShenandoahGCMode=generational) ;;
    shenandoah) GC_FLAGS=(-XX:+UseShenandoahGC) ;;
    undersized-heap) GC_FLAGS=(-XX:+UseZGC) HEAP=$UNDERSIZED_MB ;;
    thp) GC_FLAGS=(-XX:+UseZGC -XX:+UseTransparentHugePages) ;;
    *) die "unknown Java variant $1" ;;
  esac
}
```

```bash
java -Xms4g -Xmx4g -XX:+AlwaysPreTouch -XX:+UseZGC -jar examples/06-gc-tails/java/target/gc-tails-java.jar \
    --variant zgc --expect 300000 --report /tmp/zgc.json --jfr /tmp/zgc.jfr &
```

For `undersized-heap`, `HEAP=$UNDERSIZED_MB` is computed from the live set `verify.sh` measures first.

## Measure

Run the example from the repository root:

```bash
examples/06-gc-tails/verify.sh
```

It needs 4 GB for a heap and refuses to start while a `lowlat-*` VM is running; `ALLOW_BUSY=1` measures anyway, with noisier numbers. `RECHECK=results/<run-id>` evaluates the criteria on a committed run without running anything. It runs 13 consumers one at a time, each at 10 kHz for 30 s (300,000 parcels), and asserts the criteria below.

Profile for every number below: bare-metal host, Intel 8-core/16-thread laptop CPU, 16 logical CPUs, Fedora 44 kernel 7.2.11-200.fc44 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`, THP `madvise`, Temurin 25.0.5+8. Ranges are across the three committed runs `r02-run1` to `r02-run3`.

The live set was 1,802 to 1,804 MB, and the receive thread allocated 47,553 to 47,639 B per parcel in the `zgc` reports, about 454 MB/s at 10 kHz. Every report has count 300,000 and dropped 0, passes `lowlat-report check`, and (Java) names its collector and heap in `build.flags` (criterion 6).

**Pauses and the tail.** Maximum GC pause is from the flight recording; p99.9 is the end-to-end latency the line sees.

| Variant | Max GC pause | End-to-end p99.9 |
|---|---|---|
| Parallel | 158 to 162 ms | 152.8 to 153.9 ms |
| G1 | 21.4 to 22.0 ms | 16.5 to 17.0 ms |
| Generational ZGC | 0.020 to 0.039 ms | 0.147 to 0.149 ms |
| Generational Shenandoah | 0.61 to 0.81 ms | 0.164 to 0.183 ms |

Criterion 1 asserts Parallel's maximum is at least 10 ms and 20x ZGC's, ZGC's is under 1 ms, and Generational Shenandoah's is at most a fifth of Parallel's; criterion 2, that ZGC's p99.9 is at most a third of Parallel's. Both held in all three runs.

Under Parallel the p99 is already 130.9 to 131.8 ms, while the p50 is 0.06 ms in every Java variant. Parallel's worst pause spends 158 to 162 ms of the 480 ms budget before the parcel's own work begins.

ZGC's end-to-end maximum is 2.61 to 6.10 ms while its longest GC pause is under 0.04 ms. The maximum is therefore not a GC pause, and the book does not attribute it.

**Headroom.** With the heap at 1.05 times the live set (1,893 to 1,895 MB), `undersized-heap` recorded 530 to 977 allocation stalls, the longest 61.1 to 139.9 ms, and a p99.9 of 50.4 to 113.0 ms against 0.147 to 0.149 ms for right-sized ZGC. Criterion 3 asserts at least one stall and a p99.9 at least 3x right-sized ZGC's. Its GC pauses were 0.053 ms at most, so stalls, not pauses, make the tail.

**Observed only.** Non-generational Shenandoah gave a p99.9 of 0.152 to 0.167 ms and a maximum pause of 0.68 to 0.75 ms. `thp`, which got no huge pages, gave a p99.9 of 0.149 to 0.204 ms and a maximum pause of 0.028 to 0.045 ms. With the recording off, `jfr-off` gave a p99.9 of 0.149 to 0.154 ms, 0.001 to 0.007 ms above ZGC's in the same run. ZGC's spread is 0.002 ms, but `thp`, the same collector on 4 KB pages, spans 0.055 ms, so this set cannot tell that difference from noise.

**Python.** `cyclic-garbage` ran 9 generation-2 collections in the window (99 of generation 1, 1,092 of generation 0), the longest collection 145.8 to 153.7 ms, with a p99.9 of 138.1 to 141.0 ms. `frozen` ran 0 collections with 119,780 objects frozen and a p99.9 of 0.166 to 0.170 ms. Criterion 4 asserts 0 generation-2 collections for `frozen` and at least 1 for `cyclic-garbage`.

**C++.** The `bulk-free` maximum is 3.73 to 3.99 ms and its p99.9 is 2.13 to 2.31 ms, against a `deferred-free` p99.9 of 0.139 to 0.145 ms. Criterion 5 asserts the `bulk-free` maximum is at least 10x the `deferred-free` p99.9. Each run closed 33 waves; 320,000 entries were destroyed inline (`bulk-free`), by the reclaimer (`deferred-free`) or kept (`no-free`). The maxima of `deferred-free` (0.73 to 0.91 ms) and the `no-free` control (0.32 to 1.18 ms) are single operating-system events, observed as a pair; the reclaimer claim rests on criterion 5.

## Cross-check

The unified GC log (`-Xlog:gc*,safepoint`) records the same pauses independently of the flight recording. Three comparisons hold on all three runs.

1. **Event counts.** Each `jdk.GCPhasePause` count in `java-<variant>.jfr-summary.txt` equals the `count` of its `-gc-pause.json`: 13 for Parallel and 16 for G1 in every run, 38, 38 and 41 for ZGC, and 91 for Generational Shenandoah. The `jdk.ZAllocationStall` count of the undersized run equals its `alloc_stalls.count`: 977, 903 and 530.
2. **Pause sizes.** In the Parallel logs, after the `Pause Full (System.gc())` line, the largest `Pause Full (Allocation Failure)` is 161.3, 160.5 and 157.7 ms against the recording's maxima of 161.6, 161.0 and 158.1 ms.
3. **Why the window matters.** The same logs show pauses the recording never saw: a `Pause Full (System.gc())` of 178.2 to 181.4 ms in the Parallel runs and G1 evacuation pauses of up to 72.4 to 73.7 ms while the manifest was built. They happen before the recording starts, which is why `Flight.during` starts it inside the JVM.

Python's cross-check is the callback count: `collections=1200` is 1,092 + 99 + 9. C++'s is the `notes` counters: `destroyed_inline`, `reclaimed` and `retained` are each 320,000 in the variant that owns them and 0 elsewhere.

## What you learned

- On a 1.8 GB live set the maximum pause runs from 158 to 162 ms under Parallel to 0.020 to 0.039 ms under Generational ZGC.
- Headroom decides whether a concurrent collector works: at 1.05 times the live set, ZGC stalled the allocating thread 530 to 977 times, and a GC pause histogram does not show it.
- Record pauses where they happen and exclude setup: a recording started inside the JVM, and a `gc.callbacks` hook that stores into preallocated buffers.
- In CPython, reference cycles cost generation-2 collections that walk the live set; without cycles, refcounting frees each parcel and no collection runs. In C++, the choice is which thread pays for the frees.
- The `thp` variant got no huge pages from the OS, so it shows nothing about them; turning the recording off did not lower ZGC's p99.9.

The next chapter, *Off-heap and lock-free Java: Chronicle, Agrona, the Disruptor, thread affinity*, moves data out of the collector's reach.

## For deeper coverage

- Enberg, *Latency* (Manning), for the broader treatment of tail latency.
- Chapter 5, *What the JVM costs: allocation, escape analysis, JIT warmup vs AOT*, in Part 2, for allocation cost and warm-up.
- Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*, in Part 1, for why a pause charges every parcel behind it.
- Chapter 9, *Eliminating work: allocation, cache locality, false sharing*, in Part 3, for removing allocation in the data structure instead of tuning the collector.
- JEP 490 (ZGC: remove the non-generational mode, JDK 24) and JEP 521 (Generational Shenandoah, product in JDK 25).
- `examples/common/MEASUREMENT.md` for the report format and the checks every report passes.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts the pause bounds (criterion 1), the ZGC against Parallel p99.9 bound (2), the undersized-heap stall and p99.9 (3), Python's generation-2 counts (4), the C++ `bulk-free` against `deferred-free` bound (5), and the report checks (6). Non-generational Shenandoah, `thp`, `jfr-off` and the `deferred-free` and `no-free` maxima are observed only, and the headroom sweep is calibration data. It held on `r02-run1`, `r02-run2` and `r02-run3` on the bare-metal host described above.*
