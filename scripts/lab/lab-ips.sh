#!/usr/bin/env bash
# lab-ips.sh — print the IPs of the lab guest(s), ready to eval.
#   eval "$(./lab-ips.sh)"   # exports TARGET_IP (and PEER_IP when LAB_PEER=1)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
set_lab_vms
tip="$(vm_ip "${LAB_VMS[0]}" 2>/dev/null || true)"
echo "export TARGET_IP=${tip}"
if [[ "$LAB_PEER" = "1" ]]; then
  pip="$(vm_ip "${LAB_VMS[1]}" 2>/dev/null || true)"
  echo "export PEER_IP=${pip}"
fi
