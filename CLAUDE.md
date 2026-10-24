# CLAUDE.md — Low-Latency Engineering (C++, Python & Java)

## What this is
A chapter-based Jekyll tutorial and Leanpub book teaching latency ENGINEERING
through original C++23, Python 3.14 and Java 25 (JVM) examples on Fedora 44,
in the lgtm house style. Repo: low-latency-engineering. It spans code-level
technique, the low-latency JVM, the real-time kernel + CPU partitioning +
kernel bypass, transport choice by latency budget (gRPC/DDS/Aeron+SBE/FIX/
WebSockets+protobuf/Modbus/D-Bus/Kafka), low-overhead observability, and a
resilience/failure model. Chapters in _docs/, examples/, assets/diagrams/,
manuscript/.

## Sources - reference only, never a source of content
Enberg's "Latency" (Manning), its repo, AND the reader's C++ reference shelf
are REFERENCES only.
- Do NOT port, translate, adapt or paraphrase from any of them.
- COVER, don't copy: Appendix C maps every reference topic to ORIGINAL material.
- Where a C++ technique has no clean Java/Python equivalent, teach that
  divergence - it's the point, not a gap to hide.
- Design every example from the technique. If one resembles something you've
  read, change the workload or drop it.

## Domain - warehouse & shipping automation (shared across all projects)
- Running domain: the shipping/cargo world, deviating into high-speed warehouse
  materials-handling (a parcel sortation line: checkweigh, dimension, scan,
  label, sort). REUSE existing shipping examples - this is continuity, not a
  new domain. (Author background: shipping, FedEx/UPS - keep it realistic.)
- Shared workload: a line-simulator emitting parcels at a configurable rate past
  the machines above. Every chapter measures against it.
- Spine metric: SCAN-TO-DIVERT (sense -> decide -> act) end-to-end latency. The
  budget is physical: conveyor_speed * distance(scan->diverter) = deadline. Ask
  of every technique: does it fit the scan-to-divert budget?
- Coordinated omission is physical here: the belt never waits for a slow consumer.
- Hot-path example is an in-flight parcel tracker (barcode -> parcel state), NOT
  a trading order book.
- Trading is NOT the domain. Reference the Ghosh HFT books for depth/cross-check;
  do not build an HFT system; point readers there for the full trading build.
- iDDS capabilities (channel metadata, source-side PTP timestamp, config/health)
  are taught on OSS DDS via the line's scales/scanners - never the commercial
  product.

## OSS-only, no vendor/paid tech on a critical path
- Every library on a hot/critical path must be OSS with a compatible licence;
  record it per example.
- Commercial middleware (RTI Connext, TIBCO FTL/Rendezvous, Solace, Informatica
  Ultra Messaging, Chronicle paid tiers, Adaptive Aeron Premium kernel-bypass,
  OnixS, OpenOnload/ef_vi, FPGA NICs) is SURVEYED in Appendix F, never required.
- iDDS (commercial) is taught as CONCEPTS on OSS DDS: self-describing channel
  metadata + source-side PTP timestamping + config/health. Never the product.
- OSS Aeron is UDP-only; DPDK kernel-bypass on Aeron is a PAID feature - say so.

## Ground rules
- Fedora 44. Python 3.14 (GIL + free-threaded, Appendix E). C++23 floor.
  Java 25 on the plain JVM (NOT Quarkus-native on the hot path).
- Every example emits a latency DISTRIBUTION (p50/p99/p99.9), never a mean.
- RT chapters show a before/after cyclictest jitter number.
- DDS default is Cyclone; show Fast DDS as the alternative.
- Build/start success is a checkpoint, never the finish line - verify the EFFECT.
- Never report a measurement you didn't run; record the machine/VM profile (CPU,
  governor, tuned profile, pinning, isolation, bare-metal vs VM) with every number.
- Command path and data path never share a queue; a data flood must never delay
  a command.
- Never instrument the hot path synchronously; observability goes off-path.
- protobuf/protoc: latest stable upstream release, pinned, one release across C++,
  Java and Python; never Fedora's packaged protoc.
