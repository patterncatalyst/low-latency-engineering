# 08-zero-copy-flat

Chapter 8: decode without allocating. Ch5 measured what the JVM spends per parcel, and the protobuf
decode is the largest share of it: a message object, a nested `Dimensions`, a `String` for the barcode.
A fixed, versioned flat record read in place through the Foreign Function & Memory API (FFM) removes that
allocation, and the same idea applied to the in-flight parcel table removes the pointer chase of an array
of objects. Java leads; C++ and Python are inline contrasts.

## Technique

- **`MemorySegment.ofBuffer` over the receive buffer.** The receive loop already owns one direct
  `ByteBuffer`. `FlatDecoder` wraps it once and re-points one `FlatView` at each datagram. No parse, no
  copy, no object per parcel.
- **`StructLayout` plus `VarHandle`s** (`ParcelLayout`). The layout repeats the field order and widths of
  `contracts/flat/parcel-v1/parcel_v1.hpp`; every offset is derived from the layout, and
  `ParcelLayoutTest` compares the derived offsets with the header's `static_assert(offsetof(...))` lines
  and with the table in the contract README. Value layouts are unaligned and little-endian: a UDP
  payload is not guaranteed aligned, and the wire is little-endian whatever the host is.
- **`Arena`.** `FlatTable` allocates its slots from a confined arena, so the table's lifetime is explicit
  and its memory is outside the heap and the collector.
- **`Linker` downcall.** `ClockGettime` binds `clock_gettime(CLOCK_MONOTONIC)` with a hand-written
  `FunctionDescriptor`: `jextract` has early-access builds only, and a descriptor for one function is two
  lines. The standard linkage is compared with `Linker.Option.critical(false)`, a leaf call with no
  thread-state transition. Downcalls are restricted methods: run with `--enable-native-access=ALL-UNNAMED`
  (the scripts and surefire do).
- **Compact object headers.** `-XX:+UseCompactObjectHeaders` (a product flag in JDK 25) shrinks every
  header from 12 to 8 bytes. JOL shows the effect on the object table; it does nothing to the flat table.

Valhalla is not used: see [`VALHALLA.md`](VALHALLA.md).

## Workload

The line simulator at 10 kHz for 10 s (100,000 parcels), once per wire format. `line-simulator --wire flat`
emits the 80-byte `parcel-v1` record, the default wire is protobuf, and the parcels are the same for a
seed. The Java consumer is the common receive loop (`EventReceiver`) with the decoder as the only
difference; its handler does the Ch0 work (lane from the barcode) and completes the parcel at once, so the
latency is the same measurement as Ch0 to Ch3. The JMH benchmarks decode the same parcels from the same
kind of memory (one direct buffer whose position and limit select a datagram).

The table benchmark sweeps 1,000,000 in-flight parcels the way the tracker does at every encoder tick:
total weight of the in-flight parcels whose `encoder_tick` has reached the diverter's, about 2 percent of
the slots. Parcels arrive in order and sit at a shuffled slot, as a hash-addressed table fills, so slot
order is not allocation order.

## Variants

| Language | Variant | What it is |
|---|---|---|
| Java line | `protobuf-decode` | `Decoder.protobuf()`: a fresh `ParcelEvent` per datagram |
| Java line | `flat-ffm` | `FlatDecoder`: a reused `FlatView` over the receive buffer |
| Java JMH | `protobuf-decode`, `flat-ffm` | decode plus the fields the line reads; time and bytes per parcel |
| Java JMH | `object-table`, `flat-table` | sweep of 1,000,000 parcels: `ParcelState[]` against a `MemorySegment` of 24-byte structs |
| Java JMH | `nano-time`, `downcall-standard`, `downcall-critical` | one clock read three ways (observed) |
| Java | `compact-headers` | JOL footprint with `-XX:+UseCompactObjectHeaders` (observed) |
| C++ | `decode-memcpy`, `decode-bit-cast`, `decode-start-lifetime-as` | decode from `std::span<const std::byte>` (observed) |
| C++ | `flat-table`, `pointer-table` | `std::vector<ParcelState>` against `std::vector<std::unique_ptr<ParcelState>>` (observed) |
| Python | `unpack-from`, `parse-from-string` | `struct.Struct.unpack_from` over a `memoryview` against `ParseFromString` (observed) |

