---
title: "Reconciliation plan"
layout: plan
render_with_liquid: false
description: "Per-claim log of what each example's verify.sh asserts, with its verification status and the run that established it."
---

The book makes behavioural claims; this page tracks each one against a real run. A claim is
**verified** only when the example produced its observable effect in a committed run, not when
the code built. Status vocabulary: `verified` (held in every listed run), `observed` (printed
and committed but not asserted), `smoke` (ran once, not a measurement), `unverified`.

## Runs

| Run | What | Host profile |
|---|---|---|
| `r01-run1..3` | `verify.sh` of examples 00 to 04, run serially with the lab VM down; committed in `examples/NN-*/results/r01-run{1,2,3}/`. Examples 00, 01, 02 and 04 re-measured 2026-10-22 after the consumer-hook and converter fixes (commit 26a547c); example 03's runs are from 2026-10-21 (commit 1811055) and pass the current `lowlat-report check` | bare-metal host (XPS 15 9510, 16 logical CPUs), `virt: none`, governor `powersave`, tuned `balanced`, kernel 7.2.11-200.fc44 (PREEMPT_DYNAMIC), clocksource `tsc`, load average 0.35 to 1.61 at the start; "quiet host" |
| `r01-vm-smoke` | `ALLOW_BUSY=1 VM=1 examples/00-prerequisites/verify.sh`, 2026-10-21, `lowlat-target` running | host reports taken with the guest running (never quoted); guest output in `vm/`, labelled `vm` |

Every `verify.log` in `r01-run1..3` ends with all criteria passing and contains no failed
criterion. Numbers are quoted only from the committed reports; VM and bare-metal numbers are
never compared.

## Example 00: lab smoke test

| # | Claim (asserted by `verify.sh`) | Status | Evidence |
|---|---|---|---|
| 00.1 | `scripts/check-prereqs.sh` exits 0 on the host | verified (r01-run1..3) | `verify.log`: 24 PASS, 1 WARN (system protoc is not used), 0 FAIL |
| 00.2 | The C++, Python and Java consumers each receive all 5,000 parcels at 1 kHz x 5 s | verified (r01-run1..3) | `count = 5000` in `cpp.json`, `python.json`, `java.json` |
| 00.3 | No parcel is dropped (`dropped = 0`) | verified (r01-run1..3) | same reports |
| 00.4 | Each report validates (`lowlat-report check`) and carries the machine profile | verified (r01-run1..3) | `verify.log`, `profile` block in each report |
| 00.5 | The cross-language histogram decode and percentile recompute agree | verified (r01-run1..3) | `lowlat-report check` in `verify.log` |

## Example 01: latency is a distribution

| # | Claim | Status | Evidence |
|---|---|---|---|
| 01.1 | Every report has `count = 10000`, `dropped = 0` and passes `check` (3 languages x 3 variants) | verified (r01-run1..3) | `results/r01-run*/*.json`, `verify.log` |
| 01.2 | per-parcel and batch-32 throughput differ by less than 1 % | verified (r01-run1..3) | `throughput_mhz` in each report's `notes` |
| 01.3 | batch-32 p50 >= 10x per-parcel p50 | verified (r01-run1..3) | batch-32 p50 15.2 to 15.5 ms against per-parcel 0.08 to 0.19 ms |
| 01.4 | bimodal p99 >= 20x its own p50 | verified (r01-run1..3) | `verify.log`; margin is thin by design (1 % slow parcels sit on the p99 boundary) |
| 01.5 | bimodal p50 < 1/4 of the same run's measured `slow_path_us` | verified (r01-run1..3) | replaced the cross-run p50 check (bimodal p50 < 2x per-parcel p50) after it failed once in the earlier S19 runs: commit 1811055, `r01-run2/verify.log`, C++ got 158335 ns, needed < 147838 ns (user decision 2026-10-21) |

## Example 02: Little's Law and Amdahl's Law

| # | Claim | Status | Evidence |
|---|---|---|---|
| 02.1 | C++ and Java: `count = 10000`, `dropped = 0` | verified (r01-run1..3) | `cpp-littles.json`, `java-littles.json` |
| 02.2 | C++: sampled L within 5 % of lambda x W-bar | verified (r01-run1..3) | error +0.46 to +0.63 % |
| 02.3 | Java: sampled L within 5 % of lambda x W-bar | verified (r01-run1..3) | error +2.04 to +4.44 %; the narrowest margin of the suite (run 3, +4.44 %) |
| 02.4 | C++ speedup at N = 4 within 15 % of the Amdahl prediction | verified (r01-run1..3) | 2.84 to 2.85x against 3.11x (-8.6 to -8.9 %) |
| 02.5 | Java speedup at N = 4 within 15 % of the Amdahl prediction | verified (r01-run1..3) | 2.73 to 2.76x against 3.09x (-10.7 to -11.6 %) |
| 02.6 | Python threads speedup at N = 4 < 1.3x (GIL) | verified (r01-run1..3) | 0.49 to 0.67x, `build.gil_enabled = true` |
| 02.7 | Python processes speedup at N = 4 > 2x | verified (r01-run1..3) | 2.84 to 2.94x |
| 02.8 | Unit tests (C++ model, Java JUnit, Python pytest) pass | verified (r01-run1..3) | `verify.log` |
| 02.9 | `--sync free` (no barriers) beats the Amdahl prediction | observed, not asserted | 3.6x C++, 3.5 to 3.6x Java against 3.1x predicted |
| 02.10 | Effective GHz recorded from `perf stat` | observed, not asserted | C++ 4.35 to 4.36, Java 4.34 to 4.35, Python 3.78 to 3.97 |

