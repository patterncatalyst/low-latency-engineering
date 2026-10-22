# Valhalla: status and why this example has no code for it

Status at 2026-10-22.

Project Valhalla would give Java value classes: objects without identity that the JVM may flatten into
arrays and fields, which removes the per-object header and the pointer from a table such as the in-flight
parcel table. That is the layout problem this example solves today with an off-heap `MemorySegment` of
structs (`FlatTable`) and solves for the wire with `FlatView`.

| Item | State |
|---|---|
| JEP 401, Value Classes and Objects (Preview) | integrated into the JDK 28 mainline; a preview feature, so it needs `--enable-preview` even in a GA release |
| JDK 28 | early access only (build 20 on 2026-10-15); no GA date, the six-month cadence puts it near March 2027 |
| Valhalla EA build | `27-jep401ea3+1-1` (2026-03-11) at https://jdk.java.net/valhalla/, under Oracle's early-access terms |
| Project policy | no prerelease versions in any build, script or measured number (`_plans/r02-plan.md`, decision Q2) |

So the example contains no Valhalla code and no early-access build is fetched, compiled against or run
anywhere in `examples/`. The pointer-versus-flat contrast it measures is `object-table` against
`flat-table`; the C++ lane shows the layout a value type is meant to reach by default (`std::vector<ParcelState>`
against `std::vector<std::unique_ptr<ParcelState>>`).

What changes when value classes are available on a GA JDK:

- `ParcelState` becomes a value class and `ParcelState[]` can be stored flat, so the object table
  would approach the flat table's sweep time without leaving the heap or writing a layout by hand.
- The wire side does not change. A `FlatView` over a receive buffer is a view of bytes someone else
  owns, not a value; a value class does not replace reading a network record in place.
- The off-heap table keeps its other properties: an `Arena` with an explicit lifetime, no collector
  involvement, and memory shared with native code.

Re-visit at JDK 28 GA (about March 2027): measure `ParcelState` as a value class against `flat-table`
with the same `TableBenchmark` and update the chapter's status box. The chapter text covers the rest.