### C++: three decodes, and the one that is not shown

`decode-memcpy` is the contract's own `decode()`. `decode-bit-cast` copies into a `std::array` and
`std::bit_cast`s it. `decode-start-lifetime-as` begins the lifetime of a `Parcel` in the bytes already
there (`std::start_lifetime_as`, C++23; Clang 22 and GCC 16 compile it) and returns a pointer, so nothing
is copied; it requires the buffer to be aligned for `Parcel`, and the function refuses a misaligned one.

The fourth way, `reinterpret_cast<const Parcel*>(buffer)` and a read through it, is not a variant. No
`Parcel` object exists in that storage, so the read has undefined behaviour: it violates the object-lifetime
and strict-aliasing rules, and an unaligned buffer adds an alignment violation. It usually appears to work,
which is the hazard: an optimizer may assume that no `Parcel` is read from storage written as bytes and
reorder or drop the access. A number measured on such code says what one compiler did with it, not what the
code costs, so only variants whose meaning the language defines are measured. `std::start_lifetime_as` is the
sanctioned spelling of "these bytes already are a `Parcel`".

### Python: no view, so no zero allocation

`unpack_from` over a `memoryview` does not copy the datagram, but it returns a tuple, and every numeric
field larger than 256 is a new `int` object. `ParseFromString` reads fields lazily from a message that lives in
protobuf's own arena, and each field read also creates an `int`. The lane reports blocks and new int
objects per parcel for both paths; they are the same. In CPython "zero-copy" means no copy of the
bytes, not no allocation, and that divergence from the JVM and C++ is the point of the lane.

## The contract: why `parcel-v1` looks like this

`contracts/flat/parcel-v1` (the C++ header is the source of truth; the README beside it is the table; the
golden files pin the bytes) is the minimum a flat wire needs to be safe to read in place:

- **Fixed size, fixed offsets.** 80 bytes, every field at its natural alignment, no implicit padding (the
  six reserved bytes are a named field that is zero on write). A reader jumps to an offset; there is nothing to
  scan, so nothing to allocate.
- **Self-identifying header.** `schema_id` and `version` are the first four bytes. A reader checks them
  before it checks the size, so a later and larger version is reported as unsupported, not as a bad length.
  A reader accepts only versions it knows.
- **Explicit endianness.** Little-endian on the wire; the C++ header refuses to compile on a big-endian
  host and every Java value layout names its byte order.
- **Evolution by rule.** A changed field is a new `schema_id`; an added field is a new `version` that keeps
  every old offset and appends. Retired ids are never reused.
- **Golden bytes.** Three seeds, eight records each, with extreme and full-range values so a byte-order or
  signedness mistake changes a field. C++, Java and Python decode the same files.

This is the minimum, hand-written and small enough to read in one table. A production flat wire adds a
framing header, variable-length fields, repeating groups and generated codecs; that is Simple Binary Encoding
(SBE), the schema-driven format Aeron and Artio use, and it is the subject of Ch22. `parcel-v1` is the same
set of ideas without the machinery, so the layout and the cost of reading it stay visible.

## Layout of the example

| Path | Contents |
|---|---|
| `java/` | Maven module `zero-copy-flat-java` (`benchmarks.jar`: JMH main class; tools via `-cp`) |
| `cpp/` | `flat-bench`, `flat-dump`, `zero-copy-flat-test`; headers `decode.hpp`, `table.hpp` |
| `flat-py/` | Python package `lowlat_flat`, console script `flat-py`, uv workspace member `lowlat-flat` |
| `VALHALLA.md` | status of value classes and why there is no code for them |
| `verify.sh` | runs everything and asserts the criteria |

Java classes (package `io.patterncatalyst.lowlat.flat`): `ParcelLayout`, `FlatView`, `FlatDecoder`,
`FlatRecord` (writer for tests and benchmarks), `SampleWire`, `ParcelState`, `ObjectTable`, `FlatTable`,
`TableData`, `ClockGettime`, the three `*Benchmark` classes, and the tools `LineRun`, `Dump`,
`ClockCheck`, `Footprint` behind `Main`.

