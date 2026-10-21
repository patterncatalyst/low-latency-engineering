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
[ -f "$HERE/kernel/preempt-rt.config" ] || { echo "missing $HERE/kernel/preempt-rt.config" >&2; exit 1; }

mkdir -p "$OUT"
REUSE="${LOWLAT_KERNEL_REUSE:-0}"
[ "$REUSE" = 1 ] || rm -f "$OUT"/*.rpm "$OUT"/SHA256SUMS "$OUT"/BUILDINFO
echo "building $KERNEL_NVR$KERNEL_BUILDID in $FEDORA_IMAGE; log: $OUT/build.log"

# Runs as root inside the container; the final chown hands the files to the host user.
# shellcheck disable=SC2016  # the script body is expanded by the container shell, not here
INNER='
set -euo pipefail
exec > >(tee -a /out/build.log) 2>&1
echo "== start $(date -u +%FT%TZ)"
dnf -y install fedora-packager rpmdevtools dnf-plugins-core cpio
if [ "$REUSE" != 1 ]; then
mkdir -p /root/rpmbuild/{SOURCES,SPECS,SRPMS,RPMS,BUILD}
cd /root/rpmbuild/SRPMS
dnf download --source "$KERNEL_NVR"
SRPM="$(ls ./*.src.rpm)"
rpm -i "$SRPM"
SPEC=/root/rpmbuild/SPECS/kernel.spec
dnf -y builddep "$SPEC"
# Still required with the rt flavour (re-tested 2026-10-21 in a fresh fedora:44
# container: sha512hmac fails with "Allocation of hmac(sha512) cipher failed").
# The spec FIPS-signs vmlinuz with sha512hmac, which needs the kernel AF_ALG
# socket API; the default Docker seccomp profile blocks it. Rather than weaken the container, use an openssl equivalent
# (same key and output format as hmaccalc/libkcapi). The .hmac files only matter
# to FIPS-mode boots, which this lab kernel does not use.
cat > /usr/local/bin/sha512hmac <<'"'"'SHIM'"'"'
#!/bin/sh
for f in "$@"; do
  printf "%s  %s\n" "$(openssl dgst -sha512 -hmac orboDeJITITejsirpADONivirpUGroY -r "$f" | cut -d" " -f1)" "$f"
done
SHIM
chmod 0755 /usr/local/bin/sha512hmac
# The spec merges SOURCES/kernel-local into every flavour config.
install -m 0644 /kernel/preempt-rt.config /root/rpmbuild/SOURCES/kernel-local
cd /root/rpmbuild
nice -n 10 rpmbuild -bb --target x86_64 \
  --define "buildid $KERNEL_BUILDID" \
  --define "_smp_mflags -j$(nproc)" \
  --with realtime --with rtonly \
  --without debuginfo --without doc --without perf \
  --without libperf --without tools --without selftests \
  --without headers --without cross_headers --without ynl --without kmap \
  --without kernel_abi_stablelists --without kabichk --without kabidwchk \
  --without efiuki --without dtbloader \
  "$SPEC"
RPMS=/root/rpmbuild/RPMS/x86_64
ls -l "$RPMS"
# Copy the packages a bootable guest needs; devel and the rest are not required.
for p in kernel-rt kernel-rt-core kernel-rt-modules kernel-rt-modules-core kernel-rt-modules-extra; do
  find "$RPMS" -maxdepth 1 -name "$p-[0-9]*.rpm" -exec cp -t /out {} +
done
fi
cd /out
# Verify the produced kernel really is PREEMPT_RT.
CORE="$(find . -maxdepth 1 -name "kernel-rt-core-[0-9]*.rpm" -printf "%f\n")"
CFG="$(rpm2cpio "$CORE" | cpio -i --quiet --to-stdout "./lib/modules/*/config" 2>/dev/null || true)"
if [ -z "$CFG" ]; then
  CFG="$(rpm2cpio "$CORE" | cpio -i --quiet --to-stdout "./boot/config-*" 2>/dev/null || true)"
fi
grep -E "^(# )?CONFIG_(PREEMPT_RT|DEBUG_PREEMPT|PREEMPT|PREEMPT_LAZY|PREEMPT_DYNAMIC|NO_HZ_FULL|RCU_NOCB_CPU|HZ_1000)[= ]" <<<"$CFG"
grep -qx "CONFIG_PREEMPT_RT=y" <<<"$CFG" || { echo "FAIL: CONFIG_PREEMPT_RT=y not in built config" >&2; exit 3; }
echo "verified: CONFIG_PREEMPT_RT=y in $CORE"
sha256sum ./*.rpm > SHA256SUMS
{
  echo "nvr=$(rpm -qp --qf "%{NAME}-%{VERSION}-%{RELEASE}" "$CORE")"
  echo "source_nvr=$KERNEL_NVR"
  echo "buildid=$KERNEL_BUILDID"
  echo "fragment_sha256=$(sha256sum /kernel/preempt-rt.config | cut -d" " -f1)"
  echo "image=$FEDORA_IMAGE"
  echo "built_utc=$(date -u +%FT%TZ)"
} > BUILDINFO
chown -R "$HOST_UID:$HOST_GID" /out
echo "== done $(date -u +%FT%TZ)"
'

start=$(date +%s)
if ! nice -n 10 docker run --rm \
  -v "$HERE/kernel":/kernel:ro,Z \
  -v "$OUT":/out:Z \
  -e KERNEL_NVR="$KERNEL_NVR" -e KERNEL_BUILDID="$KERNEL_BUILDID" \
  -e FEDORA_IMAGE="$FEDORA_IMAGE" -e REUSE="$REUSE" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$FEDORA_IMAGE" bash -c "$INNER"; then
  # Leave the log readable even after a failed run.
  docker run --rm -v "$OUT":/out:Z "$FEDORA_IMAGE" chown -R "$(id -u):$(id -g)" /out || true
  echo "build FAILED; see $OUT/build.log" >&2
  exit 1
fi
echo "OK: $(( $(date +%s) - start )) s; RPMs in $OUT"
cat "$OUT/BUILDINFO"
