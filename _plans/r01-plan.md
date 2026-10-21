---
title: "r01 plan: foundations first"
render_with_liquid: false
description: "Relay plan for r01: line simulator, measurement kits, profile capture, contracts, VM lab, Ch0–4. Step status is kept current so a fresh session can resume."
---

Planned by Opus on 2026-10-21. Status column is updated as steps land.

## Approach

- **Line simulator:** one reference simulator in C++23 (`examples/common/line-simulator/`).
  Open-loop schedule: intended emit time of parcel *i* is `t0 + i/rate`, slept to with
  `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)` so it never drifts. One protobuf
  `Parcel` per UDP datagram to 127.0.0.1 (`seq`, `intended_emit_ns`, `actual_emit_ns`,
  encoder tick from intended time × belt speed, seeded barcode/weight/dims). Consumers in
  C++/Python/Java compute `done_ns − intended_emit_ns`, so coordinated omission cannot
  hide. UDP has no backpressure: the sender never waits, like the belt; slowness shows as
  queueing or `gaps`. The simulator reports its own emit lateness.
  Rejected: a library per language (three schedulers drift); TCP (flow control
  reintroduces CO); Unix stream (framing; no public delimited API in Python protobuf);
  shared-memory ring (Part 3/6 material).
- **Measurement kits:** `examples/common/measure/{cpp,python,java}` on HdrHistogram's own
  APIs (`hdr_record_corrected_value`; `Recorder`, `recordValueWithExpectedInterval`,
  `copyCorrectedForCoordinatedOmission`; Python `record_corrected_value`). ns units,
  1 ns–1 h, 3 significant digits. One JSON report per run against
  `contracts/measurement/latency-report.schema.json`: example, language, variant, count,
  gaps, p50/p90/p99/p99_9/max (no mean; extra fields forbidden), `hdr` (compressed base64,
  cross-decodable), `build`, `profile` (embedded from `scripts/profile.sh`). A Python CLI
  `lowlat-report` validates, tabulates and re-decodes every `hdr` (cross-language check).
  JSON via Jackson / nlohmann/json / stdlib.
- **Builds:** CMake superproject + presets with FetchContent at pinned tags (HdrHistogram_c,
  Google Benchmark, GoogleTest, nlohmann/json); protobuf + abseil built once by
  `scripts/deps/build-protobuf.sh` into `~/.cache/lowlat/prefix`, found by
  `find_package(Protobuf CONFIG)` with `protobuf_generate`. Maven aggregator; JMH archetype
  layout with shaded `benchmarks.jar`; `io.github.ascopes:protobuf-maven-plugin`. uv
  workspace for Python.
- **VM lab in r01:** provision and smoke-test only (PREEMPT_RT kernel, `cyclictest`,
  `ptp_kvm` + `phc2sys`), recorded as readiness, not claims. **All Ch1–4 numbers are host
  bare-metal, labelled.**
- **Container engine:** Docker Engine + Compose plugin everywhere, host and lab VMs
  (decided by the user 2026-10-21); minikube runs on the docker driver, per the lgtm
  skills. Podman is not used. Ch13's in-guest container numbers use Docker Engine in the guest.
  CRC uses neither: it runs its default CRI-O runtime with `crun`, left as shipped.

## Steps

Exec = sonnet executor unless MAIN. Host measurement runs are serial with the VM down.

