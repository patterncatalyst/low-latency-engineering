---
title: "Dependency pins"
render_with_liquid: false
description: "Every r01 dependency pinned to its latest stable upstream release, with licence, source and survey date."
---

Surveyed 2026-10-21 against upstream sources (GitHub releases API, Maven Central `maven-metadata.xml`, PyPI JSON API, Fedora download tree, Bodhi, Docker Hub). Prereleases (RC, beta, milestone) were excluded; where one exists it is named in Notes. Every pin is exact.

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
| kernel (Fedora 44 updates) | kernel-7.2.11-200.fc44 (stable 2026-10-17) | Bodhi API; host runs `7.2.11-200.fc44.x86_64`. `dnf -C repoquery` showed 7.2.10-200 only because its cached metadata was stale. | Upstream version 7.2.11. kernel.org lists 7.2.12 as stable and 7.3 as mainline; Fedora has not shipped 7.2.12 yet. |
| rt-tests | 5.0.7-5.fc44 | `dnf -C repoquery --latest-limit 1` | |
| linuxptp | 4.4-10.fc44 via dnf cache; Bodhi shows 4.4-9.fc44 stable | dnf and Bodhi | The two sources disagree by one release; the newer dnf figure may be a cached or testing build. Treat as 4.4. |
| tuned | 2.28.0-1.fc44 | dnf and Bodhi | |

PREEMPT_RT: mainline since 6.12, and the 7.2 tree's `kernel/Kconfig.preempt` defines `config PREEMPT_RT` with `depends on EXPERT && ARCH_SUPPORTS_RT && !COMPILE_TEST`; `arch/x86/Kconfig` at v7.2 has `select ARCH_SUPPORTS_RT`. So it is selectable on x86_64 with no out-of-tree patches. However the stock Fedora kernel does not enable it: `/boot/config-7.2.11-200.fc44.x86_64` has `# CONFIG_PREEMPT_RT is not set` (with `CONFIG_PREEMPT_DYNAMIC=y`, `CONFIG_EXPERT=y`, `CONFIG_ARCH_SUPPORTS_RT=y`), Fedora's `kernel-x86_64-fedora.config` on f44 likewise, and `dnf repoquery kernel-rt` returns nothing. The r01 VM lab therefore needs a locally built RT kernel (a Fedora kernel with `CONFIG_PREEMPT_RT=y`) or a third-party build; this is not determined here and is a plan decision.
