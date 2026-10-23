# line-consumer (C++)

C++23 consumer of the line simulator's `ParcelEvent` datagrams. The behaviour
is specified once for all languages in `../README.md`.

## Build and run

```sh
cd examples
cmake --preset release && cmake --build --preset release
ctest --preset release                       # includes line-consumer-test

scripts/profile.sh --out /tmp/p.json         # from the repo root
LOWLAT_PROFILE=/tmp/p.json build/release/common/line-simulator/consumers/cpp/line-consumer \
    --bind 127.0.0.1:47000 --expect 10000 --report /tmp/cpp-consumer.json
build/release/common/line-simulator/line-simulator --rate 1000 --duration 10 --dest 127.0.0.1:47000
```

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--bind HOST:PORT` | `127.0.0.1:47000` | UDP address (IPv4) |
| `--rcvbuf BYTES` | 4 MiB | `SO_RCVBUF` request; the granted size is printed and kept in `notes` |
| `--expect N` | none | stop after N datagrams (received + dropped) |
| `--idle-timeout-ms MS` | 2000 | stop after MS of silence, once the first datagram has arrived |
| `--report FILE` | none | write the report (needs `LOWLAT_PROFILE`) |
| `--window N` | none | also write `<stem>-first-N` (seq < N) and `<stem>-steady` reports beside `--report` |
| `--example NAME` | `00-line-consumer` | report `example` |
| `--variant NAME` | `baseline` | report `variant` |

SIGINT and SIGTERM stop the run and still write the report.

## What the latency includes

`done_ns - intended_emit_ns`, both on `CLOCK_MONOTONIC`. `done_ns` is read
after the datagram has been received, parsed, sequence-checked and handled
(SSCC serial modulo 8 gives the lane), so the number contains the simulator's
emit lateness, the loopback hop, any time spent queued in the socket buffer,
and the consumer's own work. A negative value aborts the run: the processes
are not on the same clock.

## Choices

- Idle timeout uses `SO_RCVTIMEO` (100 ms tick) rather than `poll()`: one
  `recv` per datagram, with no extra syscall between arrival and `done_ns`.
  The tick also bounds the signal race before `recv`.
- A first `seq` above 0 counts the missing leading parcels as dropped (the
  simulator numbers from 0). Reordered or repeated `seq` values are counted in
  `notes`, never recorded twice.
- `SO_RCVBUF` is set before `bind`; Linux reports twice the request.
