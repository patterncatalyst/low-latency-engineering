#!/usr/bin/env bash
# build-inner.sh - the container half of ../build-rt-kernel.sh. Runs as root inside the
# throwaway fedora:44 container, with this directory mounted read-only at /kernel and the
# host output directory at /out. Environment from the caller: KERNEL_NVR, KERNEL_BUILDID,
# FEDORA_IMAGE, REUSE, HOST_UID, HOST_GID. The final chown hands the files to the host user.
set -euo pipefail
exec > >(tee -a /out/build.log) 2>&1
echo "== start $(date -u +%FT%TZ)"
dnf -y install fedora-packager rpmdevtools dnf-plugins-core cpio
if [[ $REUSE != 1 ]]; then
  mkdir -p /root/rpmbuild/{SOURCES,SPECS,SRPMS,RPMS,BUILD}
  cd /root/rpmbuild/SRPMS
  dnf download --source "$KERNEL_NVR"
  srpms=(./*.src.rpm)
  SRPM=${srpms[0]}
  rpm -i "$SRPM"
  SPEC=/root/rpmbuild/SPECS/kernel.spec
  dnf -y builddep "$SPEC"
  # Still required with the rt flavour (re-tested 2026-10-21 in a fresh fedora:44
  # container: sha512hmac fails with "Allocation of hmac(sha512) cipher failed").
  # The spec FIPS-signs vmlinuz with sha512hmac, which needs the kernel AF_ALG
  # socket API; the default Docker seccomp profile blocks it. Rather than weaken the container, use an openssl equivalent
  # (same key and output format as hmaccalc/libkcapi). The .hmac files only matter
  # to FIPS-mode boots, which this lab kernel does not use.
  cat > /usr/local/bin/sha512hmac <<'SHIM'
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
if [[ -z $CFG ]]; then
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
