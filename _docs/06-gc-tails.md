---
title: "GC for tails: Generational ZGC and Shenandoah"
order: 6
part: "The Managed-Runtime Question"
description: "On a 4 GB heap with a 1.8 GB live set, the maximum GC pause is 158-170 ms under Parallel and 0.017-0.036 ms under Generational ZGC, and a heap at 1.05 times the live set turns ZGC's p99.9 from 0.135-0.153 ms into 49.6-134.9 ms. Bare-metal, untuned host."
duration: 50 minutes
---

## Learning objectives

By the end of this chapter you can:

- Say what each JDK 25 collector stops and read each one's maximum pause from a flight recording.
- Explain why a concurrent collector with too little headroom stalls the allocating thread, and why that stall is not a GC pause.
- Record GC pauses from inside the process, so setup collections are not counted with the run.
- Choose between `gc.freeze()` and breaking reference cycles in CPython, and between inline and deferred destruction in C++.
- Check a pause claim against the flight recording and the unified GC log.

## Why this matters

A parcel is scanned and must be diverted 480 ms later, 1.2 m down the belt at 2.5 m/s. The belt does not wait for the tracker. When the tracker stops, parcels keep arriving at 10 kHz, so every millisecond of pause puts 10 more parcels behind it, and each is charged for the wait, as Chapter 3 showed. Chapter 5 covered the pause a cold JVM adds at the start; the pauses a warm JVM adds at any time are the subject here.

The tracker keeps a 1.8 GB live set (the shift manifest and the parcels on the belt) and allocates scan history at about 400 MB/s. The same bytecode runs under four collectors; Python and C++ lanes ask the question without a tracing collector.