| id | What | Dep | Exec | Status |
|---|---|---|---|---|
| S0 | Survey latest stable + pin + licence for every dependency → `_plans/versions.md`; seed `reconciliation-plan.md` | – | sonnet | done |
| S1 | Record decisions (Docker Engine, Q2–Q5) in CLAUDE.md, Part 0 blurb, outline | answers | MAIN | done |
| S2 | Contracts: `contracts/proto/lowlat/line/v1/{parcel,divert}.proto`, measurement schema, README with design rationale | S0 | sonnet | done |
| S3 | `scripts/profile.sh` (JSON / `--text`; CPU, SMT, governor, EPP, turbo, tuned, kernel, RT, isolation, affinity, clocksource, virt, loadavg, running libvirt domains; no sudo) | – | sonnet | done |
| S4 | Build scaffolding: CMake + presets, protobuf prefix script, Maven aggregator, uv workspace | S0,S2 | sonnet | done |
| S5–S7 | Measurement kits C++ / Python (+`lowlat-report`) / Java with correction unit tests | S4 | sonnet ×3 | done |
| S8 | Reference line simulator + README | S4 | sonnet | done |
| S9a–c | Consumers C++ / Python / Java | S5–S8 | sonnet ×3 | S9a, S9b done |
| S10 | `scripts/lab/` from lgtm-systems-programming (LAB_PREFIX=lowlat, 4 vCPU, 8 GB; RT/PTP/tuned packages; refuses non-`lowlat-*`) | S0 | sonnet | done |
| S11 | `scripts/check-prereqs.sh` (PASS/WARN/FAIL; warns on system protoc 3.19) | S0 | sonnet | done |
| S12 | Provision `lowlat-target`, snapshot `lab-ready` | S10 | MAIN | todo |
| S13 | PREEMPT_RT probe in guest → fallback per Q3; cyclictest + ptp_kvm/phc2sys smoke; snapshot `lab-ready-rt` | S12 | MAIN | todo |
| S14 | `examples/00-prerequisites/verify.sh` + README (VM=1 runs lab smoke) | S9,S11 | sonnet | todo |
| S15 | `examples/01-latency-distribution` (per-parcel vs batch-32; 1 % slow re-read path) | S9 | sonnet | todo |
| S16 | `examples/02-littles-amdahl` (in-flight ≈ λ·W; Amdahl with serial lock; Python threads vs multiprocessing; effective GHz) | S9 | sonnet | todo |
| S17 | `examples/03-coordinated-omission` (A naive / B corrected / C open-loop; 200 ms stall; clock read cost; clocksource) | S9 | sonnet | todo |
| S18 | `examples/04-benchmark-harnesses` (GS1 check digit: Google Benchmark, JMH SampleTime + Blackhole, pyperf) | S5–S7 | sonnet | todo |
| S19 | Measurement runs: each verify.sh 3×, serial, VM down; results committed | S14–S18 | MAIN | todo |
| S20 | ≥2 figures per chapter 0–4, wired into `_data/diagrams.yml` | S14–S18 | sonnet | todo |
| S21–S25 | Ch0–Ch4 prose with codetabs, quoting only S19 results | S19,S20 | sonnet ×5 | todo |
| S26 | Wiring: examples table, outline links, plan status, reconciliation, `validate.py`, `wordcount.sh`, CI build job for kits | S21–25 | sonnet | todo |
| S27 | Idiomatic + voice review, Jekyll build, Opus validation, package, PR | S26 | MAIN | todo |

## Acceptance criteria

- **S0** protobuf/protoc pinned to the latest stable upstream release; every dependency has an exact version, licence, survey date; holds have a reason; no ranges or `LATEST`.
- **S2** both `.proto` compile with the pinned protoc; the schema accepts a sample and rejects one containing `mean`.
- **S3** `profile.sh | python3 -m json.tool` exits 0; host shows `virt: none`, `clocksource: tsc`, non-empty governor; guest shows `kvm`.
- **S5–S7** 1,000 × 1 ms + one 1 s value with 1 ms expected interval → corrected count exactly 2,000 and p99 > 1 ms; uncorrected p99 ≈ 1 ms; a Java-encoded `hdr` decoded in Python gives the same p99 to 3 significant digits.
- **S8** 1 kHz × 10 s emits 10,000 datagrams; emit-lateness p99 reported.
- **S9** each consumer at 1 kHz × 10 s: `count=10000`, `gaps=0`, no negative latency.
- **S11** exits 0 on this host; FAILs with an install hint when a tool is removed from PATH.
- **S12/S13** guest `/sys/kernel/realtime` = 1 and `PREEMPT_RT` in `uname -v`; `cyclictest -l 10000` exits 0 with output stored, labelled `vm`; `/dev/ptp0` exists; snapshot `lab-ready-rt` listed; `ebpf-*` and `systems-*` domains unchanged.
- **S14** verify.sh exits 0; reports for all three languages with profile; cross-decode matches.
- **S15** throughput equal within 1 %; batched p50 ≥ 10× per-parcel p50; with slow path p99/p50 ≥ 10.
- **S16** C++ and Java speedup at 4 workers within ±15 % of the Amdahl prediction from the measured serial fraction; Python threads < 1.3×, multiprocessing > 2×; effective GHz printed.
- **S17** in all three languages corrected (B) p99 ≥ 10× naive (A) p99 and B within 2× of C (one 200 ms stall at 1 kHz × 10 s back-fills ≈ 2 %; B p99 ≈ 100 ms vs A < 1 ms).
- **S18** the dead-code-eliminated variant ≥ 5× faster than the Blackhole/`DoNotOptimize` variant in C++ and Java; every harness emits percentiles.
- **S19** every result file validates and carries `profile.virt` and `loadavg`.
- **S20** `_data/diagrams.yml` ≥ 2 entries per chapter 0–4; every SVG and `.excalidraw` exists and parses; specs regenerate them unchanged.
- **S21–25** 1,900–2,500 words each; `part:` matches; full spine; every number in prose appears in a committed result file; behavioural verification footer.
- **S27** Jekyll build passes in `ruby:4.0`; `validate.py` exits 0; voice and idiom scanners clean after triage.

