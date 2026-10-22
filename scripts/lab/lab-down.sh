#!/usr/bin/env bash
# lab-down.sh — gracefully shut down the lab guest(s) so nothing is left running.
#   ./lab-down.sh            # ACPI shutdown of <prefix>-target (and -peer if LAB_PEER=1)
#   FORCE=1 ./lab-down.sh    # hard power-off any guest that ignores the ACPI request
#
# Run this when you're done. It does NOT delete anything — disks and snapshots
# survive; bring the lab back with ./lab-up.sh. It only ever touches 'lowlat-*'.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
set_lab_vms

for VM in "${LAB_VMS[@]}"; do
  virsh dominfo "$VM" >/dev/null 2>&1 || { echo "skip $VM (not defined)"; continue; }
  state="$(virsh domstate "$VM" 2>/dev/null || echo unknown)"
  if [[ "$state" != "running" ]]; then echo "$VM already $state"; continue; fi
  echo "shutting down $VM ..."
  virsh shutdown "$VM" >/dev/null 2>&1 || true
done

echo "waiting up to 60s for graceful shutdown ..."
for ((i = 0; i < 60; i++)); do
  running=0
  for VM in "${LAB_VMS[@]}"; do
    [[ "$(virsh domstate "$VM" 2>/dev/null || true)" = "running" ]] && running=1
  done
  [[ "$running" = 0 ]] && break
  sleep 1
done

for VM in "${LAB_VMS[@]}"; do
  [[ "$(virsh domstate "$VM" 2>/dev/null || true)" = "running" ]] || continue
  if [[ "${FORCE:-0}" = "1" ]]; then
    echo "forcing off $VM"; virsh destroy "$VM" >/dev/null 2>&1 || true
  else
    echo "WARNING: $VM still running (guest ignored ACPI). Re-run with FORCE=1 to power it off." >&2
  fi
done

virsh list --all
