#!/usr/bin/env bash
# deploy-to-vm.sh — rsync the repo's examples/ and scripts/ into the lab guest.
#
#   ./deploy-to-vm.sh                       # to <prefix>-target:~/low-latency-engineering/
#   ./deploy-to-vm.sh lowlat-target         # explicit guest
#   REMOTE_DIR=/home/fedora/ll ./deploy-to-vm.sh
#
# Build on the host or in the guest as the example's README says; numbers
# measured in the guest are labelled `vm` and are never compared with
# bare-metal numbers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
VM="${1:-${TARGET_VM:-${LAB_PREFIX}-target}}"
guard_name "$VM"
command -v rsync >/dev/null || die "rsync not found on the host (dnf install rsync)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${GUEST_USER}/low-latency-engineering}"
IP="$(vm_ip "$VM")"

for d in examples scripts; do
  [[ -d "$REPO_ROOT/$d" ]] || die "missing $REPO_ROOT/$d"
done

echo "→ syncing examples/ and scripts/ to ${GUEST_USER}@${IP}:${REMOTE_DIR}"
# shellcheck disable=SC2029  # REMOTE_DIR is meant to expand on the client
ssh "${SSH_OPTS[@]}" "${GUEST_USER}@${IP}" "mkdir -p '${REMOTE_DIR}'"
rsync -az --delete \
  -e "ssh ${SSH_OPTS[*]}" \
  --exclude '.git' --exclude 'target/' --exclude 'build/' --exclude '__pycache__' --exclude '.venv' \
  "$REPO_ROOT/examples" "$REPO_ROOT/scripts" \
  "${GUEST_USER}@${IP}:${REMOTE_DIR}/"
echo "deployed to $VM:$REMOTE_DIR"