## Risks

| Risk | Detection |
|---|---|
| Fedora 44 has no `kernel-rt` (host repoquery found none) | S13 probe; `/sys/kernel/realtime`; Q3 fallback |
| Clock-domain mismatch across processes | S9 negative-latency assertion; actual − intended check |
| Frequency scaling / turbo noise (`powersave` / `balanced`) | profile block; 3× runs; ratio-based criteria; `perf stat` effective GHz |
| Concurrent load (agents, VM) during host runs | S19 serial on MAIN; profile records loadavg + running domains; verify.sh refuses if a `lowlat-*` VM runs |
| `hdrhistogram` (PyPI) unmaintained or no cp314 wheel | S0 survey; S6 cross-decode test; record a hold or pick a maintained build |
| System protoc 3.19 shadows the pinned one | check-prereqs warning; `protobuf::protoc` target; Python VersionError |
| UDP drops at high rates (`rmem_max`) | `gaps` counter; `gaps=0` criterion |
| Python recording cost / JIT warm-up distort results | measured explicitly in Ch3/Ch4; warm-up reported, not dropped |
| Free-threaded `3.14t` picked by accident | `build.gil_enabled` field |
| Simulator wake-up jitter on a non-RT kernel | emit-lateness histogram on every run |

## Decisions

- **No changes to the development host** (user, 2026-10-21): no kernel, boot-param,
  sysctl, tuned, governor, hugepage or package changes and no host sudo. The host runs
  only unprivileged user-space programs and Docker containers; every system-level change
  happens in `lowlat-target`. The RT kernel is compiled in a throwaway `fedora:44`
  container and installed only in the guest. The optional host-tuning commands from the
  planner (`tuned-adm`, `perf_event_paranoid`, `pyperf system tune`) are dropped.

- **Q1 container engine:** Docker Engine + Compose plugin everywhere, host and lab VMs; no Podman; CRC keeps its default CRI-O + `crun` (user, 2026-10-21).
- **Q2 means in Little's / Amdahl's laws:** decided (default): a time-average only as a labelled modelling input in Ch2; a latency is never reported as a mean.
- **Q3 RT kernel if Fedora 44 has no package:** decided (default): rebuild Fedora's kernel SRPM with a versioned PREEMPT_RT fragment in a `fedora:44` container (alternatives: CentOS Stream 10 guest with `kernel-rt`; defer RT to r05).
- **Q4 host tuning for Ch1–4 runs:** decided (default): run as-is (`balanced`/`powersave`), labelled; tuning is taught in Part 5.

- **Q5 wire format:** decided (default): protobuf in r01; SBE contrast in Part 6.
- **protobuf/protoc version:** latest stable upstream, surveyed in S0, pinned exactly, built from source into `~/.cache/lowlat/prefix`; Fedora's protoc 3.19.6 is never used (user, 2026-10-21).
- **Plan approved by the user 2026-10-21.**

## Revision (planner pass 2, after the Docker decision)

Folded in from the planner's second pass; these refine the steps above.

- **S1** also removes every "Podman" mention from CLAUDE.md, `_parts/00-prerequisites.md`,
  the outline's Ch0 line and the iteration plan's "host (Podman)" column. Criterion:
  `grep -rni podman CLAUDE.md _parts _docs _plans` returns only intentional "not used" lines.
- **S3 host facts already checked:** clocksource `tsc`, governor `powersave`, tuned
  `balanced`, kernel `PREEMPT_DYNAMIC` (no `CONFIG_PREEMPT_RT`), Fedora `protoc` 3.19.6.
  Fedora repos carry `rt-tests`, `realtime-setup`, `linuxptp`,
  `tuned-profiles-cpu-partitioning`; no `kernel-rt`, no `tuned-profiles-realtime`.
- **S13 (coordinated omission) sharper variants and criteria:** receipt-time vs
  intended-time vs closed-loop + HdrHistogram correction. At 1 kHz × 10 s with one 200 ms
  stall: intended-time p99 ≥ 50 ms; receipt-time p99 < 1 ms; corrected closed-loop p99
  within 2× of intended-time. No-stall control: all three p99 within 2× of each other.
- **S12 Little's Law:** measured L within 5 % of λ·W̄ (the mean lives in a separate
  `model` block, per Q2), plus the Amdahl criteria above.
- **Wire format:** protobuf for the simulator in r01 (SBE contrast comes in Part 6).
  One protobuf release across C++, Java and Python, because Python rejects generated
  code newer than its runtime.
- Lab cloud-init adds `ninja-build`, `maven`, `uv`; `deploy-to-vm.sh` comes from the
  linux-systems-programming repo.
