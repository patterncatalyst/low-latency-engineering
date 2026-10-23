# 09-eliminating-work

Chapter 9: eliminating work. Status: build wiring only (S4). The Java, C++ and Python lanes, `verify.sh`
and the full README arrive in S5.

## Layout

| Path | Target |
|---|---|
| `java/` | Maven module `eliminating-work-java` (JMH, Agrona, OpenHFT Affinity, JOL) |
| `cpp/` | CMake target `lowlat::eliminating_work` (links `absl::flat_hash_map` from the pinned prefix) |
| `locality-py/` | uv workspace package `lowlat-locality` |

## Licences

| Component | Version | Licence | Used for |
|---|---|---|---|
| Agrona | 2.7.0 | Apache-2.0 | primitive-keyed map |
| OpenHFT Affinity (chronicle-bom 2026.26) | 2026.2 | Apache-2.0 | thread pinning |
| abseil-cpp | 20250512.1 | Apache-2.0 | `absl::flat_hash_map` |
| JMH | 1.37 | GPL-2.0 WITH Classpath-exception-2.0 | Java benchmarks |
| JOL | 0.17 | GPL-2.0-only WITH Classpath-exception-2.0 | object layout and footprint |

The GPL-with-Classpath-exception tools are build- and measurement-time only; no hot path links them.
