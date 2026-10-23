# 06-gc-tails

Chapter 6: the collector decides the tail. The in-flight parcel tracker runs at 10 kHz for 30 s on a
JVM whose heap holds a 1.8 GB live set (1,804 to 1,810 MB across the r02 runs, as `verify.sh` prints
it, with 1 MB = 2^20 bytes; the shift manifest and the parcels on the belt) and whose
handler allocates about 400 MB/s of scan history. Eight JVM variants run the same bytecode, the same
seed and the same `-Xms4g -Xmx4g -XX:+AlwaysPreTouch`, and differ only in the collector (or, for two of
them, in the heap or the flight recorder). A Python lane and a C++ lane show the same question in a
runtime with a cycle collector and in one with none.

## Technique

A collector bounds the tail in two ways: how long it stops the application, and whether it can keep up
with the allocation rate. The first is the pause; the second is headroom. When a concurrent collector
runs out of headroom, an allocating thread waits for it (an allocation stall), and the wait is a pause
by another name.

| Lane | Variant | What differs |
|---|---|---|
| Java | `stop-the-world` | `-XX:+UseParallelGC`: every collection stops every thread; a full collection walks the live set |
| Java | `g1` | `-XX:+UseG1GC`: region-based, pause-target driven; concurrent marking, stop-the-world evacuation |
| Java | `zgc` | `-XX:+UseZGC`: generational (the only mode in JDK 25); marking, relocation and reference processing run concurrently |
| Java | `shenandoah-gen` | `-XX:+UseShenandoahGC -XX:ShenandoahGCMode=generational` |
| Java | `shenandoah` | `-XX:+UseShenandoahGC`, non-generational (observed) |
| Java | `undersized-heap` | ZGC with the heap at 1.05x the measured live set: almost no headroom, so allocation stalls |
| Java | `thp` | ZGC with `-XX:+UseTransparentHugePages` (observed). The OS refuses huge pages for ZGC's shared-memory heap (`shmem_enabled` is `never`; `Large Page Support: Disabled (OS enforced)`), so this runs on 4 KB pages |
| Java | `jfr-off` | ZGC without the flight recorder (observed: what the recording costs) |
| Python | `cyclic-garbage` | each parcel's scan history is a reference cycle: only the cyclic collector frees it |
| Python | `frozen` | no cycles, and `gc.freeze()` after setup: refcounting frees each parcel at once, and the run has 0 collections in every generation |
| C++ | `bulk-free` | the retired wave of manifest entries is destroyed on the hot thread, in the call that closes the wave |
| C++ | `deferred-free` | the wave is handed to a reclaimer thread, which destroys it |
| C++ | `no-free` | the control: the wave is kept until after the run |

