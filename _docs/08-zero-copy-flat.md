---
title: "Zero-copy and flat data: Panama (FFM), Valhalla value objects, and the C++ comparison"
order: 8
part: "The Managed-Runtime Question"
description: "Reading an 80-byte flat record in place through the Foreign Function & Memory API allocates under 1 B per decode against 576 B for a protobuf parse, and a flat table sweeps in 0.95-0.97 ms against 4.97-5.03 ms for an array of objects (bare-metal, untuned host, three runs)."
duration: 50 minutes
---

## Learning objectives

By the end of this chapter you can:

- Read a fixed-layout record in place with a `MemorySegment`, a `StructLayout` and `VarHandle`s, and explain the unaligned little-endian layouts.
- State what a flat wire contract must fix to be safe to read without parsing.
- Choose between an array of objects and a flat off-heap table.
- Name the C++ spellings of the same idea and the one that is undefined behaviour.
- Say what Java value classes aim at, and why this book measures JDK 25 only.

## Why this matters

The belt never waits for a slow consumer. The scan-to-divert budget is 480 ms: 1.2 m at 2.5 m/s. At 10 kHz the line holds 4,800 parcels in flight at that budget (Chapter 2, *Modelling with Little's Law and Amdahl's Law*), and each datagram is decoded first. A protobuf parse builds a message, a `Dimensions` and a `String` per datagram: garbage at the rate of the belt.

This chapter removes that allocation: a fixed 80-byte record is read where the kernel wrote it, and the in-flight table is a run of memory instead of a pointer per parcel. Chapter 5, *What the JVM costs: allocation, escape analysis, JIT warmup vs AOT*, counted 654 to 733 B allocated per parcel on its receive thread, protobuf parse included.

The code is in `examples/08-zero-copy-flat/`. The run script there builds and runs it; its `README.md` covers what it does and how to drive it.

## Diagram

{% include excalidraw.html file="08-zero-copy-decode" alt="One receive buffer, a user-space direct ByteBuffer holding one datagram at a time, feeds two decoders. protobuf-decode calls parseFrom and builds a ParcelEvent, a Dimensions and a String barcode: 576 B/op with a p50 of 157-162 ns in JMH and 591 B per parcel on the line. flat-ffm (amber) puts a reused FlatView on the same bytes, a MemorySegment with VarHandles over the 80-byte parcel-v1 record that checks schema, version and size first: less than 1 B/op, p50 16 ns, and 8.76 B per parcel on the line." caption="Figure 8.1 — A flat 80-byte record read in place allocates under 1 B per decode, against 576 B for a protobuf parse." %}

## Reading bytes in place

### What zero-copy covers

Zero-copy means the datagram is not copied into another structure before it is read. It does not mean nothing is allocated: in CPython every numeric field outside the small-int cache (−5 to 256) becomes a new `int`.

### The contract

A record can be read in place only if the reader knows where every field is. `contracts/flat/parcel-v1` fixes that:

- **Fixed size and offsets.** 80 bytes, every field at its natural alignment, no implicit padding. The six `reserved` bytes are a named field, zero on write. Nothing is scanned.
- **Self-identifying header.** `schema_id` and `version` are the first four bytes, checked before the size, so a later and larger version is reported as unsupported instead of as a bad length.
- **Explicit endianness.** Little-endian whatever the host is. The C++ header refuses to compile on a big-endian host.
- **Evolution by rule.** A changed field is a new `schema_id`. An added field is a new `version` that keeps every old offset and appends.
- **Golden bytes.** Three files (seeds 1, 42 and 2026) of eight records each, with extreme and full-range values, so a byte-order mistake changes a field.

Chapter 22, *Aeron and SBE* (Part 6), covers a production flat wire.

### The Java reader

`ParcelLayout.java` describes the record as a `StructLayout`. The value layouts are unaligned because a UDP payload is not guaranteed to start on an 8-byte boundary, and they name little-endian because the wire is little-endian on any host.

