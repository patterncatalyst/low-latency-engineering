#!/usr/bin/env bash
# lab-up.sh — start the lab guest(s) and wait until ssh over vsock answers.
#   ./lab-up.sh
#
# Starts <prefix>-target (and <prefix>-peer when LAB_PEER=1) if defined but not
# running, then waits for sshd over vsock. If a guest isn't defined yet, it tells
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

for VM in "${LAB_VMS[@]}"; do
  virsh dominfo "$VM" >/dev/null 2>&1 || continue
  if wait_ssh "$VM"; then echo "$VM: ssh $(ssh_dest "$VM")  (or $SCRIPT_DIR/lab-ssh.sh $VM)"; fi
done
