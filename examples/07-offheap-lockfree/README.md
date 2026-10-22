# 07-offheap-lockfree

Chapter 7: take the hand-off between threads, the audit journal and the shift manifest off the
paths that block, call into the kernel per event or sit on the Java heap. One pipeline, ten
variants, each swapping one stage. Java leads; a C++ lane measures the same hand-off over
`std::atomic`.

## Technique

A parcel crosses three boundaries between the scanner and the diverter:

1. **Receive thread to decide thread.** The hand-off is the data path. A `BlockingQueue` is the
   idiomatic choice and parks the consumer when it is empty; waking it costs a trip through the
   kernel. An Agrona `OneToOneRingBuffer` over an `UnsafeBuffer` on a direct `ByteBuffer`, or an
   LMAX Disruptor ring of preallocated events, publishes with two ordered stores and lets the
   consumer spin on the sequence. Nothing is allocated per parcel, and the garbage collector
   never sees the records.
2. **Decide thread to the diverter.** The divert command leaves on its own UDP socket to its own
   address. It never travels through the hand-off structure, so a flood of scans cannot queue
   ahead of a command and a slow listener cannot back up the scans.
3. **Decide thread to the audit journal.** Every scan event is appended to a journal after the
   command has gone out. A Chronicle Queue appender writes into memory-mapped pages; the
   alternative is one `FileChannel.write` system call per event.

The shift manifest (barcode serial to destination, 1,000,000 entries) is a fourth question: a
`HashMap` puts a node, a boxed key and a `String` per entry in the old generation for as long as
the program runs; a Chronicle Map keeps the entries in native memory and leaves the heap with
the map handle.

The spinning variants are not a default. A busy-spin consumer holds a core at 100 % whether or
not parcels arrive, so the technique belongs to a dedicated, pinned thread (the VM part of this
chapter). On the host, scheduling is the kernel's choice and every spin thread competes with
the simulator and with the rest of the machine.

## Workload

`line-simulator` at 10 kHz for 20 s (200,000 parcels, seed 42) over UDP to `127.0.0.1:47270`.
The receive thread decodes the protobuf `ParcelEvent`, stamps `System.nanoTime()` and hands the
parcel over. The decide thread:

1. records the **hand-off latency** (pickup time minus the receive stamp);
2. looks the parcel up in the manifest, if the variant has one;
3. picks the lane (exception lane for a doubtful read or a parcel not on the manifest, otherwise
   the serial reference modulo 8, the rule `Lanes.laneOf` applies) and sends a `DivertCommand`
   on the command socket (`127.0.0.1:47271`);
4. completes the parcel: the **end-to-end latency**, intended emit to command sent;
5. appends the audit record, if the variant has a journal.

A diverter thread blocks on the command socket, counts the commands and records how long each
took from the decision to its arrival. The `Completion` belongs to the decide thread (the
ownership rule in `common/line-simulator/consumers/README.md`); the receive thread joins it in
`drain`.

Hand-off and end-to-end latency are separate reports. Both are also written per window: parcels
below 20,000 (the first two seconds, which carry JIT warm-up and cold caches) and the steady
rest. The hand-off criteria read the steady window.

## Variants

Each variant changes one stage. The rest stay at the baseline: a busy-spin Agrona ring, no
journal, no manifest.

| Variant | Stage that differs |
|---|---|
| `blocking-queue` | hand-off: `ArrayBlockingQueue` of immutable `Scan` records, consumer in `take()`; the JDK baseline |
| `linked-queue` | hand-off: `LinkedBlockingQueue`, one node per element |
| `agrona-spsc` | hand-off: `OneToOneRingBuffer` over `UnsafeBuffer`, `BusySpinIdleStrategy` |
| `agrona-spsc-backoff` | as `agrona-spsc` with `BackoffIdleStrategy` (spin, then yield, then park); observed |
| `disruptor` | hand-off: Disruptor ring of preallocated `Slot`s, `BusySpinWaitStrategy` |
| `disruptor-blocking-wait` | as `disruptor` with `BlockingWaitStrategy` |
| `chronicle-journal` | journal: Chronicle Queue appender; a tailer reads every event back |
| `write-per-parcel` | journal: one `FileChannel.write` per event |
| `chronicle-map-manifest` | manifest: Chronicle Map, 1,000,000 entries off-heap |
| `on-heap-manifest` | manifest: `HashMap`, 1,000,000 entries on the heap |

