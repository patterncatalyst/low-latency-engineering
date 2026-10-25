#!/usr/bin/env bash
# revert-vm.sh — restore a lab guest to a snapshot (default: lab-ready).
#   ./revert-vm.sh lowlat-target                 # revert to "lab-ready"
#   ./revert-vm.sh lowlat-target lab-ready-rt    # revert to a named snapshot
#
# Use this to undo destructive demos (kernel parameter changes, isolcpus, RT
# kernel swaps), or to get back to a clean tooled baseline. Reverting to a
# running-state snapshot restores it running.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
VM="${1:?usage: revert-vm.sh <vm-name> [snapshot-name]}"
SNAP="${2:-lab-ready}"
guard_name "$VM"
virsh snapshot-info "$VM" "$SNAP" >/dev/null 2>&1 \
  || { echo "no snapshot '$SNAP' on $VM — list with: virsh snapshot-list $VM" >&2; exit 1; }
virsh snapshot-revert "$VM" "$SNAP"
echo "$VM reverted to snapshot '$SNAP'"

# A running-state snapshot also restores the guest's clock as it was when the snapshot was taken,
# minutes to days behind. chronyd would only slew it back slowly (and right after the revert it still
# trusts its old estimate, so `chronyc makestep` does nothing), and meanwhile every file synced from
# the host looks like it is from the future (ninja then refuses to build: "manifest still dirty"),
# and guest timestamps in results are wrong. So set the guest clock from the host's over ssh (good to
# about a second), then ask chronyd for fresh measurements so it disciplines from there.
if [ "$(virsh domstate "$VM" 2>/dev/null)" = running ]; then
  skew=unknown
  for _ in $(seq 1 30); do
    if guest_now=$("$SCRIPT_DIR/lab-ssh.sh" "$VM" "sudo date -u -s @$(date +%s) >/dev/null && (sudo chronyc -a burst 4/4 >/dev/null 2>&1 || true) && date +%s" 2>/dev/null); then
      skew=$(( guest_now - $(date +%s) ))
      [ "${skew#-}" -le 5 ] && break
    fi
    sleep 2
  done
  case "$skew" in
    unknown) echo "could not reach $VM over ssh to set its clock; run: scripts/lab/lab-ssh.sh $VM 'sudo date -u -s @<host epoch>'" >&2; exit 1 ;;
  esac
  [ "${skew#-}" -le 5 ] || { echo "guest clock still ${skew}s off the host after setting it" >&2; exit 1; }
  echo "$VM clock set from the host (guest minus host: ${skew}s)"
fi