The code is in `examples/06-gc-tails/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="06-collector-pauses" alt="A tracker at 10 kHz for 30 s with a 4 GB pre-touched heap feeds four collectors, each with the maximum GC pause read from JFR: stop-the-world Parallel, where all threads stop and the heap is walked, 158-170 ms; G1 with stop-the-world evacuation, 21.0-21.6 ms; Generational ZGC (amber) with concurrent mark and relocate, 0.017-0.036 ms; and generational Shenandoah with concurrent evacuation, 0.53-0.82 ms." caption="Figure 6.1 — Same bytecode and allocation, different collector: the maximum pause runs from 158-170 ms under Parallel to 0.017-0.036 ms under ZGC." %}

## Concept

### What each collector stops

A collector bounds the tail in two ways: how long it stops the application, and whether it keeps up with the allocation rate. First, the stops.

- **Parallel** (`-XX:+UseParallelGC`) stops every thread for every collection, and a full collection walks the live set. All 13 pauses in the measured window were full collections.
- **G1** (`-XX:+UseG1GC`) marks concurrently and evacuates regions in stop-the-world pauses.
- **Generational ZGC** (`-XX:+UseZGC`) is the only ZGC mode in JDK 25 (JEP 490). Marking, relocation and reference processing run concurrently with the application; only short phase pauses stop it.
- **Generational Shenandoah** (`-XX:+UseShenandoahGC -XX:ShenandoahGCMode=generational`) is a product feature in JDK 25 (JEP 521) and evacuates concurrently.

The shift manifest is a ring: full before the first parcel, with each new parcel overwriting the oldest entry. The live set stays constant while the overwritten entries die in the old generation, so a generational collector has real work.

### Headroom

A concurrent collector runs beside the application, and both draw on the same free heap. If the application allocates faster than a cycle frees memory, free heap reaches zero and the allocating thread waits for the collector. That is an allocation stall: a pause by another name, and it does not appear as a GC pause. ZGC reports it as the `jdk.ZAllocationStall` event, which the example counts apart from `jdk.GCPhasePause`. The undersized variant runs ZGC with the heap at 1.05 times the measured live set.

{% include excalidraw.html file="06-headroom-stall" alt="Two lanes with the same handler allocating about 400 MB/s of garbage. With a 4 GB heap and a live set well under it, ZGC cycles stay ahead of the rate: 0 allocation stalls and p99.9 of 0.135-0.153 ms. With the heap at 1.05 times the live set, free memory runs out and an amber path leads to an allocation stall where the thread waits; the run records 532-976 stalls with p99.9 of 49.6-134.9 ms." caption="Figure 6.2 — A concurrent collector needs headroom. At 1.05 times the live set, ZGC stalls the allocating thread 532-976 times and p99.9 rises from 0.135-0.153 ms to 49.6-134.9 ms." %}

The shape came from a sweep. These are calibration runs on 2026-10-22, one run per row, not the committed measurement runs; `SWEEP=1 examples/06-gc-tails/verify.sh` reproduces them. ZGC with a fixed heap gave 0 allocation stalls at 4 GB and down to 1.10 times the live set, 14 stalls (longest 50.5 ms) at 1.075 times, and 884 stalls (longest 98.2 ms) at 1.05 times. At 1.30 times and a doubled allocation rate, ZGC gave 0 stalls and ran more minor collections instead (270 against 162). Allocation rate is not the lever; headroom is. The transition is sharp, so the book's undersized heap is 1.05 times, where the effect cannot be missed.

### Pre-touch and huge pages

Every Java variant runs with `-Xms4g -Xmx4g -XX:+AlwaysPreTouch`: no heap growth, and no first-touch page faults inside the window. The host's transparent huge pages are in `madvise` mode, and the `thp` variant adds `-XX:+UseTransparentHugePages` to ZGC so the JVM asks for them. Reserving huge pages as configuration is Part 5, *The OS, Isolation & the Network Edge*.

### Reclaiming in C++ and Python

The other two lanes make the same decision in a different place.

{% include excalidraw.html file="06-refcount-vs-tracing" alt="Three lanes in the order C++, Python, Java, each with its end-to-end p99.9 latency. C++: the owner frees, so bulk-free destroys a wave on the hot thread (2.08-2.19 ms) while deferred-free hands it to a reclaimer thread (0.135-0.141 ms). Python: refcounts free at once and a generational cycle collector finds cycles; cyclic-garbage runs 9 gen-2 collections (138-144 ms) and frozen, with no cycles and gc.freeze(), runs 0 (0.154-0.168 ms). Java: tracing collectors mark what is live; stop-the-world Parallel is 152-157 ms and ZGC 0.135-0.153 ms." caption="Figure 6.3 — C++ frees where the owner says, CPython frees by reference count and sweeps cycles in generations, and the JVM traces from roots; each has a variant that keeps the reclaim cost off the latency-critical path." %}

CPython frees an object the moment its reference count reaches zero. A reference cycle never does, so a generational cycle collector finds it (CPython 3.14.8 here; 3.14.0 to 3.14.4 shipped an incremental collector that 3.14.5 reverted). In `cyclic-garbage` every parcel's scan history is a cycle: the parcel lists its samples and each sample points back at it. By the time the parcel leaves the belt the cycle is in the oldest generation, so only a generation-2 collection, which walks every tracked object that is not frozen, frees it. The `frozen` variant has no cycles and calls `gc.freeze()` after setup, so the collector has nothing to walk.

C++ has no collector; the cost it shows is `free()`. A wave of 10,000 manifest entries owns many heap blocks, and destroying it on the hot thread delays every parcel that arrives meanwhile. `bulk-free` destroys the wave inline, `deferred-free` hands it to a reclaimer thread, and `no-free` keeps dead waves until the run ends, as a control.

## How the code works

### The handler's memory in each runtime

Each lane's handler looks up the lane, builds the scan history, overwrites a manifest entry and updates the in-flight table. In Java that is `Tracker.track` in `java/src/main/java/io/patterncatalyst/lowlat/gctails/Tracker.java`, shown with the `scan` method that creates the garbage. In C++ the choice is in `Tracker::close_wave` in `cpp/src/tracker.cpp`. In Python it is `Tracker.track` in `gctails-py/src/lowlat_gctails/tracker.py`.

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

The Java handler never frees anything. `scan` allocates an array of samples, each with a fresh `byte[]`, and `track` keeps a few in the `ParcelState` that goes into the `LinkedHashMap`; the rest is garbage once `checksum` returns. The manifest write replaces an old `ManifestEntry`, which becomes old-generation garbage. Nothing in the code mentions the collector: the collector decides what it costs.

In Python, `self.cyclic` is the one branch that matters: each sample gets `parent = state`, closing the cycle. Without it, the parcel dies when the table drops it.

In C++, `close_wave` is where the ownership decision is made. `Wave dead` owns the oldest wave. In `bulk_free` it is destroyed when the function returns, on the receive thread; in `deferred_free` it is moved into the reclaimer's queue and `Reclaimer::run` destroys it on its own thread. There is no collector to configure, so the divergence is the lesson: ownership is explicit, and so is the place the frees run.

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
# ...
```