`--journal none|chronicle|file` and `--manifest none|on-heap|chronicle-map` override a variant's
stages, so `--variant agrona-spsc --journal chronicle --manifest chronicle-map` runs the whole
pipeline. The verified variants isolate one stage each, so a difference belongs to the stage
that changed.

The decide thread's placement is a seam, `ThreadPlacement`: `unpinned` (the scheduler's choice, the
only placement the host part uses) and `pinned-isolated`, which wraps the thread body in an OpenHFT
Affinity lock (`AffinityLock.acquireLock(3)`) held until the thread ends. See the VM part below.

## C++ lane

`cpp/` holds a single-producer single-consumer ring over `std::atomic<std::uint64_t>` indices.
The producer publishes with a release store, the consumer reads with an acquire load, and each
index sits on its own cache line (`alignas(std::hardware_destructive_interference_size)`) with
the other thread's cached copy beside it. `offheap-handoff` runs two ways of waiting:

| Variant | Consumer waits by | Producer |
|---|---|---|
| `atomic-spsc` | spinning on the producer's index | release store |
| `atomic-wait` | `std::atomic::wait` on the index (a futex once the short user-space spin ends) | release store, then `notify_one` |

Same workload, same two reports (end-to-end and hand-off), UDP port 47274, no command channel,
journal or manifest: the lane isolates the hand-off. Its acquire/release pairs correspond to
`VarHandle` access modes in Java (`setRelease`/`getAcquire`); Chapter 10 treats memory orders in full.

## Run

```bash
examples/07-offheap-lockfree/verify.sh
```

About 10 minutes: twelve 20 s runs, each with its own JVM or process start, then the JMH
publish benchmark. Environment (from `examples/_lib/lib.sh`): `ALLOW_BUSY=1` to measure while a
lab VM runs or the host is loaded (the numbers are then noisy), `SKIP_BUILD=1`, `RESULTS_DIR`,
`LOWLAT_BUILD`. `RECHECK=results/<run-id>` evaluates the criteria on committed reports without
running anything. `VM=1` is the affinity part and is not built yet: it exits with
`VM part: S10`.

Reports land in `results/latest/` as `<lang>-<variant>.json` (end-to-end) with the siblings
`-handoff`, `-handoff-first-20000`, `-handoff-steady`, `-first-20000`, `-steady`,
`-journal-append`, `-manifest-lookup` (each with `-first-20000` and `-steady` too) and `-divert`
where the stage exists, plus `jmh.json`, the
machine profile and one log and GC log per run. View them with:

```bash
uv run --project examples lowlat-report show examples/07-offheap-lockfree/results/latest/*.json
```

By hand, one variant (the JVM first, then the simulator). The `--add-opens`/`--add-exports`
list is the `chronicle.jvmArgs` property of `java/pom.xml`:

```bash
export LOWLAT_PROFILE=/tmp/profile.json && scripts/profile.sh --out "$LOWLAT_PROFILE"
java -Xms1g -Xmx1g -XX:+AlwaysPreTouch -Dchronicle.analytics.disable=true $CHRONICLE_JVM_ARGS \
    -cp examples/07-offheap-lockfree/java/target/benchmarks.jar io.patterncatalyst.lowlat.offheap.Handoff \
    --variant chronicle-journal --expect 200000 --report /tmp/chronicle-journal.json &
examples/build/release/common/line-simulator/line-simulator --rate 10000 --duration 20 --dest 127.0.0.1:47270
```

Queue and journal files go under `--journal-dir` (default `.scratch/offheap-lockfree`; `verify.sh`
uses `results/<run>/queue/`). Both locations are git-ignored. Each run creates its own
subdirectory and removes it when the run ends.

## Flags (Java)

