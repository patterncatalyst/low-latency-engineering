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

The per-parcel step is a hook: each receive loop calls a handler for every new
parcel, and the handler reports it done (now or later) through a completion
object that records `done_ns − intended_emit_ns`. Example 00 uses the lane lookup
as its handler; example 01 supplies batching and slow-path handlers (C++
`consume_with`, Python `run`, Java `LineReceiver.run(ParcelHandler)`).

## Windows (`--window N`)

With `--window N` (C++, Java, Python) a consumer also reports the run in two parts: parcels
with `seq < N` as variant `<variant>-first-N`, the rest as `<variant>-steady`. They are
written beside `--report FILE` as `<stem>-first-N<ext>` and `<stem>-steady<ext>`, **in
addition to** the full `<variant>` report, which keeps its meaning (so a windowed run records
each latency twice; a run without `--window` pays nothing). The two counts sum to the full
count, and each gap is booked as `dropped` in the window of the missing parcels. The first
window carries the warm-up (JIT, page faults, cold caches); Ch5 compares it with steady state.
A handler that completes parcels later than the call that received them must pass the parcel's
`seq` to `Completion` (C++/Java `complete(seq, intended, done)`, Python `complete(intended,
done, seq)`), otherwise the parcel is attributed to whichever one the loop is handling.

## Completion on another thread

`Completion` is single-writer, not thread-safe. Exactly one thread calls `complete` at a time:
the receive thread by default, or a thread the handler hands it to (Ch7's decide thread). The
handler keeps the `Completion` from its first call, starts the thread, and in `drain` (called
on the receive thread when the loop ends) stops and joins it. The loop reads the counts and
the report reads the recorder only after `drain` returns, so the join is the happens-before
edge that publishes everything the owner wrote: no lock and no atomic on the recording path.
The receive thread must not call `complete` once ownership has moved. C++ test:
`ConsumerOwnership` in `cpp/tests/consumer_test.cpp` (`std::jthread`); Java:
`WindowAndOwnershipTest`; the Python test is a thread joined in `drain`.

## Other wire formats (Java `Decoder`)

The Java receive loop is `EventReceiver<E>` with a `Decoder<E>`: `decode(ByteBuffer)` returns
the event the handler sees and `seq(E)` feeds the gap tracker. `LineReceiver` is
`EventReceiver<ParcelEvent>` with the protobuf decoder, so existing `ParcelHandler` handlers
compile unchanged. A flat decoder returns a reused view over the datagram, so a handler for
it allocates nothing per parcel (the view reader in the tests, `FlatParcel`, is the reference;
Ch8 measures it). The wire layout is `contracts/flat/parcel-v1`; Python reads it with
`lowlat_consumer.flat`, and the C++ header `parcel_v1.hpp` is the source of truth.

## Allocation on the receive thread (Java)

`EventReceiver.runtime()` returns the report's `runtime` block: `RuntimeInfo.jvm()` plus
`alloc_bytes_per_parcel`, the receive thread's `ThreadMXBean.getThreadAllocatedBytes` difference
between the start and the end of the loop divided by the parcels received. The counter is read
twice per run, never per parcel. It counts the receive thread only (selector, channel, decode,
and handler work done on that thread), so work moved to a decide thread is not in it.
`line-consumer-java` writes it into the whole-run report. The `--window` reports carry `RuntimeInfo.jvm()` only (`EventReceiver.windowRuntime()`): the counter covers the whole run, so it is not repeated as a per-window figure.

The ready line (the first line printed once the socket is bound) is flushed
immediately in all three, so a script can wait on a redirected stdout.

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
