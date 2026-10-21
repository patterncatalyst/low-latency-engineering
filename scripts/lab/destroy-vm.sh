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
virsh undefine "$VM" --remove-all-storage --nvram 2>/dev/null \
  || virsh undefine "$VM" 2>/dev/null || true
rm -f "${LAB_CACHE:?}/${VM:?}.qcow2" "${LAB_CACHE:?}/${VM:?}-seed.img"
forget_host_key "$VM"
echo "destroyed $VM"
