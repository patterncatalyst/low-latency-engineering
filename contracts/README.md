# Contracts

Three contracts shared by every example in the book: the protobuf wire format between the
parcel line simulator and its consumers, the flat fixed-layout binary form of the same
parcel (`flat/parcel-v1`), and the measurement report every run produces.

| Path | Purpose |
|---|---|
| `proto/lowlat/line/v1/parcel.proto` | `ParcelEvent`: one per UDP datagram from the simulator (sense). |
| `proto/lowlat/line/v1/divert.proto` | `DivertCommand` and `Lane`: the decision sent to the diverter (act). |
| `flat/parcel-v1/parcel_v1.hpp` | The flat 80-byte little-endian `ParcelEvent` record: layout, `encode` and `decode` (header checked before size). |
| `flat/parcel-v1/README.md` | Field offsets, reading rules and evolution rules of the flat record. |
| `flat/parcel-v1/golden-seed{1,42,2026}.bin` and `.json` | Golden records and their decoded values; every language decodes them. |
| `measurement/latency-report.schema.json` | JSON Schema 2020-12 for the one-per-run report (`lowlat-report/1`). |
| `measurement/examples/valid.json` | A complete valid report with a real `scripts/profile.sh` capture and a real HdrHistogram string. |
| `measurement/examples/invalid-mean.json` | The same report with a `mean` in `percentiles`; the schema must reject it. |
| `measurement/examples/valid-runtime.json` | The same report with the optional `runtime` block (GC, `alloc_bytes_per_parcel`, JIT, AOT, context switches). |
| `measurement/examples/invalid-runtime-mean.json` | A `runtime` block with `gc.pause_mean_ns`; the schema and `lowlat-report check` must reject it. |
| `measurement/examples/invalid-runtime-avg.json` | A `runtime` block with `gc.pause_avg_ns`; rejected like a mean. |
| `measurement/examples/invalid-runtime-camel.json` | A `runtime.jit` window with `meanCompileNs`; rejected (camelCase). |
| `proto/buf.yaml` | buf lint (STANDARD) and breaking-change (FILE) rules. |

## Design decisions

**Unit suffixes.** Every quantity carries its unit in the name: `_ns`, `_mm`,
`_g`, `_mps`, `_permille`. A reader never has to look up whether a weight is in
grams or ounces, and a mismatch is visible in review.

**Monotonic clock domain.** Every `*_ns` field is nanoseconds on
`CLOCK_MONOTONIC` of the host that runs the simulator. It is not wall time, it
is not comparable across hosts, and it never goes backwards. Producer and
consumer run on the same host (or the same VM). Latency is `done_ns -
intended_emit_ns`: measured from the schedule, not from the actual send, so a
late sender or a slow consumer cannot hide (coordinated omission).

**Deadline in encoder ticks.** `DivertCommand.deadline_encoder_tick` is a belt
position, not a time. The scan-to-divert budget is physical:
`conveyor_speed * distance(scan, diverter)`. The belt is the clock and never
waits, so the deadline is expressed in the unit the belt moves in.

**Enum zero values.** Every enum starts at `*_UNSPECIFIED = 0`. proto3 decodes
a missing field as 0, so a command that was never filled in must not look like a
real lane. A receiver rejects `LANE_UNSPECIFIED`.

**Lane as an enum, not a `uint32 lane_id`.** The line has a fixed layout of one
exception lane and eight sort lanes. An enum names them in generated code in all
three languages, makes an out-of-range lane unrepresentable in typed code, and
adding `LANE_9` later is a compatible change. A `uint32` would be easier to
parameterise but would let `0` or `4000` through silently.

**Types.** No floating point for IDs, money-like values or confidence. The
barcode is a `string` of SSCC-18 digits (leading zeros are significant, no
arithmetic is done on it). Scan confidence is an integer in permille.
Sequence numbers and ticks are `uint64`; times are `int64`, as
`CLOCK_MONOTONIC` is signed in most APIs.

**Reserved ranges.** Each message reserves the numbers it intends to grow into
(`reserved 9 to 15, 20 to 29;` and so on, with the intent commented in the
file). Removing a field in a later version must reserve its number and name
rather than reuse them.

**Comments.** Every message, enum, enum value and field is documented,
including the clock domain on every timestamp.

**Why protobuf now and SBE later.** Protobuf has codegen for C++, Java and
Python from one definition, which is what the cross-language comparison needs
in Parts 1 to 4. It is varint-encoded, so a field's size depends on its value
and decoding allocates. Simple Binary Encoding (Part 6, with Aeron) is
fixed-layout and allocation-free; the contrast between the two is part of that
chapter, so the wire format here is deliberately the ordinary one.

## Compile

Use the pinned protoc (36.2, built into `~/.cache/lowlat/prefix` by
`scripts/deps/build-protobuf.sh`), never the distribution's `protoc` (Fedora
ships 3.19.6, which is too old):

```bash
PROTOC=~/.cache/lowlat/prefix/bin/protoc
$PROTOC --version                # libprotoc 36.2
$PROTOC -I contracts/proto --cpp_out=out/cpp --java_out=out/java \
        --python_out=out/python contracts/proto/lowlat/line/v1/*.proto
```

The Java package is `io.patterncatalyst.lowlat.line.v1` with
`java_multiple_files = true`. Generated code must come from the same protobuf
release as the runtime (Python rejects generated code newer than its runtime).

Lint (buf, STANDARD rules):

```bash
docker run --rm -v "$PWD/contracts/proto":/workspace:Z -w /workspace \
    bufbuild/buf:1.74.0 lint
```

## Validate a report

```bash
uv run --with jsonschema==4.26.0 python -I -c '
import json
from jsonschema import Draft202012Validator as V
v = V(json.load(open("contracts/measurement/latency-report.schema.json")))
v.validate(json.load(open("contracts/measurement/examples/valid.json")))'
```

The report has no latency mean: `percentiles` allows exactly `p50`, `p90`,
`p99`, `p99_9`, `max`. A time-average may appear only under the optional
`model` object, as an input to the Little's Law and Amdahl's Law checks in
Ch2. The `profile` object is owned by `scripts/profile.sh`
(`lowlat-profile/1`); the schema checks only its identifier.

## Versioning

The package is `lowlat.line.v1` and the report is `lowlat-report/1`. Within a
version, only compatible changes are made: add fields with new numbers, add enum
values, never renumber, retype or reuse a reserved number. Any breaking change
creates `lowlat.line.v2` (a new directory and package, with v1 kept until its
users are migrated) or `lowlat-report/2`. `buf breaking` (FILE rules) checks
this.
