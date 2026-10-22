# consumer-py

Python line consumer: receives the simulator's `lowlat.line.v1.ParcelEvent`
datagrams and records `done_ns - intended_emit_ns` with the Python measurement kit
(`common/measure-py`). Behaviour is specified in `../README.md`; this file covers what
is specific to Python.

## Run

```
cd examples
uv sync
export LOWLAT_PROFILE=/path/to/profile.json      # scripts/profile.sh --out FILE
uv run line-consumer-py --bind 127.0.0.1:47000 --expect 10000 --report py-consumer.json &
build/release/common/line-simulator/line-simulator --rate 1000 --duration 10 --dest 127.0.0.1:47000
uv run lowlat-report check py-consumer.json
```

`LOWLAT_PROFILE` is required (the kit refuses a number without a machine profile);
the consumer checks it before binding.

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--bind HOST:PORT` | `127.0.0.1:47000` | UDP address |
| `--rcvbuf BYTES` | 4 MiB | `SO_RCVBUF` request; the granted size (`getsockopt`) is printed. Linux caps it at `net.core.rmem_max` and reports twice the set value; the host is never changed. |
| `--expect N` | none | stop after N datagrams, received plus dropped |
| `--idle-timeout-ms MS` | 2000 | stop after MS of silence, once the first datagram has arrived |
| `--report FILE` | none | write the `lowlat-report/1` JSON |
| `--window N` | none | also write `<stem>-first-N` (seq < N) and `<stem>-steady` reports beside `--report` |
| `--example NAME` | `00-line-consumer` | report example |
| `--variant NAME` | `baseline` | report variant |

SIGINT/SIGTERM stop the loop cleanly and still write the report. A negative latency
aborts with exit status 2 and no report. `reordered`, the requested and granted
buffer sizes are written to the report's `notes`.

## Design

- **Blocking `recv_into` plus `socket.settimeout(0.05)`**, not `selectors` or
  `asyncio`. One socket has nothing to multiplex; an event loop adds a dispatch per
  datagram, which is pure latency. The 50 ms timeout slice is what implements the idle
  timeout and makes signals take effect (CPython retries an interrupted `recv`
  after the handler runs, per PEP 475, so the handler only sets a flag).
- A reused `bytearray` and `memoryview` for the datagram and one reused `ParcelEvent`.
- `GapTracker` (`gaps.py`) is a `slots` dataclass; `lane_for` (`handle.py`) takes the
  SSCC serial reference (digits 9-17) modulo 8.

## GIL and what is measured

The consumer is one thread under the GIL; the report's `build.gil_enabled` records
whether the interpreter was the GIL or the free-threaded build. There is nothing to
parallelise (one socket, one ordered stream). The per-datagram Python overhead (the
`recv_into` call, protobuf parse, barcode handling, `monotonic_ns`, histogram
record) is microseconds and is **inside** the measured latency: the Python column in
the book is what the language costs on this path. Compare runs only with the machine
profile attached; numbers from the 1 kHz acceptance run are not published.

## Clock

`time.monotonic_ns()` on Linux is `CLOCK_MONOTONIC`, the same clock the C++ simulator
stamps `intended_emit_ns` with, so subtraction is valid on one host or VM. Sources:

- CPython docs, `time.monotonic()` / `time.get_clock_info()`:
  <https://docs.python.org/3/library/time.html#time.get_clock_info>
- CPython v3.14.9 `Python/pytime.c`, `py_get_monotonic_clock()` uses
  `clock_gettime(CLOCK_MONOTONIC)` on Linux (line 1189):
  <https://github.com/python/cpython/blob/v3.14.9/Python/pytime.c#L1189>
- Checked on this host: `time.get_clock_info('monotonic')` reports
  `implementation='clock_gettime(CLOCK_MONOTONIC)'`, `adjustable=False`,
  `resolution=1e-09`.

## Tests

`uv run pytest` from `examples/`: the gap tracker, lane lookup, and an integration test
that runs the built simulator (`build/release/common/line-simulator/line-simulator`,
skipped with a message if not built) at 1 kHz for 2 s into the consumer on
`127.0.0.1:47102`, asserting count 2000, dropped 0; exit status 0 proves no negative
latency.
