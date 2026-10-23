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

## Holds

| Component | Held at | Latest stable | Reason | Re-check |
|---|---|---|---|---|
| CPython | 3.14.8 | 3.14.9 (python.org, released 2026-10-21 13:08 UTC) | No python-build-standalone build of 3.14.9 yet (latest `20261020` ships 3.14.8), so uv cannot provide it; Fedora 44 ships 3.14.8. Promote when a uv-managed 3.14.9 is available; pin it in `examples/.python-version`. | next iteration |
| uv | 0.13.0 on this host | 0.13.4 | User-local tool, not changed by the build; r01 uses no 0.13.4-only feature. `uv self update` is the user's call. | next iteration |
| JDK 27 (non-LTS) | not used | 27 GA (2026-09-15, Temurin 27.0.0+35); jdk.java.net/27 lists 27.0.1.0.2 as the current update (checked 2026-10-22) | Base is LTS 25 (Q1); libraries certify LTS | JDK 28 GA, or next LTS (JDK 29) |
| JDK 28 / Valhalla EA, jextract EA | not used | EA only | Prerelease policy (Q2) | JDK 28 GA (~2027-03); GA jextract |
| GraalVM CE 25 Innovation | not pinned | graal-25.4.4.1.1 | Prose only (Q3) | only if native-image is ever run in an example |
