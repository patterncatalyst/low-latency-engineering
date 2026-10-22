#!/usr/bin/env bash
# destroy-vm.sh — tear a guest all the way down, including its disks.
#   ./destroy-vm.sh lowlat-target
# Refuses any name not starting with 'lowlat-' before any virsh call.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
VM="${1:?usage: destroy-vm.sh <vm-name>}"
guard_name "$VM"
virsh destroy "$VM" 2>/dev/null || true
# --snapshots-metadata: undefine refuses a domain that still has snapshots.
virsh undefine "$VM" --remove-all-storage --nvram --snapshots-metadata 2>/dev/null \
  || virsh undefine "$VM" --snapshots-metadata 2>/dev/null || true
if virsh dominfo "$VM" >/dev/null 2>&1; then
  echo "failed to undefine $VM; see: virsh undefine $VM --snapshots-metadata" >&2
  exit 1
fi
rm -f "${LAB_CACHE:?}/${VM:?}.qcow2" "${LAB_CACHE:?}/${VM:?}-seed.img"
forget_host_key "$VM"
echo "destroyed $VM"
