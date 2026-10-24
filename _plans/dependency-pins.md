---
title: "Dependency pins"
render_with_liquid: false
description: "Every r01 dependency pinned to its latest stable upstream release, with licence, source and survey date."
---

Surveyed 2026-10-21 against upstream sources (GitHub releases API, Maven Central `maven-metadata.xml`, PyPI JSON API, Fedora download tree, Bodhi, Docker Hub). Prereleases (RC, beta, milestone) were excluded; where one exists it is named in Notes. Every pin is exact.

Machine-readable copy: `versions.env` at the repo root (protobuf, abseil, tarball URLs and SHA256), read by `scripts/deps/build-protobuf.sh` and `scripts/check-prereqs.sh`. The CMake (`examples/cmake/deps.cmake`), Maven (`examples/pom.xml`) and uv (`examples/pyproject.toml`) files repeat the pins in their own syntax. S4 also pins the Python build backend `hatchling` 1.32.4 (PyPI latest, 2026-10-21) for `examples/common/proto-py`. Tarball SHA256 values were computed from the downloaded release assets on 2026-10-21.

## Pins

### Native (C++)

| Component | Pinned version | Licence | Source queried | Surveyed (2026-10-21) | Notes |
|---|---|---|---|---|---|
| protobuf / protoc | v36.2 (protoc 36.2) | BSD-3-Clause | `gh api repos/protocolbuffers/protobuf/releases/latest` and `version.json` at v36.2 | yes | v37.0-rc1 (2026-10-15) is a prerelease, not used. See the release-train section. |
| abseil-cpp | 20250512.1 | Apache-2.0 | `MODULE.bazel`, `cmake/dependencies.cmake`, `protobuf_deps.bzl` at protobuf v36.2 | yes | Held: the version protobuf v36.2 requires. Newest upstream LTS is 20260817.0, deliberately not used so the protobuf build uses its tested abseil. |
| HdrHistogram_c | 0.12.1 | CC0-1.0 OR BSD-2-Clause | `gh api repos/HdrHistogram/HdrHistogram_c/releases/latest` | yes | Bug-fix release, no API change. Tag name is `0.12.1` (no prefix). GitHub reports licence as NOASSERTION; the LICENSE.txt is CC0 with an optional BSD-2-Clause grant. |
| Google Benchmark | v1.10.0 | Apache-2.0 | `gh api repos/google/benchmark/releases/latest` | yes | |
| GoogleTest | v1.18.0 | BSD-3-Clause | `gh api repos/google/googletest/releases/latest` | yes | |
| nlohmann/json | v3.12.0 | MIT | `gh api repos/nlohmann/json/releases/latest` | yes | Released 2025-04-11; still the latest stable. |
| CMake (latest stable) | 4.4.4 | BSD-3-Clause | `gh api repos/Kitware/CMake/releases/latest` | yes | Host has 4.3.0. Require `cmake_minimum_required(VERSION 4.3)` so the host builds; 4.4.4 is the latest, not a requirement. |

### Java

| Component | Pinned version | Licence | Source queried | Surveyed (2026-10-21) | Notes |
|---|---|---|---|---|---|
| com.google.protobuf:protobuf-java | 4.36.2 | BSD-3-Clause | Maven Central `maven-metadata.xml`; `version.json` java entry | yes | 4.37.0-RC1 is a prerelease, not used. |
| com.google.protobuf:protoc (Maven artifact) | 4.36.2 | BSD-3-Clause | Maven Central `maven-metadata.xml` | yes | Maven version scheme: 4.36.2 is protoc 36.2. Present on Central. |
| io.github.ascopes:protobuf-maven-plugin | 5.1.11 | Apache-2.0 | Maven Central; `gh api repos/ascopes/protobuf-maven-plugin/releases/latest` | yes | Released 2026-09-30. Docs state it pulls any `protoc` version from Maven Central without a plugin upgrade, so 36.2 is supported by design. Not test-built in S0. |
| org.hdrhistogram:HdrHistogram | 2.2.2 | CC0-1.0 OR BSD-2-Clause | Maven Central `maven-metadata.xml` | yes | Released 2024-05-30; no newer release. POM declares BSD-2-Clause plus public domain (CC0). |
| org.openjdk.jmh:jmh-core | 1.37 | GPL-2.0-only WITH Classpath-exception-2.0 | Maven Central | yes | Latest since 2023-08; upstream tags confirm 1.37 is newest. Open source; Classpath exception applies, flagged because it is GPL-based. |
| org.openjdk.jmh:jmh-generator-annprocess | 1.37 | GPL-2.0-only WITH Classpath-exception-2.0 | Maven Central | yes | Same release as jmh-core. |
| org.openjdk.jmh:jmh-java-benchmark-archetype | 1.37 | GPL-2.0-only WITH Classpath-exception-2.0 | Maven Central | yes | Same release as jmh-core. |
| maven-compiler-plugin | 3.16.0 | Apache-2.0 | Maven Central `maven-metadata.xml` | yes | |
| maven-shade-plugin | 3.6.2 | Apache-2.0 | Maven Central | yes | |
| maven-surefire-plugin | 3.6.0 | Apache-2.0 | Maven Central | yes | |
| exec-maven-plugin (org.codehaus.mojo) | 3.6.4 | Apache-2.0 | Maven Central | yes | |
| maven-enforcer-plugin | 3.6.3 | Apache-2.0 | Maven Central | yes | |
| org.junit:junit-bom | 6.1.3 | EPL-2.0 | Maven Central; POM licence | yes | JUnit 6 line. |
| Jackson (tools.jackson.core:jackson-databind, via tools.jackson:jackson-bom) | 3.2.4 | Apache-2.0 | Maven Central `maven-metadata.xml` for `tools.jackson.core` | yes | Recommended. See Jackson section. |
| Jackson 2 (com.fasterxml.jackson.core:jackson-databind) | 2.22.4 | Apache-2.0 | Maven Central | yes | Recorded for comparison; not used. |

### Python

| Component | Pinned version | Licence | Source queried | Surveyed (2026-10-21) | Notes |
|---|---|---|---|---|---|
| protobuf (PyPI) | 7.36.2 | BSD-3-Clause | PyPI JSON API; `version.json` python entry | yes | cp310-abi3 wheel covers 3.14; requires Python >=3.10. |
| hdrhistogram (PyPI) | 0.10.8 | Apache-2.0 | PyPI JSON API; `gh api repos/HdrHistogram/HdrHistogram_py` | yes | Maintained; cp314 wheel; smoke test passed on 3.14.8. See Python HdrHistogram section. |
| pyperf | 2.10.0 | MIT | PyPI JSON API | yes | |
| pytest | 9.1.1 | MIT | PyPI JSON API | yes | |
| jsonschema | 4.26.0 | MIT | PyPI JSON API | yes | |
| ruff | 0.17.1 | MIT | PyPI JSON API | yes | |

### Images and VM lab

| Component | Pinned version | Licence | Source queried | Surveyed (2026-10-21) | Notes |
|---|---|---|---|---|---|
| Fedora 44 Cloud Base qcow2 | `Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2` | Fedora distribution (mixed OSS) | `https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/` (redirector `download.fedoraproject.org` resolves to a mirror of the same tree) | yes | 583729152 bytes. SHA256 `28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f`, from `Fedora-Cloud-44-1.7-x86_64-CHECKSUM` (PGP-signed file; signature not verified in S0). The `UEFI-UKI` qcow2 also exists; the Generic one is the pin. |
| ruby Docker image | `ruby:4.0.7` | Ruby (BSD-2-Clause OR Ruby) | `docker run --rm ruby:4.0 ruby -v`; Docker Hub tags API | yes | `ruby:4.0` currently runs `ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM`. 4.0.7 is the newest 4.0.x exact tag (previous 4.0.6). Pin the exact tag, not `4.0`. |
| fedora Docker image | `fedora:44` | Fedora distribution | `docker run --rm fedora:44 cat /etc/fedora-release`: Fedora release 44 (Forty Four) | yes | Digest at pull time `sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80`. Release-line tag, no finer tag exists. |

## protobuf release train

Mapping is taken from `version.json` at tag v36.2 (key `36.x`, `protoc_version` 36.2, date 2026-09-17, `lts: false`) and confirmed against Maven Central and PyPI artifacts.

| Surface | Version |
|---|---|
| GitHub release tag | v36.2 |
| protoc | 36.2 (release asset `protoc-36.2-linux-x86_64.zip`) |
| C++ library (`version.json` cpp) | 7.36.2 |
| protobuf-java | 4.36.2 |
| Python `protobuf` | 7.36.2 |
| abseil-cpp | 20250512.1 (LTS) |

