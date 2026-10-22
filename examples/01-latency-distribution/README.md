# 01-latency-distribution

Chapter 1: latency is a distribution, and design choices that look neutral on
throughput move its shape. Three consumer variants receive the same simulator
stream (1 kHz x 10 s, UDP port 47210) in C++, Python and Java.

## What it shows

**A. Per-parcel vs batch-of-32.** Both variants see the same arrival rate, so
they process the same number of parcels per second. The batch variant holds
parcels until 32 have arrived and then handles them together, the
"throughput-friendly" design. Each parcel's latency is `done - intended_emit`,
so a parcel that arrives first waits for 31 more (31 ms at 1 kHz) before it is
handled. Throughput is equal; p50 is about 15 ms instead of about 0.1 ms.

**B. Bimodal.** Per-parcel handling, but one parcel in 100 (`seq % 100 == 0`,
a scanner no-read) takes a slow re-lookup path of about 2 ms. The median does
not move. p99 jumps by an order of magnitude, because the slow parcel and the
parcels queued behind it all land in the tail: in r01-run1..3, 2.9 to 5.0 % of
parcels took 1 ms or more, and p99 was 2.5 to 6.3 ms. A single summary number
describes neither group.

The slow path is a busy CPU loop (a dependent multiply-add chain), calibrated at
startup to about 2 ms, and not a sleep. A sleep yields the core: the OS runs
something else, the timer wakes the thread later, and the cost shows up as
scheduler noise rather than as the work the parcel really does. A real re-lookup
holds the core, so the parcels behind it queue. The busy loop reproduces that
queueing.

The calibration doubles the iteration count until a run lasts 20 ms, then keeps
the fastest of several further runs (a preempted run measures the scheduler).
Each report's `notes` records the measured slow-path duration (`slow_path_us`).

## The handler hook

The common line consumer owns the receive path: bind, parse, sequence and gap
tracking, timestamping and recording. It calls a per-parcel handler between
"received" and "done", and the handler reports each parcel done, inside the call
or later; the loop records `done - intended_emit` at that moment. This example
supplies only the three handlers (per-parcel, batch-32, bimodal). Batch-32 keeps
each parcel's `intended_emit` and completes the held parcels together, with one
done time for the batch, when the 32nd arrives; its end-of-run drain hook
completes a partial last batch.

| Language | Hook |
|---|---|
| C++ | `line::consume_with(cfg, stop, recorder, handler)`; the handler is a template parameter satisfying `line::ParcelHandler` (`handler(const ParcelEvent&, line::Completion&)`, optional `drain(Completion&)`), so the call is inlined into the loop |
| Python | `lowlat_consumer.run(sock, rec, tracker, handler, expect, idle_ns, drain)`; the handler is a callable `(ParcelEvent, Completion) -> None` |
| Java | `LineReceiver.run(ParcelHandler)`; `ParcelHandler.onParcel(ParcelEvent, Completion)` and a default `drain(Completion)` |

Each language reuses the common CLI parser and adds only `--slow-us`; the lane
lookup is the common `lane_for` / `Lanes.laneOf`.

## Layout

| Path | Contents |
|---|---|
| `cpp/` | `latdist-consumer` (CMake target, auto-discovered) |
| `latdist-py/` | Python package `lowlat_latdist`, console script `latdist-py`, uv workspace member `lowlat-latdist` |
| `java/` | Maven module `latdist-java`, `java -jar target/latdist-java.jar` |
| `verify.sh` | runs all nine runs and asserts the criteria |

## Run

```bash
examples/01-latency-distribution/verify.sh
```

Environment (from `examples/_lib/lib.sh`): `ALLOW_BUSY=1` to measure while a lab
VM runs or the host is loaded (numbers are noisy), `SKIP_BUILD=1`,
`RESULTS_DIR`, `LOWLAT_BUILD` (private C++ build directory).

Reports land in `results/latest/` as `<lang>-<variant>.json` (plus the machine
profile and the consumer logs). View them with:

```bash
uv run --project examples lowlat-report show examples/01-latency-distribution/results/latest/*.json
```

By hand, one variant (the consumer first, then the simulator):

```bash
export LOWLAT_PROFILE=/tmp/profile.json && scripts/profile.sh --out "$LOWLAT_PROFILE"
examples/build/release/01-latency-distribution/cpp/latdist-consumer \
    --variant batch-32 --bind 127.0.0.1:47210 --expect 10000 --report /tmp/batch.json &
examples/build/release/common/line-simulator/line-simulator --rate 1000 --duration 10 --dest 127.0.0.1:47210
```

## Flags (every language)

| Flag | Default | Meaning |
|---|---|---|
| `--variant` | `per-parcel` | `per-parcel`, `batch-32` or `bimodal-1pct` |
| `--bind HOST:PORT` | `127.0.0.1:47210` | UDP address |
| `--expect N` | none | stop after N parcels (received + dropped) |
| `--idle-timeout-ms` | 2000 | stop after this long with nothing received |
| `--slow-us` | 2000 | target duration of the slow path (`bimodal-1pct`) |
| `--report FILE` | none | write the `lowlat-report/1` JSON (needs `LOWLAT_PROFILE`) |
| `--example` | `01-latency-distribution` | report example name |
| `--rcvbuf BYTES` | 4194304 | `SO_RCVBUF` request (common consumer flag) |

## Expected effect and criteria

`verify.sh` exits non-zero unless, for each of C++, Python and Java:

1. processed throughput of `per-parcel` and `batch-32` differs by less than 1 %.
   Throughput is `count / (last done - first done)`, written to the report's
   `notes` as `throughput_mhz` (milli-Hz, integer). The batch variant's first
   completion is 31 ms into the run, so its figure is about 0.3 % higher.
2. `batch-32` p50 is at least 10x the `per-parcel` p50.
3. `bimodal-1pct` p99 is at least 20x its own p50.
4. `bimodal-1pct` p50 is under a quarter of the same run's measured slow-path
   duration (`slow_path_us` in `notes`): the median stays in the fast mode. An
   earlier version compared it with the `per-parcel` run's p50 and failed in one
   of three quiet-host runs (r01-run2), because on an untuned host the median
   itself moves between runs (C++ per-parcel p50 157, 74 and 80 us across
   r01-run1..3). Comparing within one run removes that dependence.

All reports must also have `count = 10000`, `dropped = 0`, and pass
`lowlat-report check`.

Criterion 3 depends on the 1 % boundary: exactly 100 of 10,000 parcels are slow,
so p99 sits where the slow parcels and the parcels queued behind them meet
(2.5 to 6.3 ms in r01-run1..3). The ratio therefore also depends on how small the
median is.
On a loaded host the median grows and the margin shrinks.

## Verification status

Behavioural: `verify.sh` runs the nine runs end to end and asserts the observable
effect (equal throughput, batch median at least 10x, bimodal tail at least 20x
the median). Run on a busy host (`ALLOW_BUSY=1`, load average about 20) all
criteria held; criterion 3 held by a margin of about 10 % (22x against 20x). The
figures are unverified on a quiet host until the S19 measurement run; the
chapter quotes only the committed S19 result files.

Every number carries the machine profile (`profile` block of each report): CPU
governor, tuned profile, virtualisation, load.
