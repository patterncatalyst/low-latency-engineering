---
title: "r02 plan: the managed-runtime question"
render_with_liquid: false
description: "Relay plan for r02: Part 2, Ch5–8 (JVM costs, GC for tails, off-heap and lock-free Java, zero-copy and flat data). Step status is kept current so a fresh session can resume."
---

Planned by Opus on 2026-10-22 on `release/r02` (cut from main at `ca2170c`). Status column is updated as steps land. Open questions in §6 are answered in S1 before execution.

## 0. Upstream facts that shape the plan (surveyed 2026-10-22; S0 re-checks and pins)

- **JDK:** JDK 27 GA 2026-09-15 (non-LTS); 25 is the latest LTS (Adoptium `most_recent_feature_release` 27, `most_recent_lts` 25). Latest 25 build: Temurin `jdk-25.0.5+8` (2026-10-22). Host runs SDKMAN Temurin 25.0.3; CI and the guest use Fedora `java-25-openjdk`.
- JDK 27 adds G1 as default everywhere (JEP 523) and compact object headers by default (JEP 534); no Valhalla, AOT, ZGC or Shenandoah JEP. JDK 26 added AOT object caching with any GC (JEP 516), so on JDK 25 the Leyden AOT cache cannot archive heap objects under ZGC: Ch5 measures AOT under G1 and says why.
- In JDK 25: Leyden AOT cache (JEP 483/514/515), Generational Shenandoah product (JEP 521, `-XX:ShenandoahGCMode=generational`), Generational ZGC is the only ZGC mode (JEP 490), FFM final (JEP 454), `-XX:+UseCompactObjectHeaders` product (JEP 519). Targeted at JDK 28, not released: JEP 544 (AOT code), 545 (ZGC startup), 535 (Shenandoah generational default).
- **Valhalla:** JEP 401 Value Objects (Preview) integrated into JDK 28 mainline; JDK 28 has no GA date (cadence → ~March 2027). Only EA builds (JDK 28 EA; Valhalla EA `27-jep401ea3+1-1`, 2026-03-11, Oracle EA terms). Prereleases are forbidden by the dependency policy → Q2.
- **Libraries (Maven Central):** Agrona 2.7.0 (2026-10-12); LMAX Disruptor 4.0.0 (still latest); JMH 1.37 (still latest). Chronicle (OpenHFT, Apache-2.0) moved to calendar versions: `chronicle-queue` 2026.7 (non-prerelease GitHub release 2026-10-06), `chronicle-map` 2026.1, `affinity` 2026.2; `5.27eaN` on Central are prereleases; `5.26.x`/`5.25.x` appear to be support-agreement lines. S0 confirms 2026.x is the public OSS line and pins `chronicle-bom`. Enterprise-only (not used): async mode, pre-toucher, replication, encryption; `BufferMode.None` is the only OSS buffer mode. Chronicle needs `--add-opens`/`--add-exports` on 17+; "full support for Java 25" announced 2026-07-08.
- **Tools:** async-profiler 4.6 (Apache-2.0); alloc mode works with `perf_event_paranoid=2` (host value). GraalVM CE releases are "25 Innovation N" (`graal-25.4.4.1.1`, JDK 25.0.4.1.1); "Innovation" not defined in release notes. CE native-image documents Serial GC; G1 in native-image historically Oracle GraalVM only. S0 verifies (Q3).
- **`sun.misc.Unsafe`:** JDK 24 warning (JEP 498) is the latest shipped step; Agrona and Chronicle warn on JDK 25 (Q6).
- **CPython:** 3.14.0–3.14.4 shipped an incremental cycle GC; 3.14.5+ reverted to generational. Pinned 3.14.8 is generational; the Ch6 Python lane states it.
- **Host (read-only):** THP `madvise` (so `-XX:+UseTransparentHugePages` works with no change); `nr_hugepages` 0 (hugetlbfs is VM-only); 62 GB RAM; 16 logical CPUs; `perf_event_paranoid` 2.
- **Release rule:** merged PR + `rNN.x` tag + notes-only GitHub release; no tarball (CLAUDE.md).

## 1. Approach

Java leads each chapter (mechanism → measure on the line → remove or bound its cost); C++ inline as a contrast, measured in the same `verify.sh` or shown in prose; Python only in Ch6 (refcount + cycle GC) and Ch8 (`memoryview`/`struct`), where it teaches a divergence.

