# Ch13 container images (UBI 10)

Three images for the container lanes, built and run only in the lab guest (decision D7: no
container lane on the host). Base images are UBI 10, newest first, each `FROM` pinned to an exact
tag plus the index digest (decision D10; pins in `_plans/dependency-pins.md`). The measured
toolchain is the same as the other lanes: one C++ binary built once, the same Temurin 25.0.5+8, the
same CPython release (`examples/.python-version`).

| Image | Contents | Entry |
|---|---|---|
| `lowlat/place-cpp:r04` | `line-simulator`, `line-consumer` (and the Ch13 and Ch12 binaries when S6/S7 add them to `TARGETS`/`BINARIES`), built with the UBI 10 GCC 14 | none; `container_run` passes the command |
| `lowlat/place-java:r04` | Ch12 Quarkus fast-jar and the Ch13 `CpuProbe` jar, Temurin 25.0.5+8 | `java -jar /app/quarkus-app/quarkus-run.jar` |
| `lowlat/place-py:r04` | uv-managed CPython (GIL build) and `lowlat-place` in `/opt/venv` | `python` |

All run as a non-root user (10001). None uses `latest`, `--privileged` or a subscription.

## Build context

The context is the **repository root**, not `examples/`. The C++ build reads `examples/`,
`contracts/` (the protobuf and flat wire contracts), `versions.env` and
`scripts/deps/build-protobuf.sh`, and the root `.dockerignore` sends only those, minus `build/`,
`target/`, `.venv*` and `results/`. `scripts/lab/deploy-to-vm.sh` copies exactly these into the guest.

## Build and lock

In the guest, from the deployed repository root:

```bash
examples/13-where-code-runs/containers/build-images.sh        # all three; or: cpp | java | python
```

It builds each image with `docker build -f .../Containerfile .` and writes `docker image inspect
--format '{{.Id}}'` into `IMAGES.lock`. The build needs network (Maven Central, GitHub release
tarballs for Boost 1.92.0, liburing, protobuf and the toolchain, PyPI, python-build-standalone);
every download is hash-checked (CMake `URL_HASH`, `versions.env`, the `ARG` sha256 values).

## IMAGES.lock

One line per image: `name:tag@sha256:<image id> <runtime base ref@digest> [builder=<ref@digest>]`.
The first field is what `container_run` (`examples/_lib/lib.sh`) parses: it requires the image it
ran to have that ID and records it as `runtime.environment.container.image_digest`. `sha256:PENDING`
marks an image not built yet. `check-prereqs.sh --vm` compares the guest's images with the lock.

## Toolchain notes

- UBI 10 AppStream ships `cmake` 3.31.8 and no `ninja-build`; the repo needs CMake 4.3 or later,
  so the builder takes the upstream CMake 4.4.4 and Ninja 1.13.2 release binaries (sha256-checked).
- The C++ configure mirrors the `release-gcc` preset (the `release` preset uses clang and a
  host-only `CMAKE_PREFIX_PATH`); the binaries are built by GCC 14 with `-O2 -g -fno-omit-frame-pointer`.
- The runtime image installs `libstdc++` from the UBI 10 BaseOS repository (a no-op if present).
- CPython 3.14.9 (GIL build) is what the image installs: it follows
  `examples/.python-version`, so promoting the other lanes promotes this one.

## Why there is no compose file

`container_run` is the single runner: it creates each container with the lane's own options
(`--cpus`, `--cpuset-cpus`, `--network`, seccomp), samples its cgroup and records the image
digest. A compose file would restate those options a second time, outside the helper that
records them, and could drift from what the report says. The Quarkus service and its client are
started by the Ch13 scripts through `container_run`.

## Production idiom

For a production service, Red Hat's `ubi10/openjdk-25-runtime` is the idiomatic Java base. The
measured lanes do not use it because its JDK build differs from the Temurin the other lanes run.
