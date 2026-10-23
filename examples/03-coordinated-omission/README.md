# 03-coordinated-omission

Chapter 3, measuring correctly: one 200 ms stall, measured four ways, in C++, Java
and Python. The same stall is invisible to a service-side timer and to a closed-loop
benchmark, and obvious to a clock that starts at the belt's schedule.

## What it does

The line simulator emits 1,000 parcels/s for 10 s (`seq`, `intended_emit_ns`).
A consumer in each language receives them and, at parcel `seq` 5000, stalls for
200 ms with a blocking sleep. `sleep` is the right tool here: it models a GC
pause, a page fault or a lock convoy, a thread that is not running. From
that one run it records:

| Variant | Latency is | What it shows |
|---|---|---|
| `receipt-time` | `done - time the datagram was dequeued` | A naive service-side timer: it starts the clock when it gets the work, so the 200 parcels that queued during the stall look fast. |
| `intended-time` | `done - intended_emit_ns` | The belt's schedule. The queued parcels are charged their wait. |
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
- control (no stall): `intended-time-control` p99 < 1 ms (no 100 ms tail), and
  `closed-loop-corrected-control` p99 within 2x of `closed-loop-naive-control` p99
  (the correction adds nothing when nothing is late)

### Why `intended-time` has a floor the others cannot see

With no stall, `intended-time` p99 is still 0.19 to 0.42 ms while `receipt-time` is 5 to 75
us (C++ 5.2 to 8.0, Python 25.7 to 27.8, Java 53.8 to 74.9). `intended-time` starts at the belt's schedule, so it includes the
simulator waking late to send, the loopback hop and the socket queue. `receipt-time`
starts after the datagram is dequeued and the closed loop starts at its own request,
so neither can see that part. The floor is real latency of the line, not a stall,
and it is why the control is judged against 1 ms rather than against the other clocks.

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
- Java and Python run unwarmed by design (noted in the reports): the first parcels
  include JIT and interpreter warm-up.

## Percentile rank differs between the HdrHistogram ports

The three kits use the HdrHistogram port of their language, and the ports do not
define the percentile rank the same way: the C and Python ports round `p x N / 100`
half up, the Java port rounds it up (`ceil`). On dense data the answers fall in the
same bucket; in a sparse tail, such as the 200 parcels behind the stall in 10,000,
the languages can land one bucket apart. Each kit keeps its library's convention, and
`lowlat-report check` recomputes a report with the convention of the language that
wrote it. Do not compare a C++ and a Java p99 as if one rule produced both. The full
statement is in [`examples/common/MEASUREMENT.md`](../common/MEASUREMENT.md).

## Verification status

Behavioural. `verify.sh` runs, in C++, Java and Python, the 200 ms stall run, the
no-stall control run and the clock probe, then asserts per language:

- `intended-time` p99 >= 50 ms and `receipt-time` p99 < 1 ms;
- `closed-loop-corrected` p99 within 2x of `intended-time` p99, `closed-loop-naive` p99 < 1 ms;
- control: `intended-time-control` p99 < 1 ms, and `closed-loop-corrected-control` p99
  within 2x of `closed-loop-naive-control` p99;
- every report passes `lowlat-report check` (schema, histogram decode, percentile recompute).

All of it held on the quiet-host runs `r02-run1..3` (bare-metal host, governor
`powersave`, tuned `balanced`, clocksource `tsc`, kernel 7.2.11-200.fc44). Ranges over
the three runs, in all three languages:

| Quantity | Range (p99 unless noted) |
|---|---|
| `intended-time`, stall | 100,401,151 to 101,842,943 ns |
| `closed-loop-corrected`, stall | 98,238,463 to 99,287,039 ns |
| `receipt-time`, stall | 5,447 to 49,695 ns |
| `closed-loop-naive`, stall | 961 to 19,359 ns |
| `intended-time-control` | 185,343 to 424,703 ns |
| `closed-loop-corrected-control` = `closed-loop-naive-control` | 965 to 19,839 ns (identical per language) |
| clock read, p50 | C++ 12 to 13 ns, Java 12 to 13 ns, Python 42 to 46 ns |
