#!/usr/bin/env bash
# build-r05-snapshots.sh - create the three r05 lane snapshots of the lab guest, all with the r05
# vCPU pins (PIN_MAP=r05: vCPU 2 -> host CPU 12, vCPU 3 -> host CPU 13).
#
#   ./build-r05-snapshots.sh [vm]        # default lowlat-target
#
#   lab-ready-r05-rt     from lab-ready-rt: guest tools (stress-ng, strace, perf, rtla, Temurin),
#                        the pins, RT kernel, no isolation
#   lab-ready-r05-stock  from lab-ready-r05-rt: the pinned stock kernel (LAB_STOCK_KERNEL) made the
#                        default boot entry, profile stock-r05, rebooted
#   lab-ready-r05-iso    from lab-ready-r05-rt: tuned cpu-partitioning (isolated_cores=2-3) and the
#                        isolate-cpu23 profile, rebooted
#
# The order matters. The pins are libvirt domain configuration and a snapshot captures the domain XML,
# so the pins have to be in place before the first r05 snapshot is taken, and the other two start from
# that snapshot (never from lab-ready, which boots the cloud image's 6.19 kernel). Each snapshot is
# verified with check-prereqs.sh --vm --r05 <lane> before it is taken. The script ends by checking
#   1. that reverting to lab-ready-r04 still gives an unpinned domain (no <cputune>); if it doesn't,
#      the pins are removed again, the guest is cycled, and the script exits non-zero;
#   2. that the XML of every r05 snapshot (virsh snapshot-dumpxml) has both vcpupins;
# then it reverts to lab-ready-r05-rt and shuts the guest down (lab-down.sh).
# Idempotent: it always starts from lab-ready-rt and replaces snapshots of the same name, so a re-run
# rebuilds all three. Prints `virsh list --all` before and after. Acts only on the one lowlat-* domain
# (the name guard runs before the first virsh call); no other domain is touched. Guest and lab-domain
# configuration only: nothing on the host changes. Any failure stops the script with the guest left
# as it was, for inspection.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=../../versions.env
. "$SCRIPT_DIR/../../versions.env"
VM="${1:-${TARGET_VM:-${LAB_PREFIX}-target}}"
guard_name "$VM"
export TARGET_VM="$VM"     # lab-down.sh and check-prereqs.sh read it
PREREQS="$SCRIPT_DIR/../check-prereqs.sh"
DEST="$(ssh_dest "$VM")"
# shellcheck disable=SC2029  # callers expand on the client by design
gssh() { ssh "${SSH_OPTS[@]}" "$DEST" "$@"; }

R05_SNAPSHOTS=(lab-ready-r05-rt lab-ready-r05-stock lab-ready-r05-iso)

virsh dominfo "$VM" >/dev/null 2>&1 || die "no such domain: $VM"
for s in lab-ready-rt lab-ready-r04; do
  virsh snapshot-info "$VM" "$s" >/dev/null 2>&1 || die "no snapshot '$s' on $VM (virsh snapshot-list $VM)"
done
step "virsh list --all (before)"
virsh list --all

# revert <snapshot>: revert (resets the guest clock) and make sure ssh answers.
revert() {
  step "reverting $VM to $1"
  "$SCRIPT_DIR/revert-vm.sh" "$VM" "$1"
  "$SCRIPT_DIR/lab-up.sh"
  wait_ssh "$VM" || die "cannot reach $VM over vsock after reverting to $1"
}
# take <lane> <snapshot>: verify the lane, then snapshot.
take() {
  step "verifying lane $1 before snapshot $2"
  "$PREREQS" --vm --r05 "$1" || die "check-prereqs.sh --vm --r05 $1 failed; not taking $2"
  "$SCRIPT_DIR/snapshot-vm.sh" "$VM" "$2"
}

# ---- 1. lab-ready-r05-rt -------------------------------------------------------------------------
revert lab-ready-rt
"$SCRIPT_DIR/install-guest-tools.sh" "$VM"
PIN_MAP=r05 "$SCRIPT_DIR/pin-vcpu.sh" "$VM"
uv="$(gssh uname -v)"
[[ "$uv" == *PREEMPT_RT* ]] || die "lab-ready-rt is not running the PREEMPT_RT kernel: $uv"
take rt lab-ready-r05-rt

