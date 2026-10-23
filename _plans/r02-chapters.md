---
title: "r02 chapters (S16–S19)"
layout: plan
render_with_liquid: false
---

# r02 chapters — S16–S19

One chapter per example, written from the example's code and its committed
S13/S14 results. Binding for every chapter. Shape, numbers and voice follow
[r01-chapters.md](r01-chapters.md); this brief adds what Part 2 changes. Each
executor edits only its own chapter file: `_data/diagrams.yml`, READMEs, the
outline, `_example_pages/` and the other chapters are S20's (wiring), and
`scripts/validate.py` is S21's.

## Files

| Step | File | `order` | `part` | Title | Example |
|---|---|---|---|---|---|
| S16 | `_docs/05-jvm-costs.md` | 5 | `The Managed-Runtime Question` | What the JVM costs: allocation, escape analysis, JIT warmup vs AOT | `examples/05-jvm-costs/` |
| S17 | `_docs/06-gc-tails.md` | 6 | `The Managed-Runtime Question` | GC for tails: Generational ZGC and Shenandoah | `examples/06-gc-tails/` |
| S18 | `_docs/07-offheap-lockfree.md` | 7 | `The Managed-Runtime Question` | Off-heap and lock-free Java: Chronicle, Agrona, the Disruptor, thread affinity | `examples/07-offheap-lockfree/` |
| S19 | `_docs/08-zero-copy-flat.md` | 8 | `The Managed-Runtime Question` | Zero-copy and flat data: Panama (FFM), Valhalla value objects, and the C++ comparison | `examples/08-zero-copy-flat/` |

Front matter: `title` (quoted, exactly as above), `order`, `part` (exactly
`"The Managed-Runtime Question"`, the `part_name` of `_parts/02-jvm.md`),
`description` (quoted; one or two sentences that name the effect with a range
from the runs and its profile class, like Ch1's), `duration` (`50 minutes` for
Ch5, Ch6 and Ch8, `55 minutes` for Ch7). The slugs give the permalinks
`/docs/05-jvm-costs/` to `/docs/08-zero-copy-flat/` (`_config.yml`: `/docs/:name/`).
The Outline page is not a chapter; do not touch it (S20 links the four chapters).

Commit each chapter on its own: `docs(§5): Ch5 What the JVM costs (S16)`,
`docs(§6): …(S17)`, `docs(§7): …(S18)`, `docs(§8): …(S19)`. Stage only the
chapter file.

## Shape (the house spine)

