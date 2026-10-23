---
layout: plan
title: "Example 08: zero-copy and flat data"
order: 8
permalink: /examples/08-zero-copy-flat/
card_eyebrow: "Example 08 · Chapter 8"
card_title: "An 80-byte record read in place"
card_blurb: "Reading a flat record through the Foreign Function & Memory API allocates under 1 B per decode against 576 B for a protobuf parse, and a flat table sweeps in 0.95 to 0.97 ms against 4.97 to 5.03 ms for an array of objects (bare-metal, untuned host)."
description: "Reading a flat record through the Foreign Function & Memory API allocates under 1 B per decode against 576 B for a protobuf parse, and a flat table sweeps in 0.95 to 0.97 ms against 4.97 to 5.03 ms for an array of objects (bare-metal, untuned host)."
languages: "Java · C++ · Python"
---

The `parcel-v1` contract fixes an 80-byte flat record (size, offsets, header, endianness and evolution), pinned by golden bytes. A Java `FlatView` re-points at the receive buffer through a `MemorySegment` and `VarHandle`s; the same bytes decode through protobuf for comparison. A flat off-heap table in an `Arena` is swept against an array of objects, and a `clock_gettime` downcall compares the standard and critical FFM linkage. C++ shows `std::start_lifetime_as` and the two pointer layouts; Python shows that zero-copy there still allocates per field. Value classes (JEP 401) are described in `VALHALLA.md` and not measured.

## Run

```bash
examples/08-zero-copy-flat/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host.

## What `verify.sh` asserts

- The C++, Java and Python readers decode the golden files of three seeds to the committed JSON.
- JMH: `flat-ffm` allocates at most 1 B/op and `protobuf-decode` at least 100 B/op, and the protobuf p50 is at least 3x the flat one.
- Line: the receive thread's allocation per parcel for `flat-ffm` is at most 5 % of `protobuf-decode`'s.
- The `flat-table` sweep p50 is at most half the `object-table` p50.
- Both `clock_gettime` downcalls agree with `System.nanoTime()` within 1 ms.
- Every report passes `lowlat-report check`, both line runs count 100,000 parcels with none dropped, and every Java report carries `build.flags`.

All of it held on the quiet-host runs `r02-run1..3`.

## Chapter and source

- Chapter: [Chapter 8, Zero-copy and flat data: Panama (FFM), Valhalla value objects, and the C++ comparison]({{ '/docs/08-zero-copy-flat/' | relative_url }})
- Source: [`examples/08-zero-copy-flat/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/08-zero-copy-flat), with its `README.md`, `VALHALLA.md`, the three language directories and the committed `results/r02-run1..3/`.