Every Java variant pre-touches the whole heap (`-XX:+AlwaysPreTouch`), so no variant pays first-touch
page faults inside the window, and logs through `-Xlog:async`, so the log write is off the application
threads. `-XX:+UseTransparentHugePages` requests huge pages for the heap; the host is not touched
(THP mode `madvise` is what the profile records; ZGC's heap is shared memory, governed by `shmem_enabled`, which this host sets to `never`, so `thp` gets no huge pages. Changing it is a host change; huge pages for ZGC belong to the Part 5 lab VM).

## Workload

The line simulator sends 300,000 parcels at 10 kHz (30 s). The tracker (`Tracker.java`) keeps three
kinds of data with three lifetimes.

- **The shift manifest** is a ring of entries, one per parcel scanned this shift. It is full before the
  first parcel arrives, and each new parcel overwrites the oldest entry. The live set stays constant
  while the overwritten entries die in the old generation, which is what a rolling manifest does to a
  generational collector.
- **The in-flight table** is a `LinkedHashMap` whose eldest entry is removed when a new parcel is
  scanned: the 480 ms between the scanner and the diverter, at 10 kHz, is 4,800 parcels. Each keeps
  8 scan samples.
- **The scan history** is built for every parcel (75 raw samples of 512 B), reduced to a checksum and
  dropped. This is the allocation rate.

Before the socket is bound the tracker builds the manifest, runs 30,000 synthetic parcels through the
protobuf decoder and the tracker (so the JIT has compiled the per-parcel path) and forces a collection to
measure the live set. The flight recording starts after all of that, in the JVM (`Flight.java`), so the
pauses of the build and the forced collection are not counted. The measured live set and the allocation
per parcel are in each report.

| Flag | Default | Meaning |
|---|---|---|
| `--live-set-mb` | 1750 | target size of the rolling manifest |
| `--entry-bytes` | 4096 | label bytes per manifest entry |
| `--alloc-mb-per-s` | 400 | scan-history allocation rate |
| `--in-flight-ms` | 480 | time between scanner and diverter |
| `--rate` | 10000 | parcels per second the simulator sends |
| `--warmup` | 30000 | synthetic parcels before the bind |
| `--jfr FILE` | none | record the measured run in the JVM and write the recording here |
| `--probe` | off | build the live set, print `live_set_bytes=` and exit |

## Layout

| Path | Contents |
|---|---|
| `java/` | Maven module `gc-tails-java` (`java -jar target/gc-tails-java.jar`): `Tracker`, `Settings`, `Options`, `Flight`, `GcTails` |
| `cpp/` | `gc-tails-consumer` (CMake target, auto-discovered) and the `lowlat::gc_tails` tracker library |
| `gctails-py/` | Python package `lowlat_gctails`, console script `gc-tails-py`, uv workspace member `lowlat-gc-tails` |
| `verify.sh` | runs the 13 runs and asserts the criteria |

The common line consumer owns the receive path in all three languages (bind, parse, gap tracking,
latency against the intended emit time). This example supplies the per-parcel handler.

## Run

```bash
examples/06-gc-tails/verify.sh
```

The script runs every JVM on its own, one after the other. It needs 4 GB for a heap and refuses to
start while a `lowlat-*` VM is running; `ALLOW_BUSY=1` measures anyway (the numbers are then noisy and
the profile says so). `SKIP_BUILD=1`, `RESULTS_DIR` and `LOWLAT_BUILD` are the shared options of
`examples/_lib/lib.sh`. `RECHECK=results/<run-id>` evaluates the criteria on a committed run without
running anything. `SWEEP=1` runs the heap-multiple sweep instead of the criteria: ZGC at 1.30, 1.15, 1.10,
1.075 and 1.05x the live set and at 4 GB, six runs, with the reports written to the results directory and
a table printed (see the headroom cliff below).

By hand, the ZGC variant (consumer first, then the simulator):

```bash
export LOWLAT_PROFILE=/tmp/profile.json && scripts/profile.sh --out "$LOWLAT_PROFILE"
java -Xms4g -Xmx4g -XX:+AlwaysPreTouch -XX:+UseZGC -jar examples/06-gc-tails/java/target/gc-tails-java.jar \
    --variant zgc --expect 300000 --report /tmp/zgc.json --jfr /tmp/zgc.jfr &
examples/build/release/common/line-simulator/line-simulator --rate 10000 --duration 30 --dest 127.0.0.1:47260
```

Ports: Java 47260, Python 47261, C++ 47262.

### What lands in `results/`

| File | Contents |
|---|---|
| `java-<variant>.json` | end-to-end latency report; `build.flags` carries the full JVM command line, `runtime.gc` the collector and heap, `runtime.alloc_bytes_per_parcel` the receive thread's allocation, `notes` the measured live set |
| `java-<variant>-gc-pause.json` | one sample per stop-the-world GC phase from the flight recording (`jdk.GCPhasePause`); `runtime.alloc_stalls` counts `jdk.ZAllocationStall` events |
| `<variant>.gc.log.gz` | the unified GC and safepoint log (`-Xlog:gc*,safepoint`), gzip-compressed |
| `java-<variant>.jfr-summary.txt` | `jfr summary` of the recording: event counts |
| `python-<variant>.json`, `python-<variant>-gc-pause.json` | end-to-end latency, and one sample per `gc.callbacks` collection; `notes` has the generation-2 count |
| `cpp-<variant>.json` | end-to-end latency; `notes` has the waves closed and where they were destroyed |
| `profile.json`, `live-set-bytes.txt`, `*.log` | machine profile, the probe's live set, program output |

The recordings (`*.jfr`) are written to a scratch directory outside the tree and deleted when the script
ends: they are binary and megabytes each, and everything the chapter quotes is in the derived reports.
The GC logs are compressed because the unified log is repetitive text that compresses well; a full run's results directory
is about 0.5 MB, far under the 20 MB budget for the iteration.

## Expected effect and criteria

`verify.sh` runs all of them, prints a line for each, and exits non-zero unless every one holds.

1. **Pauses (JFR).** The `stop-the-world` maximum pause is at least 10 ms and at least 20x the `zgc`
   maximum; the `zgc` maximum is under 1 ms; the `shenandoah-gen` maximum is at most a fifth of the
   `stop-the-world` maximum.
2. **The tail the line sees.** `zgc` p99.9 is at most a third of `stop-the-world` p99.9.
3. **Headroom.** `undersized-heap` (heap = 1.05x the measured live set) records at least one
   `jdk.ZAllocationStall` and its p99.9 is at least 3x the right-sized `zgc` p99.9.
4. **Python.** `frozen` runs zero generation-2 collections in the measured window; `cyclic-garbage` runs
   at least one.
5. **C++.** The `bulk-free` maximum is at least 10x the `deferred-free` p99.9 (same run).
6. **Every report.** `count = 300000`, `dropped = 0`, `lowlat-report check` passes, and each Java
   report's `build.flags` names its collector and its heap size.

Observed, not asserted: `shenandoah` (non-generational), `thp` and `jfr-off`, printed beside `zgc` so a
reader sees the recording's cost (`thp` got no huge pages, see above); and the `deferred-free` and `no-free`
maxima. Those two maxima are single operating-system events of 0.3 to 2 ms on both sides (across
calibration runs the ratio of one to the other ranged from 0.4 to 2.7), so the chapter reads them as a
pair, and the claim that the reclaimer thread leaves the hot path rests on the `deferred-free` p99.9
against the `bulk-free` maximum in criterion 5.

### Why 1.05x: the headroom cliff

ZGC needs a few percent of heap beyond the live set to keep up; it does not need 30 %. With the heap fixed
(`-Xms` = `-Xmx`) it cannot grow, so as the headroom shrinks it collects more often, and only when the
free space is gone does an allocating thread wait. At 1.3x the live set (2,348 MB for the 1,806 MB live
set) ZGC rode out a doubled allocation rate by running more minor collections (162 at 400 MB/s, 270 at
800 MB/s) and never stalled. Allocation rate is not the lever; headroom is, and the transition is sharp:
about 90 to 180 MB of free heap (5 to 10 % of the live set) separates no stalls from hundreds. The
criterion therefore uses 1.05x, where the heap sits 87 MB above the live set. That heap survived every run
without an out-of-memory error and without a dropped parcel (the socket buffer absorbed stalls of up to
210 ms), and `verify.sh` measures the live set first, so the size follows the workload.

Observed during calibration, 2026-10-22, one run per row, 10 kHz x 30 s, ZGC with `-Xms` = `-Xmx` and
`-XX:+AlwaysPreTouch`, 400 MB/s allocation flag (about 476 MB/s measured on the receive thread), live set
1,806 MB. Host profile: `bare-metal-host`, i7-11800H (8 cores, SMT on), governor `powersave`, tuned
`balanced`, THP `madvise`, kernel 7.2.11-200.fc44.x86_64. This is calibration data, not a committed run;
`SWEEP=1 ./verify.sh` reproduces it and writes the reports.

| Heap (x live set) | MB | Allocation stalls | Max stall | p99 | p99.9 | Minor / major collections |
|---|---|---|---|---|---|---|
| right-sized (4 GB) | 4096 | 0 | - | 0.083 ms | 0.162 ms | 28 / 12 |
| 1.30 | 2348 | 0 | - | 0.092 ms | 0.162 ms | 162 / 28 |
| 1.15 | 2077 | 0 | - | 0.095 ms | 0.161 ms | 400 / 64 |
| 1.10 | 1987 | 0 | - | 0.089 ms | 0.172 ms | 590 / 104 |
| 1.075 | 1942 | 14 | 50.5 ms | 0.139 ms | 25.2 ms | 718 / 146 |
| 1.05 | 1897 | 884 | 98.2 ms | 43.5 ms | 73.1 ms | 1882 / 186 |

At 800 MB/s: 1.30x gave 0 stalls and 270 minor collections, 1.15x gave 0 and 702, 1.10x gave 1 stall of
2.8 ms, 1.05x gave 2,115 stalls with a 209 ms maximum. Three further runs at 1.05x gave 618, 643 and 865
stalls (p99.9 97 to 157 ms); three at 1.075x gave 12, 5 and 14 stalls with p99.9 of 24, 1.5 and 14 ms,
which is why 1.075x is not used: one of the three clears the 3x bound by only 3.6x.

How the Python lane counts: CPython 3.14.8 has the generational cycle collector (3.14.0 to 3.14.4 shipped
an incremental one that 3.14.5 reverted), so a generation-2 collection walks every tracked object that is
not frozen. `gc.callbacks` runs on the thread that triggers a collection; the callback here stores two
timestamps into buffers allocated before the run and does nothing else. The pauses become samples after
the run. The count in the report's `notes` (`gen2_collections=`) is counted from those callbacks over the
measured window only.

The C++ lane has no collector; the cost it shows is `free()`. A wave of 10,000 manifest entries owns about
seventy thousand heap blocks, and destroying them on the hot thread delays every parcel that arrives
meanwhile. The `no-free` control keeps the dead waves until the run is over, so it contains the hand-off
cost without the destruction cost.

## Observation surfaces

None by design. The numbers are the reports, `verify.sh`'s printed table and the compressed GC logs;
there is no dashboard for this chapter. A collector's pauses are better read from a JFR file (`jfr
print --events jdk.GCPhasePause`) or `-Xlog` than from a panel, and Part 7 owns low-overhead
observability.

## Licences

Everything on the measured path is open source. The examples are MIT (repository licence).
Temurin 25 (the JDK, including ZGC, G1, Parallel, Shenandoah and JFR): GPL-2.0 with the Classpath
exception. protobuf: BSD-3-Clause. HdrHistogram: CC0-1.0 or BSD-2-Clause. GoogleTest: BSD-3-Clause.
CPython 3.14.8: PSF licence. Versions are pinned in `_plans/dependency-pins.md` and `versions.env`.

## Verification status

Behavioural. `verify.sh` asserts the six criteria above, and all of them held on the quiet-host
runs `r02-run1..3` (bare-metal host, governor `powersave`, tuned `balanced`, THP `madvise`, kernel
7.2.11-200.fc44, Temurin 25.0.5+8, CPython 3.14.8, VM down). Ranges over the three runs.

| Quantity | Range |
|---|---|
| Measured live set; `undersized-heap` size (1.05x) | 1,804 to 1,810 MB; 1,895 to 1,901 MB |
| Receive-thread allocation per parcel (`zgc`) | 47,639 B in every run, about 476 MB/s at 10 kHz |
| Maximum GC pause (JFR), Parallel / G1 / Generational ZGC / Generational Shenandoah | 158 to 170 ms / 21.0 to 21.6 ms / 0.017 to 0.036 ms / 0.53 to 0.82 ms |
| End-to-end p99.9, same order | 152.4 to 157.2 ms / 16.4 to 16.6 ms / 0.135 to 0.153 ms / 0.158 to 0.180 ms |
| Parallel end-to-end p99; ZGC end-to-end maximum | 130.8 to 135.4 ms; 2.45 to 2.69 ms (not a GC pause: ZGC's longest pause is under 0.04 ms) |
| `undersized-heap` allocation stalls; longest stall; p99.9 | 532 to 976; 60.7 to 156.9 ms; 49.6 to 134.9 ms (GC pauses at most 0.040 to 0.051 ms) |
| Python `cyclic-garbage`: generation-2 collections; longest collection; p99.9 | 9 (and 99 of generation 1, 1,092 of generation 0); 144.0 to 150.6 ms; 138.1 to 144.4 ms |
| Python `frozen`: collections; objects frozen; p99.9 | 0 in every generation; 119,780; 0.154 to 0.168 ms |
| C++ `bulk-free`: maximum; p99.9 | 3.65 to 3.87 ms; 2.08 to 2.19 ms |
| C++ `deferred-free`: p99.9; maximum (observed) | 0.135 to 0.141 ms; 0.79 to 0.85 ms |
| C++ `no-free` maximum (observed); waves closed; entries destroyed inline, by the reclaimer or kept | 0.36 to 0.49 ms; 33; 320,000 |
| Observed JVM variants, p99.9 / maximum pause | `shenandoah` 0.150 to 0.155 ms / 0.41 to 0.51 ms; `thp` 0.142 to 0.146 ms / 0.022 to 0.030 ms; `jfr-off` p99.9 0.145 to 0.159 ms |
| Every report | 300,000 parcels counted, none dropped, `lowlat-report check` passes |

The `thp` variant got no huge pages in any run: every `thp.gc.log.gz` logs
`Large Page Support: Disabled (OS enforced)` and `java-thp.log` warns that shared-memory THP is not
enabled. It is a second ZGC run on 4 KB pages, and its numbers say nothing about huge pages. With the
recording off, the `jfr-off` p99.9 was 6 to 11 microseconds above `zgc`'s in the same run, inside
ZGC's own run-to-run spread and the opposite direction from a recording cost. The C++ maxima of
`deferred-free` and `no-free` are single operating-system events; the reclaimer claim rests on
criterion 5.

Calibrated on a quiet host on 2026-10-22 (three dry runs plus the heap sweep above, which is
calibration data and not a committed run); criterion 3 uses the 1.05x heap that clears its bounds by
two orders of magnitude, and the former criterion 5 second half is an observed pair.
