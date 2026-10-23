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
| `r02-run1..3` | `verify.sh` of examples 00 to 04, run serially with the lab VM down after the r02 change to the shared receive path (S4); committed in `examples/NN-*/results/r02-run{1,2,3}/` (commit d419992), measured 2026-10-22 | bare-metal host (XPS 15 9510, 16 logical CPUs), `virt: none`, governor `powersave`, tuned `balanced`, kernel 7.2.11-200.fc44 (PREEMPT_DYNAMIC), clocksource `tsc`, load average 0.17 to 1.25 at the start (all 15 profile.json files); "quiet host" |
| `r01-vm-smoke` | `ALLOW_BUSY=1 VM=1 examples/00-prerequisites/verify.sh`, 2026-10-21, `lowlat-target` running | host reports taken with the guest running (never quoted); guest output in `vm/`, labelled `vm` |

Every `verify.log` in `r02-run1..3` ends with all criteria passing and contains no failed
criterion. Numbers are quoted only from the committed reports; VM and bare-metal numbers are
never compared.

## Example 00: lab smoke test

| # | Claim (asserted by `verify.sh`) | Status | Evidence |
|---|---|---|---|
| 00.1 | `scripts/check-prereqs.sh` exits 0 on the host | verified (r02-run1..3) | `verify.log`: 28 PASS, 1 WARN (system protoc is not used), 0 FAIL; the libvirt NAT default-network check was replaced by libvirt, passt and libvirt-ssh-proxy checks |
| 00.2 | The C++, Python and Java consumers each receive all 5,000 parcels at 1 kHz x 5 s | verified (r02-run1..3) | `count = 5000` in `cpp.json`, `python.json`, `java.json` |
| 00.3 | No parcel is dropped (`dropped = 0`) | verified (r02-run1..3) | same reports |
| 00.4 | Each report validates (`lowlat-report check`) and carries the machine profile | verified (r02-run1..3) | `verify.log`, `profile` block in each report |
| 00.5 | The cross-language histogram decode and percentile recompute agree | verified (r02-run1..3) | `lowlat-report check` in `verify.log` |

## Example 01: latency is a distribution

| # | Claim | Status | Evidence |
|---|---|---|---|
| 01.1 | Every report has `count = 10000`, `dropped = 0` and passes `check` (3 languages x 3 variants) | verified (r02-run1..3) | `results/r02-run*/*.json`, `verify.log` |
| 01.2 | per-parcel and batch-32 throughput differ by less than 1 % | verified (r02-run1..3) | `throughput_mhz` in each report's `notes` |
| 01.3 | batch-32 p50 >= 10x per-parcel p50 | verified (r02-run1..3) | batch-32 p50 15.2 to 15.4 ms against per-parcel 0.106 to 0.182 ms |
| 01.4 | bimodal p99 >= 20x its own p50 | verified (r02-run1..3) | `verify.log`; margin is thin by design (1 % slow parcels sit on the p99 boundary); the narrowest margin of example 01's criteria (Python run 1, p99 26.1x its own p50 against the 20x bound) |
| 01.5 | bimodal p50 < 1/4 of the same run's measured `slow_path_us` | verified (r02-run1..3) | replaced the cross-run p50 check (bimodal p50 < 2x per-parcel p50) after it failed once in the earlier S19 runs: commit 1811055, run 2 `verify.log` of that set, C++ got 158335 ns, needed < 147838 ns (user decision 2026-10-21) |

## Example 02: Little's Law and Amdahl's Law

| # | Claim | Status | Evidence |
|---|---|---|---|
| 02.1 | C++ and Java: `count = 10000`, `dropped = 0` | verified (r02-run1..3) | `cpp-littles.json`, `java-littles.json` |
| 02.2 | C++: sampled L within 5 % of lambda x W-bar | verified (r02-run1..3) | error +0.22 to +0.58 % |
| 02.3 | Java: sampled L within 5 % of lambda x W-bar | verified (r02-run1..3) | error +0.75 to +1.99 % (largest in run 2) |
| 02.4 | C++ speedup at N = 4 within 15 % of the Amdahl prediction | verified (r02-run1..3) | 2.83 to 2.85x against 3.11x (-8.5 to -9.1 %) |
| 02.5 | Java speedup at N = 4 within 15 % of the Amdahl prediction | verified (r02-run1..3) | 2.75 to 2.76x against 3.09x (-10.7 to -11.0 %) |
| 02.6 | Python threads speedup at N = 4 < 1.3x (GIL) | verified (r02-run1..3) | 0.52 to 0.69x, `build.gil_enabled = true` |
| 02.7 | Python processes speedup at N = 4 > 2x | verified (r02-run1..3) | 2.92 to 2.94x |
| 02.8 | Unit tests (C++ model, Java JUnit, Python pytest) pass | verified (r02-run1..3) | `verify.log` |
| 02.9 | `--sync free` (no barriers) beats the Amdahl prediction | observed, not asserted | 3.56 to 3.60x C++, 3.52 to 3.57x Java against 3.08 to 3.11x predicted |
| 02.10 | Effective GHz recorded from `perf stat` | observed, not asserted | C++ 4.33 to 4.34, Java 4.35 to 4.36, Python 3.82 to 3.90 |