## Example 03: coordinated omission

| # | Claim | Status | Evidence |
|---|---|---|---|
| 03.1 | `intended-time` p99 >= 50 ms in C++, Java, Python | verified (r01-run1..3) | 100.4 to 101.6 ms |
| 03.2 | `receipt-time` p99 < 1 ms | verified (r01-run1..3) | 5.1 to 56.4 us |
| 03.3 | `closed-loop-corrected` p99 within 2x of `intended-time` p99 | verified (r01-run1..3) | 98.1 to 99.3 ms |
| 03.4 | `closed-loop-naive` p99 < 1 ms | verified (r01-run1..3) | 0.5 to 19.9 us |
| 03.5 | Control: `intended-time-control` p99 < 1 ms | verified (r01-run1..3) | 177 to 449 us (the simulator's send lateness and the loopback hop) |
| 03.6 | Control: `closed-loop-corrected-control` within 2x of `closed-loop-naive-control` | verified (r01-run1..3) | identical p99 per language and run |
| 03.7 | All reports pass `lowlat-report check` (schema, decode, recompute with the writing language's rank convention) | verified (r01-run1..3) | `verify.log`; Java ceil vs C/Python half-up documented in `examples/common/MEASUREMENT.md` |
| 03.8 | Clock read cost recorded per language | observed, not asserted | p50 12 to 13 ns (C++), 13 ns (Java), 45 to 47 ns (Python) |

## Example 04: benchmark harnesses

| # | Claim | Status | Evidence |
|---|---|---|---|
| 04.1 | The check digit agrees across the C++, Java and Python tests | verified (r01-run1..3) | `verify.log` |
| 04.2 | C++: eliminated median >= 10x lower than guarded | verified (r01-run1..3) | 474 to 475x (divisor floored at 0.01 ns: a lower bound) |
| 04.3 | Java: eliminated p50 >= 10x lower than guarded | verified (r01-run1..3) | 3,200 to 3,300x (floored) |
| 04.4 | JMH console and JSON include p0.99 and p0.999 | verified (r01-run1..3) | `jmh.console.txt`, `jmh.json` |
| 04.5 | pyperf JSON holds >= 20 values from >= 3 worker processes | verified (r01-run1..3) | 24 values, 6 processes; 64 outer loops x 1,024 inner loops per value |
| 04.6 | The six converted reports validate with the profile embedded | verified (r01-run1..3) | `report-*.json` |
| 04.7 | pyperf warm-up values are close to measured values for this function | observed, not asserted | first warm-up 1,909 to 1,957 ns, median measured 2,016 to 2,071 ns |

## Lab claims (S12 to S14)

| # | Claim | Status | Evidence |
|---|---|---|---|
| L.1 | The guest runs a PREEMPT_RT kernel: `PREEMPT_RT` in `uname -v` and `CONFIG_PREEMPT_RT=y` in the running kernel's config | verified (r01-lab, guest rebuilt from scratch 2026-10-22) | `r01-lab/guest-kernel.txt`; `r01-vm-smoke/vm/profile.json`: `preempt_model: PREEMPT_RT`, release `7.2.11-200.lowlatrt.fc44.x86_64+rt` |
| L.2 | `check-prereqs.sh --vm` passes all guest checks | verified (r01-lab) | `r01-lab/check-prereqs-vm.txt`: 9 PASS, 0 WARN, 0 FAIL (adds the `/dev/ptp0` check); `r01-vm-smoke/vm/check-prereqs.txt`: 8 PASS before that check existed |
| L.3 | `cyclictest` runs in the guest and prints a Max line | smoke (r01-vm-smoke) | `vm/cyclictest.txt`: one unpinned, untuned thread, 60 s, labelled `vm`; not publishable and never compared with the host |
| L.4 | The guest profile reports a virtual machine | verified (r01-vm-smoke) | `vm/profile.json`: `virt.type = kvm`; `vm/LABEL` = `vm` |
| L.5 | `/dev/ptp0` (KVM virtual PTP) exists after every boot, `phc2sys` locks to it, Docker Engine is up | verified (r01-lab) | `r01-lab/guest-ptp.txt` (module loaded by `/etc/modules-load.d/ptp_kvm.conf`); `r01-lab/guest-phc2sys.txt` (state s2, offset within a few ns); `check-prereqs-vm.txt` PASS "guest: docker". The S13 lock relied on a hand `modprobe`; the rebuild found `/dev/ptp0` missing after reboot, now fixed in cloud-init |
| L.6 | Snapshots `lab-ready` and `lab-ready-rt` exist; `ebpf-*` and `systems-*` domains unchanged | verified (r01-lab) | `r01-lab/snapshots.txt`; `r01-lab/domains.txt` (other labs shut off) |
| L.7 | `VM=1 verify.sh` needs `ALLOW_BUSY=1` and ran end to end once | smoke (r01-vm-smoke) | `r01-vm-smoke/NOTES.md`; host reports in that directory were taken on a busy host and are never quoted |
| L.8 | A guest RT kernel beats the stock kernel under load | unverified (not claimed) | the S13 60 s unpinned smoke did not show it (worst case worse on RT; recorded in `_plans/r01-plan.md`, raw output not committed); needs vCPU pinning and many runs in r05 |

## Iteration log

| Iteration | Change |
|---|---|
| r01 | All of examples 00 to 04 verified on `r01-run1..3`; lab claims from S12 to S14; this page written in S26. Ch1 criterion 5 replaced (in-run check). |
