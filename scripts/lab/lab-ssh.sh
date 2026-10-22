#!/usr/bin/env bash
# lab-ssh.sh — ssh into a lab guest (default: <prefix>-target).
#   ./lab-ssh.sh                           # interactive shell on lowlat-target
#   ./lab-ssh.sh lowlat-target cyclictest -V
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
VM="${1:-${TARGET_VM:-${LAB_PREFIX}-target}}"
[[ $# -gt 0 ]] && shift
guard_name "$VM"
exec ssh "${SSH_OPTS[@]}" "$(ssh_dest "$VM")" "$@"
