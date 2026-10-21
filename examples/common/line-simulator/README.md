# line-simulator

The shared workload of every chapter: a parcel sortation line that emits one
`lowlat.line.v1.ParcelEvent` per parcel as it passes the scanner, at a fixed
rate, whether or not anyone is keeping up. C++23, built by the examples CMake
superproject; the wire contract is `contracts/proto/lowlat/line/v1/parcel.proto`.

## What it emits

One UDP datagram per parcel, to `--dest` (default `127.0.0.1:47000`), each a
serialized `ParcelEvent`:

| Field | Value |
|---|---|
| `seq` | 0, 1, 2, ... without gaps. A gap seen by a consumer is a lost datagram. |
| `intended_emit_ns` | `t0 + seq * 1e9 / rate`: when the schedule says this parcel is due. |
| `actual_emit_ns` | When the simulator really sent it. |
| `encoder_tick` | `floor(intended elapsed s x belt speed m/s x pulses per metre)`: belt position. |
| `barcode` | A valid SSCC-18 (18 digits, GS1 mod-10 check digit). |
| `weight_g`, `dims` | Seeded: log-normal weight around 2 kg, uniform carton sizes. |
| `scan_confidence_permille` | 950..1000 for 97% of reads, 300..700 for the rest. |

Parcels come from a `std::mt19937_64` seeded with `--seed`, so a run is
repeatable for a given standard library (the `<random>` distributions are not
bit-identical between libstdc++ and libc++).

## Why open loop, and why UDP

The belt never waits for a slow consumer. A closed-loop sender, one that waits
for the consumer before sending the next parcel, slows down exactly when the
consumer stalls, and the stall disappears from the measurements. That is
coordinated omission, and on a real line it is physical: a parcel that is not
diverted in time is on the wrong side of the diverter.

So the schedule is a pure function of the parcel number. If the simulator wakes
late it sends at once, never skipping a parcel and never stretching the
schedule, and it records how late it was. UDP supplies the other half: a
datagram send does not block on the receiver (the send uses `MSG_DONTWAIT`, so
even a full socket buffer costs a counted drop, not a stall). TCP flow control
would reintroduce the backpressure the line does not have. A slow consumer
shows up as queueing delay in its latency distribution or as gaps in `seq`.

The simulator sleeps with `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)` to
the intended time of each parcel. An absolute deadline cannot accumulate error,
and a signal interrupt needs no remaining-time bookkeeping. See
`include/lowlat/line/clock.hpp` for why `std::this_thread::sleep_until` is not used.

## Clock-domain rule

Every `*_ns` field is nanoseconds on `CLOCK_MONOTONIC` of the host that runs the
simulator. It is not wall time and means nothing on another host. Producer and
consumer run on the same host or the same VM; subtracting timestamps from
different hosts is a bug.

## Consumers measure from the schedule

A consumer computes `done_ns - intended_emit_ns`, never `done_ns - actual_emit_ns`.
The first includes any lateness of the sender and any queueing in front of the
consumer; the second hides both. The simulator's own lateness
(`actual_emit_ns - intended_emit_ns`) is recorded with the C++ measurement kit as
example `line-simulator`, variant `emit-lateness`, and printed at the end of
every run. On a non-real-time kernel it is the wake-up jitter of the host, so
read it as part of the machine profile: it bounds what any consumer can claim.

## Usage

```
line-simulator [--rate HZ] [--duration S] [--belt-speed-mps V]
               [--scan-to-divert-m D] [--encoder-ppm N] [--seed N]
               [--dest HOST:PORT] [--report FILE] [--quiet]
```

| Option | Default | Meaning |
|---|---|---|
| `--rate HZ` | 1000 | Parcels per second (integer, so the schedule is exact integer arithmetic). |
| `--duration S` | 10 | Run length; the run emits `round(duration x rate)` parcels. |
| `--belt-speed-mps` | 2.5 | Belt speed in metres per second. |
| `--scan-to-divert-m` | 1.2 | Scanner-to-diverter distance. Only used to print the deadline. |
| `--encoder-ppm` | 1000 | Encoder pulses per metre of belt. |
| `--seed` | 42 | Seed of the parcel generator. |
| `--dest` | `127.0.0.1:47000` | UDP destination, `host:port`, IPv4. |
| `--report FILE` | none | Write the emit-lateness report (`lowlat-report/1`). Requires `LOWLAT_PROFILE`; checked before the run starts. |
| `--quiet` | off | Print only the final summary line. |

On start it prints the physical budget, `distance / speed` (480.0 ms at the
defaults). `SIGINT` and `SIGTERM` stop the run after the current parcel; the
summary and the report are still written.

```bash
scripts/profile.sh --out /tmp/profile.json
LOWLAT_PROFILE=/tmp/profile.json examples/build/release/common/line-simulator/line-simulator \
    --rate 1000 --duration 10 --dest 127.0.0.1:47999 --report /tmp/sim.json
```

If nothing listens on the destination, sends fail with `ECONNREFUSED`; they are
counted as `send_errors` (and as `dropped` in the report) and the schedule keeps
running.

## Tests

`ctest --preset release` from `examples/` runs `line-simulator-test`: the SSCC
check digit against a GS1 example, the schedule arithmetic, option parsing, and
an end-to-end run at 1 kHz for 2 s against a receiver thread that checks 2,000
datagrams, contiguous `seq`, valid SSCCs and `intended_emit_ns` strictly
increasing by 1,000,000 ns. The unit tests are a smoke check, not a measurement.