- Means: a time-average may appear only as a labelled modelling input (Little's/
  Amdahl's laws, Ch2, in a separate `model` block), never as a reported latency.
- Ch1-4 numbers are host bare metal, untuned (governor/tuned recorded), labelled.
- Idiomatic code first, in every language: the standard library, the framework's
  own facilities and the established libraries before anything hand-rolled
  (lgtm-idiomatic-review checklists apply while writing, not only at review).
  Where a latency technique needs a non-idiomatic construct (busy-spin, manual
  layout, lock-free structure), say why in the prose; keep the rest idiomatic.

## Design & delivery rules
- Examine the best contract/API design for EVERY protocol (gRPC, DDS IDL, FIX/SBE,
  WebSockets, REST) - reuse the API Patterns & Practices discipline; the fast path
  is no excuse for a sloppy contract.
- Containers: say when NOT to use them. Fine for control-plane/telemetry/analytics;
  they add jitter on the hot path - show the measured cost.
- Treat kernel/boot params, tuned profile, CPU isolation and hugepages as VERSIONED
  deployment config, not hand-tweaks. Canary/rollout is gated on a latency+jitter
  SLO, not just health. Never co-locate a noisy workload with a control loop.
- FIX engine is Artio (OSS, Aeron/SBE-based); QuickFIX/J only for contrast.
- Diagram-heavy: more than one figure per chapter (language-approach differences +
  the shipping line). Use lgtm-diagram-generator.
- The RT/partitioning chapters need the lgtm-systems-programming KVM lab set up
  locally first (LAB_PREFIX=lowlat) - it's a prerequisite, not an afterthought.

## Skills to use
| Task                              | Skill                   |
|-----------------------------------|-------------------------|
| Scaffold or change the site       | lgtm-jekyll             |
| Write or revise a chapter         | lgtm-tutorial           |
| Make a figure                     | lgtm-diagram-generator  |
| Build the conference deck         | lgtm-presentation       |
| Postgres/Kafka/LGTM locally       | lgtm-docker-stack       |
| RT kernel / partitioning / bypass / VM | lgtm-systems-programming |
| Commits, releases, repo setup     | lgtm-github                |

## Reuse, don't re-derive
OS-tuning, partitioning and some protocol material already exist in the Linux
Systems Programming book and the Optimizing Quarkus/Spring Boot + cloud-native
talks. Pull and re-point; cross-link; don't rewrite.

## Repo layout
    _config.yml / _parts/*.md / _docs/NN-*.md
    examples/NN-name/{cpp,python,java}/  + README.md (behavioral verification)
    contracts/           shared protobuf / SBE / DDS IDL / FIX / wire schemas
    assets/diagrams/     paired name.svg + name.excalidraw
    scripts/             generate_diagram.py, measurement + lab helpers
    manuscript/          Markua, generated - never hand-edited
    _plans/              iteration-plan.md, reconciliation-plan.md,
                         example-plan.md (technique -> workload -> result)

## Environment isolation
- Containers: Docker Engine + Compose plugin everywhere, host and lab VMs (never
  Docker Desktop, no Podman). minikube uses the docker driver; CRC keeps its default
  CRI-O + crun runtime.
- NEVER change the development host: no kernel, boot-param, sysctl, tuned, governor,
  hugepage or package changes, and no host sudo. The host only runs unprivileged
  user-space programs and Docker containers. Every system-level change happens in
  the lowlat-* VMs (lgtm-systems-programming lab).
- Lab VMs use passt networking and ssh over vsock (`scripts/lab/lab-ssh.sh <vm>`):
  no bridge, NAT, forwarding or firewall rule on the host. Never fix lab
  networking by changing the host firewall; guests cannot reach each other.
- A throwaway KVM/libvirt VM is MANDATORY for the
  RT-kernel, partitioning, isolcpus/nohz_full/IRQ, cyclictest and kernel-bypass
  chapters - never on the host. Use lgtm-systems-programming scripts by name
  (LAB_PREFIX=lowlat); revert to snapshot between measurement runs.
- A VM number and a bare-metal number are NOT comparable; label every number.
  Exception (r04 D9): Ch13 compares host, VM and container lanes only within one
  interleaved run on this machine, every number lane-labelled; host vs VM is
  observed, never asserted, and the chapter says what the VM can't show.
- Language floor: C++23, JDK 25, Python 3.14 in every build, module and image.
- Kernel-bypass examples needing real NIC hardware: mark conceptual vs measured.
  Ch17 depth (decided): what the VM can measure (AF_XDP on virtio, DPDK in the
  VM, labelled illustrative); RDMA conceptual only.
- minikube and CRC are HEADLESS review and testing environments for this book,
  not chapter subjects. Kubernetes coverage stops at Ch13 and Ch18's rollout
  gating. One cluster at a time; stop it when idle.

## Book output, commits, chapter spine
Future Projects shared standard: _docs/ canonical -> build-manuscript.py ->
Markua; code included from files; paired SVG+excalidraw; spine hook -> diagram
-> concept -> how the code works -> measure -> cross-check -> what you learned
-> verification status; 1,900-2,500 words prose. Conventional Commits, scopes
§N / demo-NN / rNN.x. An iteration ships as its merged PR plus the rNN.x tag
and a GitHub release; no tarball or other artifact is built. Each iteration is
its own release/rNN branch and PR, branched from an updated main, squash-merged
with the branch deleted; tag rNN.x on main after merge.
Repo is public; the site deploys to GitHub Pages from main.

## Publishing rule: nothing identifies the machine or its owner
The repo is public, so no tracked file may name the development machine, its owner
or anything that helps locate or attack it later:
- No absolute home-directory path (under /home or /Users), no account name, no hostname.
  Write `<repo>/...` or `~/...`. The profile's `host_label` is already generic.
- No laptop model (DMI `product_name` is `"redacted"`), no CPU model or model number. The
  CPU is a class: "Intel 8-core/16-thread laptop CPU"; prose names its properties (SMT,
  `intel_pstate`, the L2 spatial prefetcher), never the part.
- No host kernel build number or build date. The host kernel is "7.2" and its preempt model
  (`PREEMPT_DYNAMIC`). The disposable lab guest's own RT kernel strings and the Fedora SRPM
  pin (`kernel-7.2.11-200.fc44` in `scripts/lab/` and `_plans/dependency-pins.md`) stay.
- No `/etc/machine-id`, DMI serial or UUID, MAC or IP address, `root=UUID=` or BOOT_IMAGE.
- Generators comply: `scripts/profile.sh` records vendor and topology, `major.minor` and the
  preempt model; `examples/_lib/lib.sh` scrubs each results directory on exit; a captured
  log is piped through `scripts/scrub-host-ids.py --filter` before it is committed.
- `scripts/scrub-host-ids.py` is the one table of replacements (the account name is read at
  run time, never written). `python3 scripts/validate.py` check `host-ids` fails the build on
  a leak. `scripts/scrub-host-ids.py --print-rules` prints `git filter-repo --replace-text`
  rules for a history rewrite; that output holds the account name and is never committed.

## Do not
- Do not report a number you did not measure, or omit the machine/VM profile.
- Do not compare the three languages as a shootout; compare techniques.
- Do not reproduce/port/adapt anything from a source book or repo.
- Do not put paid/vendor tech on a critical path (survey it in Appendix F).
- Do not let the data path share a queue with the command path.
- Do not use a mean latency anywhere.
