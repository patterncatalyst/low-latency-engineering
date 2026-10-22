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
