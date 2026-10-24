#!/usr/bin/env bash
# deploy-to-vm.sh — rsync the repo's examples/, scripts/ and contracts/ (plus versions.env and
# .dockerignore, the container build context) into the lab guest.
#
#   ./deploy-to-vm.sh                       # to <prefix>-target:~/low-latency-engineering/
#   ./deploy-to-vm.sh lowlat-target         # explicit guest
#   REMOTE_DIR=ll ./deploy-to-vm.sh   # relative to the guest user's home
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
REMOTE_DIR="${REMOTE_DIR:-low-latency-engineering}" # relative to the guest user's home
DEST="$(ssh_dest "$VM")"

for d in examples scripts contracts; do
  [[ -d "$REPO_ROOT/$d" ]] || die "missing $REPO_ROOT/$d"
done
for f in versions.env .dockerignore; do
  [[ -f "$REPO_ROOT/$f" ]] || die "missing $REPO_ROOT/$f"
done

echo "→ syncing examples/, scripts/, contracts/, versions.env and .dockerignore to ${DEST}:${REMOTE_DIR}"
# shellcheck disable=SC2029  # REMOTE_DIR is meant to expand on the client
ssh "${SSH_OPTS[@]}" "$DEST" "mkdir -p '${REMOTE_DIR}'"
printf -v rsh '%q ' ssh "${SSH_OPTS[@]}"
rsync -az --delete \
  -e "$rsh" \
  --exclude '.git' --exclude 'target/' --exclude 'build/' --exclude '__pycache__' --exclude '.venv' \
  "$REPO_ROOT/examples" "$REPO_ROOT/scripts" "$REPO_ROOT/contracts" \
  "$REPO_ROOT/versions.env" "$REPO_ROOT/.dockerignore" \
  "${DEST}:${REMOTE_DIR}/"
echo "deployed to $VM:$REMOTE_DIR"