`FlatDecoder` implements the consumer kit's `Decoder<FlatView>` seam, so the kit's receive loop, gap tracker
and recorder are unchanged. Its decode logic follows the reference reader in the kit's tests
(`FlatParcel`), promoted into this example because Ch8 measures it.

## Run

```bash
examples/08-zero-copy-flat/verify.sh
```

Environment (from `examples/_lib/lib.sh`): `ALLOW_BUSY=1` to measure while a lab VM runs or the host is
loaded (numbers are noisy), `SKIP_BUILD=1`, `RESULTS_DIR`, `LOWLAT_BUILD`. A full run takes several
minutes; JMH waits for `/tmp/jmh.lock` if another JMH run holds it.

By hand:

```bash
JAR=examples/08-zero-copy-flat/java/target/benchmarks.jar
java --enable-native-access=ALL-UNNAMED -jar "$JAR" DecodeBenchmark -prof gc        # one benchmark class
java --enable-native-access=ALL-UNNAMED -cp "$JAR" io.patterncatalyst.lowlat.flat.Main clock-check
java --enable-native-access=ALL-UNNAMED -cp "$JAR" io.patterncatalyst.lowlat.flat.Main consume \
    --variant flat-ffm --bind 127.0.0.1:47282 --expect 100000 --report /tmp/flat.json &
examples/build/release/common/line-simulator/line-simulator --rate 10000 --duration 10 \
    --dest 127.0.0.1:47282 --wire flat
```

`Main consume` takes the common consumer flags (`--bind`, `--rcvbuf`, `--expect`, `--idle-timeout-ms`,
`--report`, `--window`, `--example`) plus `--variant protobuf-decode|flat-ffm`; the default bind is
`127.0.0.1:47280`. `verify.sh` uses UDP 47281 (`protobuf-decode`) and 47282 (`flat-ffm`).

Reports land in `results/latest/`: `java-<variant>.json` for the line runs, `jmh/` for the JMH benchmarks,
`cpp/` and `python/` for the contrast lanes, plus the raw `jmh.json`, `cpp/gbench.json`, `clock-check.json`,
the two `footprint-*.json` and the machine profile. View them with:

```bash
uv run --project examples lowlat-report show examples/08-zero-copy-flat/results/latest/java-*.json
```

## Expected effect and criteria

`verify.sh` evaluates every criterion, prints a check mark or a cross for each, and exits non-zero if any
failed:

1. **Golden bytes.** The C++ header, the Java FFM reader and the Python reader decode
   `golden-seed{1,42,2026}.bin` to the same fields, equal to the committed JSON.
2. **JMH decode.** `flat-ffm` allocates at most 1 B/op and `protobuf-decode` at least 100 B/op;
   the `protobuf-decode` p50 is at least 3 times the `flat-ffm` p50. Same JMH run.
3. **Line.** At 10 kHz for 10 s, the receive thread's allocated bytes per parcel (channel, decode and
   handler; `runtime.alloc_bytes_per_parcel`) for `flat-ffm` are at most 5 % of `protobuf-decode`'s. The
   floor is not zero: the first decode links the `VarHandle`s and loads classes on the receive thread, a one-time
   cost spread over the parcels, so the percentage falls as the run gets longer.
4. **Table sweep.** The `flat-table` p50 is at most half the `object-table` p50. Same JMH run.
5. **Downcall.** `clock_gettime(CLOCK_MONOTONIC)` through FFM, standard and critical, agrees with
   `System.nanoTime()` within 1 ms. The check reads `nanoTime()`, the downcall, `nanoTime()` and
   measures how far outside that bracket the downcall value falls (0 when `nanoTime()` also reads
   CLOCK_MONOTONIC, which it does on Linux; see the consumer README). The cost of `critical` against
   `standard` is observed, not asserted.
6. **Reports.** Every report passes `lowlat-report check`; the line runs have `count` = 100,000 and
   `dropped` = 0; every Java report has `build.flags`.

These are mechanism counters first (bytes per operation, bytes per parcel) and ratios between variants run
back to back in one `verify.sh`, so they do not depend on the machine's absolute speed.

