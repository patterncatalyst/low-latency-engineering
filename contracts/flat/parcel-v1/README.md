# parcel-v1: flat ParcelEvent

A fixed, versioned, little-endian record for one `lowlat.line.v1.ParcelEvent`.
The protobuf contract in `contracts/proto` stays the default wire of the line;
this layout is the alternative the zero-copy chapter measures against it
(`line-simulator --wire flat`). `parcel_v1.hpp` is the source of truth; this file
explains it, and the golden files pin it.

## Layout

80 bytes, always. Offsets are from the start of the datagram.

| Offset | Size | Type | Field | Notes |
|---:|---:|---|---|---|
| 0 | 2 | u16 | `schema_id` | `1` = `lowlat.line.v1.ParcelEvent` |
| 2 | 2 | u16 | `version` | `1` = this layout |
| 4 | 4 | u32 | `weight_g` | grams |
| 8 | 8 | u64 | `seq` | |
| 16 | 8 | i64 | `intended_emit_ns` | `CLOCK_MONOTONIC`, same host only |
| 24 | 8 | i64 | `actual_emit_ns` | `CLOCK_MONOTONIC`, same host only |
| 32 | 8 | u64 | `encoder_tick` | |
| 40 | 4 | u32 | `length_mm` | `Dimensions.length_mm` |
| 44 | 4 | u32 | `width_mm` | `Dimensions.width_mm` |
| 48 | 4 | u32 | `height_mm` | `Dimensions.height_mm` |
| 52 | 4 | u32 | `scan_confidence_permille` | 0 to 1000 |
| 56 | 18 | char[18] | `barcode` | SSCC-18, ASCII digits, no terminator |
| 74 | 6 | u8[6] | `reserved` | zero on write; readers ignore it |

Field meanings, units and the clock-domain rule are those of
`contracts/proto/lowlat/line/v1/parcel.proto`.

## Endianness and alignment

- Little-endian, every multi-byte integer. The C++ header refuses to compile on a
  big-endian host.
- Natural alignment inside the record: every field sits at a multiple of its own
  size, so a record at an 8-byte aligned address needs no unaligned access. The
  record is 8-byte aligned in size (80 = 10 x 8). A UDP payload is not guaranteed
  aligned; readers that cast must align the buffer, readers that copy
  (`memcpy`, `struct.unpack_from`, FFM `MemorySegment` with unaligned layouts)
  need not.
- No implicit padding: the only unnamed bytes are `reserved`, and they are named.

## Reading rules

1. The datagram is exactly 80 bytes. Any other length is malformed.
2. `schema_id` must be `1` and `version` must be `1`; otherwise the datagram is
   malformed (a reader never guesses at a layout it does not know).
3. Then read fields at the fixed offsets. There is no length prefix, tag or
   varint, so nothing is parsed and nothing is allocated.

## Evolution rules

- A change to an existing field (type, offset, size, meaning) is a new schema, not
  a new version: it gets a new `schema_id`.
- Adding a field is a new `version` of the same `schema_id`. The new layout keeps
  every v1 offset unchanged and appends after `reserved` (or takes bytes out of
  it, if that fits), so the record only grows; the new size is part of the
  version. Readers accept only versions they know; a v1 reader rejects v2.
- Never reuse a retired `schema_id` or `version`.
- Any change updates `parcel_v1.hpp` (with its `static_assert`s), this file, the
  Java and Python readers and the golden files, in one commit.

## Golden files

`golden-seed1.bin`, `golden-seed42.bin`, `golden-seed2026.bin`: eight records
each (640 bytes), concatenated. Record 0 holds the extremes (`seq` =
2^64-1, `intended_emit_ns` = -2^63, `actual_emit_ns` = 2^63-1, every u32 field
= 2^32-1); records 1 to 7 are full-range values from the splitmix64 generator
seeded with the file's seed, so every byte lane carries data and any byte-order
mistake changes a value.

`golden-seedN.json` states what each record decodes to. All 64-bit numbers are
decimal strings (a JSON number loses precision above 2^53 in many readers).

The C++ test (`line-simulator-test`) regenerates both files with
`LOWLAT_REGEN_GOLDEN=1` and otherwise reads them; the Java and Python tests read
them. All three decode the `.bin` and compare with the `.json`; the C++ and
Python tests also re-encode and compare bytes.