One arc on the scan-to-divert path (480 ms budget, 1.2 m at 2.5 m/s): Ch5 measures what the JVM costs (bytes per parcel, warm-up tail, AOT); Ch6 picks the collector that bounds the GC tail; Ch7 moves the hand-off and state off-heap and lock-free; Ch8 removes the decode allocation Ch5 measured, through FFM flat data. Hot-path state is a light in-flight parcel tracker (barcode → state, lane decision); the full tracker is Part 3 (r03).

Part boundaries: Ch5 = JVM mechanics (TLAB, escape analysis, tiered JIT, deopt, AOT); Ch9 = data-structure-level elimination in three languages. Ch7 = the Java libraries (Agrona, Disruptor, Chronicle, Affinity); Ch10 = lock-free theory in three languages. Ch7's affinity section previews isolation; Ch15/Ch18 own it as versioned config.

Criteria are mechanism counters first, latency second (r01: cross-run absolute comparisons flake): deterministic counters (JMH `-prof gc` `gc.alloc.rate.norm`, `ThreadMXBean` allocated bytes, JFR `jdk.GCPhasePause`/`jdk.ZAllocationStall`, `/proc/<pid>/task/<tid>/status` context switches, AOT cache hits); ratios within one JVM (first window vs steady window); ratios between variants run back to back in one `verify.sh`, margins ≥ 3×. S12 gate: every asserted ratio clears its bound by ≥ 2× on three quiet dry runs; any bound change goes back to the user.

Run locations: host bare metal, untuned, serial, VM down, profile-labelled (`r02-run1..3`); VM-only work (affinity with guest isolation; hugetlbfs if approved) serial in `lowlat-target`, snapshot revert between runs, labelled `vm`, never compared (`r02-vm-run1..3`).

