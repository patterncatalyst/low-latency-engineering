#!/usr/bin/env bash
# lab-status.sh — state, IP, readiness marker and snapshots of the lab guest(s).
#   ./lab-status.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
set_lab_vms
for VM in "${LAB_VMS[@]}"; do
  if ! virsh dominfo "$VM" >/dev/null 2>&1; then echo "$VM: not defined"; continue; fi
  state="$(virsh domstate "$VM" 2>/dev/null || echo unknown)"
  echo "$VM: $state"
  [[ "$state" = "running" ]] || continue
  if ip="$(vm_ip "$VM" 2>/dev/null)"; then
    echo "  ip:    $ip"
    echo "  ready: $(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${GUEST_USER}@${ip}" 'head -1 /var/log/lab-ready' 2>/dev/null || echo 'unreachable')"
  else
    echo "  ip:    no lease yet"
  fi
  virsh snapshot-list "$VM" --name 2>/dev/null | sed '/^$/d; s/^/  snapshot: /'
done
