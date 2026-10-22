---
title: "Iteration plan"
render_with_liquid: false
description: "How the book ships: what each release iteration delivers, in order, and the gates every chapter passes."
---

Source of truth for scope: the PRD in Notion (*PRD — Latency with C++, Python &
Java*, §7 outline + §7a additions). This plan turns that outline into release
iterations. Iterations ship as `low-latency-engineering_rNN.x.tar.gz` and are
tagged `rNN.x`.

## Status

- **r00 (`release/r00`):** repo, CLAUDE.md, site scaffold, Parts, outline, Figure 0.1,
  this plan. No chapter prose.
- **r01 (`release/r01`): in progress.** Steps S0 to S26 done (simulator, kits, lab, Ch0 to Ch4,
  examples page, validation, CI); S27 (review, Jekyll build, package, PR) pending. Step status: `_plans/r01-plan.md`.
  Claim log: `_plans/reconciliation-plan.md`.
- Everything after r01 is planned, not started.

## Chapter numbering (resolves PRD §7 + §7a)

The PRD's §7 lists Ch0–31. §7a adds a CI/CD and deployment chapter "in the Part V/VII
area". It lands as **Ch18, the last chapter of Part 5**, because it versions the
kernel, `tuned` and isolation config that Ch14–17 introduce. Transports and
everything after shift by one: **33 chapters, Ch0–32**, plus Appendices A–F.
"When not to use containers" (§7a) folds into Ch13. The per-protocol contract-design
thread (§7a) runs through Part 6 as a section in each transport chapter, not a
chapter of its own.

| Part | Chapters | Lab |
|---|---|---|
| 0 Prerequisites & the Lab | 0 | host + VM |
| 1 Understanding & Measuring Latency | 1–4 | host (bare metal) |
| 2 The Managed-Runtime Question | 5–8 | host |
| 3 Accelerating Code | 9–10 | host |
| 4 Threading & I/O Models | 11–13 | host; Ch13 host + VM |
| 5 The OS, Isolation & the Network Edge | 14–18 | **VM mandatory** |
| 6 Transports by Latency Budget | 19–25 | host (Docker Engine); DDS/Aeron latency runs in VM |
| 7 Observing Without Wrecking It | 26–27 | host + LGTM |
| 8 Failure: Detect, Withstand, Act, Observe | 28–31 | host |
| 9 Capstone | 32 | VM |
| Appendices | A–F | — |

## Foundations first (r01)

Nothing in Part 1 can be written honestly until these exist, so r01 is mostly
infrastructure plus the chapters that explain it:

1. **Line simulator** (`examples/common/line-simulator/`): emits parcels at a
   configurable rate with encoder ticks; open-loop (constant arrival schedule) so
   coordinated omission can't hide. One reference implementation; consumers in all
   three languages.
2. **Measurement kit** per language: HdrHistogram recording, intended-start-time
   correction, a shared output format (p50/p90/p99/p99.9/max + machine profile block).
3. **Machine-profile capture** script (`scripts/profile.sh`): CPU model, governor,
   `tuned` profile, kernel and RT flag, isolation and pinning, bare metal vs VM.
   Every number on the site is emitted next to this block.
4. **`contracts/`** seeded with the parcel and divert-command schema (protobuf
   first; SBE and DDS IDL added with Part 6).
5. **`scripts/check-prereqs.sh`** and Ch0.
6. **Ch1–4.**

## Iterations

| Iter | Delivers | Notes |
|---|---|---|
| r00 | Scaffold, outline, plan, Figure 0.1 | `release/r00` |
| r01 | Line simulator, measurement kit, profile capture, Ch0, Ch1–4 | VM lab provisioned (LAB_PREFIX=lowlat) as part of Ch0. **In progress; S26 done** |
| r02 | Part 2 (Ch5–8): the low-latency JVM track | Java-led; C++ comparisons inline |
| r03 | Part 3 (Ch9–10): the in-flight parcel tracker hot path | tri-language |
| r04 | Part 4 (Ch11–13): threading, I/O engines, where the code runs | Ch13 needs VM + container numbers |
| r05 | Part 5 (Ch14–18): PREEMPT_RT, partitioning, jitter, kernel bypass, latency config as code | VM only; before/after `cyclictest` every chapter |
| r06 | Part 6a (Ch19–22): channel strategy, gRPC, DDS, Aeron + SBE | Appendix B drafted alongside Ch19 |
| r07 | Part 6b (Ch23–25): FIX/Artio, WebSockets + Kafka, Modbus + D-Bus | Appendix D (PTP) with Ch21 follow-up |
| r08 | Part 7 (Ch26–27): low-overhead observability | LGTM via lgtm-docker-stack |
| r09 | Part 8 (Ch28–31): failure model | Appendix A |
| r10 | Part 9 (Ch32): capstone | VM; command latency held under data flood |
| r11 | Appendices C, E, F; coverage-map audit; manuscript build | Appendix C proves coverage of every reference topic |
| r12 | Companion decks (100, 101 ×2, 201, appendix decks) | decks last, mined from finished content |

## Chapter gate (every chapter, every iteration)

- Spine: hook → diagram → concept → how the code works → measure → cross-check →
  what you learned → verification status. 1,900–2,500 words of prose.
- More than one figure per chapter; specs in `diagrams/`, never hand-edited output.
- Example under `examples/NN-name/{cpp,python,java}/` with a README stating the
  expected effect. Build success is a checkpoint, not verification.
- Every number is a measured distribution with the machine/VM profile beside it.
  VM and bare-metal numbers are labelled and never compared directly.
- Both observation surfaces named: terminal output and the Grafana query (or
  "no panel by design").
- Every dependency OSS, licence recorded in the example README.
- `lgtm-idiomatic-review` and `lgtm-professional-voice` pass before merge.

## Decisions (PRD §11, resolved 2026-10-21)

- **Chapter numbering:** accepted as above (Ch18 = latency config as code; Ch0–32).
- **Kernel-bypass depth (Ch17):** concepts plus what the VM can measure (AF_XDP on
  a virtio NIC, DPDK in the VM, labelled illustrative); RDMA conceptual only.
- **Containers/Kubernetes depth:** nothing beyond Ch13 and Ch18's rollout gating.
  minikube and CRC are headless review and testing environments, not chapter
  subjects.
- **Code style:** idiomatic in every language; a non-idiomatic latency construct
  is explained where it appears.
- **Branching:** one `release/rNN` branch and PR per iteration, deleted on merge.
- **Still open:** any further titles from the C++ reference shelf, for the
  bibliography and Appendix C.
