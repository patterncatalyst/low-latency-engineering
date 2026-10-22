# 00-prerequisites - lab smoke test

Chapter 0 proves the toolchain end to end before any latency claim is made. It
does not measure a technique. It shows that the C++ line simulator, the three
language consumers, the measurement kits and the machine profile all work
together, and that nothing is lost on the way.

## What it shows

1. `scripts/check-prereqs.sh` exits 0 (toolchain, pinned protoc, JDK 25, Python 3.14, uv).
2. The simulator emits 1 kHz for 5 s (5,000 parcels). Each consumer, in turn
   (C++, Python, Java), receives all 5,000 over loopback with `dropped = 0`.
3. Each writes a `lowlat-report/1` that validates against the schema and carries
   the machine profile. The percentile columns are a smoke number, not a result.

## Run

```bash
examples/00-prerequisites/verify.sh                 # host smoke test
ALLOW_BUSY=1 examples/00-prerequisites/verify.sh    # measure even while a lab VM or other load is running
VM=1 examples/00-prerequisites/verify.sh            # also the lab-guest smoke test (see below)
```

Reports land in `results/latest/` (`cpp.json`, `python.json`, `java.json`,
`profile.json`, plus each consumer's stdout). The script exits non-zero if any
check fails, and never changes the host.

## Ports

UDP `47200` (C++), `47201` (Python), `47202` (Java) on `127.0.0.1`; override the
first with `PORT_BASE`. The languages run one after another, never concurrently.
Readiness is detected by polling `ss` for the bound socket.

## Flags and environment

| Variable | Meaning |
|---|---|
| `RESULTS_DIR` | report directory (default `results/latest`) |
| `ALLOW_BUSY=1` | do not refuse when a `lowlat-*` VM is running; numbers are noisy |
| `SKIP_BUILD=1` | reuse existing builds |
| `LOWLAT_BUILD` | private C++ build directory |
| `PORT_BASE` | first UDP port (default 47200) |
| `VM=1` | run the guest smoke test after the host one |

## VM mode (`VM=1`)

`VM=1` needs `ALLOW_BUSY=1` as well: the guest must be running, and `verify.sh`
otherwise refuses to measure while a `lowlat-*` VM is up. The host smoke test
then runs while the guest competes for the CPUs, so its numbers are noisy.

It runs `scripts/check-prereqs.sh --vm`, deploys `examples/` and `scripts/` with
`scripts/lab/deploy-to-vm.sh`, then through `scripts/lab/lab-ssh.sh lowlat-target`
runs `cyclictest -m -p95 -D60 -q` (via `sudo` inside the guest, which has
passwordless sudo; the host is untouched) and the guest's `scripts/profile.sh`.
Outputs go to `results/latest/vm/` with a `LABEL` file containing `vm`, and the
script asserts the guest profile reports a virtual machine.

It has run once: `ALLOW_BUSY=1 VM=1 ./verify.sh` on 2026-10-21 against the
PREEMPT_RT guest (snapshot `lab-ready-rt`). The output is committed in
`results/r01-vm-smoke/`, with the guest results in `vm/` labelled `vm`.
`check-prereqs.sh --vm` reported 8 PASS, 0 WARN, 0 FAIL, and `cyclictest` ran one
unpinned, untuned 60 s thread. This is a smoke test of the lab path, not a
measurement. The host reports in that directory were taken with the guest running
and are never quoted (see `NOTES.md` there). That smoke test predates the
`/dev/ptp0` check; after the guest was rebuilt from the scripts on 2026-10-22,
`check-prereqs.sh --vm` passes 9 of 9 and `phc2sys` locks to `/dev/ptp0`
(`results/r01-lab/`, VM).

**Labelling rule:** every number from the guest is labelled `vm` and is never
compared with a bare-metal number. The guest shows what the lab can do (real-time
kernel, cyclictest jitter), not what the host does.

## Expected effect

Three valid reports, each `count = 5000`, `dropped = 0`. Percentiles vary with host
load and are not asserted.

## Verification status

Behavioural. `verify.sh` asserts that `check-prereqs.sh` exits 0; that the C++,
Python and Java consumers each receive all 5,000 parcels from the 1 kHz x 5 s
simulator run with `dropped = 0`; and that each report validates, carries the
machine profile and matches `lowlat-report check`. Exit 0 requires all of it.

It held on all three quiet-host runs, `r01-run1..3` (bare-metal host, governor
`powersave`, tuned `balanced`, kernel 7.2.11-200.fc44, `virt: none`): every report
had `count = 5000` and `dropped = 0`. The p99 smoke values were not asserted; across
the runs they were 180,607 to 182,783 ns (C++), 202,367 to 217,727 ns (Python) and
212,735 to 325,375 ns (Java, which includes JIT warm-up).

The `VM=1` path ran once (`results/r01-vm-smoke/`, labelled VM): 8 of 8 guest
checks passed and `cyclictest` produced its output. Those values are VM numbers and
are not compared with the host runs.
