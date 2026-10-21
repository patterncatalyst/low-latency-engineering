# Line consumers

One consumer per language receives the simulator's `ParcelEvent` datagrams and
measures latency against the belt's schedule, not against arrival.

| Language | Directory | Run |
|---|---|---|
| C++ | `cpp/` (executable `line-consumer`) | `examples/build/release/.../line-consumer` |
| Python | `consumer-py/` (console script `line-consumer-py`) | `uv run line-consumer-py` |
| Java | `java/` (Maven module `line-consumer-java`, main class `io.patterncatalyst.lowlat.line.Consumer`) | `java -jar .../line-consumer-java.jar` |

## Behaviour (identical in all three)

1. Bind a UDP socket on `--bind HOST:PORT` (default `127.0.0.1:47000`). Size the
   receive buffer with `SO_RCVBUF` (`--rcvbuf BYTES`, default 4 MiB) and print
   the size the kernel actually granted, since Linux caps it at
   `net.core.rmem_max` and the host's settings are never changed.
2. For each datagram: parse a `lowlat.line.v1.ParcelEvent`, then "handle" it
   (r01: decode the barcode and look up a lane from the SSCC serial modulo 8;
   later chapters replace this with real work), then take `done_ns` from
   CLOCK_MONOTONIC and record `done_ns − intended_emit_ns` with the language's
   measurement kit (`common/MEASUREMENT.md`). The latency includes any time the
   datagram waited in the socket buffer, so coordinated omission cannot hide it.
3. Track `seq`: each jump forward by more than one adds the missing count to
   `dropped`; a datagram with `seq` at or below the highest seen counts as
   `reordered` (reported in `notes`, not recorded twice).
4. Stop after `--expect N` datagrams (counting received + dropped), or after
   `--idle-timeout-ms` (default 2000) with nothing received once the first datagram
   has arrived, or on SIGINT/SIGTERM. Then write the report (`--report FILE`,
   needs `LOWLAT_PROFILE`) and print the summary line.
5. A negative latency is a bug: it means the two processes are not on the same
   monotonic clock. Abort with a clear message instead of recording it.

Clock reads:

- C++: `lowlat::line::monotonic_ns()` from `line-simulator/include/lowlat/line/clock.hpp`
- Python: `time.monotonic_ns()`, which is CLOCK_MONOTONIC on Linux
- Java: `System.nanoTime()`. Confirm from the JDK 25 HotSpot source that on Linux
  it reads CLOCK_MONOTONIC, and cite where in the consumer's README.

Report fields: `example` = `"00-line-consumer"` unless `--example` overrides it;
`variant` from `--variant` (default `"baseline"`).

## Acceptance (each language)

Run the simulator at 1 kHz for 10 s into the consumer, with `--expect 10000`:

- the report validates against the schema
- `count` = 10,000, `dropped` = 0, no negative latency
- `lowlat-report check` on the three reports exits 0
