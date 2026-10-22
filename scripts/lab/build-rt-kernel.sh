#!/usr/bin/env bash
# build-rt-kernel.sh - build a PREEMPT_RT Fedora 44 kernel inside a throwaway
# container and leave the RPMs in a host directory.
#
# Why: Fedora 44 does not ship a kernel-rt package, and the stock kernel is built
# with "# CONFIG_PREEMPT_RT is not set". The Fedora kernel SRPM does, however,
# carry its own realtime flavour (kernel-x86_64-rt-fedora.config, enabled with
# `rpmbuild --with realtime`), so the RT kernel is built from Fedora's own spec
# and config, producing kernel-rt* RPMs. The RT chapters then measure a real RT
# kernel in the lab guest.
#
# Fragment: scripts/lab/kernel/preempt-rt.config is merged through the spec's
# kernel-local mechanism. Fedora's rt config already has PREEMPT_RT, PREEMPT,
# NO_HZ_FULL, RCU_NOCB_CPU, RCU_BOOST and HZ_1000; the one setting it lacks for
# a latency kernel is CONFIG_DEBUG_PREEMPT (set to y there), which the fragment
# turns off.
#
# Host-safety guarantee: nothing is installed on the development host and no
# sudo is used. The whole build (dnf, rpmbuild, build dependencies) runs in a
# `docker run --rm` container from a pinned fedora:44 image; the only host
# effects are files under the output directory. This script never installs the
# RPMs; installation happens later, inside the lab guest only.
#
# Usage:  scripts/lab/build-rt-kernel.sh
# Env:    LOWLAT_KERNEL_OUT   output dir (default ~/.cache/lowlat/kernel-rt)
#         KERNEL_NVR          kernel to rebuild (default kernel-7.2.11-200.fc44)
#         KERNEL_BUILDID      RPM release suffix (default .lowlatrt)
#         LOWLAT_KERNEL_REUSE=1  skip the build and only verify, checksum and record
#                             RPMs already in the output dir (after an interrupted run)
#         FEDORA_IMAGE        pinned image reference (default: digest below)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${LOWLAT_KERNEL_OUT:-$HOME/.cache/lowlat/kernel-rt}"
KERNEL_NVR="${KERNEL_NVR:-kernel-7.2.11-200.fc44}"
KERNEL_BUILDID="${KERNEL_BUILDID:-.lowlatrt}"
# Digest pinned in _plans/dependency-pins.md.
FEDORA_IMAGE="${FEDORA_IMAGE:-fedora:44@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80}"

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
[[ -f $HERE/kernel/preempt-rt.config ]] || { echo "missing $HERE/kernel/preempt-rt.config" >&2; exit 1; }
[[ -f $HERE/kernel/build-inner.sh ]] || { echo "missing $HERE/kernel/build-inner.sh" >&2; exit 1; }

mkdir -p "$OUT"
REUSE="${LOWLAT_KERNEL_REUSE:-0}"
[[ $REUSE == 1 ]] || rm -f "$OUT"/*.rpm "$OUT"/SHA256SUMS "$OUT"/BUILDINFO
echo "building $KERNEL_NVR$KERNEL_BUILDID in $FEDORA_IMAGE; log: $OUT/build.log"

start=$(date +%s)
# No nice on docker run: it would only renice the docker CLI. The build is niced inside the
# container, in build-inner.sh.
if ! docker run --rm \
  -v "$HERE/kernel":/kernel:ro,Z \
  -v "$OUT":/out:Z \
  -e KERNEL_NVR="$KERNEL_NVR" -e KERNEL_BUILDID="$KERNEL_BUILDID" \
  -e FEDORA_IMAGE="$FEDORA_IMAGE" -e REUSE="$REUSE" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$FEDORA_IMAGE" bash /kernel/build-inner.sh; then
  # Leave the log readable even after a failed run.
  docker run --rm -v "$OUT":/out:Z "$FEDORA_IMAGE" chown -R "$(id -u):$(id -g)" /out || true
  echo "build FAILED; see $OUT/build.log" >&2
  exit 1
fi
echo "OK: $(( $(date +%s) - start )) s; RPMs in $OUT"
cat "$OUT/BUILDINFO"