Pattern: protoc 36.N pairs with Java 4.36.N, Python 7.36.N and C++ 7.36.N. Abseil 20250512.1 appears in `MODULE.bazel` (`bazel_dep abseil-cpp 20250512.1`), `cmake/dependencies.cmake` (`abseil-cpp-version "20250512.1"`) and `protobuf_deps.bzl` (commit 76bb24329e8bf5f39704eb10d21b9a80befa7c81, "Abseil LTS 20250512.1"). `version.json` marks 36.x as non-LTS; the pin follows the user's rule of latest stable.

## Python HdrHistogram

- PyPI `hdrhistogram` 0.10.8, uploaded 2026-10-12; requires Python >=3.10; licence Apache-2.0 (classifier and GitHub).
- Wheels exist for cp310 to cp314: `hdrhistogram-0.10.8-cp314-cp314-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl` plus musllinux, macOS arm64, win32, win_amd64, and an sdist. No compile needed on Fedora x86_64.
- Upstream `HdrHistogram/HdrHistogram_py` is active: GitHub releases 0.10.8 (2026-10-12), 0.10.7 (2026-06-09), 0.10.4 (2026-05-03); last commits 2026-10-12 ("fix: include the final histogram counter in recorded and all-value iteration (#66)", CI updates); not archived; 20 contributors, 8 open issues. Verdict: maintained.
- Install pulls `pbr 7.1.3` and `setuptools 84.2.1` as dependencies.
- Tested: `uv venv .../scratchpad/hdrpy --python 3.14` (Python 3.14.8), `uv pip install hdrhistogram==0.10.8`, then:

```python
from hdrh.histogram import HdrHistogram
h=HdrHistogram(1,3_600_000_000_000,3)
for v in range(1,1001): h.record_value(v*1000)
h.record_corrected_value(5_000_000, 1_000_000)
enc=h.encode()
d=HdrHistogram.decode(enc)
print(type(enc), d.get_total_count(), d.get_value_at_percentile(99), d.get_max_value())
```

Output: `<class 'bytes'> 1005 995327 5001215`. Total count 1005 = 1000 recorded + 5 from the corrected record (5 ms with expected interval 1 ms adds 4 synthetic values plus the value itself). `encode()` returns bytes (compressed base64 V2 form). No alternative is needed. Note the module import name is `hdrh`.

## Jackson

Jackson 3 is GA: `tools.jackson.core:jackson-databind` 3.0.0 is on Central, and the line is at 3.2.4 (2026-10-18), alongside the Jackson 2 line at 2.22.4 (2026-10-17), both Apache-2.0. Jackson 3 moves packages and group id to `tools.jackson`, requires Java 17 or newer (POM `javac.src.version` 17), and keeps the annotations on `com.fasterxml.jackson.annotation`. Recommendation: use Jackson 3.2.4 through `tools.jackson:jackson-bom`. The book is new code on Java 25 with no legacy dependants, the 3 line is current and still receiving releases, and teaching the retiring 2 line would date the book immediately. The measurement kit only does JSON report serialisation, so the migration surface is small.

## Recorded, not pinned

Distro packages, resolved on this Fedora 44 host. These float with the distro and are recorded for reproducibility, not pinned.

| Component | Version seen | Source | Notes |
|---|---|---|---|
| kernel (Fedora 44 updates) | kernel-7.2.11-200.fc44 (stable 2026-10-17) | Bodhi API. `dnf -C repoquery` showed 7.2.10-200 only because its cached metadata was stale. | Upstream version 7.2.11. kernel.org lists 7.2.12 as stable and 7.3 as mainline; Fedora has not shipped 7.2.12 yet. |
| realtime-tests (cyclictest) | 2.11-1.fc44 | `dnf repoquery --whatprovides "*/cyclictest"` | Fedora's `rt-tests` is an unrelated package |
| linuxptp | 4.4-10.fc44 via dnf cache; Bodhi shows 4.4-9.fc44 stable | dnf and Bodhi | The two sources disagree by one release; the newer dnf figure may be a cached or testing build. Treat as 4.4. |
| tuned | 2.28.0-1.fc44 | dnf and Bodhi | |

PREEMPT_RT: mainline since 6.12, and the 7.2 tree's `kernel/Kconfig.preempt` defines `config PREEMPT_RT` with `depends on EXPERT && ARCH_SUPPORTS_RT && !COMPILE_TEST`; `arch/x86/Kconfig` at v7.2 has `select ARCH_SUPPORTS_RT`. So it is selectable on x86_64 with no out-of-tree patches. However the stock Fedora kernel does not enable it: the stock `/boot/config-$(uname -r)` has `# CONFIG_PREEMPT_RT is not set` (with `CONFIG_PREEMPT_DYNAMIC=y`, `CONFIG_EXPERT=y`, `CONFIG_ARCH_SUPPORTS_RT=y`), Fedora's `kernel-x86_64-fedora.config` on f44 likewise, and `dnf repoquery kernel-rt` returns nothing. The r01 VM lab therefore needs a locally built RT kernel (a Fedora kernel with `CONFIG_PREEMPT_RT=y`) or a third-party build; this is not determined here and is a plan decision.

## r02 pins (surveyed 2026-10-22)

Sources: `api.adoptium.net`, Maven Central `maven-metadata.xml` and resolved POMs, `gh api repos/.../releases`, Fedora `dnf repoquery` (read-only), python.org docs, jdk.java.net, graalvm.org. No prerelease is pinned. Machine-readable: `TEMURIN_*` and `ASYNC_PROFILER_*` in `versions.env`; the Maven pins go into `examples/pom.xml` properties in S6.

| Component | Pinned version | Licence | Source queried | Surveyed (2026-10-22) | Notes |
|---|---|---|---|---|---|
| Temurin JDK (linux x64) | 25.0.5+8 (LTS) | GPL-2.0-only WITH Classpath-exception-2.0 | `api.adoptium.net/v3/assets/latest/25/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse` | yes | Built 2026-10-22. URL `https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_x64_linux_hotspot_25.0.5_8.tar.gz`, SHA256 `68982529869257d0ee6b824ec5aa270ff8b118bb438670da0b97ebdab178d7fb` (API value; matches the downloaded file). 141341188 bytes. |
| Fedora 44 `java-25-openjdk` | 25.0.4.1.1-1.1.fc44 (updates) | GPL-2.0-only WITH Classpath-exception-2.0 | `dnf repoquery --latest-limit=1 java-25-openjdk-devel` | yes | Lags Temurin by one update (25.0.5 not yet in Fedora). Recorded, not pinned; the guest and CI use the Temurin tarball (Q12). |
| org.openjdk.jmh:jmh-core, jmh-generator-annprocess | 1.37 | GPL-2.0-only WITH Classpath-exception-2.0 | Maven Central `maven-metadata.xml` (latest/release 1.37, lastUpdated 2023-08-03) | yes | Unchanged since r01. |
| org.agrona:agrona | 2.7.0 | Apache-2.0 | Maven Central metadata (lastUpdated 2026-10-12); `gh api repos/real-logic/agrona/releases/latest` | yes | Released 2026-10-12. Uses `sun.misc.Unsafe` and warns on JDK 25 (Q6). |
| com.lmax:disruptor | 4.0.0 | Apache-2.0 | Maven Central metadata (lastUpdated 2023-09-29); GitHub latest release 4.0.0 | yes | Still the latest; `4.0.0.RC1` is a prerelease, not used. Java 11+ line. |
| net.openhft:chronicle-bom | 2026.26 | Apache-2.0 | Maven Central metadata (release 2026.26, 2026-10-06) | yes | Imported in `dependencyManagement`; pins the versions below. See Chronicle section. Usage analytics (chronicle-core 2026.6, posted by queue and map) must be off: `-Dchronicle.analytics.disable=true` in every JVM that loads Chronicle, enforced by `ChronicleAnalytics.disable()` in code and by the `chronicle` check in `scripts/validate.py`. |
| net.openhft:chronicle-queue | 2026.7 | Apache-2.0 | resolved by the BOM; GitHub release `chronicle-queue-2026.7`, prerelease=false, 2026-10-06 | yes | |
| net.openhft:chronicle-map | 2026.1 | Apache-2.0 | resolved by the BOM; GitHub release `chronicle-map-2026.1`, prerelease=false, 2026-01-29 | yes | `3.26ea*`/`3.27ea*` are early access, not used. |
| net.openhft:chronicle-bytes | 2026.4 | Apache-2.0 | resolved by the BOM; GitHub release `chronicle-bytes-2026.4`, prerelease=false, 2026-06-04 | yes | `2.27ea*` are early access, not used. |
| net.openhft:affinity | 2026.2 | Apache-2.0 | BOM entry; Maven Central metadata (2026-01-28); GitHub release `Java-Thread-Affinity-2026.2` | yes | Licence from the repo `LICENSE.adoc` (Apache 2.0; GitHub reports NOASSERTION) and the SPDX header in the POM. `3.26ea*`/`3.27ea*` early access, not used. |
| async-profiler (linux x64) | 4.6 | Apache-2.0 | `gh api repos/async-profiler/async-profiler/releases/tags/v4.6` (prerelease=false, 2026-10-19) | yes | URL `https://github.com/async-profiler/async-profiler/releases/download/v4.6/async-profiler-4.6-linux-x64.tar.gz`, SHA256 `1e79ed54d8952889a2e74f993d22ee925e3322460d4f37a2ed95bfb88585da36` (GitHub asset digest). The `nightly` release is a prerelease, not used. |
| org.openjdk.jol:jol-core | 0.17 | GPL-2.0-only WITH Classpath-exception-2.0 | Maven Central metadata (lastUpdated 2023-02-27); openjdk/jol `LICENSE` | yes | Latest; used for object layout in Ch5/Ch8 prose and compact-header footprint. |
| stress-ng (guest) | 0.22.01-1.fc44 (updates) | GPL-2.0-or-later | `dnf repoquery --latest-limit=1 stress-ng` | yes | Distro package in the guest; floats with Fedora, recorded not pinned. |
| CPython | 3.14.8 | PSF-2.0 | `python3.14 -V`; docs.python.org/3.14 | yes | Unchanged; hold on 3.14.9 stays (see Holds). GC mode below. |

