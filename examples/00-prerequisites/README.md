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
Readiness is detected by polling `ss` for the bound socket, because a consumer's
stdout is block-buffered when redirected to a file.

## Flags and environment

| Variable | Meaning |
|---|---|
| `RESULTS_DIR` | report directory (default `results/latest`) |
| `ALLOW_BUSY=1` | do not refuse when a `lowlat-*` VM is running; numbers are noisy |
| `SKIP_BUILD=1` | reuse existing builds |
| `LOWLAT_BUILD` | private C++ build directory |
| `PORT_BASE` | first UDP port (default 47200) |
| `VM=1` | run the guest smoke test after the host one |

## VM mode (`VM=1`) - implemented, not yet run

Runs `scripts/check-prereqs.sh --vm`, deploys `examples/` and `scripts/` with
`scripts/lab/deploy-to-vm.sh`, then through `scripts/lab/lab-ssh.sh lowlat-target`
runs `cyclictest -m -p95 -D60 -q` (via `sudo` inside the guest, which has
passwordless sudo; the host is untouched) and the guest's `scripts/profile.sh`.
Outputs go to `results/latest/vm/` with a `LABEL` file containing `vm`, and the
script asserts the guest profile reports a virtual machine.

**Labelling rule:** every number from the guest is labelled `vm` and is never
compared with a bare-metal number. The guest shows what the lab can do (real-time
kernel, cyclictest jitter), not what the host does.

## Expected effect

Three valid reports, each `count = 5000`, `dropped = 0`. Percentiles vary with host
load and are not asserted.

## Verification status

Behavioural. Last run (host busy: a kernel build and other compiles, `ALLOW_BUSY=1`):
exit 0; all three reports valid with count 5000 and dropped 0 (p99 about 6.0 ms
C++, 4.9 ms Python, 83 ms Java including interpreter warm-up). Unverified on a
quiet host until the S19 measurement run. The `VM=1` path has passed `bash -n` and
shellcheck only; it has not been run because the guest is not provisioned yet.