## Observation surfaces

| Surface | What it shows |
|---|---|
| JMH `-prof gc`, `gc.alloc.rate.norm` | bytes allocated per decoded parcel (a counter, not a time) |
| `runtime.alloc_bytes_per_parcel` in the line reports | `ThreadMXBean.getThreadAllocatedBytes` of the receive thread, read twice per run |
| JMH SampleTime percentiles | time per decode, per sweep, per clock read (loaded into HdrHistogram by `lowlat-report from-jmh`) |
| JOL (`Main footprint`) | instance sizes and graph size with and without compact object headers |
| `Main clock-check` | skew of each downcall outside the `System.nanoTime()` bracket |
| Google Benchmark | the C++ decode variants (per 1024 records) and sweeps |
| `flat-py decode` | per-call percentiles and, per parcel, blocks and new `int` objects allocated |

## Licences

JMH and JOL: GPL-2.0 with Classpath Exception. protobuf (Java, Python and C++): BSD-3-Clause. Jackson 3
(Apache-2.0), HdrHistogram (BSD-2-Clause), Google Benchmark (Apache-2.0), GoogleTest (BSD-3-Clause),
nlohmann/json (MIT), pytest (MIT). Versions are pinned in `versions.env`.

## Verification status

Behavioural. `verify.sh` asserts the six criteria above, and all of them held on the quiet-host
runs `r02-run1..3` (bare-metal host, governor `powersave`, tuned `balanced`, clocksource `tsc`,
kernel 7.2, Temurin 25.0.5+8, VM down). Ranges over the three runs.

| Quantity | Range |
|---|---|
| Golden bytes: C++, Java and Python readers, 3 seeds x 8 records | agree with the committed JSON in all three runs |
| JMH `flat-ffm` / `protobuf-decode` allocation | 0.0012 to 0.0014 B/op / 576 B/op |
| JMH decode p50, `flat-ffm` / `protobuf-decode` | 16 ns / 157 to 162 ns; ratio 9.8x to 10.1x (bound 3x) |
| Line, receive-thread allocation per parcel, `flat-ffm` / `protobuf-decode` | 8.76 B / 591 B; share 1.5 % (bound 5 %) |
| Table sweep of 1,000,000 parcels, p50, `flat-table` / `object-table` | 0.95 to 0.97 ms / 4.97 to 5.03 ms, about 5x (bound one half) |
| Downcalls against `System.nanoTime()` | largest skew outside the bracket 0 ns, standard and critical, in all three runs |
| Line runs | 100,000 parcels counted, none dropped; 16 reports pass `lowlat-report check`; every Java report carries `build.flags` |
| Observed: per-call p50, `nanoTime()` / standard / critical downcall | 12 ns / 18 to 20 ns / 17 ns |
| Observed: footprint of 100,000 parcels (JOL) | object table 4,400,016 B (3,600,016 B with compact headers), flat table 2,400,000 B, protobuf `ParcelEvent` 80 B |
| Observed: C++ decode p50 per 1,024 records, `memcpy` / `bit_cast` / `start_lifetime_as` | 9,055 to 9,247 / 8,535 to 8,663 / 7,423 to 7,543 ns |
| Observed: C++ sweep p50, `flat-table` / `pointer-table` | 0.91 to 0.92 ms / 4.78 to 4.84 ms |
| Observed: Python `unpack_from` / `ParseFromString` | 8.7 blocks and 6.7 new `int` objects per parcel for both; per-call p50 336 to 349 ns / 997 to 1,050 ns |
| Observed: line end-to-end latency, both variants | p50 57.0 to 57.6 us, p99 87 to 94 us, p99.9 4.9 to 11.1 ms |

The line's end-to-end latency does not show the decode saving. The p99.9 of 4.9 to 11.1 ms
was measured on unwarmed JVMs on the default heap (Ch5 measures that cost). It is lower for `flat-ffm` in each
run (4.9 to 7.7 ms against 9.3 to 11.1 ms), a gap far larger than the decode's saving, and this example
attributes no cause to it. JMH and the allocation counters resolve the saving, 141 to 146 ns and 582 to
583 B per parcel; an end-to-end percentile at this load does not.