### Chronicle: the 2026.x calendar line is the public open-source line

- Maven Central lists `chronicle-bom` 2026.0 to 2026.26 as plain release versions (no `ea`, `RC` suffix); `chronicle-queue` 2026.0 to 2026.7, `chronicle-map` 2026.0, 2026.1, `chronicle-bytes` 2026.1 to 2026.4, `affinity` 2026.1, 2026.2. The BOM POM (2026.26) is Apache-2.0 (SPDX header). The GitHub repos (Chronicle-Queue, -Map, -Bytes, Java-Thread-Affinity) are Apache-2.0 and their `2026.x` releases have `prerelease=false`. Early-access lines (`3.26ea*`, `3.27ea*`, `2.27ea*`, `5.27ea*`) are on Central under older numbering and are excluded.
- `5.26.x` and `5.25.x` GitHub releases (for example `chronicle-queue-5.26.17`, 2026-07-27) are older-numbering maintenance lines; the 2026.x line supersedes them. Not used.
- `mvn dependency:tree` of the BOM with queue, map, bytes and affinity resolves: `chronicle-queue` 2026.7, `chronicle-core` 2026.6, `chronicle-wire` 2026.10, `chronicle-threads` 2026.4, `chronicle-bytes` 2026.4, `chronicle-map` 2026.1, `posix` 2026.2, `chronicle-values` 2026.2, `chronicle-algorithms` 2026.2, `affinity` 2026.2, plus `net.java.dev.jna` 5.5.0, `jnr-ffi` 2.2.15, `asm` 9.2, `slf4j-api` 2.0.17, `commons-cli` 1.5.0. These transitives (old asm and jna) are the ones S6 `dependencyConvergence` must reconcile.
- Usage analytics: `chronicle-core` 2026.6 depends on `net.openhft:chronicle-analytics` 2026.2, and `chronicle-queue` 2026.7 and `chronicle-map` 2026.1 call it from their `AnalyticsHolder` (Google Analytics 4, `started` event) when the first queue or map is built, unless the system property `chronicle.analytics.disable` is `true` at that moment (read by `AnalyticsFacade.isEnabled()`; no environment variable). Every Chronicle-using JVM here sets it; see examples/07-offheap-lockfree/README.md, Licences.
- Enterprise-only (excluded, from the Chronicle Queue and Map READMEs): queue encryption (and the `Copy` buffer mode paired with it), TCP/UDP replication of queues and of Chronicle Map, timezone rollover, async mode (`BufferMode.Asynchronous`), the Pre-toucher. The BOM also lists Enterprise and supported-client artifacts (`chronicle-queue-enterprise`, `chronicle-wire-enterprise`, FIX, matching engine and similar); none is imported. OSS Chronicle Queue provides `BufferMode.None` only and does not `fsync` per append.

### JDK status (not used)