| Flag | Default | Meaning |
|---|---|---|
| `--variant` | `blocking-queue` | one of the ten above |
| `--bind HOST:PORT` | `127.0.0.1:47270` | data socket |
| `--command-bind HOST:PORT` | `127.0.0.1:47271` | the diverter's command socket |
| `--journal`, `--manifest` | from the variant | override a stage |
| `--manifest-entries N` | 1000000 | manifest size |
| `--slots N` | 65536 | hand-off capacity in records, a power of two |
| `--window N` | 20000 | split the reports at parcel N |
| `--journal-dir DIR` | `.scratch/offheap-lockfree` | where journal files live during the run |
| `--sample-hold-ms MS` | 0 | keep the decide thread alive this long after the last parcel |
| `--placement` | `unpinned` | decide-thread placement: `unpinned` or `pinned-isolated` (guest CPU 3, VM part) |
| `--expect`, `--idle-timeout-ms`, `--rcvbuf`, `--report`, `--example` | | common consumer options |

The Chronicle JVM flags are required for the journal and manifest stages. Chronicle Core posts
usage analytics unless `-Dchronicle.analytics.disable=true` is set; the scripts and the tests set it.

## Observation surfaces

- **Decide-thread context switches.** The program prints `decide-thread pid=P tid=T` when the
  decide thread starts. The id is the kernel's, read from the target of `/proc/thread-self` on
  that thread (`Thread.threadId()` is the JVM's own number). `verify.sh` reads
  `voluntary_ctxt_switches` and `nonvoluntary_ctxt_switches` from `/proc/P/task/T/status`
  (`task_ctx_switches` in `lib.sh`) before the simulator starts and at the `window-end` line the
  program prints once every parcel is handled, and writes the difference into the end-to-end report
  as `runtime.ctx_switches`. The decide thread stays alive for `--sample-hold-ms` after that line
  so the read lands before it exits. The C++ lane prints the same two lines.
- **Allocation.** JMH `-prof gc` on `PublishBenchmark`, which calls the production
  `HandOff.publish` with a draining consumer: `gc.alloc.rate.norm` is bytes per publish across all
  threads. The throughput score is not a latency and is not quoted.
- **Old generation.** After the run, `System.gc()` and the old-generation `MemoryPoolMXBean`
  usage, once, off the hot path (`OldGen`). Written to the end-to-end and window reports as
  `runtime.gc.old_gen_used_bytes`, with the figure before the manifest was loaded as
  `old_gen_baseline_bytes` in the notes.
- **GC and safepoint log.** `-Xlog:gc*,safepoint` through `-Xlog:async` to
  `results/<run>/java-<variant>.gc.log`. A JFR recording is not taken: its sampler is another
  thread on a measured path.
- **Journal I/O.** `decide_write_syscalls` (`syscw` of the decide thread) and `decide_minor_faults`
  (field 10 of its `/proc/P/task/T/stat`) in the end-to-end notes, taken over the same window as the
  context switches, and `journal_fs`, the file system under the journal files. A `write()` to tmpfs
  costs a fraction of one to btrfs, so a journal comparison is only as portable as that field.
- **Journal readback.** The Chronicle tailer (or the file reader) re-reads every event after the
  run; count and sequence order are in the notes (`journal_readback_count`, `journal_in_order`).
- **Command path.** The diverter's receive count (`divert_received`) and the `-divert` report.

## Expected effect and criteria

`verify.sh` exits non-zero unless all of the following hold:

1. Decide-thread voluntary context switches: `agrona-spsc` and `disruptor` at most 1 % of the
   parcels (2,000), `blocking-queue` at least 25 % (50,000). The spinning consumer never blocks;
   the blocking one parks whenever the queue is empty, which at 10 kHz is nearly every parcel.
2. Hand-off p99 in the steady window: `agrona-spsc` and `disruptor` at most one fifth of
   `blocking-queue`, in the same run.
3. JMH `gc.alloc.rate.norm`: Disruptor and Agrona publish at most 1 B/op; `linked-queue` at least
   16 B/op (a node per element, before the `Scan` record).
4. The journal tailer reads back exactly 200,000 events in sequence order. The decide thread makes no
   write system call under `chronicle-journal` (at most 1 % of the events) and at least one per event
   under `write-per-parcel` (exact), read from `syscw` in `/proc/P/task/T/io`. The decide thread's
   minor faults show the first touch of the mapped file: under `chronicle-journal` they are at least
   the journal's bytes / (4096 x 16), the floor even if every fault mapped 16 pages, and at least 5x
   the `write-per-parcel` count, which sits near the thread's baseline. The append p50, p99 and p99.9
   of both are reported as observed, with the faults, the journal bytes, `journal_fs`, the block size
   and the roll cycle; the p99 ratio is not asserted.
5. Old generation after a full GC: `chronicle-map-manifest` at most one quarter of
   `on-heap-manifest`.
6. Every run: `count` = 200,000, `dropped` = 0, no hand-off overflow, every divert command received,
   every report passes `lowlat-report check`, the steady window holds 180,000 parcels.

### What the memory-mapped append removes

It removes the system call, not the first-touch page fault. The appender copies a record into a
`MAP_SHARED` mapping of the cycle file (`blockSize` 64 MiB, roll cycle `FAST_DAILY`, one 80 MiB file for
the whole run); the first write to each new 4 KiB page takes a minor fault, about 1.9 us for the
faulting append against a median of 0.3 us. Records are about 75 bytes, so on tmpfs a fault falls on roughly
every 55th append (1.9 % of appends, more than the 1 % that a p99 looks at: there the Chronicle p99 is the
fault); on btrfs it is 0.7 % and the p99 drops below the fault.
How often it happens depends on the file system under the journal:

| `journal_fs` | Decide-thread minor faults, 200,000 appends (15.0 MB, 3,662 pages) | Per page | Chronicle p50 / p99 / p99.9 | `write-per-parcel` p50 / p99 / p99.9 |
|---|---|---|---|---|
| tmpfs | 3,767 | 1.03 | 324 / 1,957 / 4,371 ns | 387 / 1,151 / 2,601 ns |
| btrfs (zstd) | 1,459, 1,457, 1,426 | 0.39 | 318 / 913 / 5,783, 313 / 823 / 5,267, 314 / 819 / 4,951 ns | 1,073 / 2,685 / 6,059, 1,075 / 2,589 / 5,855, 1,064 / 2,499 / 5,919 ns |

tmpfs takes one fault per page. On btrfs and ext4 the kernel's fault-around maps several neighbouring
pages already in the page cache on one fault, so there are fewer (about 2.5 pages per fault here, below
the 16-page ceiling), and `write-per-parcel` pays a full system call to a compressing file system on
every event, which is why the p99 ratio swings from 0.6x (tmpfs: Chronicle slower) to about 3x
(btrfs: Chronicle faster). Observed on the development host, 2026-10-22, three runs on btrfs and one on
tmpfs; the `write-per-parcel` thread takes 66 to 81 faults over the window with no journal pages
involved. The Chronicle OSS jar offers no way to avoid the first-touch fault: `ExcerptAppender.pretouch()`
and `ChronicleQueue.createPretoucher()` are the pre-toucher hook, and pretouching is a Chronicle Enterprise
feature. In the 2026.7 OSS jar `PretouchFactoryEmpty.createPretoucher(q)` calls `q.createPretoucher()`,
which is the default method that dispatches back to the same factory, so the call recurses until
`StackOverflowError`; `ExcerptAppender.pretouch()` on a `StoreAppender` reaches the same method. Do not
call it. A larger `blockSize` does not help either (faults are per page touched, not per chunk map).

Observed, not asserted: `agrona-spsc-backoff` (the park phase of the idle strategy returns the
context switches), `disruptor-blocking-wait` against `disruptor`, the manifest lookup cost of the
off-heap map against the `HashMap`, and the C++ `atomic-spsc` against `atomic-wait` hand-off and
context switches.

The Chronicle Queue journal is not a durability mechanism. The open-source queue does not
`fsync` on append: a record survives a process crash because it sits in the page cache, and a
power loss can take the pages that were not yet written back. No claim here depends on durability.

## VM part: pinning to an isolated CPU

```bash
scripts/lab/revert-vm.sh lowlat-target lab-ready-iso && scripts/lab/lab-up.sh
VM=1 examples/07-offheap-lockfree/verify.sh        # about 5 minutes
scripts/lab/lab-down.sh
```

The spin hand-off (`agrona-spsc`) holds a core at 100 %, so it only behaves where it owns one. The
lab guest `lowlat-target`, restored from the snapshot `lab-ready-iso`, boots the PREEMPT_RT kernel
with `isolcpus=3 nohz_full=3 rcu_nocbs=3` (`scripts/lab/guest-profiles/isolate-cpu3.conf`, applied
by `scripts/lab/apply-guest-profile.sh`) and libvirt pins its vCPU 3 to host CPU 13
(`scripts/lab/pin-vcpu.sh`). `stress-ng --cpu 3` runs under `taskset` on guest CPUs 0-2 as the noise.
The same 10 kHz x 20 s run (N = 200,000) then goes twice, alternated three times inside one boot
(unpinned, pinned, unpinned, pinned, ...):

| Placement | Decide thread |
|---|---|
| `unpinned` | wherever the guest scheduler puts it, among the noise on CPUs 0-2 |
| `pinned-isolated` | `AffinityLock.acquireLock(3)` before its first parcel, released when the thread ends |

`pinned-isolated` fails loudly instead of measuring something else: the program refuses to start
when the guest's `/proc/cmdline` has no `isolcpus=3`, and the decide thread throws when the lock
does not leave `Affinity.getCpu()` at 3. The script also reads `Cpus_allowed_list` and the CPU of
the decide thread from `/proc` and requires CPU 3 alone.

Criteria (S12 calibrates the bounds):

1. decide-thread involuntary context switches per run, from `/proc/PID/task/TID/status` between the
   thread's id line and the end of the window: pinned <= 10, unpinned >= 100, in every run.
2. hand-off p99.9 (steady window): pinned <= 1/2 of unpinned, the median of the three alternations
   of each.
3. every run: count = N, dropped = 0, no overflow, every divert command arrived, the pinned thread
   confined to CPU 3, every report passes `lowlat-report check` (run on the host).

Reports land in `results/latest/vm/` as `rK-PLACEMENT/java-agrona-spsc*.json`, with the guest's own
`profile.json` (`virt.type` is `kvm`), `check-prereqs.txt`, `vcpupin.txt` and a `LABEL` file saying `vm`.
The script requires the guest to run exactly the pinned Temurin, the isolation on its command line
and `stress-ng` confined to CPUs 0-2, and removes `stress-ng` and any JVM it started when it ends or
fails. The host-built `benchmarks.jar` and `line-simulator` are copied into the guest; nothing is
built there and nothing system-level changes on the host.

What isolation and the pin promise, and what they do not:

- **Inside the guest**, `isolcpus` takes CPU 3 out of the scheduler's balancing and `nohz_full` and
  `rcu_nocbs` take the tick and RCU callbacks off it, so once the decide thread owns it nothing else
  is scheduled there: no other task to preempt it, and the stress workers stay on CPUs 0-2.
- **The host is not partitioned.** The libvirt pin sends vCPU 3 to host CPU 13 and nowhere else, but
  the host kernel may still schedule other work on CPU 13 and on its hyperthread sibling CPU 5, and
  any host interrupt can still land there. The guest sees such a stall as a pause it cannot explain.
  The pin narrows the tail; it does not remove the host's share of it.
- **A VM number is a `vm` number.** It carries the hypervisor's timing, the virtual clock and the
  noise of whatever the host is doing. It is never compared with a host (bare-metal) number in this
  book, and the unpinned/pinned comparison holds only inside one boot of one guest.
- Isolation is deployment configuration (kernel arguments and a domain pin, both versioned in
  `scripts/lab/`), not a tweak: Chapters 15 and 18 own it as such. This part previews it.

## Files

| Path | Contents |
|---|---|
| `java/` | Maven module `offheap-lockfree-java`; `target/benchmarks.jar` is the JMH jar and carries the dependencies, so it also runs `Handoff` |
| `java/.../Handoff.java` | the program: build the stages, bind, run, write the reports |
| `java/.../QueueHandOff.java`, `RingHandOff.java`, `DisruptorHandOff.java` | the three hand-off structures behind `HandOff` |
| `java/.../DecideStage.java` | what the decide thread does per parcel |
| `java/.../ChronicleJournal.java`, `FileJournal.java` | the two journals behind `Journal` |
| `java/.../OnHeapManifest.java`, `ChronicleMapManifest.java` | the two manifests behind `Manifest` |
| `java/.../PublishBenchmark.java` | JMH publish-path allocation |
| `cpp/` | `spsc_ring.hpp`, `offheap-handoff`, GoogleTest for the ring |
| `java/.../ThreadPlacement.java` | the placement seam: `unpinned`, `pinned-isolated` (Affinity lock on guest CPU 3) |
| `vm/run.sh`, `vm/guest-run.sh` | the VM part: host-side orchestration and the guest-side run |
| `verify.sh` | runs everything and asserts the criteria; `VM=1` runs `vm/run.sh` |

## Licences

| Component | Licence | Used for |
|---|---|---|
| Agrona 2.7.0 | Apache-2.0 | ring buffer, idle strategies |
| LMAX Disruptor 4.0.0 | Apache-2.0 | Disruptor ring |
| Chronicle Queue 2026.7, Chronicle Map 2026.1, Chronicle Bytes 2026.4, OpenHFT Affinity 2026.2 | Apache-2.0 | audit journal, manifest, thread placement |
| JMH 1.37 | GPL-2.0 with Classpath exception | allocation benchmark |

Only the open-source edition of Chronicle is used. Its commercial edition adds features this
example does not use: asynchronous write buffers (`BufferMode.Asynchronous`), the pre-toucher,
queue and map replication, queue encryption and timezone roll-over. `BufferMode.None` is the only
buffer mode the open-source queue offers, and it is the one set here. Agrona and Chronicle call
`sun.misc.Unsafe`, which JDK 25 warns about at first use; the warnings stay on (JEP 471 and 498).
Versions are pinned in `_plans/dependency-pins.md`.

Chronicle Core posts usage analytics by default. Chronicle Queue and Chronicle Map each hold an
`AnalyticsHolder` whose static initializer runs when the first queue or map is built; it calls
`AnalyticsFacade.isEnabled()`, which reads the system property `chronicle.analytics.disable`
(through `Jvm.getBoolean`, so the property is the only switch: there is no environment variable,
though a `system.properties` file on the classpath or in the working directory can set it). Unless
it is `true`, a Google Analytics 4 client posts a `started` event to
`https://www.google-analytics.com/mp/collect` with a random client id kept in
`~/.chronicle.analytics.client.id`, the JDK, OS and architecture, time zone, processor count,
maximum heap and direct memory, the caller's package name and the queue's wire type and roll
cycle. This example never allows it, in four places: `ChronicleAnalytics.disable()` in the static
initializer of every class that touches Chronicle (`ChronicleJournal`, `ChronicleMapManifest`)
and in `Handoff.main`; `-Dchronicle.analytics.disable=true` in the surefire `argLine` and the
`exec:exec` arguments of `java/pom.xml`; the same flag in the `PublishBenchmark` fork and in
`verify.sh`; and `ChronicleAnalyticsTest`, which fails if the forked test JVM was not started with
it. `scripts/validate.py` (check `chronicle`) fails any pom or Java source that uses Chronicle
without one of them. If you write your own program on these classes, set the property before
the first queue or map is built.

## Verification status

Unverified. The host part builds, its unit tests pass and `verify.sh` runs end to end; the VM part
(`VM=1`) ran once functionally in the lab guest; the `r02-run1..3` and `r02-vm-run1..3`
measurements are still to come.

Calibrated on a quiet host on 2026-10-22 (three dry runs on tmpfs, three more on btrfs, one more on tmpfs
for the fault bound). The former criterion 4 p99 ratio was replaced by the fault mechanism above,
because the ratio is set by the journal's file system and not by the technique.