# ---- 2. lab-ready-r05-stock ----------------------------------------------------------------------
revert lab-ready-r05-rt
step "making the $LAB_STOCK_KERNEL stock entry the default boot entry"
# By BLS id, as install-rt-kernel.sh does: grubby --set-default silently does nothing when /boot is
# a btrfs subvolume (Fedora Cloud) unless it's given the /boot/loader/entries path.
# shellcheck disable=SC2029  # expands on the client by design
id="$(gssh "sudo ls /boot/loader/entries/ | grep -F -- '-$LAB_STOCK_KERNEL.x86_64.conf' | grep -v lowlatrt | sed 's/\\.conf\$//'")"
[[ -n "$id" && "$id" != *$'\n'* ]] || die "expected one BLS entry for the stock $LAB_STOCK_KERNEL kernel, got: '${id:-none}'"
# shellcheck disable=SC2029
gssh "sudo grub2-set-default '$id' && sudo grub2-editenv list | grep saved_entry"
"$SCRIPT_DIR/apply-guest-profile.sh" stock-r05 "$VM"
kr="$(gssh uname -r)"; uv="$(gssh uname -v)"
[[ "$kr" == "$LAB_STOCK_KERNEL.x86_64" ]] || die "stock lane runs $kr, expected $LAB_STOCK_KERNEL.x86_64"
[[ "$uv" != *PREEMPT_RT* ]] || die "stock lane runs a PREEMPT_RT kernel: $uv"
take stock lab-ready-r05-stock

# ---- 3. lab-ready-r05-iso ------------------------------------------------------------------------
revert lab-ready-r05-rt
"$SCRIPT_DIR/apply-guest-tuned.sh" "$VM"
"$SCRIPT_DIR/apply-guest-profile.sh" isolate-cpu23 "$VM"
iso="$(gssh cat /sys/devices/system/cpu/isolated)"; nz="$(gssh cat /sys/devices/system/cpu/nohz_full)"
[[ "$iso" == 2-3 ]] || die "/sys/devices/system/cpu/isolated is '$iso', expected 2-3"
[[ "$nz" == 2-3 ]] || die "/sys/devices/system/cpu/nohz_full is '$nz', expected 2-3"
take iso lab-ready-r05-iso

# ---- 4. final checks -----------------------------------------------------------------------------
FAILED=0
has_cputune() {
  local x
  for x in "" "--inactive"; do
    # shellcheck disable=SC2086  # $x is empty or one flag
    virsh dumpxml "$VM" $x | grep -q '<cputune>' && return 0
  done
  return 1
}
step "lab-ready-r04 must still revert to an unpinned domain"
revert lab-ready-r04
if has_cputune; then
  warn "the domain has a <cputune> after reverting to lab-ready-r04: removing the pins and cycling $VM"
  PIN_MAP=r05 "$SCRIPT_DIR/pin-vcpu.sh" --remove "$VM"
  "$SCRIPT_DIR/lab-down.sh"
  "$SCRIPT_DIR/lab-up.sh"
  if has_cputune; then warn "the domain is STILL pinned; fix it by hand (virsh dumpxml $VM)"; else warn "the domain is unpinned again; the lab-ready-r04 snapshot itself carries a <cputune>, so retake it (README, 'The ordinary VM')"; fi
  FAILED=1
else
  ok "lab-ready-r04 reverts to an unpinned domain (no <cputune>)"
fi

step "every r05 snapshot must carry vCPU 2 -> 12 and vCPU 3 -> 13"
for s in "${R05_SNAPSHOTS[@]}"; do
  sx="$(virsh snapshot-dumpxml "$VM" "$s")"
  if grep -Eq "<vcpupin vcpu=.2. cpuset=.12." <<<"$sx" && grep -Eq "<vcpupin vcpu=.3. cpuset=.13." <<<"$sx"; then
    ok "$s: vcpupin 2 -> 12 and 3 -> 13 in the snapshot XML"
  else
    warn "$s: the snapshot XML lacks one of the two vcpupins"; FAILED=1
  fi
done

revert lab-ready-r05-rt
"$SCRIPT_DIR/lab-down.sh"
step "virsh list --all (after)"
virsh list --all
virsh snapshot-list "$VM"
(( FAILED == 0 )) || die "final checks failed (see the warnings above)"
ok "snapshots ready: ${R05_SNAPSHOTS[*]}; $VM is shut down"
