#!/usr/bin/env bash
# build-rt-kernel.sh - build a PREEMPT_RT Fedora 44 kernel inside a throwaway
# container and leave the RPMs in a host directory.
#
# Why: Fedora 44 ships no kernel-rt package, and the stock kernel is built with
# "# CONFIG_PREEMPT_RT is not set". PREEMPT_RT has been mainline since 6.12, so
# the same Fedora kernel source builds as an RT kernel with one config fragment
# (scripts/lab/kernel/preempt-rt.config, merged through the spec's kernel-local
# mechanism). The RT chapters then measure a real RT kernel in the lab guest.
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
rm -f "$OUT"/*.rpm "$OUT"/SHA256SUMS "$OUT"/BUILDINFO
echo "building $KERNEL_NVR$KERNEL_BUILDID in $FEDORA_IMAGE; log: $OUT/build.log"

# Runs as root inside the container; the final chown hands the files to the host user.
# shellcheck disable=SC2016  # the script body is expanded by the container shell, not here
INNER='
set -euo pipefail
exec > >(tee -a /out/build.log) 2>&1
echo "== start $(date -u +%FT%TZ)"
dnf -y install fedora-packager rpmdevtools dnf-plugins-core cpio
mkdir -p /root/rpmbuild/{SOURCES,SPECS,SRPMS,RPMS,BUILD}
cd /root/rpmbuild/SRPMS
dnf download --source "$KERNEL_NVR"
SRPM="$(ls ./*.src.rpm)"
rpm -i "$SRPM"
SPEC=/root/rpmbuild/SPECS/kernel.spec
dnf -y builddep "$SPEC"
# The spec FIPS-signs vmlinuz with sha512hmac, which needs the kernel AF_ALG socket
# API; the default Docker seccomp profile blocks it ("Allocation of hmac(sha512)
# cipher failed"). Rather than weaken the container, use an openssl equivalent
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
# configchecks is off because the x86-only fragment is merged into every
# architecture config (s390x, ppc64le) and the checker would reject those; only
# the x86_64 config is built here and it is verified below.
cd /root/rpmbuild
nice -n 10 rpmbuild -bb --target x86_64 \
  --define "buildid $KERNEL_BUILDID" \
  --define "_smp_mflags -j$(nproc)" \
  --with baseonly \
  --without debug --without debuginfo --without doc --without perf \
  --without libperf --without tools --without selftests   --without headers --without cross_headers --without ynl --without kmap \
  --without kernel_abi_stablelists --without kabichk --without kabidwchk \
  --without configchecks --without efiuki --without zfcpdump --without arm64_64k --without dtbloader \
  "$SPEC"
RPMS=/root/rpmbuild/RPMS/x86_64
ls -l "$RPMS"
# Copy the packages a bootable guest needs; devel and the rest are not required.
for p in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
  find "$RPMS" -maxdepth 1 -name "$p-[0-9]*.rpm" -exec cp -t /out {} +
done
cd /out
# Verify the produced kernel really is PREEMPT_RT.
CORE="$(find . -maxdepth 1 -name "kernel-core-[0-9]*.rpm" -printf "%f\n")"
CFG="$(rpm2cpio "$CORE" | cpio -i --quiet --to-stdout "./lib/modules/*/config" 2>/dev/null || true)"
if [ -z "$CFG" ]; then
  CFG="$(rpm2cpio "$CORE" | cpio -i --quiet --to-stdout "./boot/config-*" 2>/dev/null || true)"
fi
echo "$CFG" | grep -E "^(# )?CONFIG_(PREEMPT_RT|PREEMPT|PREEMPT_LAZY|PREEMPT_DYNAMIC|NO_HZ_FULL|RCU_NOCB_CPU|HZ_1000)[= ]"
echo "$CFG" | grep -qx "CONFIG_PREEMPT_RT=y" || { echo "FAIL: CONFIG_PREEMPT_RT=y not in built config" >&2; exit 3; }
echo "verified: CONFIG_PREEMPT_RT=y in $CORE"
sha256sum ./*.rpm > SHA256SUMS
{
  echo "nvr=$KERNEL_NVR$KERNEL_BUILDID"
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
  -e FEDORA_IMAGE="$FEDORA_IMAGE" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$FEDORA_IMAGE" bash -c "$INNER"; then
  # Leave the log readable even after a failed run.
  docker run --rm -v "$OUT":/out:Z "$FEDORA_IMAGE" chown -R "$(id -u):$(id -g)" /out || true
  echo "build FAILED; see $OUT/build.log" >&2
  exit 1
fi
echo "OK: $(( $(date +%s) - start )) s; RPMs in $OUT"
cat "$OUT/BUILDINFO"
