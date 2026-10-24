---
title: "r04 chapters (S13–S15)"
layout: plan
render_with_liquid: false
---

# r04 chapters: S13–S15

One chapter per example, written from the example's code and its committed S11 (or S19) results. Shape, numbers, voice, Liquid and listing rules follow [r03-chapters.md](r03-chapters.md) unless this brief changes them. Each executor edits only its own chapter file; `_data/diagrams.yml`, READMEs, the outline and `_example_pages/` are S16's.

## Files

| Step | File | `order` | `part` | Title | Example |
|---|---|---|---|---|---|
| S13 | `_docs/11-stackful-stackless.md` | 11 | `Threading & I/O Models` | Stackful vs stackless: threads and fibers vs event loops and coroutines | `examples/11-stackful-stackless/` |
| S14 | `_docs/12-io-engines.md` | 12 | `Threading & I/O Models` | I/O engines: `epoll` and `io_uring`, `asyncio`, virtual threads vs reactive; thread-per-core | `examples/12-io-engines/` |
| S15 | `_docs/13-where-code-runs.md` | 13 | `Threading & I/O Models` | Where the code runs: bare metal, VMs and containers, and when not to use containers | `examples/13-where-code-runs/` |

`duration`: `55 minutes` each. Commits: `docs(§11): Ch11 Stackful vs stackless (S13)`, `docs(§12): Ch12 I/O engines (S14)`, `docs(§13): Ch13 Where the code runs (S15)`.

## What changes from r03

- **Code tabs:** `langs="C++|Python|Java"` explicitly, or a subset where a language has no equivalent, said in one sentence:
  - Ch11: no Python stackful lane (greenlet is third-party), no Java stackless lane.
  - Ch12: no JDK or Python io_uring.
  - Ch13: Python CPU counts only.
- **Before/after pairs:** each technique gets a before/after code pair with `#A`/`#B` callouts (for example, `os-thread` against `coroutine`, `epoll` against `io-uring`, `@Blocking` against `@RunOnVirtualThread`, `--cpus` against `--cpuset-cpus`).
- **Profile line:** Ch11 and Ch12 use `r04-run1/profile.json` plus placement ("threads placed on distinct physical cores by `sched_setaffinity`, an experiment control, not isolation"). Ch13 gives one profile line per lane:
  - host: bare metal, VM booted and idle;
  - vm: `lowlat-target`, guest profile `stock-unpinned`, snapshot `lab-ready-r04`, 4 vCPU unpinned, stock kernel 7.2;
  - container: image tag + digest, network, `--cpus`/`--cpuset-cpus`, default seccomp.
  - Never the CPU part, the host kernel build or a container ID.
- **Comparisons:** within one run, median of 3 alternations; never p50 across runs; sub-2x margins stated where the claim is made. Ch13's host vs VM lines are observed and worded "on this machine, in this run" (D9); container lanes are compared with VM-native in the same guest.
- **Runtime facts:** every sentence about a kernel, runtime or tool behaviour (io_uring, epoll, seccomp default, CFS bandwidth, JEP 491, Quarkus pool defaults, asyncio, `os.process_cpu_count`) cites the S0 source in `dependency-pins.md` or a committed run. S18 checks each one.
- **Companion projects:** the user's cpp-concurrency-and-parallelism (Ch11, Ch12, Ch13, Ch32), linux-systems-programming (09 epoll, 10 io_uring, 32 namespaces and cgroups, 34 containers, 35 KVM, 55 Boost.Asio), quarkus-optimization and spring-boot-optimization are cited in "For deeper coverage" as companion sites, not re-taught. Their wording isn't carried over where it breaks house rules (no "lies" framing).
- **House voice from the first draft** (lgtm-professional-voice, Geewax model). Paste the rubric into the executor prompt:
  - open each section on a concrete line object (the WMS lookup, a tunnel camera's socket, the controller PC, the hub's VM farm, a pod);
  - contractions; varied sentence length; no rhetorical triads;
  - captions `Figure N.x: …`, no em dash anywhere.
  - Before hand-back: `scan.sh --tier ban` 0 and `scan.sh --stats` clean.

## Ch11: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Hook | Every scan asks the WMS for a sort plan, and the answer takes about 2 ms. At 10 kHz that's 20 parcels waiting at once (Ch2); at a hub with a slow WMS it's thousands. Something has to hold each wait. |
| Who holds the wait | OS thread (`std::jthread`, platform thread, `threading.Thread`), stackful (Boost.Fiber, virtual thread), stackless (C++23 coroutine on Asio, asyncio task) -> 10,000 parked tasks -> bytes per wait fall by orders of magnitude from thread to fiber to coroutine -> frame bytes (exact), RSS ratios, Python bytes (exact) |
| The hand-off | Ping-pong between two tasks -> 1,000,000 round trips -> a futex sleep and wake per switch against a user-space context swap against a resume -> voluntary switches per round trip (exact-ish), same-run p50 ratio |
| The blocking call | One `sleep_for` inside a fiber, one `time.sleep` inside a coroutine -> neighbours on the same carrier wait -> wake lateness ≥ 1 ms for a 2 ms call (2x by construction); Java: JEP 491 and what still pins (JFR count, observed). Function colouring explained from the code, not as a slogan |
| Python | No stdlib stackful coroutine; asyncio is stackless; threads under the GIL against free-threaded (observed); the measured free-threaded process imports no `lowlat_measure` |
| Line | 10 kHz x 20 s with a 2 ms lookup wait per parcel -> all variants fit 480 ms; the saving is memory and CPU per wait, said without a latency claim |
| Cross-check | RSS against the configured stack sizes (`ulimit -s`, `protected_fixedsize_stack`) and the promise allocation count; `/proc` context switches against the round-trip histogram |

