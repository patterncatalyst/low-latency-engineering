#!/usr/bin/env bash
# apply-guest-tuned.sh - switch the lab guest to tuned's cpu-partitioning profile (or back to
# virtual-guest), reboot it, and verify the result.
#
#   ./apply-guest-tuned.sh                 # cpu-partitioning, isolated_cores=2-3, on lowlat-target
#   ./apply-guest-tuned.sh --remove        # back to virtual-guest
#   ./apply-guest-tuned.sh [--remove] [vm]
#
# The variables file is scripts/lab/tuned/cpu-partitioning-variables.conf (isolated_cores=2-3).
# It is copied to /etc/tuned/ in the guest, then `tuned-adm profile cpu-partitioning` runs; tuned's
# bootloader plugin writes nohz=on nohz_full=2-3 rcu_nocbs=2-3 (and a few more) into the boot entry,
# and its systemd plugin sets CPUAffinity=0 1. After the reboot the script checks
#   /proc/cmdline         has nohz_full=2-3 and rcu_nocbs=2-3
#   tuned-adm active      reports cpu-partitioning
#   systemd CPUAffinity   is 0 1 (system.conf, and PID 1's actual affinity mask)
# --remove runs `tuned-adm profile virtual-guest`, deletes the variables file, reboots, and checks
# that the nohz_full / rcu_nocbs arguments are gone and virtual-guest is active.
# It does not add isolcpus or irqaffinity: guest-profiles/isolate-cpu23.conf does, through
# apply-guest-profile.sh. Idempotent: when the guest already matches, nothing changes and it isn't
# rebooted. Guest-only: nothing on the host changes. Revert to a snapshot to undo it as well.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODE=apply
if [[ "${1:-}" == --remove ]]; then MODE=remove; shift; fi
VM="${1:-${TARGET_VM:-${LAB_PREFIX}-target}}"
guard_name "$VM"
VARS="$SCRIPT_DIR/tuned/cpu-partitioning-variables.conf"
[[ -f "$VARS" ]] || die "no such file: $VARS"
DEST="$(ssh_dest "$VM")"
# shellcheck disable=SC2029  # callers expand on the client by design
gssh() { ssh "${SSH_OPTS[@]}" "$DEST" "$@"; }

wait_ssh "$VM" || die "cannot reach $VM over vsock (scripts/lab/lab-up.sh)"
gssh 'test -d /usr/lib/tuned/profiles/cpu-partitioning || test -d /usr/lib/tuned/cpu-partitioning' ||
  die "tuned-profiles-cpu-partitioning is not installed in $VM"

# state_ok: the running guest already matches the wanted mode (prints nothing; returns 0 or 1).
state_ok() {
  local cmd active
  cmd="$(gssh cat /proc/cmdline)"
  active="$(gssh 'tuned-adm active' || true)"
  if [[ "$MODE" == apply ]]; then
    [[ " $cmd " == *" nohz_full=2-3 "* && " $cmd " == *" rcu_nocbs=2-3 "* ]] &&
      [[ "$active" == *"cpu-partitioning" ]] &&
      gssh 'cmp -s /etc/tuned/cpu-partitioning-variables.conf /dev/stdin' <"$VARS"
  else
    [[ " $cmd " != *" nohz_full="* && " $cmd " != *" rcu_nocbs="* ]] &&
      [[ "$active" == *"virtual-guest" ]] &&
      ! gssh 'test -e /etc/tuned/cpu-partitioning-variables.conf'
  fi
}

step "$MODE tuned cpu-partitioning (isolated_cores=2-3) in $VM"
if state_ok; then
  ok "guest already matches; no change, no reboot"
else
  if [[ "$MODE" == apply ]]; then
    scp -q "${SSH_OPTS[@]}" "$VARS" "$DEST:cpu-partitioning-variables.conf"
    gssh 'set -e
      sudo install -m 0644 cpu-partitioning-variables.conf /etc/tuned/cpu-partitioning-variables.conf
      rm -f cpu-partitioning-variables.conf
      sudo tuned-adm profile cpu-partitioning'
  else
    gssh 'set -e
      sudo tuned-adm profile virtual-guest
      sudo rm -f /etc/tuned/cpu-partitioning-variables.conf'
  fi
  step "rebooting $VM"
  gssh 'sudo systemctl reboot' >/dev/null 2>&1 || true
  sleep 5
  wait_ssh "$VM" 100 || die "$VM did not come back: virsh console $VM, or scripts/lab/revert-vm.sh $VM <snapshot>"
fi

cmd="$(gssh cat /proc/cmdline)"
active="$(gssh 'tuned-adm active' || true)"
if [[ "$MODE" == apply ]]; then
  for a in nohz_full=2-3 rcu_nocbs=2-3; do
    [[ " $cmd " == *" $a "* ]] || die "/proc/cmdline lacks $a: $cmd"
  done
  [[ "$active" == *"cpu-partitioning" ]] || die "tuned-adm active: ${active:-nothing}"
  aff="$(gssh "grep -rhs '^CPUAffinity=' /etc/systemd/system.conf /etc/systemd/system.conf.d/ | tail -n1")"
  aff="${aff#CPUAffinity=}"; aff="${aff//,/ }"
  [[ "$aff" == "0 1" ]] || die "systemd CPUAffinity is '${aff:-unset}', expected '0 1'"
  mask="$(gssh 'taskset -cp 1')"
  [[ "${mask##*: }" == "0,1" ]] || die "PID 1 affinity is '${mask##*: }', expected 0,1"
  ok "cmdline: $cmd"
  ok "tuned-adm active: $active"
  ok "systemd CPUAffinity: $aff (PID 1 on CPUs ${mask##*: })"
else
  [[ " $cmd " != *" nohz_full="* && " $cmd " != *" rcu_nocbs="* ]] || die "/proc/cmdline still has tuned's arguments: $cmd"
  [[ "$active" == *"virtual-guest" ]] || die "tuned-adm active: ${active:-nothing}"
  ok "cmdline: $cmd"
  ok "tuned-adm active: $active"
fi