- JDK 27: GA 2026-09-15 (openjdk.org/projects/jdk/27), non-LTS; `api.adoptium.net/v3/info/available_releases` reports `most_recent_feature_release` 27, `most_recent_lts` 25; Temurin `27.0.0+35` exists. OpenJDK GA build page: https://jdk.java.net/27/ (27.0.1.0.2). Not used: non-LTS (Q1).
- JDK 28: early access only, build 20 (2026-10-15), https://jdk.java.net/28/ ; Adoptium EA `jdk-28+20-ea-beta`. JEP 401 Value Objects (Preview) shows Status Integrated, Release 28 (https://openjdk.org/jeps/401, updated 2026-08-07). Valhalla EA build `27-jep401ea3+1-1` (2026-03-11): https://jdk.java.net/valhalla/ . Hold: no EA/preview in measured runs (Q2). Re-check at JDK 28 GA (about March 2027).
- jextract: early-access builds only (https://jdk.java.net/jextract/). Not used; Ch8 writes the `FunctionDescriptor` by hand. Re-check when a GA jextract ships.

### GraalVM CE (prose only, Q3; not pinned)

- Current release: GraalVM Community `graal-25.4.4.1.1` "25 Innovation 4" (JDK 25.0.4.1.1), GitHub release 2026-09-22, prerelease=false. graalvm.org release notes call it "an innovation release". The tag pattern is `graal-25.N.x`: a monthly-ish Innovation release on JDK 25, not a separate LTS line; release notes do not define the term further.
- Native Image GC in CE: Serial GC is the default; Epsilon is available; G1 is documented as "Not available in GraalVM Community Edition" (graalvm.org JDK 25 Memory Management reference). G1, and the better throughput it brings, is Oracle GraalVM only. Ch5/Ch6 say native-image on CE means Serial or Epsilon, which does not apply to the hot path.

### `std::start_lifetime_as` (test-compiled 2026-10-22, `-std=c++23`)

Probe: `std::start_lifetime_as<P>(buf)` on an `alignas(P) std::byte[8]`, `#include <memory>`. Clang 22.1.8 (Fedora 22.1.8-4.fc44) and GCC 16.2.1 20260819 both compile it; both report `__cpp_lib_start_lifetime_as 202207L` through the host libstdc++. Ch8 may use it. Not tested: clang with libc++.

### CPython 3.14 cycle GC

Python 3.14.0 to 3.14.4 shipped an incremental cycle GC; 3.14.5 and later (including the pinned 3.14.8) use the generational collector again ("Forward-port the generational cycle garbage collector", gh-142516). Sources: https://docs.python.org/3.14/whatsnew/3.14.html (Incremental garbage collection: "Python 3.14.0-3.14.4 shipped with a new incremental garbage collector"), the 3.14 changelog, and `gc` docs. Checked on the host's 3.14.8: `gc.get_threshold()` is `(2000, 10, 10)`, three generations. Ch6 Python lane describes generations and `gc.freeze()`.

### Findings that change r02-plan §0

- Fedora's `java-25-openjdk` is 25.0.4.1.1, one update behind Temurin 25.0.5; consistent with Q12 (pinned tarball), no plan change.
- `chronicle-bom` is at 2026.26 and resolves queue 2026.7, map 2026.1, bytes 2026.4, affinity 2026.2 (consistent with §0). Chronicle Map replication is Enterprise too.
- `check-prereqs.sh` still checks only "java 25"; the "warn below the pin" idea needs a `TEMURIN_VERSION` comparison, added where S5/S6 touch the script.

## r03 pins (checked 2026-10-23)

Sources: Maven Central `maven-metadata.xml` and POMs, `gh api repos/.../releases` and `/tags`, upstream `LICENSE` files, python.org docs, read-only host probes. No prerelease is pinned. All probes ran unprivileged; `perf_event_paranoid` was read (value 2) and never changed.

| Component | Pinned version | Licence | Source queried | Checked (2026-10-23) | Notes |
|---|---|---|---|---|---|
| org.openjdk.jcstress:jcstress-core | 0.16 | GPL-2.0-only WITH Classpath-exception-2.0 (header-designated; the POM declares no licence) | Maven Central `maven-metadata.xml` (latest/release 0.16, lastUpdated 2023-02-27); `gh api repos/openjdk/jcstress/tags` (newest tag 0.16) | yes | Latest; no GitHub releases, only tags. Test-time harness only (`verify.sh`, not a CI gate, Q4), never on a hot path. Recommended bootstrap is the archetype `org.openjdk.jcstress:jcstress-java-test-archetype` 0.16 (same date) generating a project that depends on `jcstress-core` and builds an uber jar with `mvn clean verify`; S4 wires `jcstress-core` as a module dependency rather than running the archetype. No newer version, no hold. |
| org.agrona:agrona | 2.7.0 | Apache-2.0 | Maven Central metadata (lastUpdated 2026-10-12); `gh api repos/real-logic/agrona/releases/latest` (2.7.0, prerelease=false, 2026-10-12) | yes | Still the latest. Unchanged. |
| org.openjdk.jol:jol-core | 0.17 | GPL-2.0-only WITH Classpath-exception-2.0 | Maven Central metadata (lastUpdated 2023-02-27); tags show 0.17 newest | yes | Still the latest. Unchanged. |
| net.openhft:chronicle-bom / affinity | BOM 2026.26 / affinity 2026.2 | Apache-2.0 | Maven Central metadata: BOM release 2026.26 (2026-10-06), affinity release 2026.2 (2026-01-28) | yes | Current pin equals latest for both; unchanged from r02. |
| CPython free-threaded (uv) | cpython-3.14.8+freethreaded (python-build-standalone 20261009, via uv 0.13.0) | PSF-2.0 | `uv python install cpython-3.14.8+freethreaded`; install-dir `BUILD` file; docs.python.org/3.14 | yes | User-local, not a system package. Interpreter `python3.14t`. Held at 3.14.8 with the GIL build (see Holds). |
| abseil-cpp (`absl::flat_hash_map`) | 20250512.1 (held) | Apache-2.0 | Installed prefix `~/.cache/lowlat/prefix` | yes | Hold unchanged (protobuf v36.2 requires it; see Holds). The prefix ships `include/absl/container/flat_hash_map.h` and its `lib64/cmake/absl/abslTargets.cmake` defines the imported target `absl::flat_hash_map`, so S4 can link it without a new dependency. |
| net.java.dev.jna:jna, jna-platform | 5.19.1 (managed in `examples/pom.xml` as `jna.version`) | LGPL-2.1-or-later OR Apache-2.0 | Maven Central; validator run of `mvn verify` and a jcstress quick pass on 2026-10-23 | yes | Managed in the parent `dependencyManagement`, so 07, 09 and 10 all resolve the newest stable: Affinity (via chronicle-bom) would bring 5.5.0 and jcstress-core 0.16 brings 5.8.0, which also keeps `dependencyConvergence` on in 10. Test-time/affinity use only. |
| net.sf.jopt-simple:jopt-simple | 5.0.4 (managed in the `10-lockfree-waitfree` POM) | MIT | Maven Central | yes | Convergence between JMH 1.37 (5.0.4) and jcstress-core 0.16 (4.6); newest stable. Known: jcstress `-h` throws `NoSuchMethodError` on 5.0.4 (its help formatter needs 4.6), so never call `-h`; running tests is unaffected. |

### Recorded, not pinned

| Tool | Version recorded | Source |
|---|---|---|
| valgrind | 3.27 (3.27.1 on the host) | `valgrind --version` |
| perf | 7.2 (major.minor only) | `perf --version` |
| uv | 0.13.0 | `uv --version`; hold unchanged |
| GCC / Clang | 16.2.1 / 22.1.8 | `g++ --version`, `clang++ --version` (CMake presets `release-gcc` and `release`) |

### perf probes at the current `perf_event_paranoid` (2)

| Probe | Result | Fallback / decision |
|---|---|---|
| `perf stat --control fifo:ctl,ack -D -1 -e L1-dcache-load-misses:u,cycles:u -x,` around a C++ test with three equal work phases, `enable` before the middle one and `disable` after it | Works. The gated run counted 4.19 M L1 misses / 123 M cycles; an ungated whole-process run of the same program counted 12.6 M / 374 M, i.e. one third, as expected for one of three phases. Events start disabled with `-D -1`. | Use `--control` for region counting in the C and Python lanes; the program writes `enable`/`disable` to the control FIFO and reads the ack FIFO. |
| JMH `-prof perfnorm` with `event=L1-dcache-load-misses:u,cycles:u,instructions:u` (existing example 05 `benchmarks.jar`, `AllocationBenchmark.escaping`, 1 fork, 2 short iterations) | Works. Produced `L1-dcache-load-misses:u`, `cycles:u`, `instructions:u` per op plus derived `CPI`/`IPC`. Only a plumbing check, the numbers are not results. | Java lane uses `perfnorm` with `:u` events. Always pass the `:u` suffix explicitly; JMH prints the paranoid-2 notice but proceeds. |
| `perf c2c record -- <short program>` | Refused: "Failure to open any events for recording" (needs kernel-side access, paranoid above 1 blocks it). | Not used on the host. Cross-core line transfer is observed with `perf stat -e L1-dcache-load-misses:u,ocr.demand_rfo.l3_hit.snoop_hitm:u,machine_clears.memory_ordering:u`; `perf c2c` is not a dependency of any chapter. |
| Event availability, `perf stat -x,` on the test program | Counted without error: `L1-dcache-load-misses:u`, `LLC-load-misses:u`, `machine_clears.memory_ordering:u`, `ocr.demand_rfo.l3_hit.snoop_hitm:u`. All four appear in `perf list`. | Asserted criteria use only the generic `L1-dcache-load-misses:u` (and `LLC-load-misses:u`); the other two are microarchitecture-specific, observed and labelled as such. |

### C++26 `<hazard_pointer>` and `<rcu>` (status only, `-std=c++2c`)

GCC 16.2.1 and Clang 22.1.8 (both using the host libstdc++, the standard library of the project's presets) ship neither header: `__has_include(<hazard_pointer>)` and `__has_include(<rcu>)` are false, and `__cpp_lib_hazard_pointer` and `__cpp_lib_rcu` are undefined in `<version>`. Not used; Ch10 stays on C++23 (`std::atomic`, `std::atomic_ref`). Not tested: clang with libc++.

### Free-threaded CPython (Q3)

- Installed `cpython-3.14.8+freethreaded` with `uv python install` (user-local, interpreter `python3.14t`). Not a system package. Build: 3.14.8, python-build-standalone 20261009.
- `sys._is_gil_enabled()`: `False` on the free-threaded build (`Py_GIL_DISABLED` 1); `True` on the host 3.14.8 (`Py_GIL_DISABLED` 0).
- Documentation: the CPython 3.14 free-threading howto (docs.python.org/3.14/howto/free-threading-python.html, "Iterators") says "It is generally not thread-safe to access the same iterator object from multiple threads concurrently, and threads may see duplicate or missing elements." The 3.14 `itertools` page makes no thread-safety statement for `count` or its `__next__`. Result: **`itertools.count.__next__` is not documented thread-safe in either build.**
- Observation (not a documentation claim): 4 threads x 1,000,000 `next(count)` calls, 3 repetitions per build: every repetition yielded exactly 4,000,000 unique values 0..3,999,999 on both the GIL and the free-threaded build.
- Observation: racy `counter += 1` on a shared list cell, 4 threads x 1,000,000, 3 repetitions. GIL build: 0 lost increments in all three runs (the 5 ms switch interval did not interleave a read-modify-write here). Free-threaded build: 2,172,123, 2,124,129 and 2,011,474 lost of 4,000,000. `threading.Lock` around the increment gave exactly 4,000,000 in both builds (one run each).
- Decision for the Ch10 Python lane: Ch10 asserts exactly-once for `lock` in both builds; `itertools-count` exactly-once is **observed and reported, not asserted**, because it is undocumented; the racy claim asserts at least 1 lost claim under free threading only. The GIL build may show zero lost claims, so it is reported as observed.

## r04 pins (checked 2026-10-23)

Sources: `gh api` on GitHub releases and tags, Maven Central `maven-metadata.xml`, the quarkus.io releases page, PyPI JSON API, `skopeo` against `registry.access.redhat.com` (read-only), the public UBI 10 repository metadata at `cdn-ubi.redhat.com`, upstream source files, vendor docs, and read-only host probes. No prerelease is pinned. Nothing was installed or changed on the host; the Boost and liburing tarballs were downloaded to a scratch directory only to hash them.

### Pins

| Component | Pinned version | Licence | Source queried | Checked (2026-10-23) | Checksum or digest | Notes |
|---|---|---|---|---|---|---|
| Boost (cmake tarball) | 1.92.0 | BSL-1.0 | `gh api repos/boostorg/boost/releases`; asset `boost-1.92.0-cmake.tar.xz` at `https://github.com/boostorg/boost/releases/download/boost-1.92.0/boost-1.92.0-cmake.tar.xz` | yes | SHA256 `9bed76128d4e46755dbe818487788c6fceb6f72b378f4daa49b7e1e600d9088d` | Released 2026-08-12. Computed from the downloaded file (107878596 bytes) and equal to the SHA256 in the release's `boost-1.92.0-cmake.tar.xz.txt`. GitHub lists `boost-1.92.0.beta1` with prerelease=false; it is a beta and is not used. Previous stable: 1.91.0 (tag `boost-1.91.0-1`). Fedora's `boost-devel` is 1.90.0 and is not the pin source (D1). |
| liburing | liburing-2.15 (2.15) | LGPL-2.1-or-later OR MIT (library); GPL-2.0-only WITH Linux-syscall-note OR MIT (kernel uapi header) | `gh api repos/axboe/liburing/tags` and `/releases` (2.15 released 2026-06-29, prerelease=false); `https://github.com/axboe/liburing/archive/refs/tags/liburing-2.15.tar.gz` | yes | SHA256 `8d052f2622dcb3678cbaee5ff582a87572672a6c0a56533cdda5b65cb636120a` | Licence from the 2.15 `README` ("dual licensed LGPL and MIT, see COPYING and LICENSE"), `COPYING` (LGPL 2.1), `LICENSE` (MIT) and `COPYING.GPL` for the header; the source files carry `SPDX-License-Identifier: MIT`. Hash is of GitHub's generated tag archive, which GitHub does not guarantee stable; S4 re-verifies at fetch time. `liburing-2.15-rc1` is a prerelease, not used. Fedora's `liburing-devel` is 2.13. The 2.15 tag object is `84bb497ca2f9d24ca0b9e5646fb6a05e72c0f04e`. |
| Quarkus platform (`io.quarkus.platform:quarkus-bom`) | 3.40.1.1 | Apache-2.0 | Maven Central `maven-metadata.xml` (versions 3.40.1, 3.40.1.1; `latest` is the beta below); `https://quarkus.io/releases` | yes | none (Maven artifact; resolved by Maven's own checksums) | 3.40 is the current LTS (released 2026-09-30, community support until 2027-09-30); 3.40.1.1 is its newest micro, an emergency CVE release of 2026-10-19. 4.0.0.Beta1 (2026-10-01; Maven `latest`/`release` point at it) is a prerelease, not used; the releases page lists 4.0.0 as upcoming. See the Quarkus notes below. |
| uvloop | 0.23.0 | MIT OR Apache-2.0 (dual-licensed; the README says "dual-licensed under MIT and Apache 2.0", PyPI lists both classifiers) | PyPI JSON API `https://pypi.org/pypi/uvloop/json` | yes | none pinned here; `uv.lock` in S4 records the wheel hashes | Uploaded 2026-10-01. Wheels exist for cp314 and cp314t: `uvloop-0.23.0-cp314-cp314-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl` and `uvloop-0.23.0-cp314-cp314t-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl` (also aarch64, musllinux, macOS, and cp315). A cp314t wheel existing does not prove uvloop runs without re-enabling the GIL: not tested. D11 plan is the GIL lane only, observed. |

### S4 additions (2026-10-24)

- `io.quarkus:quarkus-junit` (the test artifact; `quarkus-junit5` is still in the 3.40.1.1 BOM as the old name) and `io.rest-assured:rest-assured` carry no version in the POM: both come from `quarkus-bom` 3.40.1.1. The standalone Quarkus module repeats the parent's compiler plugin 3.16.0, surefire 3.6.0 and enforcer 3.6.3.
- `versions.env` now repeats the Boost, liburing, Quarkus platform and uvloop pins (nothing new was chosen).
- CPython 3.14.9 promotion not done: uv 0.13.0 cannot see it (see the r04 plan Follow-ups).

### Images (UBI, newest first)

Digests are the multi-arch index digest of the pinned tag, and the linux/amd64 manifest digest in the last column. Taken with `skopeo inspect` and `skopeo inspect --raw` on 2026-10-23. The tag is the exact `version-release` label of the build that `latest` pointed at when checked. Pin the tag and the index digest together (`image:tag@sha256:...`).

| Image | Tag | Index digest | linux/amd64 manifest digest | Built | Notes |
|---|---|---|---|---|---|
| `registry.access.redhat.com/ubi10/ubi` | `10.2-1792744468` | `sha256:7495bfa53ae7a81a58aeface0bb4858d12741832c542c29dc690d67b183b73b0` | `sha256:323150de5f418e7abd37551c3d979bc59c26efca67e347d136f34540bfc1c2da` | 2026-10-23 | RHEL 10.2 userland. Same digest as `latest`. Builder for the C++ binary (D10). |
| `registry.access.redhat.com/ubi10/ubi-minimal` | `10.2-1792742351` | `sha256:ab67cd02caf8706e34a695a1432ebe965934f6128ec352a6c3f4048b43a4fb5e` | `sha256:eed1fd1de97f2638206c08969b875434b02488ce566e4a9fbfdb7922b1798140` | 2026-10-23 | Base for the Java and Python runtime stages. |
| `registry.access.redhat.com/ubi10/openjdk-25-runtime` | `1792203102` | `sha256:cfc8606329db9ee031c42c38ddbe11fe48980f3765822511a5bc6a321c73b193` | `sha256:af55f8c4b0e29410bd945efdc0021b42708f9644b4f1237c74de50dc9b0ffea2` | 2026-10-17 | Exists (Red Hat build of OpenJDK 25, label version 1.24, release 1791891203). Not used for measured lanes: it is not the pinned Temurin build (D10 option b, README mention only). `ubi10/openjdk-25` (build image) also exists. |
| `registry.access.redhat.com/ubi10/python-314` | does not exist | none | none | n/a | `skopeo list-tags` returns "Repo not found" for `ubi10/python-39`, `-311`, `-312`, `-313` and `-314`. No ubi10 Python s2i image is published. Python in the ubi10 lanes comes from `ubi10/ubi-minimal` plus uv-managed CPython 3.14 (D10). |
| `registry.access.redhat.com/ubi9/ubi` (fallback) | `9.8-1792742206` | `sha256:217dd5692d369799d34d09ffb6f5f3404efebc7900834490fdf9ae92fd6721d4` | `sha256:3bd1aa8b49948633375021c22ef5601ae644f5c08c869751ac2b542884622ea1` | 2026-10-23 | Fallback only. |
| `registry.access.redhat.com/ubi9/ubi-minimal` (fallback) | `9.8-1792742033` | `sha256:2d4c4551af6831dcd26bbf86108c4385de5183ec8fe6b5868f6f9640fe47f4ed` | `sha256:0e40cd75c9a128b6b9db185c8220193dc46e86dbf97815555df255c622683570` | 2026-10-23 | Fallback only. |
| `registry.access.redhat.com/ubi9/openjdk-25-runtime` (fallback) | `1.24-3.1791779557` | `sha256:a2577e5438a824a7f85b80783525371d937550089710a91bf3e8979c26eaf8e8` | `sha256:9aa12effc1bc91573b2270ba0e6b0658c08822d190281d037cec1258e442dad4` | 2026-10-12 | Fallback only. |
| `registry.access.redhat.com/ubi9/python-314` (fallback) | `9.8-1792671590` | `sha256:14b7b7245ed127d7b1cef888b2f90e3d0f91638566c2656765d82646ec9bb30c` | `sha256:d8f2d67be3eea63b3f6d701920f98e06ace9471718bfa07d60bf7a57a20e21f6` | 2026-10-22 | Exists on ubi9 only. Fallback only. |

UBI images are redistributable under the Red Hat UBI EULA (free, no subscription or licence key needed; the content is open source packages). The tags move: S5 re-resolves the tag and digest on the day the images are built and records them in the `Containerfile`s.

UBI 10 GCC: the public UBI 10 AppStream repository metadata (`https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi10/10/x86_64/appstream/os/`, revision of 2026-10-23) lists `gcc`, `gcc-c++` and `libstdc++-devel` 14.3.1-4.4.el10, and BaseOS has `glibc` 2.39-145.el10_2 and `liburing` 2.12-1.el10. GCC 14.3.1 is at least 14, which `<generator>` and `<print>` need (`__cpp_lib_generator` and `__cpp_lib_print` first ship in libstdc++ 14). The full C++23 probe below was compiled with GCC 16.2.1 on the host; compiling it with the ubi10 GCC 14 happens in S5 in the guest and is not claimed here. No `gcc-toolset` fallback is needed on the GCC-version evidence alone.

### Quarkus notes

- Newest stable platform: 3.40.1.1 (LTS). The sibling's 3.33.1 is not the newest: the 3.33 LTS line is now at 3.33.4.1 (2026-10-19, supported until 2027-03-25) and the current LTS is 3.40. Older LTS: 3.27 ended 2026-09-24.
- Java 25: supported. The Quarkus 3.31 release announcement (2026-01-28, https://quarkus.io/blog/quarkus-3-31-released/) is titled "Full Java 25 support"; 3.40 is later.
- `@RunOnVirtualThread` on `quarkus-rest`: supported, Java 21 or later, extension `io.quarkus:quarkus-rest` (https://quarkus.io/guides/virtual-threads). It works only on endpoints that are blocking, either by `@Blocking` or by a plain-value return signature; an endpoint returning `Uni` is non-blocking and runs on the event loop. The guide has no JDK 25 text beyond "Java 24+: `synchronized` no longer pins"; JDK 25 behaviour is verified by running, not by the guide.

### Defaults and runtime facts (doc citations)

Each line is a fact the chapters may assert, with its source and the date checked.

| Topic | Finding | Source |
|---|---|---|
| JEP 491 | Delivered in JDK 24: `synchronized` no longer pins a virtual thread to its carrier ("eliminate nearly all cases of virtual threads being pinned"). Still pins: blocking inside a native method or FFM downcall that calls back into Java, blocking while loading a class during symbolic reference resolution, blocking inside a class initializer, and waiting for another thread to finish initializing a class. `jdk.tracePinnedThreads` is removed; JFR `jdk.VirtualThreadPinned` stays for the remaining cases. | https://openjdk.org/jeps/491 |
| JDK 25 container CPU count | `Runtime.availableProcessors()` in a container starts from `sched_getaffinity` (a cpuset shows up here), then, if a cgroup quota is set, takes the quota divided by the period rounded up, never above the affinity count. So `--cpus=2` gives 2 and `--cpuset-cpus=2,3` gives 2. Source: the comment of `CgroupSubsystem::active_processor_count` in `cgroupSubsystem_linux.cpp` and the arithmetic in `CgroupUtil::processor_count` in `cgroupUtil_linux.cpp` (`ceilf(quota / period)`, then `MIN2(host_cpus, limit_count)`), both at tag `jdk-25-ga`. `-XX:ActiveProcessorCount=n` overrides it. The `Runtime` Javadoc says only "number of processors available to the Java virtual machine". | https://github.com/openjdk/jdk/blob/jdk-25-ga/src/hotspot/os/linux/cgroupSubsystem_linux.cpp ; https://github.com/openjdk/jdk/blob/jdk-25-ga/src/hotspot/os/linux/cgroupUtil_linux.cpp ; https://docs.oracle.com/en/java/javase/25/docs/specs/man/java.html |
| Python CPU count | `os.cpu_count()` is "the number of logical CPUs in the system" (not affected by affinity); `os.process_cpu_count()` (added in 3.13) is "the number of logical CPUs usable by the calling thread of the current process", "can be less than `cpu_count()` depending on the CPU affinity". Both honour `PYTHON_CPU_COUNT` / `-X cpu_count` (3.13+). The docs say nothing about a CFS quota; the affinity-based reading means a quota is not reflected. Host check with `taskset -c 0,1`: `cpu_count` unchanged, `process_cpu_count` 2. | https://docs.python.org/3.14/library/os.html |
| C++ `hardware_concurrency()` | libstdc++ `thread::hardware_concurrency()` returns `get_nprocs()` (`_GLIBCXX_USE_GET_NPROCS`), and glibc `get_nprocs()` reads `/sys/devices/system/cpu/online` (fallback `/proc/stat`, then `sched_getaffinity`). It therefore counts online CPUs, ignores the affinity mask and ignores any cgroup quota or cpuset. Host check with `taskset -c 0,1`: `hardware_concurrency()` unchanged at the online count. **This contradicts plan §2 item 2**: under `--cpuset-cpus=2,3` the C++ value is the guest's 4, not 2. Python `process_cpu_count()` and Java give 2 there; `cpu_count()` gives 4. | https://github.com/gcc-mirror/gcc/blob/releases/gcc-16.1.0/libstdc++-v3/src/c++11/thread.cc ; https://github.com/bminor/glibc/blob/glibc-2.39/sysdeps/unix/sysv/linux/getsysstats.c (unchanged on master) |
| Docker seccomp and io_uring | The default profile has `defaultAction` `SCMP_ACT_ERRNO` and no `io_uring_setup`, `io_uring_enter` or `io_uring_register` entry, so all three fail with `EPERM`. moby commit `891241e7` "seccomp: block io_uring_* syscalls in default profile" (2023-11-02) removed them from the allow list; the profile in moby v24.0.9 still allows them, v25.0.0-rc.1 and v25.0.0 (2024-01-19) and the current profile do not. So: blocked by default since Docker Engine 25.0. Docker Engine here is 29.9.1. The `EPERM` result itself is verified in the guest in S5, not here. | https://github.com/moby/profiles/blob/main/seccomp/default.json ; https://github.com/moby/moby/commit/891241e7 |
| CFS period in Docker | `--cpu-period` "defaults to 100000 microseconds (100 milliseconds)"; `--cpus=N` is the equivalent of `--cpu-period=100000` and `--cpu-quota=N*100000`; `--cpuset-cpus` selects which CPUs rather than how much time. | https://docs.docker.com/engine/containers/resource_constraints/ |
| Boost.Asio io_uring | `BOOST_ASIO_HAS_IO_URING` is opt-in (defined by the user; needs liburing and kernel 5.10 or later). With it, io_uring is used for file-related asynchronous operations and `epoll` still demultiplexes other event sources, which includes sockets. Adding `BOOST_ASIO_DISABLE_EPOLL` makes io_uring serve all asynchronous operations (`BOOST_ASIO_HAS_IO_URING_AS_DEFAULT`). So sockets go through io_uring only with both macros. Config parameters `reactor`/`io_uring_ring_count`, `io_uring_ring_size`, `io_uring_submit_batch_size` and `io_uring_iowait` exist in 1.92. D16: the Asio io_uring lane is feasible for sockets if both macros are set; this is documented, not yet run. | `libs/asio/doc/overview/implementation.qbk`, `libs/asio/doc/history.qbk` and `libs/asio/include/boost/asio/detail/config.hpp` inside the 1.92.0 cmake tarball ; https://www.boost.org/doc/libs/1_92_0/doc/html/boost_asio/overview/implementation.html |
| Boost CMake and libraries | The cmake tarball is a CMake superproject (`CMakeLists.txt`, `tools/cmake/README.md`). `BOOST_INCLUDE_LIBRARIES` restricts the build to the named libraries and their dependencies. `libs/asio`, `libs/fiber` and `libs/context` each ship a `CMakeLists.txt` in 1.92.0. Asio is header-only (`Boost::asio`); fiber and context are compiled. `add_subdirectory` use with this variable is the documented pattern; a real configure-and-build of `asio;fiber;context` is S4's job and is not claimed here. | `tools/cmake/README.md` in the tarball |
| Quarkus thread defaults | Event loops: `quarkus.vertx.event-loops-pool-size`, when unset, comes from `VertxCoreRecorder.calculateDefaultIOThreads()` at tag 3.40.1: `max(2, min(maxMemoryMiB / 10, availableProcessors))`. The floor is 2, the count is capped at one loop per 10 MiB of max heap, and the CPU term is 1 x cores (the source comment says the old recommendation of 2 x cores was replaced by 1:1). **Ch13's exact event-loop count therefore depends on both the container CPU limit (via `availableProcessors()`, quota-aware) and the heap limit**: a small heap can lower it below the CPU count, and 1 CPU still gives 2. Worker pool: `quarkus.thread-pool.max-threads` is "the greatest of 8 * the number of available processors and 200" (200 on 4 CPUs, 384 on 48). Worker `max-worker-execute-time` 60 s. Blocked-thread settings are in the next row. | https://github.com/quarkusio/quarkus/blob/3.40.1/extensions/vertx/runtime/src/main/java/io/quarkus/vertx/core/runtime/VertxCoreRecorder.java ; https://quarkus.io/guides/all-config |
| Quarkus blocked-thread checker | `quarkus.vertx.max-event-loop-execute-time` (default 2 s; a bare number is seconds, `1ms` parses as one millisecond per `DurationConverter` at 3.40.1) is how long an event-loop task may run before the checker warns. `quarkus.vertx.warning-exception-time` (default 2 s) sets the exception-stack threshold and, in `VertxCoreRecorder`, is also passed as `setBlockedThreadCheckInterval(warningExceptionTime.toMillis())`, so it is the checker period. **Consequence for Ch12 assert 5:** with the defaults a 2 ms block on the event loop produces 0 warnings. The defect variant must set `quarkus.vertx.max-event-loop-execute-time=1ms` (below the 2 ms block) and a short `quarkus.vertx.warning-exception-time` (for example `1ms`, a 1 ms check period) so at least one warning is reachable in the run. A sampling checker can still miss a single short block, so the assert is on the count over the whole run under load, and S7 confirms it. | https://quarkus.io/guides/all-config ; https://github.com/quarkusio/quarkus/blob/3.40.1/extensions/vertx/runtime/src/main/java/io/quarkus/vertx/core/runtime/VertxCoreRecorder.java ; https://github.com/quarkusio/quarkus/blob/3.40.1/core/runtime/src/main/java/io/quarkus/runtime/configuration/DurationConverter.java |
| `@Blocking`, `@NonBlocking`, `@RunOnVirtualThread` | In Quarkus REST a method returning a plain value runs on a worker thread and one returning `Uni`/`Multi` runs on the event loop; `@Blocking` and `@NonBlocking` override that (method, class or application level). `@RunOnVirtualThread` moves a blocking endpoint to a new virtual thread, keeps the duplicated context, does not propagate thread locals, and does not apply to an endpoint returning `Uni`. | https://quarkus.io/guides/rest ; https://quarkus.io/guides/virtual-threads |
| asyncio on free-threaded 3.14 | Supported: Python 3.14 "What's New" says asyncio has "first class support for free-threading builds", which lets multiple event loops run in parallel in different threads and scale with the thread count; per-thread task lists made native tasks 10 to 20 percent faster. Caveat from the dedicated page: a single event loop is not thread-safe, so cross-thread calls go through `call_soon_threadsafe` / `run_coroutine_threadsafe`; one loop still runs one thread. | https://docs.python.org/3.14/whatsnew/3.14.html ; https://docs.python.org/3.14/library/asyncio-threading.html |
| JDK virtual-thread scheduler | `jdk.virtualThreadScheduler.parallelism` defaults to `Runtime.getRuntime().availableProcessors()` (so quota-aware in a container); `jdk.virtualThreadScheduler.maxPoolSize` defaults to `max(parallelism, 256)`, and parallelism is capped at an explicit `maxPoolSize`. Source of `VirtualThread.createDefaultScheduler` at tag `jdk-25-ga`; the `java.lang.Thread` docs do not state the defaults. | https://github.com/openjdk/jdk/blob/jdk-25-ga/src/java.base/share/classes/java/lang/VirtualThread.java |
| asyncio debug mode | In debug mode "callbacks taking longer than 100 milliseconds are logged"; `loop.slow_callback_duration` sets the threshold in seconds (default 0.1). The log record is `Executing <Handle/Task ...> took N seconds` at WARNING level (message text from CPython `base_events.py`, not re-fetched here). | https://docs.python.org/3.14/library/asyncio-dev.html |
| Virtual thread in `DatagramChannel.receive` | A virtual thread that finds no datagram configures the socket non-blocking and calls `park(Net.POLLIN)`, which calls `Poller.poll(fd, event, nanos, isOpen)`; the poller is `EPollPoller` on Linux (`DefaultPollerProvider`, `EPollPoller.java` under `src/java.base/linux/classes/sun/nio/ch/`). So a blocked receive parks the virtual thread and frees the carrier, with epoll as the readiness mechanism. Which poller mode (system or virtual poller threads) is the default was not checked. | https://github.com/openjdk/jdk/blob/jdk-25-ga/src/java.base/share/classes/sun/nio/ch/DatagramChannelImpl.java ; https://github.com/openjdk/jdk/blob/jdk-25-ga/src/java.base/share/classes/sun/nio/ch/Poller.java |
| Coroutine frames and HALO | Probe (GCC 16.2.1, `-O2 -std=c++23`, promise-level counting `operator new`, 1000 coroutines parked in a `std::vector<Task>`): exactly 1000 allocations, 1 per frame, 48 bytes per frame for a coroutine with an `int` and a pointer parameter plus one `co_await`. Non-escaping control (create, resume to completion and destroy inside one function): 1000 allocations of 40 bytes at `-O2`, i.e. **no elision observed** with either a promise-level or a replaced global `operator new`. HALO is allowed but not guaranteed, so the Ch11 probe makes frames escape (stored and parked) and counts allocations per frame rather than assuming elision. Frame size is compiler and flag specific. | probe run 2026-10-23; compiler-specific, no external URL |
| `tracemalloc` | The module "trace[s] memory blocks allocated by Python" by hooking Python's memory allocators; it reports sizes and counts of those blocks. It does not claim to count memory taken outside the Python allocators (for example C extension `malloc`), and tracing adds overhead. The docs give no exactness guarantee, so wording is "measured by tracemalloc", never "exact". | https://docs.python.org/3.14/library/tracemalloc.html |
| JVM GC threads under a quota (observed only) | `-XX:ParallelGCThreads`: "the default value depends on the number of CPUs available to the JVM and the garbage collector selected". With container support that CPU count is the quota-aware `availableProcessors()` value, so GC worker counts shrink under `--cpus`. The actual counts are read at startup in Ch13 and reported as observed. | https://docs.oracle.com/en/java/javase/25/docs/specs/man/java.html |

### Read-only host probes (2026-10-23)

| Probe | Result |
|---|---|
| `g++ --version` | GCC 16.2.1 (Red Hat build 16.2.1-2). |
| C++23 compile test, `g++ -std=c++23 -O1 -Wall -Wextra`, with `<generator>`, `<print>`, `<expected>`, `std::move_only_function`, deducing `this`, `std::jthread` with `std::stop_token` | Compiles with no warnings and runs. `__cpp_lib_generator` 202207, `__cpp_lib_print` 202406, `__cpp_lib_expected` 202211, `__cpp_lib_move_only_function` 202110. `__cpp_lib_senders` is undefined, so `std::execution` is not available (matches plan §0). |
| `/proc/sys/kernel/io_uring_disabled` | 0 (unprivileged io_uring allowed). Read only. |
| `ulimit -r` | 0 (no real-time priority for ordinary threads). |
| `/proc/sys/kernel/perf_event_paranoid` | 2. Read only. |
| Kernel | 7.2 (major.minor only). |
| `docker --version` | Docker version 29.9.1. Upstream moby has 29.9.2 (`docker-v29.9.2`); host version is recorded, not changed. |
| `docker compose version` | Docker Compose version v5.6.0. |
| `skopeo --version` | skopeo 1.22.3 (present; used for the image digests above). |
| C++23 probe through the repo's CMake `release-gcc` settings | A tiny out-of-tree CMake project (Ninja, `g++`, `CMAKE_CXX_STANDARD 23` required, extensions off, `cxx_std_23` on the target) built with the preset's flags `-O2 -g -fno-omit-frame-pointer -DNDEBUG` (CMake adds `-std=c++23`). Compiles and runs; same feature macros as above, `__cpp_lib_senders` undefined. Flags of the preset: Release flags `-O2 -g -fno-omit-frame-pointer -DNDEBUG` for C and C++; `release` uses `clang++`, `release-gcc` uses `g++`, `sanitize` uses `-O1` with the same extras. |
| Deferred to S5 (accepted) | Guest `io_uring_disabled`; guest vPMU (`perf stat -e cycles:u true`); guest Docker Engine version; `docker run` of a ubi10 image and the `io_uring_setup` errno under the default seccomp profile; the UBI 10 GCC 14 compile of the C++23 probe (`<generator>`, `<print>`). S5's acceptance picks these up. |

### Hold re-check and decisions (2026-10-23)

| Component | Held at | Latest stable found 2026-10-23 | Status / decision |
|---|---|---|---|
| CPython 3.14 | 3.14.8 (until S4) | 3.14.9 (python.org, 2026-10-21) | **User decision 2026-10-23: promote to 3.14.9** (python-build-standalone `20261021`, which ships both the GIL and the free-threaded builds). S4 pins `examples/.python-version` as `3.14.9+gil` and the free-threaded lane as `cpython-3.14.9+freethreaded`; neither file is changed in S0. The old hold reason (no standalone build of 3.14.9) is resolved. Fedora 44 stable is still 3.14.8 (Bodhi), so the system `python3.14` stays 3.14.8 until it updates; uv-managed 3.14.9 is the pin source. |
| CPython 3.15 | not used | 3.15.1 (3.15 GA 2026-10-09; endoflife.date) | **Held by user decision 2026-10-23.** The book targets 3.14, and wheel support (`pyhdrh`, `protobuf`) for 3.15 must be checked first. Revisit next iteration. |
| uv | 0.13.0 | 0.13.5 (2026-10-22) | **User runs `uv self update` themselves.** The new version will be recorded here after they do; until then 0.13.0 is the recorded version and nothing in the repo is pinned to 0.13.5. |
| Temurin 25 | 25.0.5+8 | 25.0.5+8 (Adoptium API, built 2026-10-22) | Current; SHA256 `68982529869257d0ee6b824ec5aa270ff8b118bb438670da0b97ebdab178d7fb` matches the r02 pin. No hold. |

### Findings that change the r04 plan

- Plan §2 item 2: C++ `hardware_concurrency()` does not follow the cpuset. glibc `get_nprocs()` reads the online-CPU list, so `--cpuset-cpus=2,3` leaves it at the guest's 4; only Python `process_cpu_count()` and Java give 2. Under `--cpus=2` C++ is 4, Python `process_cpu_count()` is 4 and Java is 2 (as the plan has it).
- Quarkus: the event-loop count is `max(2, min(heap MiB / 10, CPUs))` (1 x CPUs, floor 2, heap-capped), and the default worker pool is 200 on a small host, so the Ch12 pool of 16 must be set in config.
- Ch12 assert 5 as written could never pass at default settings: Vert.x warns only after `quarkus.vertx.max-event-loop-execute-time` (2 s), so a 2 ms block gives 0 warnings. The plan now sets that key to `1ms` and a short check period in the defect variant.
- Quarkus 3.40.1.1 is the stable LTS pin; the sibling 3.33.1 is two minors behind the 3.33 LTS head and one LTS behind.
- Docker's default seccomp does block `io_uring_*` (Engine 25.0 onward), as the plan assumed.
- ubi10 AppStream GCC is 14.3.1, at least 14; there is no `ubi10/python-314` image.
- The CPython 3.14.9 hold is resolved by the user's decision to promote in S4; 3.15.1 is held.

## Holds

| Component | Held at | Latest stable | Reason | Re-check |
|---|---|---|---|---|
| CPython | 3.14.8 (promotion to 3.14.9 decided 2026-10-23, applied in r04 S4) | 3.14.9 (python.org, released 2026-10-21 13:08 UTC) | Resolved: python-build-standalone `20261021` now ships 3.14.9 (GIL and free-threaded), and the user decided on 2026-10-23 to promote. Until S4 changes `examples/.python-version` (to `3.14.9+gil`) the repo stays on 3.14.8; Fedora 44 still ships 3.14.8. | S4 |
| CPython 3.15 | not used | 3.15.1 (3.15 GA 2026-10-09) | User decision 2026-10-23: held. The book targets 3.14 and wheel support (`pyhdrh`, `protobuf`) for 3.15 needs checking. | next iteration |
| uv | 0.13.0 on this host | 0.13.5 (2026-10-22) | User-local tool, not changed by the build. The user runs `uv self update` themselves; the new version is recorded here after they do. | after the user's update |
| JDK 27 (non-LTS) | not used | 27 GA (2026-09-15, Temurin 27.0.0+35); jdk.java.net/27 lists 27.0.1.0.2 as the current update (checked 2026-10-22) | Base is LTS 25 (Q1); libraries certify LTS | JDK 28 GA, or next LTS (JDK 29) |
| JDK 28 / Valhalla EA, jextract EA | not used | EA only | Prerelease policy (Q2) | JDK 28 GA (~2027-03); GA jextract |
| GraalVM CE 25 Innovation | not pinned | graal-25.4.4.1.1 | Prose only (Q3) | only if native-image is ever run in an example |

## S5 additions (2026-10-24): container image toolchain

Pins used only inside the Ch13 Containerfiles (`examples/13-where-code-runs/containers/`). The base images are the UBI 10 rows in "Images (UBI, newest first)" above; the index digests were re-checked on 2026-10-24 with `skopeo inspect --raw` (sha256 of the manifest list equals the pinned digest for both `ubi10/ubi:10.2-1792744468` and `ubi10/ubi-minimal:10.2-1792742351`). Nothing here is installed on the host.

| Component | Pinned version | Licence | Source queried | Checksum | Notes |
|---|---|---|---|---|---|
| CMake (upstream binary, builder stage only) | 4.4.4 | BSD-3-Clause | `gh api repos/Kitware/CMake/releases/latest` (v4.4.4, prerelease=false); `https://github.com/Kitware/CMake/releases/download/v4.4.4/cmake-4.4.4-linux-x86_64.tar.gz` | SHA256 `e5bb807f7728cb60cd8b27ebc97a2edb469b68655f21e844a600c3575b76f5bb` (GitHub asset digest; equal to the line in `cmake-4.4.4-SHA-256.txt`) | UBI 10 AppStream (public repo metadata, 2026-10-24) carries `cmake` 3.31.8-1.el10 only; the repo needs 4.3 or later (`cmake_minimum_required(VERSION 4.3)`). |
| Ninja (upstream binary, builder stage only) | 1.13.2 | Apache-2.0 | `gh api repos/ninja-build/ninja/releases/latest` (v1.13.2, prerelease=false); asset `ninja-linux.zip` | SHA256 `5749cbc4e668273514150a80e387a957f933c6ed3f5f11e03fb30955e2bbead6` (GitHub asset digest) | `ninja-build` is in none of UBI 10 BaseOS, AppStream or CodeReady Builder (public repo metadata, 2026-10-24). |
| Apache Maven (builder stage only) | 3.9.16 | Apache-2.0 | Maven Central `maven-metadata.xml` for `org.apache.maven:apache-maven` (newest 3.9.x); `https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.16/apache-maven-3.9.16-bin.tar.gz` | SHA256 `80ffca22aed9e8b9713a232f3394fd81d7f20322df75efdb2b047dbd3e3a23bb` (computed from the downloaded file, 9278065 bytes; Central's `.sha512` is `831a8591...6f6`) | Latest stable 3.9 line. Maven 4.0.0 is only at `4.0.0-rc-7` (2026-10-01), a prerelease, not used. The POMs require `[3.9,)`. |
| uv (upstream static binary, python image) | 0.13.0 | Apache-2.0 OR MIT | `gh api repos/astral-sh/uv/releases/tags/0.13.0`; asset `uv-x86_64-unknown-linux-musl.tar.gz` | SHA256 `b0828fc4cdc47d65951e94b5f0a15a5364420e8dcd88723f3b21e7a2eb30bbc3` (GitHub asset digest) | Same uv version as the host (see the hold table: 0.13.5 exists, the user updates uv themselves). It installs the CPython named by `examples/.python-version` (3.14.8 GIL build until uv can see 3.14.9). |
| GCC, libstdc++ (UBI 10 AppStream/BaseOS) | 14.3.1-4.4.el10 | GPL-3.0-or-later WITH GCC-exception-3.1 | public UBI 10 repository metadata, 2026-10-24 | n/a (dnf's own signatures) | Unchanged from the Images note: at least 14, so `<generator>` and `<print>` exist. |

The same versions are in `versions.env` (`CMAKE_*`, `NINJA_*`, `MAVEN_*`, `UV_*`) and repeated as `ARG` defaults in the Containerfiles.
