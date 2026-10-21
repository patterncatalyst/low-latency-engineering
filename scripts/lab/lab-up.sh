#!/usr/bin/env bash
# lab-up.sh — start the lab guest(s) and print their IPs.
#   ./lab-up.sh
#   eval "$(./lab-up.sh --export)"   # also export TARGET_IP (and PEER_IP) into your shell
#
# Starts <prefix>-target (and <prefix>-peer when LAB_PEER=1) if defined but not
# running, then waits for DHCP leases. If a guest isn't defined yet, it tells
# you to provision it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
set_lab_vms

for VM in "${LAB_VMS[@]}"; do
  if ! virsh dominfo "$VM" >/dev/null 2>&1; then
    echo "skip $VM (not defined — provision it: $SCRIPT_DIR/provision-vm.sh $VM)" >&2
    continue
  fi
  state="$(virsh domstate "$VM" 2>/dev/null || echo unknown)"
  if [[ "$state" = "running" ]]; then
    echo "$VM already running" >&2
  else
    echo "starting $VM" >&2
    virsh start "$VM" >/dev/null 2>&1 || true
  fi
done

echo "waiting for DHCP leases ..." >&2
for _ in $(seq 1 30); do
  vm_ip "${LAB_VMS[0]}" >/dev/null 2>&1 && break
  sleep 2
done

if [[ "${1:-}" = "--export" ]]; then
  exec "$SCRIPT_DIR/lab-ips.sh"
fi
for VM in "${LAB_VMS[@]}"; do
  if ip="$(vm_ip "$VM" 2>/dev/null)"; then echo "$VM: $ip"; else echo "$VM: no lease yet / not provisioned"; fi
done