Rejected: JDK 27 as base (non-LTS, contradicts "Java 25", libraries certify LTS; Q1); Valhalla EA in measured runs (prerelease); GraalVM native-image as the main AOT story (hot path is plain JVM); host thread pinning (proves nothing without isolation; isolation is a host change); SBE in Ch8 (Ch22's subject; minimal versioned flat layout instead, Q10); committing `.jfr` (binary, large); a separate GC-pressure simulator (allocation driven by the handler; one shared workload).

## 2. Per chapter

### Ch5 — `examples/05-jvm-costs/` (host)

- **Technique:** per-parcel JVM cost: TLAB allocation and escape analysis (scalar replacement); tiered JIT warm-up tail (interpreter → C1 → C2, deopt); Leyden AOT cache (JDK 25 JEP 483/514/515, under G1 per JEP 516).
- **Workload:** tracker `decide(ParcelEvent)`: lane from dims and weight, a `DivertDecision` record, barcode-keyed `HashMap` of in-flight parcels.
- **Java:** JMH `-prof gc`: `escaping` (stored), `scalar-replaced` (consumed locally), same with `--no-escape-analysis` (`-XX:-DoEscapeAnalysis`). Line runs 1 kHz × 20 s: `--unwarmed` (r01 behaviour), `warmed` (in-process replay of 20,000 synthetic parcels before bind), `aot-cache` (train with `-XX:AOTCacheOutput`, run with `-XX:AOTCache` + `-XX:AOTMode=on` so a stale cache is fatal).
- **C++:** Google Benchmark `--allocating` (`new` per parcel) vs value (stack struct), observed `std::pmr::monotonic_buffer_resource`; first-window/steady split on the C++ consumer (no JIT; residual = page faults and cold caches).
- **Measured:** B/op per variant; first-window (parcels 0–1,999) and steady (last 10,000) p50/p99/p99.9; time to ready (JVM start → listening, 5 alternating launches); JFR `jdk.Compilation`/`jdk.Deoptimization` per window; end-to-end allocated bytes per parcel including protobuf parse (reused in Ch8).
- **Asserts:** (1) JMH `escaping` ≥ 24 B/op, `scalar-replaced` ≤ 1 B/op, `--no-escape-analysis` ≥ 24 B/op; (2) `--unwarmed` first-window p99 ≥ 5× steady p99 (same run); (3) `warmed` first-window p99 ≤ 3× steady p99 (same run); (4) `aot-cache` median time to ready ≤ 0.8× no-cache median (5 alternating launches in one `verify.sh`) and the AOT log shows the cache used; (5) every Java report's `build.flags` carries the JVM args; (6) count, `dropped=0`, `check`.
- **Observed:** compilations per window; C++ first/steady ratio; async-profiler alloc flame graph vs JMH B/op; AOT first-window p99.
- **Figures:** 5.1 `05-jit-tiers`; 5.2 `05-escape-analysis`.

### Ch6 — `examples/06-gc-tails/` (host; optional VM part per Q5)

- **Technique:** collector choice for tail latency: STW Parallel, G1, Generational ZGC, Generational Shenandoah (non-generational observed); headroom vs allocation stall; pre-touch; THP.
- **Workload:** 10 kHz × 30 s (300k parcels). Live set ~1.5–2 GB (in-flight parcels + rolling shift manifest); per-parcel scan history at a configurable rate (~300–500 MB/s, calibrated in S12). Same `-Xms=-Xmx` 4 GB, `-XX:+AlwaysPreTouch`, seed, `-Xlog:async`.
- **Variants:** `--stop-the-world` (Parallel), `g1`, `zgc`, `shenandoah-gen`, `shenandoah` (observed); `--undersized-heap` (ZGC at ~1.3× live set); `thp` (ZGC + `-XX:+UseTransparentHugePages`, observed). Python: `--cyclic-garbage` vs `frozen` (`gc.freeze()`, no cycles), pauses from `gc.callbacks` timestamps off-path. C++: `--bulk-free` (manifest destroyed on the hot thread) vs `deferred-free` (reclaimer thread).
- **Asserts (one invocation):** (1) JFR max pause `--stop-the-world` ≥ 10 ms and ≥ 20× `zgc`; `zgc` max < 1 ms; `shenandoah-gen` max ≤ 1/5 of `--stop-the-world`; (2) `zgc` p99.9 ≤ 1/3 of `--stop-the-world` p99.9; (3) `--undersized-heap` ≥ 1 `jdk.ZAllocationStall` and p99.9 ≥ 3× right-sized `zgc`; (4) Python `frozen` 0 gen-2 collections in the window, `--cyclic-garbage` ≥ 1 (max recorded); (5) C++ `--bulk-free` max ≥ 10× `deferred-free` p99.9 (same run), `deferred-free` max within 3× of the no-free control; (6) count, `dropped=0`, `check`, `build.flags` naming GC and heap. JFR-off run observed to bound JFR overhead; new `gc-pause` report per Java variant via the kit.
- **VM (only if Q5 = b):** hugetlbfs `-XX:+UseLargePages`, labelled `vm`, observed.
- **Figures:** 6.1 `06-collector-pauses`; 6.2 `06-headroom-stall`; 6.3 `06-refcount-vs-tracing` (optional).

### Ch7 — `examples/07-offheap-lockfree/` (host + VM affinity part)

- **Technique:** Agrona `OneToOneConcurrentArrayQueue`/`OneToOneRingBuffer` over `UnsafeBuffer` + `IdleStrategy`; Disruptor `RingBuffer` (preallocated events, wait strategy); Chronicle Queue journal (memory-mapped, off the hot path); Chronicle Map off-heap manifest; OpenHFT Affinity.
- **Workload:** receive → hand-off → decide → divert command on a separate command channel (never the data queue); decide thread appends every scan event to the audit journal; 10 kHz × 20 s. Kit change: `Completion` must be ownable by the decide thread (S4).
- **Variants:** `blocking-queue` (`ArrayBlockingQueue`, idiomatic JDK baseline); `--linked-queue` (node per element); `agrona-spsc` (busy-spin; backoff observed); `disruptor` (`BusySpinWaitStrategy`) with `--blocking-wait`; `chronicle-journal` vs `--write-per-parcel` (`FileChannel.write` per event); `chronicle-map-manifest` vs `--on-heap-manifest` (1M entries).
- **C++ inline:** SPSC on `std::atomic` acquire/release indices with `alignas(std::hardware_destructive_interference_size)` vs `std::atomic::wait`/`notify_one`; prose maps memory orders to VarHandle access modes; full treatment Ch10.
- **Host asserts:** (1) decide-thread voluntary ctx switches: `agrona-spsc`/`disruptor` ≤ 1 % of parcels vs `blocking-queue` ≥ 25 %; (2) hand-off p99 spin ≤ 1/5 of `blocking-queue` (same run); (3) JMH Disruptor and Agrona publish ≤ 1 B/op, `--linked-queue` ≥ 16 B/op; (4) tailer reads back exactly N events in seq order, `chronicle-journal` append p99 ≤ 1/5 of `--write-per-parcel`; (5) `chronicle-map-manifest` old-gen used after GC ≤ 1/4 of `--on-heap-manifest`; (6) usual. Prose: OSS Chronicle Queue does not `fsync` per append; no durability claim.
- **VM (`VM=1`, `vm`):** guest `isolcpus=3 nohz_full=3 rcu_nocbs=3` from a versioned config, optional libvirt `vcpupin` (Q4), `stress-ng --cpu 3` on other vCPUs; `unpinned` vs `pinned-isolated` (`AffinityLock.acquireLock(3)`), alternated 3× in one boot. Asserts: pinned involuntary ctx switches ≤ 10/run vs ≥ 100 unpinned; pinned hand-off p99.9 ≤ 1/2 of unpinned (same boot).
- **Figures:** 7.1 `07-handoff-topology`; 7.2 `07-ring-sequences`; 7.3 `07-affinity-vm`.

### Ch8 — `examples/08-zero-copy-flat/` (host)

- **Technique:** FFM `MemorySegment.ofBuffer` over the receive direct buffer, `StructLayout` + VarHandles, `Arena`; zero-copy decode of a fixed versioned flat record vs protobuf `parseFrom`; flat struct array for the in-flight table vs object array; `Linker` downcall `clock_gettime` with/without `Linker.Option.critical` (jextract is EA-only, so the `FunctionDescriptor` is hand-written); compact object headers footprint; Valhalla per Q2.
- **Workload:** simulator `--wire flat`; layout in `contracts/flat/parcel-v1` (C++ header is source of truth, doc, golden bytes; first fields `schema_id`, `version`); line runs both formats at 10 kHz × 10 s, plus JMH.
- **Variants:** Java `protobuf-decode` vs `flat-ffm`; `--object-table` vs `flat-table` (sweep of 1M in-flight parcels by encoder tick); downcall `standard` vs `critical`; `compact-headers` (observed). C++ inline `std::bit_cast`/`memcpy` from `std::span<const std::byte>` vs pointer cast (`std::start_lifetime_as` only if the pinned Clang implements it); `std::vector<ParcelState>` flat by default. Python `struct.Struct.unpack_from` over `memoryview` vs `ParseFromString` (each field read still creates an int).
- **Asserts:** (1) golden bytes: C++ writer, Java FFM reader and Python reader agree on every field for 3 seeds; (2) JMH `flat-ffm` ≤ 1 B/op vs `protobuf-decode` ≥ 100 B/op, protobuf/flat p50 ≥ 3× (same run); (3) line `flat` end-to-end allocated bytes/parcel ≤ 5 % of protobuf; (4) `flat-table` sweep p50 ≤ 1/2 of `--object-table` (same JMH run); (5) downcall `clock_gettime(CLOCK_MONOTONIC)` agrees with `System.nanoTime()` within 1 ms; `critical` vs `standard` observed; (6) usual.
- **Figures:** 8.1 `08-zero-copy-decode`; 8.2 `08-flat-vs-pointer-layout` (Valhalla as a ghost box "JDK 28 preview, not GA").

## 3. Steps

Executor is Sonnet unless MAIN. One checkpoint commit per step (scopes `r02.x`, `demo-NN`, `§N`). Host runs serial, VM down; VM runs serial.

| id | What | Files | Dep | Runs on | Status |
|---|---|---|---|---|---|
| S0 | Upstream survey + exact pins, licences, date, holds: JDK 25.0.x/27/28-EA, Temurin SHA, Fedora `java-25-openjdk`, JMH, Agrona, Disruptor, `chronicle-bom` (+ queue, map, bytes; confirm 2026.x OSS; list Enterprise-only), Affinity, async-profiler, JOL, GraalVM CE "Innovation" + native-image GC, jextract (EA only), `std::start_lifetime_as` in Clang/GCC, CPython 3.14.8 GC, `stress-ng` | `_plans/dependency-pins.md`, `versions.env` | – | host (read-only queries) | done |
| S1 | Record answers to Q1–Q12; iteration plan status; outline/part blurb if Valhalla scope changes | `CLAUDE.md` (only if Q1/Q2 change a rule), `_plans/iteration-plan.md`, this file | answers | MAIN | done |
| S2 | Report contract: optional top-level `runtime` object (GC, heap, `alloc_bytes_per_parcel`, `jit`, `aot`, `ctx_switches`), additive in `lowlat-report/1`; `check` validates it and rejects `mean` inside it; fixtures; Java `BuildInfo` fills `flags` from `RuntimeMXBean.getInputArguments()` and GC names from `GarbageCollectorMXBean`s | `contracts/measurement/latency-report.schema.json`, `measure-py`, `measure-java`, `measure-fixtures/` | S0 | host | done |
| S3 | `profile.sh`: `memory.thp_enabled`/`thp_defrag`, `perf_event_paranoid`, memlock, full `java -version`. `lib.sh`: `java_run` (JFR to scratch, async `-Xlog:gc*,safepoint` to `$OUT`, flags echoed), `jfr_pauses` (measure-java CLI on `jdk.jfr.consumer.RecordingFile` → `gc-pause` report), `task_ctx_switches PID TID`, `time_to_ready`. `.gitignore`: `*.jfr`, queue dirs | `scripts/profile.sh`, `examples/_lib/lib.sh`, `measure-java` (`JfrPauses`), `.gitignore` | S2 | host | todo |
| S4 | Common kit: Java `LineReceiver` pluggable `Decoder` (protobuf default; FFM flat in Ch8); `--window N` writes `<variant>-first-N` + `-steady`; receive-thread allocated bytes via `com.sun.management.ThreadMXBean` (off-path); `Completion` ownable by another thread (single writer, published by join). C++ `--window`. Simulator `--wire flat` + `contracts/flat/parcel-v1` (header, doc, golden bytes). Python flat reader. Tests | `common/line-simulator/**`, `contracts/flat/`, consumers ×3 | S2 | host | todo |
| S5 | Lab: pinned Temurin tarball (SHA-checked) in the guest only; versioned guest isolation profile `scripts/lab/guest-profiles/isolate-cpu3.conf` applied by `scripts/lab/apply-guest-profile.sh` (grubby in the guest); optional `vcpupin` (Q4); `stress-ng`; snapshot `lab-ready-iso`; hugetlbfs only if Q5 = b | `scripts/lab/**`, `scripts/check-prereqs.sh --vm` | S0, Q4 | VM | done |
| S6 | Build wiring: modules in `examples/pom.xml`, pins as properties, `chronicle-bom` import; `dependencyConvergence` passes (exclusions ok, disabled rule not); surefire/exec `argLine` with Chronicle `--add-opens`; CMake targets 05–08; uv packages for 06/08 Python | `examples/pom.xml`, `examples/0[5-8]-*/java/pom.xml`, `examples/CMakeLists.txt`, `pyproject.toml` | S0, S4 | host | todo |
| S7 | Example 05 + README (technique, workload, expected effect, licences) | `examples/05-jvm-costs/**` | S3, S4, S6 | host | todo |
| S8 | Example 06 (Java, C++, Python) | `examples/06-gc-tails/**` | S3, S4, S6 | host | todo |
| S9 | Example 07 host part | `examples/07-offheap-lockfree/**` | S3, S4, S6 | host | todo |
| S10 | Example 07 VM part (`VM=1`, `deploy-to-vm.sh`) | `examples/07-offheap-lockfree/verify.sh`, `vm/` | S5, S9 | VM | todo |
| S11 | Example 08 + Valhalla per Q2 (conceptual, or a separate EA directory outside `pom.xml`) | `examples/08-zero-copy-flat/**` | S4, S6 | host | todo |
| S12 | Calibration gate: 3 quiet dry runs of each `verify.sh` into `results/latest` (uncommitted); margin table; every bound ≥ 2×; tuned parameters into READMEs; bound changes go to the user | READMEs, this file's follow-ups | S7–S11 | host (MAIN), VM for 07 | todo |
| S13 | Host measurement `r02-run{1,2,3}` for 05–08, serial, VM down, one recorded commit | `examples/0[5-8]-*/results/r02-run*/` | S12 | host (MAIN) | todo |
| S14 | VM measurement 07 `VM=1` `r02-vm-run{1,2,3}`, revert to `lab-ready-iso` between runs, `LABEL=vm`, VM down after; 06 hugetlbfs if Q5 = b | `…/results/r02-vm-run*/` | S10, S12 | VM (MAIN) | todo |
| S15 | Figures ≥ 2 per chapter (9–11), r01 visual grammar, S13/S14 ranges only | `_plans/r02-figures.md`, `diagrams/0[5-8]-*.py`, `assets/diagrams/`, `_data/diagrams.yml` | S13, S14 | host | todo |
| S16–S19 | Ch5–Ch8 prose; brief `_plans/r02-chapters.md` cloned from r01's; code tabs Java first (`Java\|C++`, `Java\|C++\|Python`), checked against the include and `validate.py` | `_docs/05-…08-*.md`, `_plans/r02-chapters.md` | S15 | – | todo |
| S20 | Wiring: `_example_pages/05..08`, outline links, READMEs quoting `r02-run1..3`, reconciliation claims 05.x–08.x + runs table, iteration-plan status; forward/back links (Ch1 "Part 2 treats the cause", Ch4 closing line, consumer README warm-up note) | listed files | S16–S19 | – | todo |
| S21 | CI: modules picked up; pin CI JDK (Q12); `validate.py` checks: no `*.jfr` committed, every Java report has `build.flags`, every `*vm-run*` has `LABEL`=`vm`, no EA/prerelease versions in pom/CMake/uv, variant names only from the defect list; JUnit AOT-cache smoke test (train, then `AOTMode=on`) | `.github/workflows/ci.yml`, `scripts/validate.py` | S6, S20 | CI | todo |
| S22 | Idiom + voice review (`lgtm-idiomatic-review` on 05–08 and kit diffs; `lgtm-professional-voice` on `_docs/05-08`, READMEs, `_plans/r02-*`); fix findings | all r02 files | S21 | host (MAIN + executors) | todo |
| S23 | Re-measure: any S22 change to measured code or `verify.sh` invalidates S13/S14 → re-run and re-quote; otherwise record "no re-measure needed" with the diff stat | results, chapters, figures, reconciliation | S22 | host, VM (MAIN) | todo |
| S24 | Opus validation: every number recomputed; §4 criteria; Jekyll in `ruby:4.0`; `validate.py`; `wordcount.sh` | – | S23 | host (MAIN) | todo |
| S25 | Ship: PR `release/r02` → main, `ci-ok` green, squash-merge (user OK), delete branch, tag `r02.x`, notes-only GitHub release; no tarball | – | S24 | GitHub (MAIN) | todo |

## 4. Acceptance criteria

- **S0** every new dependency has exact version, licence, source, date; no ranges, `LATEST` or `ea`; Chronicle OSS line confirmed by Central metadata + non-prerelease GitHub release; Enterprise-only features listed as excluded; JDK 25.0.x latest and 27 GA recorded; Valhalla status recorded with links; every hold has a reason and a re-check trigger.
- **S2** a report with `runtime` validates; one with `runtime.mean_ns` fails; r01 fixtures still validate; a Java report shows `build.flags` containing `-XX:+UseZGC` when launched with it.
- **S3** `profile.sh | jq .memory.thp_enabled` prints `madvise` on the host; `jfr_pauses` on a 5 s ZGC recording produces a report that passes `check` with `count` = JFR pause event count; `git check-ignore x.jfr` succeeds.
- **S4** r01 examples 00–04 pass unchanged (`RECHECK` on r01 runs + one live run of 00); `--window 2000` gives two reports whose counts sum to the total; flat golden-bytes test passes in C++, Java, Python; a completion on a second thread records the same count the receive thread received.
- **S5** guest `/proc/cmdline` contains `isolcpus=3`; `check-prereqs.sh --vm` passes incl. Temurin version; snapshot `lab-ready-iso` listed; host sysctl/hugepages/tuned unchanged (`profile.sh` diff before/after); `ebpf-*` and `systems-*` untouched.
- **S6** `mvn -B -f examples/pom.xml verify` passes with the enforcer, no `skip`, `-Werror` kept; C++ and uv builds pass.
- **S7–S11** each `verify.sh` exits 0 on the host and asserts its §2 criteria; variant names only from §2; READMEs state technique, workload, expected effect, observation surfaces and licences.
- **S12** margin table committed in follow-ups; every asserted bound ≥ 2× in all 3 dry runs, or a user decision recorded.
- **S13/S14** every report passes `check`, carries `profile.virt` and `loadavg`, starts at loadavg ≤ 2; VM dirs have `LABEL` `vm` and `virt.type` `kvm`; every `verify.log` passes; committed r02 results ≤ 20 MB.
- **S15** ≥ 2 `_data/diagrams.yml` entries per Ch5–8; every SVG/`.excalidraw` exists, parses and regenerates byte-identically; every number in a figure is a parameter or an S13/S14 range.
- **S16–S19** 1,900–2,500 words; `part: "The Managed-Runtime Question"`; full spine; every number traceable and profile-labelled; no mean; Valhalla text matches Q2; Python only where it teaches a divergence.
- **S20** examples page lists 05–08; reconciliation has one row per asserted and observed claim with run evidence.
- **S21** CI `ci-ok` green on the PR; new `validate.py` checks fail on planted bad fixtures and pass on the tree.
- **S22** both scanners 0 ban-tier after triage; idiom findings fixed or justified in prose.
- **S23** quoted numbers match the final runs.
- **S24** every criterion above holds; Jekyll builds cleanly.
- **S25** PR merged (squash), tag `r02.x`, GitHub release published, branch deleted.

## 5. Risks

| Risk | Detection |
|---|---|
| Chronicle on JDK 25: module access, `Unsafe` warnings, transitive conflicts breaking `dependencyConvergence` | S6 `mvn verify` with enforcer; JUnit opens and tails a queue; grep logs for `IllegalAccess`, `terminally deprecated` |
| Chronicle 2026.x is EA/support-only, or an Enterprise-only feature slips in | S0 metadata + release check; S22 grep for Enterprise classes, `BufferMode` |
| Thin margins on a powersave/balanced host | mechanism-first criteria; S12 2× gate; profile loadavg |
| Busy-spin threads compete with the simulator | ≤ 2 spin threads; simulator emit lateness; `gaps=0` |
| Stale AOT cache silently ignored | `-XX:AOTMode=on` makes it fatal; criterion checks the AOT log |
| AOT + ZGC on JDK 25 loses object archiving | Ch5 runs AOT under G1, states JEP 516 |
| JFR/GC logging distorts the tail | `-Xlog:async`; JFR-off run observed in 06 |
| UDP drops at 10 kHz | `dropped=0`; granted rcvbuf in notes |
| Parallel pauses too short to separate | live set and rate calibrated in S12; pause criterion reads JFR |
| Guest RT kernel / VM noise hides affinity | ctx-switch criterion primary; alternating runs in one boot; snapshot revert |
| Host accidentally changed | S5/S13 profile diff; `lib.sh` never calls sudo; host tools user-local under `~/.cache/lowlat` |
| EA/prerelease leaks into the build (Valhalla, jextract) | S21 version check; Valhalla outside `pom.xml` |
| Overlap with Ch9/Ch10 | boundaries in `r02-chapters.md`; checked at S24 |
| Host Temurin 25.0.3 vs pin 25.0.5; Fedora OpenJDK drift in CI/guest | `profile.tools.java` in every report; check-prereqs warns below the pin |
| Python lane depends on 3.14.x patch (incremental GC ≤ 3.14.4) | version recorded; criterion counts collections only |
| Results bloat (GC logs, queues) | `*.jfr` and queue dirs ignored; S13 size check |

## 6. Open questions (answered in S1)

1. **Base JDK** — rec: 25.0.5 LTS pinned; JDK 27 only as an observed side run if wanted. Upgrading the host's user-local SDKMAN JDK 25.0.3 → 25.0.5 is the user's call; otherwise a recorded hold.
2. **Valhalla (Ch8)** — (a) conceptual only + C++ comparison + FFM flat layout as today's substitute, "status at 2026-10-22" box, re-visit at JDK 28 GA; (b) (a) + an EA appendix run outside the aggregator (needs a policy exception); (c) omit until JDK 28 GA. Rec: (a).
3. **AOT story** — rec: Leyden AOT cache on the plain JVM is the measured lane; GraalVM CE native-image in prose only; never on the hot path.
4. **Affinity (VM only)** — rec: guest isolation as versioned config, plus libvirt `vcpupin` as committed domain config applied by a lab script and reverted by snapshot.
5. **Large pages** — (a) host THP only (`madvise`, no change), observed; (b) + hugetlbfs in the VM. Rec: (a); hugepages as versioned config belong to Part 5.
6. **`sun.misc.Unsafe` warnings** — rec: keep default `warn`, show it, explain JEP 471/498; never silently allow.
7. **JFR files** — rec: don't commit `.jfr`; commit derived `gc-pause` reports, GC logs, `jfr summary` and the settings file.
8. **Rates** — rec: 10 kHz for 06–08; 1 kHz for 05.
9. **Python scope** — rec: Ch6 and Ch8 lanes only.
10. **Flat wire format** — rec: minimal versioned layout `contracts/flat/parcel-v1`, forward reference to SBE in Ch22.
11. **C++ lanes** — rec: Ch5 `--allocating` vs value + first-window split; Ch6 `--bulk-free` vs `deferred-free`; Ch7 `std::atomic` SPSC vs `atomic::wait`; Ch8 `bit_cast`/`span` + `vector<struct>`; never a shootout.
12. **CI JDK** — rec: pinned Temurin 25.0.5 tarball (SHA-checked) in CI and the guest instead of Fedora's floating `java-25-openjdk`.

## Follow-ups

| Item | Decision |
|---|---|
| Q1 base JDK (2026-10-22) | Temurin 25.0.5 LTS, pinned; no JDK 27 side run. Host user-local SDKMAN JDK upgraded 25.0.3 → 25.0.5 (user approved; no system change) |
| Q2 Valhalla | (a) conceptual only, C++ `vector<struct>` comparison, FFM flat layout as today's substitute, dated status box, re-visit at JDK 28 GA |
| Q3 AOT | Leyden AOT cache measured; GraalVM CE native-image prose only (recommendation, not objected) |
| Q4 affinity | guest isolation (`isolcpus`/`nohz_full`/`rcu_nocbs`) + libvirt `vcpupin` as committed domain config, applied and reverted by a lab script/snapshot |
| S5 (2026-10-22) | vcpupin: guest vCPU 3 -> host CPU 15 (highest logical CPU, sibling of 7; host housekeeping and default IRQs favour low CPUs). A pin only, not host isolation; the prose says so. `grubby --update-kernel` must address the RT entry by index on Fedora Cloud btrfs `/boot` (paths rejected). Snapshot `lab-ready-iso` = RT + isolation + pin + Temurin + stress-ng; reverting to `lab-ready`/`lab-ready-rt` restores the unpinned domain XML |
| Q5 large pages | host THP only (`madvise`), observed; hugetlbfs deferred to Part 5 |
| Q6–Q12 | plan recommendations taken (default `warn` for Unsafe; no `.jfr` committed; 10 kHz for 06–08, 1 kHz for 05; Python in Ch6/Ch8 only; `contracts/flat/parcel-v1`; C++ lanes as listed; pinned Temurin in CI and guest) |
| S0 survey (2026-10-22) | Pins in `dependency-pins.md` "r02 pins" and `versions.env` (`TEMURIN_*`, `ASYNC_PROFILER_*`). Chronicle: `chronicle-bom` 2026.26 → queue 2026.7, map 2026.1, bytes 2026.4, affinity 2026.2 (OSS line confirmed). Fedora `java-25-openjdk` is 25.0.4.1.1 (behind Temurin 25.0.5), reinforcing Q12. Chronicle Map replication is also Enterprise-only. `std::start_lifetime_as` compiles with Clang 22.1.8 and GCC 16.2.1: Ch8 may use it. GraalVM CE native-image has Serial/Epsilon only (G1 is Oracle GraalVM). CPython 3.14.8 is generational. Host SDKMAN now has Temurin 25.0.5 as default (25.0.3 kept). S5/S6: `check-prereqs.sh` should compare against `TEMURIN_VERSION` and warn below it; S6 `dependencyConvergence` must reconcile old transitives of Chronicle (jna 5.5.0, asm 9.2) |
| S2 design (2026-10-22) | `runtime` is schema-enforced no-mean via a recursive `$defs/noMean` (keys `mean`, `*_mean`, `*mean_ns`), so `validate` and `check` both reject. Java `BuildInfo.flags` = all JVM input arguments, space-joined (null when none); structured GC view is opt-in `RuntimeInfo.jvm()` (`gc.collectors`, `gc.heap_bytes`, `gc.flags`), not `Runtime` (avoids shadowing `java.lang.Runtime`). Committed java goldens not regenerated (flags only appear on regeneration) |
