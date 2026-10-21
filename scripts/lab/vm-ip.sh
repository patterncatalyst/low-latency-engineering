#!/usr/bin/env bash
# vm-ip.sh — print the IPv4 address libvirt leased to a guest.
#   ./vm-ip.sh lowlat-target
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
VM="${1:?usage: vm-ip.sh <vm-name>}"
guard_name "$VM"
vm_ip "$VM"
