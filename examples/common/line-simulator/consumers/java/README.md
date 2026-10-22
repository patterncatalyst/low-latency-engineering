# line-consumer-java

Java 25 line consumer (Maven module `line-consumer-java`, main class
`io.patterncatalyst.lowlat.line.Consumer`). Behaviour is the shared spec in
[`../README.md`](../README.md); latency goes through `measure-java`
(`LatencyRecorder.singleThreaded`).

## Build and run

```bash
mvn -B -f examples/pom.xml verify        # builds, tests, shades
scripts/profile.sh --out /tmp/profile.json
LOWLAT_PROFILE=/tmp/profile.json java -jar \
    examples/common/line-simulator/consumers/java/target/line-consumer-java.jar \
    --bind 127.0.0.1:47000 --expect 10000 --report /tmp/java-consumer.json
```

| Flag | Default | Meaning |
|---|---|---|
| `--bind HOST:PORT` | `127.0.0.1:47000` | UDP address (IPv4) |
| `--rcvbuf BYTES` | 4194304 | `SO_RCVBUF` request; the granted size is printed |
| `--expect N` | no limit | stop after N datagrams, received + dropped |
| `--idle-timeout-ms MS` | 2000 | stop after MS of silence once the first datagram arrived |
| `--report FILE` | none | write `lowlat-report/1` (needs `LOWLAT_PROFILE`); `notes` = `reordered=N; rcvbuf_requested=X; rcvbuf_granted=Y` |
| `--window N` | none | also write `<stem>-first-N` (seq < N) and `<stem>-steady` reports beside `--report` |
| `--example`, `--variant` | `00-line-consumer`, `baseline` | report labels |

SIGINT/SIGTERM stop the loop and still write the report (exit 130/143). A negative
latency aborts with exit 1 and no report. A seq at or below the highest seen is counted
as `reordered` and not recorded; a late arrival that was already counted dropped stays
dropped. The first datagram's gap from seq 0 counts as dropped.

## Design choices

- **Channel, non-blocking + `Selector`.** `DatagramChannel.receive(ByteBuffer)` into one
  reused direct buffer. `DatagramSocket.setSoTimeout` only applies to the socket API
  (which receives into `byte[]` `DatagramPacket`s), and a channel in blocking mode has no
  timeout. A `Selector` gives the idle timeout (`select(action, ms)`) and `wakeup()` for
  shutdown. The loop calls `receive` first and selects only when it returns null, so a
  busy line costs one syscall per datagram.
- **`ParcelEvent.parseFrom(ByteBuffer)`.** protobuf-java wraps a direct buffer in
  an `UnsafeDirectNioDecoder`-style `CodedInputStream` and reads in place; the explicit
  `CodedInputStream` route adds nothing but ceremony, and `parseFrom(byte[])` would force a copy
  out of the direct buffer. The message object and barcode `String` are still allocated.
- **Shutdown hook** stops the loop, joins the receive thread (the happens-before edge to the
  non-thread-safe recorder), then prints the summary and writes the report. `main` joins
  the same thread and calls `System.exit`, so normal end and signals share one path.
- Records for `Config`; `GapTracker` and `Lanes` are small package-private classes.
  Lane = the 9-digit SSCC serial reference (digits 9 to 17) modulo 8.

## JIT warm-up

This is the plain HotSpot JVM. The first few thousand parcels run in the interpreter and
C1 before C2 code arrives, and the first receive also pays class loading and
protobuf initialisation. r01's consumer does not discard a warm-up window: the cost lands in
the high percentiles and max (tens of ms in a 10 s run at 1 kHz), and the report
notes say so. Ch4 and Ch5 measure warm-up (and ways to shorten it) rather than hide it.

## `System.nanoTime()` is CLOCK_MONOTONIC on Linux

Checked against the `jdk-25-ga` tag of github.com/openjdk/jdk:

- `src/java.base/share/classes/java/lang/System.java:384`: `public static native long nanoTime();`
- `src/hotspot/share/prims/jvm.cpp:236-237`: `JVM_NanoTime` returns `os::javaTimeNanos()`
  (C1/C2 intrinsify the call, same function underneath).
- `src/hotspot/os/posix/os_posix.cpp:1482-1484`: `os::javaTimeNanos()` calls
  `clock_gettime(CLOCK_MONOTONIC, &tp)`. `os_linux.cpp` has no override of
  `javaTimeNanos` (the `#if !defined(__APPLE__) && !defined(AIX)` guard at line 1480
  selects this generic version on Linux).

So `done_ns` and the simulator's `intended_emit_ns` share one clock on the same host.

## Tests

`mvn -f examples/pom.xml verify` runs gap tracker (0,1,2,5,6 gives dropped 2; repeat gives
reordered 1), lane lookup, option parsing, and an integration test that spawns
`examples/build/release/common/line-simulator/line-simulator` at 1 kHz for 2 s into
127.0.0.1:47103 and asserts 2,000 received, 0 dropped, no negative latency. It skips with
a message when the simulator is not built.
