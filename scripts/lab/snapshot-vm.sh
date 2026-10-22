#!/usr/bin/env bash
# snapshot-vm.sh — capture a named snapshot of a lab guest (default: lab-ready).
#   ./snapshot-vm.sh lowlat-target                 # snapshot named "lab-ready"
#   ./snapshot-vm.sh lowlat-target lab-ready-rt    # a differently-named snapshot
#
# Take a snapshot after the guest is fully provisioned + tooled (cloud-init done,
# /var/log/lab-ready says ok) so you can revert to a known-good state in seconds.
# Snapshots of a running guest capture RAM + disk, so a revert restores it running.
#
# Uses the system libvirt instance; if your login shell isn't in the `libvirt`
# group yet, run via: sg libvirt -c '...'.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
VM="${1:?usage: snapshot-vm.sh <vm-name> [snapshot-name]}"
SNAP="${2:-lab-ready}"
guard_name "$VM"
virsh dominfo "$VM" >/dev/null 2>&1 || { echo "no such domain: $VM" >&2; exit 1; }
# Replace an existing snapshot of the same name so re-running is idempotent.
virsh snapshot-delete "$VM" "$SNAP" >/dev/null 2>&1 || true
virsh snapshot-create-as "$VM" "$SNAP" \
  --description "lab snapshot taken $(date -u +%FT%TZ)" --atomic
echo "snapshot '$SNAP' created for $VM"
virsh snapshot-list "$VM"
