# 03-coordinated-omission

Chapter 3, measuring correctly: one 200 ms stall, measured four ways, in C++, Java
and Python. The same stall is invisible to a service-side timer and to a closed-loop
benchmark, and obvious to a clock that starts at the belt's schedule.

## What it does

The line simulator emits 1,000 parcels/s for 10 s (`seq`, `intended_emit_ns`).
A consumer in each language receives them and, at parcel `seq` 5000, stalls for
200 ms with a blocking sleep. `sleep` is the right tool here: it models a GC
pause, a page fault or a lock convoy, a thread that is simply not running. From
that one run it records:

| Variant | Latency is | What it shows |
|---|---|---|
| `receipt-time` | `done - time the datagram was dequeued` | A naive service-side timer: it starts the clock when it gets the work, so the 200 parcels that queued during the stall look fast. |
| `intended-time` | `done - intended_emit_ns` | The belt's schedule. The queued parcels are charged their wait. Honest. |
| `closed-loop-naive` | one sample per request | A client that issues the next request only after the previous completes (one request per 1 ms, same 200 ms stall). One slow sample in 10,000. |
| `closed-loop-corrected` | the same samples through the kit's `record_corrected(latency, 1 ms)` | HdrHistogram back-fills the ~199 requests a 1 kHz client would have issued during the stall. |

A control run (`--stall-ms 0`, variants suffixed `-control`) records the same four
without a stall. A clock probe records the cost of one clock read (variant
`clock-read`).

## Run

```sh
examples/03-coordinated-omission/verify.sh            # quiet host
ALLOW_BUSY=1 examples/03-coordinated-omission/verify.sh
```

Builds, runs 3 languages x (stall, control) x 10 s plus 3 probes, writes
`lowlat-report/1` files and `profile.json` to `results/latest/`, runs
`lowlat-report check`, and asserts the criteria below. Exit non-zero means the
effect was not observed. UDP ports 47230-47235 on 127.0.0.1.

Each language is also a plain program (`run` and `probe` subcommands):

| Language | Program |
|---|---|
| C++ | `co-experiment` (CMake target in `cpp/`) |
| Java | `java -jar java/target/co-experiment-java.jar` |
| Python | `uv run --package lowlat-co co-experiment-py` |

## Criteria (each language)

- `intended-time` p99 >= 50 ms
- `receipt-time` p99 < 1 ms
- `closed-loop-corrected` p99 within 2x of `intended-time` p99
- `closed-loop-naive` p99 < 1 ms
- control: `receipt-time`, `intended-time` and `closed-loop-corrected` p99 within 2x of each other
  (and `intended-time-control` p99 < 50 ms, the stall is gone)

## Clock probe

Two back-to-back clock reads, the difference recorded, 1e6 times. The cost per
read is the floor of any timing you do around sub-microsecond work.

| Language | Clocks probed |
|---|---|
| C++ | `lowlat::line::monotonic_ns` (`clock_gettime`), `std::chrono::steady_clock::now` |
| Java | `System.nanoTime` |
| Python | `time.monotonic_ns`, `time.perf_counter_ns` |

`verify.sh` prints the host clocksource from the profile (`tsc` is read in
user space through the vDSO; `acpi_pm` or `hpet` would cost a syscall or an I/O
read and show up in these numbers).

## Design choices

- One program per language with the same two subcommands, so the three code paths
  can be compared line by line. The receive loop is written for the example (it needs
  the dequeue time and the stall), reusing each language's lane lookup and sequence
  tracking from the line consumer.
- All percentiles come from the measurement kits (`common/MEASUREMENT.md`); the
  correction is the kit's `record_corrected` / `recordCorrected`, never hand-rolled.
- The closed-loop phase runs after the UDP phase in the same process, with the same
  stall; a pure closed loop (one request per 1 ms, no queueing behind the stall).
- Java and Python run unwarmed on purpose (noted in the reports): the first parcels
  include JIT and interpreter warm-up.

## Verification status

Run on the development host, busy (kernel build and other agents running,
`ALLOW_BUSY=1`), governor `powersave`, `tuned=balanced`, bare metal, clocksource `tsc`:
numbers are indicative only. A quiet-host run (S19) is pending.

- Stall criteria (4 per language): observed in C++, Java and Python.
  `intended-time` p99 about 100 ms, `receipt-time` p99 5 to 59 us,
  `closed-loop-corrected` p99 about 98 to 99 ms, `closed-loop-naive` p99 0.4 to 17 us.
- Control criteria: **not met**. With no stall, `intended-time` p99 is 180 to 225 us
  against 5 to 28 us for `receipt-time` and 1 to 19 us for `closed-loop-corrected`. The
  gap is the simulator's wake-up lateness plus the loopback hop, which `intended-time`
  includes by design and the other two cannot see; it is not a stall.
- `lowlat-report check` fails on `java-closed-loop-corrected.json`: the Java kit's
  p99 differs from the Python recomputation of the same histogram by about 1 ms
  (one rank in the sparse back-filled tail). Cross-language percentile rank rounding in the kits.
- Status: **unverified** until both items above are resolved.