```java
    private static final ByteOrder LE = ByteOrder.LITTLE_ENDIAN;
    private static final ValueLayout.OfShort U16 = JAVA_SHORT_UNALIGNED.withOrder(LE);
    private static final ValueLayout.OfInt U32 = JAVA_INT_UNALIGNED.withOrder(LE);
    private static final ValueLayout.OfLong U64 = JAVA_LONG_UNALIGNED.withOrder(LE);

    /** Field order and names as in parcel_v1.hpp. */
    static final StructLayout LAYOUT = MemoryLayout.structLayout(
            U16.withName("schema_id"),
            U16.withName("version"),
            U32.withName("weight_g"),
            U64.withName("seq"),
            U64.withName("intended_emit_ns"),
            U64.withName("actual_emit_ns"),
            U64.withName("encoder_tick"),
            U32.withName("length_mm"),
            U32.withName("width_mm"),
            U32.withName("height_mm"),
            U32.withName("scan_confidence_permille"),
            MemoryLayout.sequenceLayout(BARCODE_LEN, JAVA_BYTE).withName("barcode"),
            MemoryLayout.paddingLayout(6).withName("reserved"));
```

Offsets are derived from the layout, and each field gets a `VarHandle` from `LAYOUT.varHandle(...)`, so a mismatch cannot hide in a hand-typed constant. `ParcelLayoutTest` checks them against the header.