Boundaries: MPSC hand-off and memory orders are Ch10 (back-link); the I/O engine under the event loop is Ch12 (forward link); the coroutine-type internals are the companion cpp-concurrency-and-parallelism Ch11 and Ch13 (cross-ref).

## Ch12: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Hook | A hub concentrator takes four scan tunnels' UDP feeds. For each datagram, something tells a thread there's work: a readiness event or a completion. |
| Readiness and completion | `epoll` + `recvmsg` (Asio reactor as the idiom), `recvmmsg`, liburing multishot with a buffer ring -> four cameras at saturation -> syscalls per parcel fall from ≥ 2 to well under 1 -> exact in-program counters, `strace -c` cross-check (observed) |
| Thread-per-core | `SO_REUSEPORT` socket and ring per pinned thread against one receive thread + MPSC hand-off -> same load -> 0 hand-offs per parcel (exact), saturation p99 ratio |
| Virtual threads and the event loop | Quarkus sort-plan service: `Uni` on the event loop, `@Blocking`, `@RunOnVirtualThread`, plus the `blocking-on-event-loop` defect -> open-loop at λW > pool -> worker pool queues (Little's law), VTs don't, the event loop is fine until something blocks it -> same-run p99 ratio, blocked-thread warnings (exact). Plain-JDK lane shows the VT poller is epoll underneath |
| Python | asyncio datagram endpoint against a blocking thread (GIL and free-threaded) and uvloop -> observed; no stdlib io_uring |
| Line | Four cameras at 2.5 kHz -> all fit 480 ms; saturation shows where they'd differ |
| Cross-check | In-program syscall counters against `strace -c`; client lateness against server-side pool counters |

Boundaries: Ch10 owns the MPSC queue; Ch15 owns isolation (pinning here is an experiment control); Part 6 owns transports and protocol design (HTTP/1.1 on loopback is a harness, not a transport recommendation).

## Ch13: arc

| Section | Technique -> workload -> expected effect -> how asserted |
|---|---|
| Hook | The same decide service can run on the controller PC under the conveyor, in the hub's VM farm, or as a container in a pod. What moves when it moves? |
| Three places | Host, VM-native, container-in-VM, interleaved in one run -> line 10 kHz x 20 s per lane -> the jitter floor (simulator emit lateness) and the decide percentiles per lane, labelled -> observed (D9); what the VM can't show |
| The network namespace | Bridge veth against host network inside the guest -> observed delta |
| Quota against cpuset | `--cpus=2` against `--cpuset-cpus=2,3`, 4 busy decide workers -> CFS bandwidth throttling stops the whole cgroup until the next period -> `nr_throttled` ≥ 1 vs 0 (exact), p99.9 ratio (S10 decides) |
| What the runtime thinks it has | `hardware_concurrency()`, `availableProcessors()`, `os.process_cpu_count()` under quota and cpuset (exact), and the pool sizes each derives (VT carriers, Vert.x event loops, GC threads); size pools from the cgroup, not the core count |
| Seccomp and io_uring | Default Docker seccomp against the same binary outside -> `EPERM` (exact, if S0 confirms) |
| When not to use a container | Hot path under a CPU quota, or anywhere the I/O engine is filtered: no. Control plane, telemetry, analytics: fine. Kubernetes QoS classes and the CPU Manager static policy in prose (pointer to Ch18 rollout gating and the companion sites) |
| Cross-check | `cpu.stat` against the tail spikes' timing; guest steal ticks against the VM lane's jitter floor |

Boundaries: isolation and RT are Part 5 (Ch14–Ch16); rollout gating is Ch18; the container-sizing deep dive is the companion cpp-concurrency-and-parallelism Ch32; JVM container ergonomics in depth is quarkus-optimization.

## Claims and evidence tables

Filled in at S13–S15 from `r04-run1..3`, in the r03 form (claim | evidence file and field). Ch13 adds a lane column (`host`/`vm`/`container-*`). Report failures and outliers as they are.

## Verification status footer

The r03 form, naming the asserted criteria, what's observed only, and the runs (`r04-run1` to `r04-run3`). Ch11 and Ch12: bare-metal host, untuned. Ch13: per lane (host with VM idle; VM `stock-unpinned`; container image digests).