1. **Learning objectives** (3–5 bullets, "By the end of this chapter you can:").
2. **Why this matters**: the hook in the sortation-line domain. The budget is
   physical: 480 ms scan-to-divert, 1.2 m at 2.5 m/s. The belt never waits for a
   slow consumer (Ch3's coordinated omission is physical here). Never trading.
   End the section with the example-dir sentence: "The code is in
   `examples/NN-name/`. The run script there builds and runs it; its `README.md`
   covers what it does and how to drive it."
3. **Diagram**: every figure of the chapter from `_data/diagrams.yml`, each
   embedded exactly once with
   `{% include excalidraw.html file="<name>" alt="<alt>" caption="<caption>" %}`
   on one line, `alt` and `caption` copied character for character from the YAML
   (validate.py `figures` compares them; the YAML uses `-` in ranges and `—` in
   captions, keep both). The first figure goes under `## Diagram`; the others go
   where the text they support is (as Ch4 places Figure 4.2 in Measure).
4. **Concept** (`###` subsections as needed).
5. **How the code works**: real code copied verbatim from the named source files
   (name each file in the sentence before the excerpt). Elide with a comment line
   (`// ...` or `# ...`) only; never edit a line. Explain each meaningful call and
   why it is written that way, as if the reader were writing it. Where a
   technique has no clean equivalent in a language, say so and teach the
   divergence; never a language shootout.
6. **Measure**: the run command (`examples/NN-name/verify.sh`), `ALLOW_BUSY=1`
   and `RECHECK=` as each README describes, then the profile line (below), then
   the results as ranges, each criterion's claim with its evidence.
7. **Cross-check** against an independent tool or method the example has (per
   chapter below).
8. **What you learned** (bullets), then one line pointing to the next chapter.
9. **For deeper coverage**: only sources already named in the repo (`CLAUDE.md`,
   `_docs/00-outline.md`, `_plans/iteration-plan.md`): Enberg, *Latency*
   (Manning) as further reading; other chapters by number, title and `Part N`;
   repo files such as `examples/common/MEASUREMENT.md` or the example's
   `VALHALLA.md`. JEP numbers are named as facts with their status (below);
   no URLs except the ones already in `examples/08-zero-copy-flat/VALHALLA.md`.
   Never invent a book, author, URL or quotation, and never paraphrase or adapt
   a source book's content.
10. **Verification status** footer, after a `---` line, in the Ch0–Ch4 form:
    `*Verification status: <span class="status status--verified">verified (behavioural)</span>. …*`
    naming what `verify.sh` asserts (the criteria, briefly), what is observed
    only, and the runs it held on (`r02-run1` to `r02-run3`; Ch7 also
    `r02-vm-run1` to `r02-vm-run3`, labelled VM). Ch5 states the recheck (below).

Length: 1,900–2,500 words of prose, excluding front matter, fenced code,
include tags and table rows. Count with `scripts/wordcount.sh _docs/NN-*.md`
(the r01 method as a script: it strips the front matter, fenced blocks,
`{% … %}` tags and lines starting with `|`; inline code counts; exit 1 outside
the range). Ch0–Ch4 land at 2,489–2,500, so budget the prose and cut, do not pad.

### Code tabs: Java first

Part 2 is Java-led, so every tab group lists Java first, then C++, then Python
where the example has a Python lane:

    {% include codetabs.html langs="Java|C++" %}

    ```java
    ```
    ```cpp
    ```

or `langs="Java|C++|Python"` followed by ```` ```java ````, ```` ```cpp ````,
```` ```python ```` in that order. Always pass `langs` (the include defaults to
`C++|Python|Java` when it is omitted). Blank lines only between the tag and the
fences: any other line ends the group. A subset is allowed where a language has
nothing equivalent (the include documents subsets); a single-language excerpt is
a plain fence with no tab tag. Fence info strings are `java`, `cpp`, `python`,
`bash`, `text`, as in Ch0–Ch4.

Checked on 2026-10-22: `_includes/codetabs.html` emits `data-langs` verbatim and
`assets/js/codetabs.js` builds the tabs in the order given, so `Java|C++` and
`Java|C++|Python` render Java first. `scripts/validate.py` (`check_codetabs`)
counts the labels against the fenced blocks that follow the tag; it enforces no
language order and does not check that a fence's info string matches its label.
Nothing in S21 has to change for Java-first. Two notes for S20/S21, not for the
executors: (1) the tab script syncs the selected label across groups and pages
through `localStorage` (`lle-lang`), so a reader who picked C++ in Part 1 opens
Part 2 on C++; Java is the default only with nothing stored. (2) S21 may add a
`codetabs` check that each fence's info string matches its label, and should
widen `diagrams-yml` from chapters 0–4 to 0–8 (`for n in range(5)`).

Liquid: `_docs` pages render Liquid, and `validate.py` (`liquid`) fails a stray
`{{` or `{%` outside include tags and `{% raw %}` blocks. Java `{@link …}` and
`{}` are fine. If an excerpt contains `{{` or `{%`, put `{% raw %}` as the first
line inside the fence and `{% endraw %}` as the last line inside it, never around
the fences (a line between the tab tag and a fence ends the group). None of the
excerpts named below contains either sequence; grep yours.

## Numbers

- Every number in the prose is a configured parameter (README, `verify.sh`,
  source constants) or a value in the committed results:
  `examples/0[5-8]-*/results/r02-run{1,2,3}/` (reports `*.json`, percentiles in
  ns; `verify.log`; `recheck.log` in 05; JMH and Google Benchmark JSON) and, for
  Ch7's VM part only, `examples/07-offheap-lockfree/results/r02-vm-run{1,2,3}/`
  (`verify.log`, `vm/**`). Quote measured values as the range across the three
  runs, rounded sensibly, and say which runs. Prefer the report JSON over the
  rounded `verify.log` print where both exist (06 `verify.log` truncates: ZGC
  p99.9 prints 0.152/0.141/0.134 ms, the reports hold 0.153/0.141/0.135 ms).
- Profile line, once per chapter at the top of Measure, from
  `r02-run1/profile.json` (`cpu.model`, `cpu.logical_cpus`, `kernel.release`,
  `kernel.preempt_model`, `power.governor`, `tuned`, `clock.current_clocksource`,
  `tools.java_full`, `memory.thp_enabled`):

  > Profile for every number below: bare-metal host, an 8-core, 16-thread Intel laptop CPU (SMT on,
  > `intel_pstate`), Fedora 44 kernel 7.2 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`, Temurin 25.0.5+8.
  > Ranges are across the three committed runs `r02-run1` to `r02-run3`.

  Ch6 adds "THP `madvise`" after the clocksource. That is `memory.thp_enabled`; ZGC's heap is
  governed by `memory.thp_shmem_enabled` (`never` on this host), which is why the
  `thp` variant got no huge pages (see Large pages below).
- VM profile line, Ch7 only, at the top of the VM part, from
  `r02-vm-run1/vm/profile.json`, `vm/vcpupin.txt` and `vm/LABEL`:

  > VM profile: lab guest `lowlat-target`, 4 vCPUs on the same Intel host,
  > PREEMPT_RT kernel 7.2.11-200.lowlatrt.fc44.x86_64+rt, guest command line
  > `isolcpus=3 nohz_full=3 rcu_nocbs=3`, guest vCPU 3 pinned to host CPU 13 by
  > libvirt (a pin, not host isolation), tuned `virtual-guest`, clocksource
  > `kvm-clock`, `stress-ng --cpu 3` on guest CPUs 0-2, Temurin 25.0.5+8. Label
  > `vm`; ranges across `r02-vm-run1` to `r02-vm-run3`, each from the snapshot
  > `lab-ready-iso`. Never compared with the host numbers.

- Never a mean or average latency, anywhere. JMH's `Score` (SampleTime mean),
  Google Benchmark's `mean` aggregate, the JFR summary and the unified GC log's
  statistics tables (ZGC's `Avg`/interval columns) print averages: never quote
  them. JMH latencies come from the `p0.50`/`p0.99`/`p0.999` lines or the
  reports `verify.sh` builds; Google Benchmark per-iteration times are quoted as
  the median of the repetitions, as Ch4 does. `gc.alloc.rate.norm` (bytes per
  operation) is a normalised counter, not a latency, and may be quoted. Avoid
  the words "mean"/"average" except in a sentence that negates them
  (`validate.py` `means` fails "mean/average latency" and lists every other use).
- Means of a percentile across runs are also forbidden: give the range, or the
  three values.
- Never a number you cannot point at in a committed file. Two committed
  calibration observations may be quoted, each labelled "calibration run,
  2026-10-22, one run per row, not a committed measurement run": the 06 heap
  sweep table in `examples/06-gc-tails/README.md` (user decision, S12), and the
  07 tmpfs journal row in `examples/07-offheap-lockfree/README.md` (if used at
  all). Nothing else from READMEs: their calibration-era margins (S12 dry runs)
  and their stale status sections are not results.
- JVM flags are shown exactly as run, copied from `verify.sh` (`JVM_ARGS`,
  `JVM_FLAGS`, `gc_flags`) or from a report's `build.flags`. Host paths in
  `build.flags` (`~/…`, `/tmp/lowlat-scratch.*`) are replaced with
  `<results>` and `<scratch>`; nothing else in a flag is changed.
- Report the failures and outliers that were observed, plainly: 05 `r02-run2`'s
  original criterion 2 failure, and 07 `r02-run1`'s criterion 2 margin of 1.01
  (both detailed per chapter below).

## Part 2 decisions that shape the prose

- **JDK.** Temurin 25.0.5 LTS, pinned, on the host, in CI and in the guest. JDK 27
  is GA (2026-09-15) and not LTS; the book does not use it (Q1). JDK 28 and
  Valhalla exist as early-access builds only and appear as status, never as code
  or numbers (Q2).
- **AOT (Ch5).** The Leyden AOT cache on the plain JVM is the measured lane (JEP
  483, 514, 515 in JDK 25), under G1 because on JDK 25 the cache archives heap
  objects only with G1 (JEP 516, JDK 26, lifts that). GraalVM CE native-image is
  prose only and never on the hot path; its CE edition documents Serial and
  Epsilon collectors only (G1 in native-image is Oracle GraalVM). Q3.
- **Affinity (Ch7).** Guest isolation (`isolcpus`/`nohz_full`/`rcu_nocbs`) plus a
  libvirt `vcpupin` (vCPU 3 to host CPU 13), both versioned in `scripts/lab/`
  and restored by snapshot (Q4). The pin is not host isolation: the host may
  still run other work and take interrupts on CPU 13 and its sibling CPU 5. No
  thread pinning on the host (it proves nothing without isolation, and isolation
  would be a host change).
- **Large pages (Ch6).** Host THP only (`madvise`, no host change). The host
  refuses huge pages for ZGC: its heap is shared memory (`memfd:java_heap`),
  governed by `shmem_enabled`, which is `never`, and every `thp.gc.log.gz` logs
  `Large Page Support: Disabled (OS enforced)`. The `thp` variant is therefore a
  second ZGC run on 4 KB pages, observed, and the chapter draws no conclusion
  about huge pages. Huge pages for ZGC are versioned VM config in Part 5 (Q5; the
  Follow-ups row "THP for ZGC refused by the host" in `r02-plan.md`).
- **Unsafe (Ch7).** Chronicle, through its `jffi` native-call dependency, and the
  JMH harness call `sun.misc.Unsafe` memory-access methods; Agrona is not the
  source. JDK 25 warns at first use (JEP 471, JDK 23, deprecated the methods for
  removal; JEP 498, JDK 24, made the warning the default) and the warnings stay
  on. Q6.
- **Chronicle (Ch7).** Only the open-source line (Queue 2026.7, Map 2026.1, Bytes
  2026.4, Affinity 2026.2, Apache-2.0). The commercial edition's features
  (asynchronous `BufferMode`, the pre-toucher, replication, encryption) are not
  used and are surveyed in Appendix F; `BufferMode.None` is the only open-source
  buffer mode. Chronicle's usage analytics are disabled in code
  (`ChronicleAnalytics.disable()`), in the pom and in `verify.sh`; say so in one
  or two sentences. The open-source pre-toucher hook is a stub that recurses
  until `StackOverflowError` (confirmed with `javap` during calibration): the
  code never calls it, and the chapter says not to. OSS Chronicle Queue does not
  `fsync` per append: no durability claim.
- **Headroom (Ch6).** The undersized heap is 1.05x the measured live set (user
  decision); the sweep that found the cliff is calibration data, labelled so.
- **Python** only in Ch6 and Ch8, where it teaches a divergence (Q9).
- **Flat wire (Ch8).** `contracts/flat/parcel-v1`, minimal and versioned; SBE is
  Ch22's subject (Q10).

## Part boundaries and cross-links

- Ch5 owns JVM mechanics (TLAB, escape analysis, tiered JIT, deoptimization, AOT
  cache). Data-structure-level elimination of work in three languages is
  Chapter 9, *Eliminating work: allocation, cache locality, false sharing*
  (Part 3): Ch5 and Ch8 point there and do not teach cache locality or false
  sharing beyond what their measurement needs.
- Ch7 owns the Java libraries (Agrona, Disruptor, Chronicle, OpenHFT Affinity)
  and uses memory orders only as far as the hand-off needs. Lock-free theory in
  three languages is Chapter 10, *Lock-free and wait-free synchronization*
  (Part 3).
- Ch7's affinity part previews isolation. Chapter 15, *CPU partitioning and the
  noisy-neighbour problem*, and Chapter 18, *Latency config as code* (Part 5),
  own it as versioned deployment config; Chapter 14 covers PREEMPT_RT.
- Ch8's flat record points to Chapter 22, *Aeron and SBE* (Part 6), for a
  production flat wire.
- Off-path telemetry is Part 7 (*Observing Without Wrecking It*). (06's README
  says "Part 5 owns low-overhead observability": wrong part, do not repeat it.)
- Back-links by number and title: Chapter 1, *Latency vs bandwidth: latency is a
  distribution* (its Java runs showed the warm-up p99.9 that Ch5 explains;
  "Part 2 treats the cause"); Chapter 2, *Modelling with Little's Law and
  Amdahl's Law* (in-flight count, 480 parcels at 1 kHz, 4,800 at 10 kHz);
  Chapter 3, *Measuring correctly: clocks, percentiles and coordinated
  omission* (latency is `done - intended_emit`; a stall charges every parcel
  behind it); Chapter 4, *Benchmark harnesses: Google Benchmark, pyperf and JMH*
  (JMH SampleTime, forks, `Blackhole`, warm-up iterations). Ch6 to Ch8 back-link
  to Ch5 (and each other) by title.
- Links: other chapters are named, not linked, unless they have shipped; a link
  to a shipped chapter uses `{{ '/docs/NN-slug/' | relative_url }}` (the only
  `{{ }}` form validate.py accepts).

## Ch5 — What the JVM costs (S16, `examples/05-jvm-costs/`)

Languages in the example: Java and C++ (no Python directory). Workload: the
light tracker's `decide(ParcelEvent)` on JMH and on the line at 1 kHz x 20 s
(20,000 parcels, UDP 47250), first window parcels 0–1,999, steady the rest.
Every Java line run uses `-XX:+UseG1GC -Xms256m -Xmx256m` (`JVM_ARGS`).

**Mechanisms to explain:** TLAB bump allocation (the cost is the bytes added to
the next young collection, not the `new`); escape analysis and scalar
replacement after inlining; tiered compilation (interpreter, C1 tiers 1–3 with
profiling, C2 tier 4) and deoptimization back to the interpreter; why a JVM that
binds at once pays this on the first parcels of the belt; an in-process warm-up
replay before the bind; the Leyden AOT cache (training run with
`-XX:AOTCacheOutput`, then `-XX:AOTCache` with `-XX:AOTMode=on`, so a cache the
JVM cannot use is a startup failure, never a silent fallback), under G1 and why
(JEP 516); a cache records the module graph, so the line run uses a cache
trained with the same JFR flags (README). C++ contrast: no JIT, so no warm-up;
a stack value costs nothing, `std::make_unique` costs an allocator call,
`std::pmr::monotonic_buffer_resource` turns it into a pointer bump.

**Claims and evidence:**

| Claim | Evidence |
|---|---|
| `escaping` 24 B/op, `scalar-replaced` under 0.001 B/op (0.00016–0.00017), `--no-escape-analysis` 24 B/op again; 24 B = 12-byte header + `int` + `long` (exact counters) | `alloc-per-op.json`; `verify.log` criterion 1 lines |
| C++ `--allocating` 16 B/op and one allocation per parcel, value 0 (1.3e-06 B/op), pmr arena 0.00 B/op through the global allocator (observed) | `gbench-alloc.json`; `verify.log` criterion 1 (C++) and observed lines |
| C++ median ns per decision (observed, median of 30 repetitions): value 2.3, `--allocating` 11.1–11.2, pmr 3.7–3.8 | `verify.log` "observed (C++) median ns/op" |
| `--unwarmed` first-window p99.9 13.4–28.5 ms against steady p99.9 0.26–0.49 ms; ratio 58.3x, 51.7x, 98.3x (bound 5x) | `java-unwarmed-first-2000.json`, `-steady.json`; `recheck.log` criterion 2 |
| The p99 ratio swings: 24.7x, 1.7x, 52.0x (first-window p99 11.0, 0.34, 11.0 ms) | `verify.log` "java unwarmed: p99 first …" |
| `warmed` first-window p99 0.23–0.33 ms, ratio to steady 1.1x in all runs (bound 3x); first-window p99.9 0.29–0.36 ms | `java-warmed-*.json`; `verify.log` criterion 3 |
| `aot-cache` first-window p99.9 0.61–3.2 ms (observed; p99.9 ratio 2.2x, 2.2x, 12.5x) | `java-aot-cache-first-2000.json`; `verify.log` |
| Time to ready, median of 5 alternating launches: 50.7–54.8 ms with the AOT cache against 173.1–176.9 ms without (ratio about 0.3, bound 0.8); `-Xlog:aot` shows `Opened AOT cache`; `runtime.aot.used` true | `time-to-ready.json` `median_aot_cache`/`median_no_cache`; `aot-cache.aot.log`; `verify.log` criterion 4 |
| JIT events (observed): `--unwarmed` compiles 245–248 methods in the first window (16–19 at tier 4); `warmed` compiles 1,059–1,069 before the first parcel (234–236 at tier 4) and 20–24 in the first window; `aot-cache` 183–189 at startup and 266–270 in the first window, 0 deoptimizations there | `verify.log` "JIT events per window"; `runtime.jit` in `java-<variant>.json` |
| Receive-thread allocation per parcel, protobuf parse included (observed): 732.7 (`--unwarmed`), 667.3 (`warmed`), 654.4 (`aot-cache`) B/parcel in every run; Ch8 removes most of it | `verify.log` "allocated bytes per parcel"; `runtime.alloc_bytes_per_parcel` |
| C++ consumer first-window/steady p99 ratio 1.0 in all runs (observed): no JIT, residual cost is page faults and cold caches | `verify.log` "C++ (no JIT)" |
| Count 20,000, dropped 0, every report passes `check`, `build.flags` carries the JVM args | `verify.log` criteria 5 and 6 |

**Criterion 2, told plainly.** The criterion was first written on p99 (first
window at least 5x steady). In `r02-run2` it failed: 1.7x. The cold stall is
a stall at the start: the first-window maximum is 30.3, 15.2 and 30.3 ms, and
31, 15 and 31 parcels land above 1 ms (0.75 to 1.55 % of a 2,000-parcel
window). The window's p99 is its 21st-worst parcel, so it sits on the stall's
edge and lands inside it in runs 1 and 3 and outside it in run 2 (15 parcels).
The p99.9, its 3rd-worst parcel, lands inside every time. By user decision the criterion is asserted on p99.9,
the p99 ratio is printed as observed, and `RECHECK` re-evaluated the committed
reports of all three runs without rerunning (`recheck.log` in each run
directory: 58.3x, 51.7x, 98.3x). Run 2's `verify.log` still records the
original failure; say so, and say the run was not repeated. This is a
measurement lesson worth a paragraph (which percentile a window can resolve),
back-linking Chapter 1.

**Asserted vs observed** (`verify.sh` header): asserted 1 (JMH and C++ bytes,
exact counters), 2 (p99.9), 3, 4, 5, 6. Observed only: compilations and
deoptimizations per window, allocated bytes per parcel, the C++ first/steady
split, the C++ value/allocating/pmr times and the pmr counter, the AOT
first-window p99, the async-profiler share.

**Code excerpts** (verify each line against the file):

1. `Java|C++`: `Tracker.decide` and the `DivertDecision` record
   (`java/src/main/java/io/patterncatalyst/lowlat/jvmcosts/Tracker.java`,
   `DivertDecision.java`) against `decide` and `struct Decision` in
   `cpp/include/lowlat/jvmcosts/tracker.hpp`.
2. `Java|C++`: `AllocationBenchmark` methods `escaping`, `scalarReplaced`,
   `scalarReplacedNoEscapeAnalysis` (the `@Fork(value = 2, jvmArgsAppend =
   "-XX:-DoEscapeAnalysis")` line) and `sumOfDecisions`
   (`AllocationBenchmark.java`) against `BM_Decide_Value`, `BM_Decide_Allocating`
   and `BM_Decide_Pmr` in `cpp/src/alloc_bench.cpp`. Explain that the C++
   counter is a replaced global `operator new` (same file) and JMH's is
   `-prof gc`.
3. Java only (plain fence): `WarmUp.replay` and `WarmUp.awaitCompilerQuiet`
   (`WarmUp.java`), and the warm-up branch of `Costs.main` (`Costs.java`). Prose:
   C++ has nothing to warm; that is the divergence.
4. Plain `bash` fence: the AOT lines of `verify.sh` (`train_aot`, the
   `run_java aot-cache "-XX:AOTCache=$AOT_OBSERVED" -XX:AOTMode=on …` line and its
   comments). `JVM_ARGS=(-XX:+UseG1GC -Xms256m -Xmx256m)` shown as in the script.

**Figures:** 5.1 `05-jit-tiers` under `## Diagram`; 5.2 `05-escape-analysis` in
the allocation part of Concept or How the code works.

**Cross-check:** async-profiler 4.6's allocation event on the `escaping`
benchmark attributes 100 % of the sampled bytes to the `DivertDecision` leaf in
all three runs (`verify.log`, `async-alloc/`), an independent view of the 24
B/op JMH counts; JFR `jdk.Compilation`/`jdk.Deoptimization` per window (counted
by `JitWindows` from the recording) confirm the warm-up mechanism behind the
latency ratio (compiles move from the first window to startup); the AOT log line
and `runtime.aot.used` confirm the cache was used, not just passed.

**Mention** that the async-profiler lane is optional and user-local
(`scripts/deps/install-async-profiler.sh`). Do not attribute the `aot-cache`
run-3 first-window p99.9 (3.2 ms) to a cause; it is an observed value.

## Ch6 — GC for tails (S17, `examples/06-gc-tails/`)

Languages: Java, C++ and Python. Workload: 10 kHz x 30 s (300,000 parcels;
Java UDP 47260, Python 47261, C++ 47262); live set 1,804–1,810 MB measured
(`verify.log` "live set"; target `--live-set-mb 1750`); scan history at
`--alloc-mb-per-s 400`, measured 47,639 B/parcel on the receive thread in every
run (about 476 MB/s at 10 kHz); every Java variant `-Xms4g -Xmx4g
-XX:+AlwaysPreTouch` and `-Xlog:async`; the recording starts after setup
(`Flight.during`), so setup pauses are not counted.

**Mechanisms to explain:** what each collector stops (Parallel: everything, and
a full collection walks the live set; G1: concurrent marking, stop-the-world
evacuation; Generational ZGC, the only ZGC mode in JDK 25 (JEP 490): marking,
relocation and reference processing concurrent, short phase pauses;
Generational Shenandoah, product in JDK 25 (JEP 521), concurrent evacuation);
the rolling manifest that makes overwritten entries die in the old generation;
headroom against allocation rate: a concurrent collector that runs out of free
heap makes the allocating thread wait (allocation stall), which is a pause by
another name and does not appear as a GC pause; pre-touch; the `thp` variant, refused by the host (no huge pages for ZGC's shared-memory heap);
CPython's refcount plus generational cycle collector (3.14.8; 3.14.0–3.14.4
shipped an incremental collector, reverted in 3.14.5) and `gc.freeze()`; C++
ownership: `free()` is the cost, and where it runs is the choice.

**Claims and evidence** (Java maxima from `java-<variant>-gc-pause.json`
`percentiles.max`; latencies from `java-<variant>.json`):

| Claim | Evidence |
|---|---|
| Max GC pause: Parallel 158–170 ms, G1 21.0–21.6 ms, ZGC 0.017–0.036 ms, Generational Shenandoah 0.53–0.82 ms (criterion 1: STW at least 10 ms and 20x ZGC, ZGC under 1 ms, Shenandoah-gen at most 1/5 of STW) | `*-gc-pause.json`; `verify.log` criterion 1 |
| End-to-end p99.9: Parallel 152.4–157.2 ms, G1 16.4–16.6 ms, ZGC 0.135–0.153 ms, Shenandoah-gen 0.158–0.180 ms (criterion 2: ZGC at most 1/3 of STW) | `java-<variant>.json` `p99_9`; `verify.log` criterion 2 |
| Under Parallel the p99 is already 130.8–135.4 ms while p50 is 0.06 ms in every variant | `java-stop-the-world.json` |
| ZGC's end-to-end maximum is 2.45–2.69 ms while its longest GC pause is under 0.04 ms: the maximum is not a GC pause; do not attribute it | `java-zgc.json` `max`; `java-zgc-gc-pause.json` |
| Undersized heap (1,895–1,901 MB, 1.05x the live set): 532–976 allocation stalls, longest 60.7–156.9 ms, p99.9 49.6–134.9 ms against right-sized ZGC 0.135–0.153 ms (criterion 3); its GC pauses stay at 0.040–0.051 ms max, so the stalls are the whole cost | `java-undersized-heap-gc-pause.json` `runtime.alloc_stalls` (`count`, `max_ns`) and `max`; `java-undersized-heap.json`; `verify.log` criterion 3 |
| Observed: non-generational Shenandoah p99.9 0.150–0.155 ms, max pause 0.41–0.51 ms; `thp` p99.9 0.142–0.146 ms, max pause 0.022–0.030 ms, but it got no huge pages (a second ZGC run on 4 KB pages: it shows nothing about huge pages); `jfr-off` p99.9 0.145–0.159 ms, 6 to 11 microseconds above ZGC's in the same run, inside ZGC's own run-to-run spread and the opposite direction from a recording cost; say exactly that, no more | reports; `verify.log` "observed (no bound)" |
| Python `cyclic-garbage`: 9 generation-2 collections in the window (99 gen-1, 1,092 gen-0), longest collection 144.0–150.6 ms, p99.9 138.1–144.4 ms; `frozen`: 0 collections, 119,780 objects frozen, p99.9 0.154–0.168 ms (criterion 4) | `python-<variant>.json` and `-gc-pause.json` `notes`, `percentiles` |
| C++ `bulk-free` max 3.65–3.87 ms and p99.9 2.08–2.19 ms against `deferred-free` p99.9 0.135–0.141 ms (criterion 5: at least 10x); 33 waves, 320,000 entries destroyed inline or by the reclaimer | `cpp-<variant>.json` `percentiles`, `notes` |
| Observed pair: `deferred-free` max 0.79–0.85 ms, `no-free` control max 0.36–0.49 ms, both single OS-noise events; the reclaimer claim rests on criterion 5, not on these maxima | `verify.log` "cpp deferred-free max …"; README |
| Every report: count 300,000, dropped 0, `check`, `build.flags` names GC and heap | criterion 6 |

**The headroom cliff (calibration).** The user's decision fixed the undersized
heap at 1.05x the live set after a sweep. Quote the sweep only from the table in
`examples/06-gc-tails/README.md` ("Why 1.05x: the headroom cliff"), labelled:
calibration runs on 2026-10-22, one run per row, not the committed measurement
runs, reproducible with `SWEEP=1 examples/06-gc-tails/verify.sh`. The point is
the shape: 0 stalls from 4 GB down to 1.10x, a handful at 1.075x, hundreds at
1.05x; allocation rate is not the lever, headroom is (1.3x at a doubled rate
gave 0 stalls and more minor collections). Do not mix sweep numbers with the
`r02-run` numbers in one sentence.

**Asserted vs observed** (`verify.sh` header): asserted 1–6; observed only
`shenandoah`, `thp`, `jfr-off`, and the `deferred-free`/`no-free` maxima.

**Code excerpts:**

1. `Java|C++|Python`, the per-parcel handler's memory in each runtime:
   `Tracker.track` (`java/src/main/java/io/patterncatalyst/lowlat/gctails/Tracker.java`);
   `Tracker::close_wave` (`cpp/src/tracker.cpp`, the `switch (policy_)` with
   `bulk_free`, `deferred_free`, `no_free`); `Tracker.track`
   (`gctails-py/src/lowlat_gctails/tracker.py`, the `if self.cyclic:` loop that
   builds `state -> samples -> sample -> state`).
2. `Java|Python`, measuring pauses without touching the parcel path:
   `Flight.during` (`Flight.java`) and `GcPauseLog.__call__` (and `__enter__`)
   (`gctails-py/src/lowlat_gctails/pauses.py`). C++ has no collector to observe;
   say it in the sentence before the group (that is why the group has no C++
   tab).
3. Python only (plain fence): the `frozen` setup in `cli.py` `main`
   (`gc.collect()` then `gc.freeze()`).
4. Plain `bash` fence: `gc_flags` in `verify.sh` (the `case` mapping variants to
   `-XX:+UseParallelGC`, `-XX:+UseG1GC`, `-XX:+UseZGC`,
   `-XX:+UseShenandoahGC -XX:ShenandoahGCMode=generational`), plus the heap
   flags `-Xms4g -Xmx4g -XX:+AlwaysPreTouch` as the README's by-hand command
   shows them.

**Figures:** 6.1 `06-collector-pauses` under `## Diagram`; 6.2
`06-headroom-stall` with the headroom section; 6.3 `06-refcount-vs-tracing` with
the C++/Python contrast. Figure 6.3 draws its lanes in the order C++, Python,
Java (the figure grammar); that is fine, the prose and tabs stay Java-first.

**Cross-check:** the unified GC log against JFR, three ways. (1) Event counts:
each `java-<variant>.jfr-summary.txt` `jdk.GCPhasePause` count equals the
`count` of its `-gc-pause.json` (run 1: 13 Parallel, 16 G1, 38 ZGC, 91
Shenandoah-gen; check runs 2 and 3) and `jdk.ZAllocationStall` equals
`alloc_stalls.count`. (2) Pause sizes: in `<variant>.gc.log.gz`
(`zcat … | grep '] GC(.*) Pause'`) the pauses after the `Pause Full
(System.gc())` line belong to the measured window; the largest Parallel
`Pause Full (Allocation Failure)` there is 157.2, 169.2 and 157.6 ms against the
JFR maxima 157.5, 169.6 and 158.1 ms (re-read them before quoting; the two
tools time the pause at different points, so they agree closely, not exactly).
(3) Why the window matters: the same logs show setup pauses JFR never saw,
`Pause Full (System.gc())` of 178.7–185.9 ms in the Parallel runs and G1
evacuation pauses up to 72.5–75.5 ms while the manifest was built, all before
the recording started. That is the reason `Flight.during` starts the recording
in-process. Never quote the GC log's statistics tables (averages). Python's
cross-check is the callback count against `gc.get_count`-style notes
(`collections=1200` = 1,092 + 99 + 9); C++'s is the `notes` counters
(`destroyed_inline`/`reclaimed`/`retained` = 320,000).

## Ch7 — Off-heap and lock-free Java (S18, `examples/07-offheap-lockfree/`)

Languages: Java and C++ (no Python directory). Workload: receive thread to
hand-off (65,536 slots, `--slots`) to decide thread; divert commands on a
separate UDP socket (47271) and never through the hand-off; every scan event
appended to an audit journal after the command; 10 kHz x 20 s = 200,000
parcels, seed 42, data UDP 47270, C++ lane 47274; windows split at parcel
20,000; JVM `-Xms1g -Xmx1g -XX:+AlwaysPreTouch -XX:+UseG1GC
-Dchronicle.analytics.disable=true` (`JVM_FLAGS`) plus the Chronicle
`--add-opens`/`--add-exports` list (`chronicle.jvmArgs` in `java/pom.xml`; name
it, do not paste it).

**Mechanisms to explain:** parking versus spinning (a `BlockingQueue` consumer
parks when empty and is woken through the kernel; a spinning consumer never
blocks and holds a core at 100 %, so it belongs on a dedicated, pinned thread);
Agrona `OneToOneRingBuffer` over `UnsafeBuffer` on a direct `ByteBuffer`
(`tryClaim`/`commit`, `IdleStrategy`); the Disruptor's preallocated events and
`BusySpinWaitStrategy`; sequences that only grow and `slot = sequence & (slots -
1)` with a power-of-two ring, each side writing only its own cursor on its own
cache line (Figure 7.2); release/acquire as the minimum ordering, mapped to
`VarHandle` `setRelease`/`getAcquire` with the full treatment in Ch10; the
command path never shares the data queue (CLAUDE.md rule); a memory-mapped
journal removes the per-event system call but not the first-touch page fault
(fault-around maps several cached pages per fault on btrfs); an off-heap map
moves a million entries out of the old generation, and its lookup costs more
than a `HashMap`'s (say so); affinity: what guest isolation and the pin do and
do not promise (README "What isolation and the pin promise").

**Claims and evidence (host):**

| Claim | Evidence |
|---|---|
| Decide-thread voluntary context switches over 200,000 parcels: `blocking-queue` 199,523–199,540, `agrona-spsc` 29–47, `disruptor` 37–41 (criterion 1: spin at most 1 %, blocking at least 25 %); `linked-queue` and `disruptor-blocking-wait` 199,380–199,541, `agrona-spsc-backoff` 358,431–359,020 (observed: the park phase returns the switches) | `java-<variant>.json` `runtime.ctx_switches`; `verify.log` "voluntary / involuntary per run" |
| Steady-window hand-off p99: `blocking-queue` 10,495–10,871 ns, `agrona-spsc` 576–590 ns, `disruptor` 641–2,117 ns (criterion 2: at most 1/5 of `blocking-queue`) | `java-<variant>-handoff-steady.json`; `verify.log` "hand-off p50 / p99 / p99.9" and criterion 2 |
| JMH publish allocation: Agrona 0 B/op, Disruptor 0.001 B/op, `linked-queue` 96.1–97.1 B/op (criterion 3); `blocking-queue` 90.2–95.7 B/op (observed: the immutable `Scan` record per publish) | `jmh.json`; `verify.log` criterion 3 block |
| Journal: tailer reads back 200,000 events in order for both journals; `chronicle-journal` decide thread 0 write system calls against 200,000 for `write-per-parcel` (exact); minor faults 1,427–1,459 against 64–67, journal 15,002,637 B on btrfs, block size 64 MiB, roll cycle `FAST_DAILY` (criterion 4) | `verify.log` criterion 4 block; end-to-end report `notes` |
| Observed append latency, steady window, btrfs: Chronicle p50 311–322, p99 800–835, p99.9 4,643–5,299 ns; `write-per-parcel` p50 1,071–1,079, p99 2,485–3,023, p99.9 5,139–7,607 ns. Not asserted: the ratio is set by the journal's file system, not the technique | `verify.log` "append p50 / p99 / p99.9, steady window" |
| Old generation after a full GC: `chronicle-map-manifest` 13.99–14.00 MB against `on-heap-manifest` 137.3–137.4 MB, baseline 3.8 MB (criterion 5) | `verify.log` criterion 5; `runtime.gc.old_gen_used_bytes` |
| Observed: manifest lookup p50/p99 Chronicle Map 280–282 / 1,204–1,313 ns against `HashMap` 31–33 / 402–445 ns (the off-heap map is slower per lookup; it buys heap footprint) | `verify.log` "manifest lookup p50 / p99" |
| Observed: `on-heap-manifest` hand-off p99.9 227–397 us against 1.2–2.4 us for `chronicle-map-manifest`; the run's GC log shows G1 young pauses during the run (run 1: 23.1 ms at 15.9 s). Attribute only with the log line you quote; otherwise call it observed | `verify.log`; `on-heap-manifest.gc.log` |
| C++ lane (observed): `atomic-spsc` hand-off p50/p99/p99.9 121–127 / 326–329 / 431–511 ns, voluntary switches 0; `atomic-wait` 1,908–2,006 / 9,023–9,439 / 53,855–76,863 ns, voluntary 199,861–199,892 (parks like the blocking queue) | `verify.log` "observed: the C++ lane"; `cpp-<variant>-handoff*.json` |
| Every run: count 200,000, dropped 0, no overflow, every divert command received, every report passes `check` | criterion 6 |

**Criterion 2's run 1, told plainly.** It passed in all three runs, run 1 at a
margin of 1.01: Disruptor steady p99 2,117 ns against a bound of 2,131 ns (one
fifth of 10,655 ns); runs 2 and 3 were 670 and 641 ns against bounds of 2,174
and 2,099 ns. By user decision the bound stays at one fifth and run 1 is
reported as an observed outlier. Do not explain it (no cause was measured);
say a spinning consumer on an unisolated host is at the scheduler's mercy, which
is the VM part's motivation.

**VM part (labelled `vm`, never compared with host):**

| Claim | Evidence |
|---|---|
| Decide-thread involuntary context switches per 200,000-parcel run: unpinned 174,388–313,298, pinned-isolated 0–5, in all nine alternations of each (criterion 1: pinned at most 10, unpinned at least 100) | `r02-vm-run{1,2,3}/verify.log` `placement …: involuntary N` lines |
| Steady hand-off p99.9, median of three alternations per run: unpinned 1.09–1.86 ms (1,864,703, 1,087,487, 1,640,447 ns), pinned 51–55 us (51,167, 54,559, 52,383 ns) (criterion 2: pinned at most 1/2 of unpinned) | criterion 2 line of each `verify.log` |
| The pinned thread ran only on CPU 3 (`Cpus_allowed_list` 3, `/proc` CPU 3); unpinned allowed on 0-3 and seen on 0-2; guest Temurin 25.0.5, `isolcpus=3` on the command line, `stress-ng` confined to CPUs 0-2 | `verify.log` check lines; `vm/check-prereqs.txt`, `vm/guest-java.txt` |
| vCPU 3 pinned to host CPU 13, vCPUs 0-2 free over 0-15 | `vm/vcpupin.txt` |

Say why pinned p99.9 stays at tens of microseconds: the pin narrows the tail and
does not remove the host's share on CPU 13 and its sibling 5 (README). Never set
a VM number beside a host number in one sentence or table.

**Asserted vs observed** (`verify.sh` header; README "VM part"): host asserted
1–6; observed: `agrona-spsc-backoff`, `disruptor-blocking-wait`, append
p50/p99/p99.9, manifest lookup cost, the C++ lane. VM asserted 1–3.

**Code excerpts:**

1. `Java|C++`, the hand-off: `RingHandOff.publish` and `RingHandOff.consume`
   (`java/src/main/java/io/patterncatalyst/lowlat/offheap/RingHandOff.java`;
   include the constructor if the `UnsafeBuffer` over `ByteBuffer.allocateDirect`
   is explained there) against `SpscRing::try_push` and `SpscRing::try_pop` with
   the `alignas(kCacheLine)` members (`cpp/include/lowlat/offheap/spsc_ring.hpp`).
2. Java only (plain fence): `DisruptorHandOff.publish` (`DisruptorHandOff.java`),
   the claim-write-publish of a preallocated `Slot`.
3. C++ only (plain fence): `SpscRing::wait_for_data` and `notify_consumer`
   (`spsc_ring.hpp`), the `atomic::wait` variant, if the C++ lane's parking is
   taught; otherwise describe it from `cpp/src/handoff.cpp`.
4. Java only, two plain fences: the `ChronicleJournal` static initializer,
   constructor (`writeBufferMode(BufferMode.None)`) and `append`
   (`ChronicleJournal.java`), then `FileJournal.append` (`FileJournal.java`).
5. Java only (plain fence): `ThreadPlacement.PINNED_ISOLATED` (`ThreadPlacement.java`,
   the `requireIsolatedCpu` call and `AffinityLock.acquireLock(ISOLATED_CPU)`
   block with its check). Optionally a `text` fence of
   `scripts/lab/guest-profiles/isolate-cpu3.conf` as the versioned guest config.

**Figures:** 7.1 `07-handoff-topology` under `## Diagram`; 7.2
`07-ring-sequences` with the ring explanation; 7.3 `07-affinity-vm` at the top
of the VM part, after the VM profile line.

**Cross-check:** the mechanism counters and the latency agree, from different
sources: `/proc/<pid>/task/<tid>/status` switches (read by `verify.sh` via
`task_ctx_switches`) against the hand-off percentiles from the in-process
recorder; `syscw` from `/proc/<pid>/task/<tid>/io` against the journal readback
count; JMH `-prof gc` publish bytes against the old-generation
`MemoryPoolMXBean` reading; the C++ lane, built on different primitives,
reproduces the park/spin split (`atomic-wait` voluntary switches about one per
parcel, `atomic-spsc` 0). In the VM, `Cpus_allowed_list` and the observed CPU
confirm the placement the latency claim depends on.

**Chronicle wording:** describe what the classes do and what was measured; no
superlatives, no "ultra-low latency", no vendor claims. One short paragraph on
analytics (disabled in four places, `validate.py` check `chronicle`), one on the
open-source/commercial line (features not used, Appendix F), the pre-toucher
stub sentence, the no-`fsync` sentence.

## Ch8 — Zero-copy and flat data (S19, `examples/08-zero-copy-flat/`)

Languages: Java, C++ and Python. Workload: the simulator at 10 kHz x 10 s
(100,000 parcels) once per wire format (`--wire flat` for the 80-byte
`parcel-v1`; protobuf default), UDP 47281 (`protobuf-decode`) and 47282
(`flat-ffm`), the common `EventReceiver` with the decoder as the only
difference, `--enable-native-access=ALL-UNNAMED` (the only JVM flag the line
runs pass: default collector and heap, no warm-up); JMH decodes the same parcels
from one direct buffer; the table benchmark sweeps 1,000,000 in-flight parcels
(about 2 % due per tick, shuffled slots); JOL on 100,000 parcels.

**Mechanisms to explain:** a protobuf parse builds a message, a nested
`Dimensions` and a `String` per datagram; `MemorySegment.ofBuffer` over the
receive buffer once, one reused `FlatView` re-pointed per datagram; a
`StructLayout` of unaligned little-endian value layouts and `VarHandle`s at
derived offsets (why unaligned: a UDP payload is not guaranteed aligned; why
little-endian named: the wire is LE whatever the host); the contract
(`contracts/flat/parcel-v1`: fixed size and offsets, `schema_id`/`version`
first and checked before the size, explicit endianness, evolution rules, golden
bytes); `Arena` for an explicit lifetime outside the heap; a flat table against
an array of references (one run of memory against a pointer per parcel); compact
object headers (JEP 519, product in JDK 25; default in JDK 27 under JEP 534)
shrink the object, not the flat table; `Linker` downcall of
`clock_gettime(CLOCK_MONOTONIC)` with a hand-written `FunctionDescriptor`
(jextract is early access only), standard against `Linker.Option.critical`.
C++: `memcpy`/`std::bit_cast` from `std::span<const std::byte>` and
`std::start_lifetime_as` (C++23, compiled with the pinned Clang 22 and GCC 16),
and why a `reinterpret_cast` read is not a variant (undefined behaviour: no
`Parcel` object lives there); `std::vector<ParcelState>` is flat by default.
Python: `struct.Struct.unpack_from` over a `memoryview` copies no bytes but
still creates objects: zero-copy is not zero-allocation in CPython.

**Valhalla (Q2).** Conceptual only, in a dated status box (a blockquote or
`### Value classes: status at 2026-10-22`), content from `VALHALLA.md` only:
JEP 401 Value Classes and Objects (Preview) integrated into the JDK 28 mainline;
JDK 28 early access only, no GA date (the cadence points near March 2027); the
Valhalla EA build `27-jep401ea3+1-1` under Oracle's early-access terms; the
project uses no prerelease in any build, script or number; re-visit at JDK 28
GA. What value classes would change (`ParcelState[]` stored flat) and what they
would not (a `FlatView` over a receive buffer stays a view; the off-heap table
keeps its explicit lifetime). Figure 8.2's ghost box is the visual. Never
"Valhalla is coming soon", never a number for it.

**Claims and evidence:**

| Claim | Evidence |
|---|---|
| C++, Java FFM and Python readers decode the golden files of seeds 1, 42, 2026 (8 records each) identically to the committed JSON (criterion 1) | `golden-agreement.txt`; `verify.log` criterion 1 |
| JMH decode: `flat-ffm` 0.0012 B/op, p50 16 ns; `protobuf-decode` 544–576 B/op, p50 150–160 ns (criterion 2: flat at most 1 B/op, protobuf at least 100 B/op, p50 ratio at least 3x) | `jmh/java-*.json`; `verify.log` criterion 2 lines |
| Line, receive-thread bytes per parcel: `flat-ffm` 8.76 B against `protobuf-decode` 531–591 B (criterion 3: at most 5 %); the floor is not zero (first decode links the `VarHandle`s and loads classes, spread over 100,000 parcels) | `runtime.alloc_bytes_per_parcel`; `verify.log` criterion 3; README |
| Table sweep of 1,000,000 parcels, JMH p50: `flat-table` 0.97–1.00 ms against `object-table` 5.01–5.03 ms (criterion 4: at most 1/2) | `jmh/java-*-table.json`; `verify.log` criterion 4 |
| Downcall agrees with `System.nanoTime()`: largest skew outside the `nanoTime()` bracket 0 ns for standard and critical (criterion 5). Per-call p50 (observed): `nanoTime` 12 ns, standard 18–20 ns, critical 17 ns | `clock-check.json` `max_skew_ns`; `verify.log` |
| JOL (observed): `ParcelState` 40 B, 32 B with `-XX:+UseCompactObjectHeaders`; object table of 100,000 parcels 4,400,016 B and 3,600,016 B; flat table 2,400,000 B (24 B a slot) either way; protobuf `ParcelEvent` 80 B either way | `footprint-standard.json`, `footprint-compact-headers.json`; `verify.log` compact-headers lines |
| C++ (observed, median of the Google Benchmark repetitions): per 1,024 records `decode-memcpy` 9,047–9,455 ns, `decode-bit-cast` 8,511–8,855 ns, `decode-start-lifetime-as` 7,615–7,851 ns; sweep `flat-table` 0.90–0.91 ms, `pointer-table` 4.77–4.80 ms | `cpp/gbench.json`, `cpp/cpp-*.json`; `verify.log` C++ lane |
| Python (observed): `unpack_from` and `ParseFromString` both allocate 8.7 blocks and 6.7 new `int` objects per parcel; per-call p50 344–346 ns against 1,165–1,210 ns (each sample includes two `perf_counter_ns` reads) | `python/python-allocations.json`, `python/python-<variant>.json` |
| Every report passes `check`; line runs count 100,000, dropped 0; Java reports carry `build.flags` (criterion 6) | `verify.log` criterion 6 |

**What not to claim.** The line runs' end-to-end latency is not a criterion and
does not show the decode saving: p50 57.0–57.5 us and p99 91–99 us for both
variants, with p99.9 6.6–12.8 ms in both (unwarmed JVMs, default heap; do not
attribute a cause beyond pointing to Ch5's warm-up as the known first-parcel
cost, and only as a pointer, since 08 does not measure it). The saving is about
140 ns of decode and 520–580 B of allocation per parcel, which the counters and
JMH resolve and an end-to-end percentile at this load does not. Say this
plainly. Compare C++ only with C++, Java only with Java; the C++ and Java
sweeps are each a within-language ratio (about 5x in both), never one
language's time against the other's. The clock-check `max_bracket_ns` (up to
1.36 ms) is the width of a preempted bracket, not a skew; do not quote it as
one.

**Asserted vs observed** (`verify.sh` header): asserted 1–6; observed: compact
headers (JOL), the downcall per-call cost, the C++ decode variants and tables,
the Python lane.

**Code excerpts:**

1. `Java|C++|Python`, the in-place decode: `FlatDecoder.decode`
   (`java/src/main/java/io/patterncatalyst/lowlat/flat/FlatDecoder.java`) with
   `ParcelLayout.LAYOUT` (`ParcelLayout.java`, the `StructLayout` and the
   unaligned LE value layouts) as a preceding Java-only block if needed;
   `decode_memcpy` and `view_start_lifetime_as`
   (`cpp/include/lowlat/flat/decode.hpp`); `unpack_decoder`
   (`flat-py/src/lowlat_flat/decode.py`) and `RECORD`
   (`examples/common/line-simulator/consumers/consumer-py/src/lowlat_consumer/flat.py`).
2. `Java|C++`, the table: `FlatTable.sweepDue` (and the constructor's `Arena`)
   (`FlatTable.java`) with `ObjectTable.sweepDue` (`ObjectTable.java`) as the
   Java object layout, against the two `sweep_due` overloads
   (`cpp/include/lowlat/flat/table.hpp`). Python has no table lane: no Python
   tab, and one sentence on why the lane stops at decode.
3. Java only (plain fence): `ClockGettime.link` and `standard`/`critical`
   (`ClockGettime.java`).
4. Optional `cpp` fence: the contract's `static_assert`/layout lines from
   `contracts/flat/parcel-v1/parcel_v1.hpp`, as the source of truth.

**Figures:** 8.1 `08-zero-copy-decode` under `## Diagram`; 8.2
`08-flat-vs-pointer-layout` with the table section or the Valhalla box.

**Cross-check:** two independent allocation counters agree: JMH `-prof gc`
(544–576 B/op protobuf, 0.0012 flat) and `ThreadMXBean` on the line's receive
thread (531–591 B and 8.76 B per parcel); the golden bytes cross three
independent readers; JOL footprints match the record arithmetic (8+8+4+1+1 B of
fields plus a 12-byte header, padded to 40; with an 8-byte header, 32; flat 24 B
a slot); the downcall is checked against `System.nanoTime()` on the same clock.
Back-link: Ch5's 654–733 B per parcel on the receive thread is the cost this
chapter removes (Ch5 runs at 1 kHz with its own handler; do not subtract one
from the other).

## Voice

Apply `lgtm-professional-voice` (`~/.claude/skills/lgtm-professional-voice/SKILL.md`)
while writing and run its `scripts/scan.sh` on the chapter until it reports
0 ban-tier findings. No "honest/honestly/lie" framing of people or methods (a
machine reporting a wrong value may "lie"). No reference to "the roadmap", "the
requirements", the PRD, step ids (S12, S13) or "the user"; a user decision is
stated as the book's choice ("the criterion is asserted on p99.9"). No em-dash
runs; plain declarative sentences.

Part 2 additions:

- No "magic", "free lunch", "blazing", "ultra-low", "zero-cost" (unless it is a
  measured 0), "game-changer", or vendor superlatives about Chronicle, Agrona,
  the Disruptor, ZGC or Shenandoah. Name what the library does and what was
  measured.
- "Zero-copy" means the bytes are not copied; "zero allocation" only where a
  counter shows under 1 B per operation, and then say "under 1 B/op", not "zero".
- JVM and tool flags in backticks, exactly as run. JEPs as "JEP 516"-style
  numbers with their JDK and status; never "coming in Java X" without the dated
  status.
- Collectors by their JDK names: Parallel, G1, Generational ZGC (ZGC),
  Generational Shenandoah; variant names in backticks, defects with the `--`
  prefix in prose as the READMEs do (`--unwarmed`, `--undersized-heap`).
- No GC tribalism and no language shootout: each comparison is between
  techniques or variants in one runtime, in one `verify.sh` run.
- A number is never "fast" or "slow" alone; it is set against the 480 ms budget
  or against the other variant in the same run.

## Validation checklist (Opus, after S16–S19)

1. Front matter: `title` matches the Files table; `order` 5–8; `part` exactly
   `The Managed-Runtime Question`; `description` quoted; `duration` present.
2. `scripts/wordcount.sh _docs/0[5-8]-*.md`: each 1,900–2,500.
3. Spine: all ten sections present in order; Verification status footer names
   the asserted criteria, the observed-only items and the runs (Ch7 host and VM).
4. Figures: every Ch5–Ch8 entry of `_data/diagrams.yml` embedded exactly once in
   its chapter; `python3 scripts/validate.py` passes `figures`, `codetabs`,
   `liquid`, `parts`, `front-matter`, `means` (review each listed mean/average
   use).
5. Code tabs: every group Java first; labels match the fences' languages; only
   languages the example has; a subset is explained in the preceding sentence.
6. Every excerpt is verbatim: diff each against its named file (elisions only
   as `// ...`/`# ...` lines); every file, class, method and function named
   exists.
7. Every number recomputed from `results/r02-run{1,2,3}` (and `r02-vm-run{1,2,3}`
   for Ch7's VM part) or found in `verify.sh`/README parameters; ranges, not
   means; the profile line present once and correct; VM numbers labelled and
   never beside host numbers; the two calibration observations labelled.
8. Ch5 tells the criterion-2 story (run 2's p99 failure, the p99.9 decision,
   `recheck.log`); Ch7 tells run 1's 1.01 margin; neither is explained away.
9. Asserted vs observed matches each `verify.sh` header; nothing observed is
   called asserted.
10. Decisions honoured: JDK 25.0.5 LTS; JDK 27 and 28 as status only; Valhalla
    conceptual with a dated box matching `VALHALLA.md`; AOT under G1 with JEP 516;
    native-image prose only; Q4 pin is not host isolation; Q5 host THP only, `thp` refused by the host;
    Chronicle OSS only, analytics disabled, pre-toucher stub never called, no
    `fsync` claim; Unsafe warnings kept.
11. Boundaries: no cache-locality/false-sharing lesson (Ch9), no lock-free theory
    beyond the hand-off (Ch10), no isolation-as-config lesson (Ch15/Ch18); the
    forward references name those chapters; back-links to Ch1–Ch4 by title.
12. Python appears only in Ch6 and Ch8 and teaches a divergence; no shootout.
13. Voice scanner 0 ban-tier on each chapter; no step ids, "the user", PRD.
14. Jekyll builds in `ruby:4.0` (Jekyll 4.4.1) with the four pages rendering
    their tabs and figures.

## Status

| Step | Status |
|---|---|
| S16 Ch5 | done |
| S17 Ch6 | done |
| S18 Ch7 | done |
| S19 Ch8 | done |
| Opus validation | done (per chapter; see `r02-plan.md` S16–S19) |