## Example 03: coordinated omission

| # | Claim | Status | Evidence |
|---|---|---|---|
| 03.1 | `intended-time` p99 >= 50 ms in C++, Java, Python | verified (r02-run1..3) | 100.3 to 102.3 ms |
| 03.2 | `receipt-time` p99 < 1 ms | verified (r02-run1..3) | 5.1 to 52.5 us |
| 03.3 | `closed-loop-corrected` p99 within 2x of `intended-time` p99 | verified (r02-run1..3) | 98.1 to 99.3 ms |
| 03.4 | `closed-loop-naive` p99 < 1 ms | verified (r02-run1..3) | 1.0 to 19.8 us |
| 03.5 | Control: `intended-time-control` p99 < 1 ms | verified (r02-run1..3) | 186 to 284 us (the simulator's send lateness and the loopback hop) |
| 03.6 | Control: `closed-loop-corrected-control` within 2x of `closed-loop-naive-control` | verified (r02-run1..3) | identical p99 per language and run |
| 03.7 | All reports pass `lowlat-report check` (schema, decode, recompute with the writing language's rank convention) | verified (r02-run1..3) | `verify.log`; Java ceil vs C/Python half-up documented in `examples/common/MEASUREMENT.md` |
| 03.8 | Clock read cost recorded per language | observed, not asserted | p50 12 to 13 ns (C++), 12 to 13 ns (Java), 42 to 47 ns (Python) |

## Example 04: benchmark harnesses

| # | Claim | Status | Evidence |
|---|---|---|---|
| 04.1 | The check digit agrees across the C++, Java and Python tests | verified (r02-run1..3) | `verify.log` |
| 04.2 | C++: eliminated median >= 10x lower than guarded | verified (r02-run1..3) | 473 to 476x (divisor floored at 0.01 ns: a lower bound) |
| 04.3 | Java: eliminated p50 >= 10x lower than guarded | verified (r02-run1..3) | 3,200x (floored) |
| 04.4 | JMH console and JSON include p0.99 and p0.999 | verified (r02-run1..3) | `jmh.console.txt`, `jmh.json` |
| 04.5 | pyperf JSON holds >= 20 values from >= 3 worker processes | verified (r02-run1..3) | 24 values, 6 processes; 64 outer loops x 1,024 inner loops per value |
| 04.6 | The six converted reports validate with the profile embedded | verified (r02-run1..3) | `report-*.json` |
| 04.7 | pyperf warm-up values are close to measured values for this function | observed, not asserted | first warm-up 1,912 to 1,991 ns, median measured 1,977 to 1,989 ns (3.0 and 3.3 percent lower in runs 2 and 3, 0.4 percent higher in run 1; below the minimum measured value in runs 2 and 3, not in run 1) |

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
| r01 | All of examples 00 to 04 verified on the r01 host runs (kept at tag r01.x); lab claims from S12 to S14; this page written in S26. Ch1 criterion 5 replaced (in-run check). |
| r01.x S27 | Idiom fixes (S27) applied to the example code; all of examples 00 to 04 re-measured on the bare-metal host with the VM down (the r01 host runs, commit c3e4cce, after the S27 validation fixes) and every quoted number in the chapters, READMEs, figures and this page moved to the new runs; example 04 re-measured at 9410287 after verify.sh printed pyperf's true median (it had printed the 13th of 24 sorted values), and its quoted numbers moved to those runs. Check-prereqs now reports 26 PASS, 1 WARN, 0 FAIL after the libvirt NAT check was replaced by passt and libvirt-ssh-proxy checks. |
| r02.x S13b | The shared receive path changed in S4, so the r01 numbers no longer described the code. Examples 00 to 04 were re-measured as `r02-run1..3` (S13a, commit d419992) and every quoted number in Ch0 to Ch4, the READMEs, the figures and this page moved to those runs; the r01 host run directories were removed (they remain at tag r01.x). Check-prereqs now reports 28 PASS, 1 WARN, 0 FAIL (zlib headers and async-profiler checks added). |