`FlatDecoder.decode` is the Java tab. C++ shows `decode_memcpy` and `view_start_lifetime_as` (`cpp/include/lowlat/flat/decode.hpp`). The Python tab shows `RECORD` (the consumer's `flat.py`) with `unpack_decoder` (`flat-py/src/lowlat_flat/decode.py`).

{% include codetabs.html langs="Java|C++|Python" %}

```java
    @Override
    public FlatView decode(ByteBuffer datagram) throws MalformedDatagramException {
        if (datagram.remaining() < HEADER_BYTES) {
            throw new MalformedDatagramException(
                    "parcel-v1 header is " + HEADER_BYTES + " bytes, got " + datagram.remaining());
        }
        // The receiver reuses one buffer, so the wrap (one allocation) happens once, not per parcel.
        if (datagram != wrapped) {
            // A segment over the whole buffer: ofBuffer would start at the current position, and
            // the view addresses the record by absolute offset.
            segment = MemorySegment.ofBuffer(datagram.duplicate().clear());
            wrapped = datagram;
        }
        long base = datagram.position();
        view.wrap(segment, base);
        if (view.schemaId() != ParcelLayout.SCHEMA_ID) {
            throw new MalformedDatagramException("not parcel-v1: schema_id " + view.schemaId());
        }
        if (view.version() != ParcelLayout.VERSION) {
            throw new MalformedDatagramException("unsupported parcel-v1 version " + view.version());
        }
        if (datagram.remaining() != ParcelLayout.SIZE) {
            throw new MalformedDatagramException(
                    "parcel-v1 is " + ParcelLayout.SIZE + " bytes, got " + datagram.remaining());
        }
        return view;
    }
```

```cpp
[[nodiscard]] inline std::expected<p1::Parcel, p1::DecodeError> decode_memcpy(std::span<const std::byte> bytes) noexcept {
  return p1::decode(bytes);
}

// ...

[[nodiscard]] inline std::expected<const p1::Parcel*, ViewError> view_start_lifetime_as(
    std::span<const std::byte> bytes) noexcept {
  if (const auto ok = p1::check_header(bytes); !ok) return std::unexpected{to_view_error(ok.error())};
  if (std::bit_cast<std::uintptr_t>(bytes.data()) % alignof(p1::Parcel) != 0) {
    return std::unexpected{ViewError::misaligned};
  }
  return std::start_lifetime_as<p1::Parcel>(bytes.data());
}
```

```python
RECORD: Final = struct.Struct("<HHIQqqQIIII18s6x")

# ...

def unpack_decoder(wire: bytes) -> Decode:
    """Decode record ``i`` with ``unpack_from`` over one ``memoryview`` of ``wire``."""
    view = memoryview(wire)
    unpack_from = flat.RECORD.unpack_from

    def decode(i: int) -> tuple[Any, ...]:
        return unpack_from(view, i * flat.SIZE)

    return decode
```

`MemorySegment.ofBuffer` wraps the receive loop's one direct buffer, and the `datagram != wrapped` test makes that happen once, not per parcel. `view.wrap(segment, base)` re-points the single `FlatView` at the datagram the kernel just wrote. The three checks follow the contract's order: schema, version, then size. The returned view is valid only until the next `decode`, and one decoder serves one receive thread.

In C++ `decode_memcpy` copies 80 bytes into a trivially copyable `Parcel`; it is correct at any alignment. `view_start_lifetime_as` copies nothing: `std::start_lifetime_as` (C++23, compiled with the pinned Clang 22 and GCC 16) begins the lifetime of a `Parcel` in the bytes already there and returns a pointer. It checks the header with `p1::check_header` (errors mapped by `to_view_error`) and refuses a misaligned buffer. A `reinterpret_cast<const Parcel*>(buffer)` read is not measured: no `Parcel` object exists in that storage, so the read is undefined behaviour.

In Python `Struct.unpack_from` over a `memoryview` does not copy the datagram but returns a tuple of new objects: the measured lane makes 6.7 new `int` objects per parcel, and the barcode is copied into a new `bytes`. There is no view type to re-point.

## The in-flight table

The tracker sweeps its table at every encoder tick, summing the weight of the in-flight parcels whose `encoder_tick` has reached the diverter's, about 2 % of 1,000,000 slots, stored in shuffled order.

{% include excalidraw.html file="08-flat-vs-pointer-layout" alt="An object-table of 1,000,000 references points at ParcelState objects scattered on the heap, each with a header and fields, and a sweep of the table takes a p50 of 4.97-5.03 ms. A flat-table keeps 24-byte slots side by side in one MemorySegment in an Arena, and the same sweep takes 0.95-0.97 ms. A dashed ghost box, ParcelState as a value class (JEP 401, JDK 28 early access only), points at the object-table to show the flat layout it aims at on the heap; on common hardware JEP 401 flattens a mutable field or array element only up to 64 bits, null flag included, so a 22-byte ParcelState needs later enhancements. It is not measured, and the book pins JDK 25 LTS." caption="Figure 8.2 — Sweeping one run of memory takes 0.95-0.97 ms, against 4.97-5.03 ms for a pointer per parcel. Value classes aim at that layout but are early access only, so the book measures the flat table." %}

The object table is a `ParcelState[]`, a heap object behind each reference; the flat table is a `MemorySegment` of 24-byte structs from an `Arena`. The Java tab joins `FlatTable.java` and `ObjectTable.sweepDue`; the C++ tab shows both `sweep_due` overloads from `cpp/include/lowlat/flat/table.hpp`. Python has no table lane; the decode lane already shows its object model.

{% include codetabs.html langs="Java|C++" %}

```java
    public FlatTable(int size) {
        this.arena = Arena.ofConfined();
        this.slots = arena.allocate(MemoryLayout.sequenceLayout(size, STATE)); // zeroed
        this.size = size;
    }

// ...

    @Override
    public long sweepDue(long dueTick) {
        long weight = 0;
        for (long at = 0, end = size * SLOT_BYTES; at < end; at += SLOT_BYTES) {
            if ((long) ENCODER_TICK.get(slots, at) <= dueTick && (byte) STATE_H.get(slots, at) == IN_FLIGHT) {
                weight += (int) WEIGHT_G.get(slots, at);
            }
        }
        return weight;
    }

// ...

    @Override
    public long sweepDue(long dueTick) {
        long weight = 0;
        for (ParcelState parcel : slots) {
            if (parcel.encoderTick() <= dueTick && parcel.state() == IN_FLIGHT) {
                weight += parcel.weightG();
            }
        }
        return weight;
    }
```

```cpp
[[nodiscard]] inline std::uint64_t sweep_due(std::span<const ParcelState> table, std::uint64_t due_tick) noexcept {
  std::uint64_t weight = 0;
  for (const ParcelState& p : table) {
    if (p.encoder_tick <= due_tick && p.state == kInFlight) weight += p.weight_g;
  }
  return weight;
}

[[nodiscard]] inline std::uint64_t sweep_due(std::span<const std::unique_ptr<ParcelState>> table,
                                             std::uint64_t due_tick) noexcept {
  std::uint64_t weight = 0;
  for (const auto& p : table) {
    if (p->encoder_tick <= due_tick && p->state == kInFlight) weight += p->weight_g;
  }
  return weight;
}
```

`Arena.ofConfined()` gives the table an explicit lifetime: `close()` releases the memory when the code chooses, with no collector involved, and only the creating thread may touch the segment. The `VarHandle`s are `static final` so the JIT treats them as constants.

The sweep reads `encoder_tick` of every slot, and `state` and `weight_g` only for the about 2 % that are due; in the object layout each read first follows a reference. Why adjacent slots are cheaper than pointers is the subject of [Chapter 9, *Eliminating work: allocation, cache locality, false sharing*]({{ '/docs/09-eliminating-work/' | relative_url }}) (Part 3); this chapter only measures the difference.

C++ gets the flat layout by default: a `std::vector<ParcelState>` is contiguous, and the pointer layout is the one the code has to ask for with `std::vector<std::unique_ptr<ParcelState>>`. The two are a contrast of layouts, not of languages.

### Where the bytes go

`ParcelState` holds 8 + 8 + 4 + 1 + 1 bytes of fields behind a 12-byte header, padded to 40 B; JOL confirms it. With an 8-byte header it is 32 B. JOL measures 100,000 parcels (`Footprint.PARCELS`); the sweep uses 1,000,000 (`TableBenchmark.PARCELS`). The object table's 4,400,016 B is 100,000 × 40 B plus a 400,016 B reference array (3,600,016 B is 100,000 × 32 B plus the same). JEP 519 makes `-XX:+UseCompactObjectHeaders` a product flag in JDK 25; JEP 534 makes it the default in JDK 27. The flat slot has no header and is 24 B either way: compact headers shrink the object, not the flat table.

### Value classes: status at 2026-10-22

> Project Valhalla would give Java value classes: objects without identity that the JVM may flatten into arrays and fields. JEP 401, *Value Objects (Preview)*, is integrated into the JDK 28 mainline and is a preview feature, so it needs `--enable-preview` even in a GA release. JDK 28 is early access only, with no GA date; the six-month cadence points near March 2027. The Valhalla early-access build is `27-jep401ea3+1-1`, under Oracle's early-access terms. This book pins Temurin 25.0.5 LTS; JDK 27 is GA but not LTS. No build, script or number uses a prerelease. Revisit at JDK 28 GA.

Value classes aim at a flat layout on the heap without a hand-written one. That is the dashed ghost box in Figure 8.2; it is not measured. On common hardware JEP 401 flattens a mutable field or array element only up to 64 bits, null flag included, so a 22-byte `ParcelState` needs later null-restricted or non-atomic enhancements. A `FlatView` over a receive buffer would stay a view of bytes someone else owns, and the off-heap table would keep its explicit lifetime. `VALHALLA.md` carries the same status.

## Calling C: the clock downcall

`ClockGettime.java` binds `clock_gettime(CLOCK_MONOTONIC)` through `Linker` with a hand-written `FunctionDescriptor`, because `jextract` has early-access builds only. The standard linkage is compared with `Linker.Option.critical(false)`, a leaf call with no thread-state change.

```java
    // static final, so the JIT treats the handles as constants and inlines the native call.
    private static final MethodHandle STANDARD = link();
    private static final MethodHandle CRITICAL = link(Linker.Option.critical(false));

// ...

    @SuppressWarnings("restricted")
    private static MethodHandle link(Linker.Option... options) {
        Linker linker = Linker.nativeLinker();
        MemorySegment symbol = linker.defaultLookup().find("clock_gettime")
                .orElseThrow(() -> new IllegalStateException("clock_gettime not found in the default lookup"));
        return linker.downcallHandle(symbol, DESCRIPTOR, options);
    }

    /** {@code CLOCK_MONOTONIC} in nanoseconds through the standard downcall. */
    public long standard() {
        return read(STANDARD);
    }

    /** {@code CLOCK_MONOTONIC} in nanoseconds through the critical downcall. */
    public long critical() {
        return read(CRITICAL);
    }
```

`downcallHandle` is a restricted method, so the scripts and tests run with `--enable-native-access=ALL-UNNAMED`. The critical option is the caller's promise that the callee is quick, never blocks and never calls back into Java. C++ calls the function directly and has no counterpart.

## Measure

Run from the repository root:

```bash
examples/08-zero-copy-flat/verify.sh
```

`ALLOW_BUSY=1` measures while the host is loaded; numbers are then noisy. The line runs use the simulator at 10 kHz for 10 s (100,000 parcels), once per wire format, to UDP 47281 (`protobuf-decode`) and 47282 (`flat-ffm`). Both use the common `EventReceiver`; only the decoder differs. The only JVM flag is `--enable-native-access=ALL-UNNAMED`, so collector and heap are defaults. JMH decodes the same parcels from one direct buffer.

Profile for every number below: bare-metal host, an 8-core, 16-thread Intel laptop CPU (SMT on, `intel_pstate`), Fedora 44 kernel 7.2 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`, untuned, clocksource `tsc`, Temurin 25.0.5+8. Ranges span the committed runs `r02-run1` to `r02-run3`.

**Golden bytes (criterion 1).** The C++, Java and Python readers decode the golden files of seeds 1, 42 and 2026 (eight records each) to the committed JSON, in all three runs.

**Decode, JMH (criterion 2).** In one JMH run, `flat-ffm` allocates under 1 B/op (0.0012 to 0.0014) with a p50 of 16 ns. `protobuf-decode` allocates 576 B/op with a p50 of 157 to 162 ns. The criterion asks for a p50 ratio of at least 3x; the measured ratio is 9.8x to 10.1x. The allocation counter `gc.alloc.rate.norm` is bytes per operation, not a latency.

**Line allocation (criterion 3).** The receive thread's allocation per parcel, which covers the channel, the decode and the handler, is 8.76 B for `flat-ffm` against 591 B for `protobuf-decode`. The bound is 5 %; the measured share is 1.5 %. The floor is not zero: the first decode loads classes and links the `VarHandle`s.

**Table sweep (criterion 4).** In one JMH run, the `flat-table` sweep of 1,000,000 parcels has a p50 of 0.95 to 0.97 ms and the `object-table` sweep 4.97 to 5.03 ms, about 5x. The bound is one half.

**Clock downcall (criterion 5).** Both linkages agree with `System.nanoTime()`: the largest skew outside the `nanoTime()` bracket is 0 ns for standard and for critical in all three runs. Observed only: the per-call p50 is 12 ns for `nanoTime()`, 18 to 20 ns for the standard downcall and 17 ns for the critical one.

**Reports (criterion 6).** Every report passes `lowlat-report check`, every Java report carries `build.flags`, and both line runs count 100,000 with 0 dropped.

**Observed only.** The object table of 100,000 parcels is 4,400,016 B, or 3,600,016 B with compact headers; the flat table is 2,400,000 B either way; the protobuf `ParcelEvent` is 80 B either way. In C++, the p50 over the Google Benchmark repetitions per 1,024 records is 9,055 to 9,247 ns for `decode-memcpy`, 8,535 to 8,663 ns for `decode-bit-cast` and 7,423 to 7,543 ns for `decode-start-lifetime-as`. The C++ sweep is 0.91 to 0.92 ms for `flat-table` and 4.78 to 4.84 ms for `pointer-table`, also about 5x. Each ratio is within its own language. In Python, `unpack_from` and `ParseFromString` both allocate 8.7 blocks and 6.7 new `int` objects per parcel; the per-call p50 is 336 to 349 ns against 997 to 1,050 ns, each sample including two `perf_counter_ns` reads.

### What the line does not show

The line runs' end-to-end latency is not a criterion, and it does not show the decode saving. The p50 is 57.0 to 57.6 us and the p99 is 87 to 94 us for both variants, and the p99.9 is 4.9 to 11.1 ms, measured on unwarmed JVMs on the default heap (Chapter 5 measures that cost). It is lower for `flat-ffm` in each run (4.9 to 7.7 ms against 9.3 to 11.1 ms), a gap far larger than the decode's saving, and is given no cause. JMH and the counters resolve the saving, 141 to 146 ns and 582 to 583 B per parcel; an end-to-end percentile at this load does not. The latency is `done - intended_emit`, as in Chapter 3, *Measuring correctly: clocks, percentiles and coordinated omission*. All of it fits the budget.

## Cross-check

Two independent allocation counters agree: JMH `-prof gc` (576 B/op for protobuf, 0.0012 to 0.0014 B/op for flat) and `ThreadMXBean` on the line's receive thread (591 B and 8.76 B per parcel). The golden bytes cross three readers, JOL matches the record arithmetic, and the downcall is checked against `System.nanoTime()`. Chapter 5's 654 to 733 B per parcel is the cost this chapter removes, but Chapter 5 ran at 1 kHz with its own handler, so the numbers are not subtracted.

## What you learned

- A flat record is safe to read in place only when its contract fixes size, offsets, header, endianness and evolution, and golden bytes pin it across readers.
- A reused view over the receive buffer allocates under 1 B/op in JMH and 8.76 B per parcel on the line, against 576 B/op and 591 B for a protobuf parse.
- End-to-end percentiles on the line do not show a saving of 141 to 146 ns per parcel. Counters and JMH do.
- A flat off-heap table in an `Arena` swept in 0.95 to 0.97 ms against 4.97 to 5.03 ms for an array of objects, at the cost of an explicit lifetime.
- C++ spells the idea `std::start_lifetime_as`; a `reinterpret_cast` read is undefined behaviour. CPython copies no bytes but allocates per field.
- Value classes (JEP 401) are a JDK 28 early-access preview. The book measures JDK 25 and revisits at JDK 28 GA.

The next chapter, [*Eliminating work: allocation, cache locality, false sharing*]({{ '/docs/09-eliminating-work/' | relative_url }}) (Part 3), takes data-structure-level work elimination across all three languages.

## For deeper coverage

- Enberg, *Latency* (Manning), as further reading.
- Chapter 6, *GC for tails: Generational ZGC and Shenandoah* (Part 2), for what the collector does with the allocation removed here.
- Chapter 4, *Benchmark harnesses: Google Benchmark, pyperf and JMH* (Part 1), for JMH SampleTime, forks and `Blackhole`.
- `contracts/flat/parcel-v1/README.md`, `examples/08-zero-copy-flat/VALHALLA.md` and `examples/common/MEASUREMENT.md`.
- JEP 519 (compact object headers, product in JDK 25), JEP 534 (default in JDK 27) and JEP 401 (preview, JDK 28 early access only).

---

*Verification status: <span class="status status--verified">verified (behavioural)</span>. `verify.sh` asserts that the C++, Java and Python readers decode the golden files identically; that `flat-ffm` allocates at most 1 B/op and `protobuf-decode` at least 100 B/op in JMH with a p50 ratio of at least 3x; that the receive thread's allocation per parcel on the line is at most 5 % of `protobuf-decode`'s; that the `flat-table` p50 is at most half the `object-table` p50; that both `clock_gettime` downcalls agree with `System.nanoTime()` within 1 ms; and that every report passes `lowlat-report check` and every Java report carries `build.flags`, with 100,000 parcels counted and none dropped. Observed only, not asserted: compact object headers (JOL), the downcall per-call cost, the C++ decode variants and tables, and the Python lane. It held on `r02-run1`, `r02-run2` and `r02-run3` on the bare-metal host described above.*
