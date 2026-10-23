# 10-lockfree-waitfree

Chapter 10: lock-free and wait-free. Status: build wiring only (S4). The Java, C++ and Python lanes,
`verify.sh` and the full README arrive in S6.

## Layout

| Path | Target |
|---|---|
| `java/` | Maven module `lockfree-waitfree-java` (JMH, Agrona, OpenHFT Affinity, jcstress) |
| `cpp/` | CMake target `lowlat::lockfree` (header-only) |
| `sync-py/` | uv workspace package `lowlat-sync` |

## Build notes

- `mvn -B -f examples/pom.xml verify` builds `target/benchmarks.jar` (JMH) and
  `target/lockfree-waitfree-java-1.0.0-SNAPSHOT-jcstress.jar` (the jcstress runner with the module's tests
  and the processor-generated `META-INF/TestList`). The jcstress tests are compiled by the
  `jcstress-core` annotation processor. jcstress is run by `verify.sh` only, never as a CI gate.
- `dependencyConvergence` stays on. Affinity and jcstress-core disagree on JNA, JMH and jcstress-core on
  jopt-simple; the module manages JNA (`jna.version` in `examples/pom.xml`, 5.19.1) and jopt-simple 5.0.4 (the JMH version). Consequence: the
  jcstress runner's `-h` text fails (NoSuchMethodError in the help formatter): never call `-h`. Running
  tests is unaffected. Pass `-jvmArgsPrepend --enable-native-access=ALL-UNNAMED` to silence JNA's warning.
- The Python package runs under the GIL and the free-threaded build. See the comment at the top of
  `sync-py/pyproject.toml` for the command; `LOWLAT_EXPECT_FREE_THREADED=1` makes a test assert
  `sys._is_gil_enabled() is False`.

## Licences

| Component | Version | Licence | Used for |
|---|---|---|---|
| jcstress | 0.16 | GPL-2.0-only WITH Classpath-exception-2.0 | litmus tests (test-time harness) |
| Agrona | 2.7.0 | Apache-2.0 | `ManyToOneConcurrentArrayQueue` |
| OpenHFT Affinity (chronicle-bom 2026.26) | 2026.2 | Apache-2.0 | thread pinning |
| JMH | 1.37 | GPL-2.0-only WITH Classpath-exception-2.0 | Java benchmarks |
| JNA | 5.19.1 | LGPL-2.1-or-later OR Apache-2.0 | Affinity's native calls (version managed for convergence) |
| jopt-simple | 5.0.4 | MIT | option parsing in JMH and jcstress (version managed for convergence) |

The GPL-with-Classpath-exception tools are build- and measurement-time only; no hot path links them.
