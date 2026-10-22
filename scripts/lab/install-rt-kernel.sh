#!/usr/bin/env bash
# install-rt-kernel.sh — install the PREEMPT_RT kernel built by build-rt-kernel.sh
# into a lab guest, boot it, and verify it is the running kernel.
#
#   ./install-rt-kernel.sh                  # into <prefix>-target
#   ./install-rt-kernel.sh lowlat-target
#   SNAPSHOT=lab-ready-rt ./install-rt-kernel.sh   # also snapshot once verified
#
# Guest-only: copies the RPMs in over vsock, checks their sha256 against
# SHA256SUMS, installs them next to the matching stock kernel (same version,
# so stock vs RT comparisons differ only in the preemption model), makes the RT
# entry the default and reboots. Nothing on the host changes.
#
# Env: LOWLAT_KERNEL_OUT  directory holding the RPMs (default ~/.cache/lowlat/kernel-rt)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
VM="${1:-${TARGET_VM:-${LAB_PREFIX}-target}}"
guard_name "$VM"
DEST="$(ssh_dest "$VM")"
OUT="${LOWLAT_KERNEL_OUT:-$HOME/.cache/lowlat/kernel-rt}"

core="$(find "$OUT" -maxdepth 1 -name 'kernel-rt-core-[0-9]*.rpm' -printf '%f\n')"
[[ -n "$core" && -f "$OUT/SHA256SUMS" ]] || die "no kernel-rt RPMs + SHA256SUMS in $OUT: run build-rt-kernel.sh first"
rt_nvr="${core#kernel-rt-core-}"; rt_nvr="${rt_nvr%.rpm}"     # 7.2.11-200.lowlatrt.fc44.x86_64
stock="kernel-${rt_nvr/.lowlatrt/}"; stock="${stock%.x86_64}"   # kernel-7.2.11-200.fc44
(cd "$OUT" && sha256sum --quiet -c SHA256SUMS) || die "sha256 mismatch in $OUT"
ok "RPMs verified: $rt_nvr (stock counterpart $stock)"

wait_ssh "$VM" || die "cannot reach $VM over vsock"
step "copying RPMs into $VM"
ssh "${SSH_OPTS[@]}" "$DEST" 'rm -rf ~/kernel-rt && mkdir -p ~/kernel-rt'
scp -q "${SSH_OPTS[@]}" "$OUT"/kernel-rt*.rpm "$OUT/SHA256SUMS" "$OUT/BUILDINFO" "$DEST:kernel-rt/"

step "installing $stock and the RT kernel in $VM"
# The default boot entry is set by its BLS id: grubby mis-resolves paths when
# /boot is a btrfs subvolume (Fedora Cloud), so --set-default silently no-ops.
# shellcheck disable=SC2029  # $stock expands on the client by design
ssh "${SSH_OPTS[@]}" "$DEST" "set -e
  cd ~/kernel-rt && sha256sum --quiet -c SHA256SUMS
  sudo dnf -y -q install $stock ./kernel-rt*.rpm
  id=\$(sudo ls /boot/loader/entries/ | grep -F lowlatrt | sed 's/\\.conf\$//')
  sudo grub2-set-default \"\$id\"
  sudo grub2-editenv list | grep saved_entry"

step "rebooting $VM into the RT kernel"
ssh "${SSH_OPTS[@]}" "$DEST" 'sudo systemctl reboot' >/dev/null 2>&1 || true
sleep 5
wait_ssh "$VM" || die "$VM did not come back after reboot: console with virsh console $VM, or revert-vm.sh $VM"

# Mainline PREEMPT_RT has no /sys/kernel/realtime; uname -v and the running
# kernel's config are the evidence.
ver="$(ssh "${SSH_OPTS[@]}" "$DEST" 'uname -rv')"
cfg="$(ssh "${SSH_OPTS[@]}" "$DEST" 'grep -x CONFIG_PREEMPT_RT=y /boot/config-$(uname -r)' || true)"
[[ "$ver" == *lowlatrt*PREEMPT_RT* && "$cfg" == CONFIG_PREEMPT_RT=y ]] \
  || die "RT kernel is not the running kernel: $ver"
ok "running: $ver"
ssh "${SSH_OPTS[@]}" "$DEST" 'docker info >/dev/null 2>&1' || die "Docker daemon not up on the RT kernel"
ok "Docker daemon up on the RT kernel"

if [[ -n "${SNAPSHOT:-}" ]]; then
  "$SCRIPT_DIR/snapshot-vm.sh" "$VM" "$SNAPSHOT"
fi
