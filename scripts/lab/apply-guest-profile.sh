#!/usr/bin/env bash
# apply-guest-profile.sh - apply (or remove) a versioned kernel-argument profile in the
# lab guest, reboot it, and verify /proc/cmdline.
#
#   ./apply-guest-profile.sh                       # isolate-cpu3 on lowlat-target
#   ./apply-guest-profile.sh --remove              # take the profile's arguments off again
#   ./apply-guest-profile.sh stock-unpinned        # strip isolation arguments from the stock entry
#   ./apply-guest-profile.sh [--remove] [profile [vm]]
#
# The profile is scripts/lab/guest-profiles/<profile>.conf. It sets
#   PROFILE_ARGS       kernel arguments to put on the entry (may be empty)
#   PROFILE_ENTRY      "rt" (default): the PREEMPT_RT entry; "stock": the stock Fedora entry
#   PROFILE_DENY_KEYS  argument names (before any "=") that must NOT be on the entry; any such
#                      argument not named in PROFILE_ARGS is removed when the profile is applied
# Arguments go on the chosen boot entry only (grubby --update-kernel=<its index> --args/--remove-args);
# the other entry keeps its command line. A profile with empty PROFILE_ARGS (stock-unpinned) only
# strips the denied arguments. The guest must already be running the kernel of PROFILE_ENTRY
# (revert to lab-ready or lab-ready-rt first). grubby --set-default is not used (it silently does
# nothing on Fedora Cloud's btrfs /boot); the default entry stays as it was.
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
PROFILE_ARGS="${PROFILE_ARGS:-}"
PROFILE_ENTRY="${PROFILE_ENTRY:-rt}"
PROFILE_DENY_KEYS="${PROFILE_DENY_KEYS:-}"
case "$PROFILE_ENTRY" in rt | stock) ;; *) die "$CONF: PROFILE_ENTRY must be rt or stock" ;; esac
[[ -n "$PROFILE_ARGS$PROFILE_DENY_KEYS" ]] || die "$CONF sets neither PROFILE_ARGS nor PROFILE_DENY_KEYS"
DEST="$(ssh_dest "$VM")"
# shellcheck disable=SC2029  # callers expand on the client by design
gssh() { ssh "${SSH_OPTS[@]}" "$DEST" "$@"; }

wait_ssh "$VM" || die "cannot reach $VM over vsock (scripts/lab/lab-up.sh)"
# Address the entry by its grubby INDEX: on Fedora Cloud's btrfs /boot grubby spells kernel paths
# /boot/boot/vmlinuz-..., and --update-kernel rejects both that and the real /boot/vmlinuz-... path.
if [[ "$PROFILE_ENTRY" == rt ]]; then
  ENTRY="$(gssh "sudo grubby --info=ALL | awk -F'[=\"]' '/^index=/ { i = \$2 } /^kernel=.*lowlatrt/ { print i; exit }'")"
  [[ "$ENTRY" =~ ^[0-9]+$ ]] || die "no PREEMPT_RT kernel installed in $VM (SNAPSHOT=lab-ready-rt scripts/lab/install-rt-kernel.sh)"
else
  ENTRY="$(gssh "sudo grubby --info=ALL | awk -F'[=\"]' '/^index=/ { i = \$2 } /^kernel=/ && !/lowlatrt/ && !/rescue/ { print i; exit }'")"
  [[ "$ENTRY" =~ ^[0-9]+$ ]] || die "no stock kernel entry found in $VM"
  running_kernel="$(gssh uname -r)"
  [[ "$running_kernel" != *lowlatrt* ]] || die "$VM runs the PREEMPT_RT kernel ($running_kernel); revert to lab-ready first (scripts/lab/revert-vm.sh $VM lab-ready)"
fi
step "$MODE profile $PROFILE (args: '${PROFILE_ARGS:-none}', deny: '${PROFILE_DENY_KEYS:-none}') on the $PROFILE_ENTRY boot entry $ENTRY in $VM"

# present: every profile argument is on the boot entry's args; absent: none is.
entry_args() { gssh "sudo grubby --info=$ENTRY | sed -n 's/^args=\"\\(.*\\)\"\$/\\1/p'"; }
has_all() { local a; for a in $PROFILE_ARGS; do [[ " $1 " == *" $a "* ]] || return 1; done; }
has_none() { local a; for a in $PROFILE_ARGS; do [[ " $1 " != *" $a "* ]] || return 1; done; }
# denied <args>: the arguments whose name is in PROFILE_DENY_KEYS and that PROFILE_ARGS does not set.
denied() {
  local a k d
  for a in $1; do
    k="${a%%=*}"
    for d in $PROFILE_DENY_KEYS; do
      [[ "$k" == "$d" && " $PROFILE_ARGS " != *" $a "* ]] && echo "$a"
    done
  done
  return 0
}

cur="$(entry_args)"
if [[ "$MODE" == apply ]]; then
  if has_all "$cur" && [[ -z "$(denied "$cur")" ]]; then ok "boot entry already matches the profile"; else
    if ! has_all "$cur" && [[ -n "$PROFILE_ARGS" ]]; then
      # shellcheck disable=SC2029  # expands on the client by design
      gssh "sudo grubby --update-kernel=$ENTRY --args='$PROFILE_ARGS'"
    fi
    strip="$(denied "$cur" | tr '\n' ' ')"
    if [[ -n "${strip% }" ]]; then
      # shellcheck disable=SC2029
      gssh "sudo grubby --update-kernel=$ENTRY --remove-args='${strip% }'"
    fi
  fi
else
  if has_none "$cur"; then ok "boot entry has none of the profile arguments"; else
    rm_args=""; for a in $PROFILE_ARGS; do rm_args+="$a "; done
    # shellcheck disable=SC2029
    gssh "sudo grubby --update-kernel=$ENTRY --remove-args='${rm_args% }'"
  fi
fi
new="$(entry_args)"
if [[ "$MODE" == apply ]]; then
  has_all "$new" && [[ -z "$(denied "$new")" ]] || die "grubby did not persist the profile: $new"
else has_none "$new" || die "grubby did not remove the arguments: $new"; fi
ok "boot entry args: $new"

running="$(gssh cat /proc/cmdline)"
want_ok() {
  if [[ "$MODE" == apply ]]; then has_all "$1" && [[ -z "$(denied "$1")" ]]; else has_none "$1"; fi
}
if want_ok "$running"; then
  ok "running kernel already matches; no reboot needed"
else
  step "rebooting $VM"
  gssh 'sudo systemctl reboot' >/dev/null 2>&1 || true
  sleep 5
  wait_ssh "$VM" 100 || die "$VM did not come back: virsh console $VM, or scripts/lab/revert-vm.sh $VM <snapshot>"
  running="$(gssh cat /proc/cmdline)"
  want_ok "$running" || die "/proc/cmdline does not match after reboot: $running"
fi
ok "/proc/cmdline: $running"
uv="$(gssh uname -v)"
if [[ "$PROFILE_ENTRY" == rt ]]; then
  [[ "$uv" == *PREEMPT_RT* ]] || die "running kernel is not PREEMPT_RT: $uv"
else
  [[ "$uv" != *PREEMPT_RT* ]] || die "running kernel is PREEMPT_RT, expected the stock kernel: $uv"
fi
ok "uname -v: $uv"