`-XX:StartFlightRecording` records from JVM start, so the manifest build, the warm-up and the forced collection that measures the live set would be counted with the run. `Flight.during` starts the recording after those and stops it in a `finally`, because `stop()` writes the destination file. It uses the same `default` configuration as the command-line flag.

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

`gc.collect()` clears the setup's garbage. `gc.freeze()` then moves everything alive into a permanent generation that later collections skip. `cyclic-garbage` never freezes, so its collections walk the manifest.

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

For `undersized-heap`, `HEAP=$UNDERSIZED_MB` is computed from the live set that `verify.sh` measures first, so the size follows the workload.

## Measure

Run the example from the repository root:

```bash
examples/06-gc-tails/verify.sh
```

It needs 4 GB for a heap and refuses to start while a `lowlat-*` VM is running; `ALLOW_BUSY=1` measures anyway, with noisier numbers. `RECHECK=results/<run-id>` evaluates the criteria on a committed run without running anything. It runs 13 consumers one at a time, each at 10 kHz for 30 s (300,000 parcels), and asserts the criteria below.

Profile for every number below: bare-metal host, Intel Core i7-11800H, 16 logical CPUs, Fedora 44 kernel 7.2.11-200.fc44 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`, THP `madvise`, Temurin 25.0.5+8. Ranges are across the three committed runs `r02-run1` to `r02-run3`.

The measured live set was 1,804 to 1,810 MB, and the receive thread allocated 47,639 B per parcel in every run, about 476 MB/s at 10 kHz. Every report has count 300,000 and dropped 0 and passes `lowlat-report check` (criterion 6).

**Pauses and the tail.** Maximum GC pause is from the flight recording; p99.9 is the end-to-end latency the line sees.

| Variant | Max GC pause | End-to-end p99.9 |
|---|---|---|
| Parallel | 158 to 170 ms | 152.4 to 157.2 ms |
| G1 | 21.0 to 21.6 ms | 16.4 to 16.6 ms |
| Generational ZGC | 0.017 to 0.036 ms | 0.135 to 0.153 ms |
| Generational Shenandoah | 0.53 to 0.82 ms | 0.158 to 0.180 ms |

Criterion 1 asserts Parallel's maximum is at least 10 ms and 20x ZGC's, ZGC's is under 1 ms, and Generational Shenandoah's is at most a fifth of Parallel's. Criterion 2 asserts ZGC's p99.9 is at most a third of Parallel's. Both held in all three runs.

Under Parallel the p99 is already 130.8 to 135.4 ms, while the p50 is 0.06 ms in every Java variant. Parallel's worst pause spends 158 to 170 ms of the 480 ms scan-to-divert budget before the parcel's own work begins.

ZGC's end-to-end maximum is 2.45 to 2.69 ms while its longest GC pause is under 0.04 ms. The maximum is therefore not a GC pause, and the book does not attribute it.

**Headroom.** With the heap at 1.05 times the live set (1,895 to 1,901 MB), `undersized-heap` recorded 532 to 976 allocation stalls, the longest 60.7 to 156.9 ms, and a p99.9 of 49.6 to 134.9 ms against 0.135 to 0.153 ms for right-sized ZGC. Criterion 3 asserts at least one stall and a p99.9 at least 3x right-sized ZGC's. Its GC pauses stayed at 0.040 to 0.051 ms at most, so the stalls are the whole cost; a pause histogram would call this run healthy.

**Observed only.** Non-generational Shenandoah gave a p99.9 of 0.150 to 0.155 ms and a maximum pause of 0.41 to 0.51 ms. With `thp` the p99.9 was 0.142 to 0.146 ms, inside ZGC's own range, and the maximum pause 0.022 to 0.030 ms. With the recording off, `jfr-off` gave 0.145 to 0.159 ms, 6 to 11 microseconds above ZGC in each run. Neither the huge pages nor the recording moves p99.9 beyond ZGC's own run-to-run spread; the book claims no more.

**Python.** `cyclic-garbage` ran 9 generation-2 collections in the window (99 of generation 1, 1,092 of generation 0), the longest collection 144.0 to 150.6 ms, with a p99.9 of 138.2 to 144.4 ms. `frozen` ran 0 collections with 119,780 objects frozen and a p99.9 of 0.154 to 0.168 ms. Criterion 4 asserts 0 generation-2 collections for `frozen` and at least 1 for `cyclic-garbage`.

**C++.** The `bulk-free` maximum is 3.65 to 3.87 ms and its p99.9 is 2.08 to 2.19 ms, against a `deferred-free` p99.9 of 0.135 to 0.141 ms. Criterion 5 asserts the `bulk-free` maximum is at least 10x the `deferred-free` p99.9. Each run closed 33 waves and destroyed 320,000 entries, inline or on the reclaimer. The maxima of `deferred-free` (0.79 to 0.85 ms) and the `no-free` control (0.36 to 0.49 ms) are single operating-system events, observed as a pair; the claim that the reclaimer takes the cost off the hot thread rests on criterion 5.

## Cross-check

The unified GC log (`-Xlog:gc*,safepoint`) records the same pauses independently of the flight recording. Three comparisons hold on all three runs.

1. **Event counts.** Each `jdk.GCPhasePause` count in `java-<variant>.jfr-summary.txt` equals the `count` of its `-gc-pause.json`: 13 for Parallel and 16 for G1 in every run, 38, 41 and 35 for ZGC, and 91, 113 and 91 for Generational Shenandoah. The `jdk.ZAllocationStall` count of the undersized run equals its `alloc_stalls.count`: 532, 976 and 613.
2. **Pause sizes.** In the Parallel logs, after the `Pause Full (System.gc())` line, the largest `Pause Full (Allocation Failure)` is 157.2, 169.2 and 157.6 ms against the recording's maxima of 157.5, 169.6 and 158.1 ms. The tools time a pause at different points.
3. **Why the window matters.** The same logs show pauses the recording never saw: a `Pause Full (System.gc())` of 178.7 to 185.9 ms in the Parallel runs and G1 evacuation pauses of 72.5 to 75.5 ms while the manifest was built. They happen before the recording starts, which is the reason `Flight.during` starts it in the process.

Python's cross-check is the callback count: the report's `collections=1200` is 1,092 + 99 + 9. C++'s is the counters in `notes`: `destroyed_inline`, `reclaimed` and `retained` are each 320,000 in the variant that owns them and 0 elsewhere.

## What you learned

- On a 1.8 GB live set the maximum pause runs from 158 to 170 ms under Parallel to 0.017 to 0.036 ms under Generational ZGC.
- Headroom decides whether a concurrent collector works: at 1.05 times the live set, ZGC stalled the allocating thread 532 to 976 times, and a GC pause histogram does not show it.
- Record pauses where they happen and exclude setup: a recording started in the process, and a `gc.callbacks` hook that stores into preallocated buffers.
- In CPython, reference cycles cost generation-2 collections that walk the live set, and `gc.freeze()` removes the setup's objects from that walk. In C++, the frees cost what they cost, and the choice is which thread pays.
- Huge pages and the flight recording did not move ZGC's p99.9 beyond its run-to-run spread here.

The next chapter, Off-heap and lock-free Java: Chronicle, Agrona, the Disruptor, thread affinity, moves data out of the collector's reach.

## For deeper coverage

- Enberg, *Latency* (Manning), for the broader treatment of tail latency.
- Chapter 5, *What the JVM costs: allocation, escape analysis, JIT warmup vs AOT*, in Part 2, for allocation cost and warm-up.
- Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*, in Part 1, for why a pause charges every parcel behind it.
- Chapter 9, *Eliminating work: allocation, cache locality, false sharing*, in Part 3, for removing allocation in the data structure instead of tuning the collector.
- JEP 490 (ZGC: remove the non-generational mode, JDK 24) and JEP 521 (Generational Shenandoah, product in JDK 25), named here as facts.
- `examples/common/MEASUREMENT.md` for the report format and the checks every report passes.

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts the pause bounds (criterion 1), the ZGC against Parallel p99.9 bound (2), the undersized-heap stall and p99.9 (3), Python's generation-2 counts (4), the C++ `bulk-free` against `deferred-free` bound (5), and the report checks (6). Non-generational Shenandoah, `thp`, `jfr-off` and the `deferred-free` and `no-free` maxima are observed only, and the headroom sweep is calibration data. It held on `r02-run1`, `r02-run2` and `r02-run3` on the bare-metal host described above.*
