#!/usr/bin/env bash
# apply-guest-profile.sh - apply (or remove) a versioned kernel-argument profile in the
# lab guest, reboot it, and verify /proc/cmdline.
#
#   ./apply-guest-profile.sh                       # isolate-cpu3 on lowlat-target
#   ./apply-guest-profile.sh --remove              # take the profile's arguments off again
#   ./apply-guest-profile.sh [--remove] [profile [vm]]
#
# The profile is scripts/lab/guest-profiles/<profile>.conf (PROFILE_ARGS). The arguments go on
# the PREEMPT_RT boot entry only (grubby --update-kernel=<its index> --args/--remove-args);
# the stock entry keeps its command line. grubby --set-default is not used (it silently does
# nothing on Fedora Cloud's btrfs /boot); the default entry stays as install-rt-kernel.sh set it.
# Idempotent: when the entry already matches, nothing is changed and the guest is not rebooted
# (unless the running /proc/cmdline disagrees). Guest-only: nothing on the host changes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODE=apply
if [[ "${1:-}" == --remove ]]; then MODE=remove; shift; fi
PROFILE="${1:-isolate-cpu3}"
VM="${2:-${TARGET_VM:-${LAB_PREFIX}-target}}"
guard_name "$VM"
CONF="$SCRIPT_DIR/guest-profiles/$PROFILE.conf"
[[ -f "$CONF" ]] || die "no such profile: $CONF"
# shellcheck source=guest-profiles/isolate-cpu3.conf
. "$CONF"
[[ -n "${PROFILE_ARGS:-}" ]] || die "$CONF sets no PROFILE_ARGS"
DEST="$(ssh_dest "$VM")"
# shellcheck disable=SC2029  # callers expand on the client by design
gssh() { ssh "${SSH_OPTS[@]}" "$DEST" "$@"; }

wait_ssh "$VM" || die "cannot reach $VM over vsock (scripts/lab/lab-up.sh)"
# Address the RT entry by its grubby INDEX: on Fedora Cloud's btrfs /boot grubby spells kernel paths
# /boot/boot/vmlinuz-..., and --update-kernel rejects both that and the real /boot/vmlinuz-... path.
RTK="$(gssh "sudo grubby --info=ALL | awk -F'[=\"]' '/^index=/ { i = \$2 } /^kernel=.*lowlatrt/ { print i; exit }'")"
[[ "$RTK" =~ ^[0-9]+$ ]] || die "no PREEMPT_RT kernel installed in $VM (SNAPSHOT=lab-ready-rt scripts/lab/install-rt-kernel.sh)"
step "$MODE profile $PROFILE ($PROFILE_ARGS) on boot entry $RTK in $VM"

# present: every profile argument is on the boot entry's args; absent: none is.
entry_args() { gssh "sudo grubby --info=$RTK | sed -n 's/^args=\"\\(.*\\)\"\$/\\1/p'"; }
has_all() { local a; for a in $PROFILE_ARGS; do [[ " $1 " == *" $a "* ]] || return 1; done; }
has_none() { local a; for a in $PROFILE_ARGS; do [[ " $1 " != *" $a "* ]] || return 1; done; }

cur="$(entry_args)"
if [[ "$MODE" == apply ]]; then
  if has_all "$cur"; then ok "boot entry already has the profile"; else
    # shellcheck disable=SC2029  # expands on the client by design
    gssh "sudo grubby --update-kernel=$RTK --args='$PROFILE_ARGS'"
  fi
else
  if has_none "$cur"; then ok "boot entry has none of the profile arguments"; else
    rm_args=""; for a in $PROFILE_ARGS; do rm_args+="$a "; done
    # shellcheck disable=SC2029
    gssh "sudo grubby --update-kernel=$RTK --remove-args='${rm_args% }'"
  fi
fi
new="$(entry_args)"
if [[ "$MODE" == apply ]]; then has_all "$new" || die "grubby did not persist the arguments: $new"
else has_none "$new" || die "grubby did not remove the arguments: $new"; fi
ok "boot entry args: $new"

running="$(gssh cat /proc/cmdline)"
want_ok() { if [[ "$MODE" == apply ]]; then has_all "$running"; else has_none "$running"; fi; }
if want_ok; then
  ok "running kernel already matches; no reboot needed"
else
  step "rebooting $VM"
  gssh 'sudo systemctl reboot' >/dev/null 2>&1 || true
  sleep 5
  wait_ssh "$VM" 100 || die "$VM did not come back: virsh console $VM, or scripts/lab/revert-vm.sh $VM lab-ready-rt"
  running="$(gssh cat /proc/cmdline)"
  want_ok || die "/proc/cmdline does not match after reboot: $running"
fi
ok "/proc/cmdline: $running"
uv="$(gssh uname -v)"
[[ "$uv" == *PREEMPT_RT* ]] || die "running kernel is not PREEMPT_RT: $uv"
ok "uname -v: $uv"
