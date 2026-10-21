#!/usr/bin/env bash
# lib.sh — shared helpers for the lowlat VM lab scripts. Source it, don't run it.
#
# Provides: config (lab.env), the name guard, vm_ip, render_user_data, and the
# step/ok/warn/die output helpers.

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
# shellcheck source=lab.env
. "$LAB_DIR/lab.env"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; CYN=$'\033[0;36m'; YLW=$'\033[1;33m'; RST=$'\033[0m'
step() { echo "${CYN}━━ $*${RST}"; }
ok()   { echo "${GRN}✓ $*${RST}"; }
warn() { echo "${YLW}⚠ $*${RST}"; }
die()  { echo "${RED}✗ $*${RST}" >&2; exit 1; }

# Name guard. Other projects' guests (ebpf-*, systems-*, ...) share this libvirt
# instance; a wrong LAB_PREFIX or a typo must never reach them. Call this on
# every domain name BEFORE the first virsh call.
guard_name() {
  local name="${1:-}"
  case "$name" in
    "${LAB_GUARD_PREFIX}"?*) ;;
    *) die "refusing '${name}': this lab only acts on domains named '${LAB_GUARD_PREFIX}*' (LAB_PREFIX='${LAB_PREFIX}')" ;;
  esac
}

# set_lab_vms — fill the global LAB_VMS array: target, plus peer when LAB_PEER=1.
# (Not a $(...) function: die must exit the calling script, not a subshell.)
set_lab_vms() {
  local target="${TARGET_VM:-${LAB_PREFIX}-target}" peer="${PEER_VM:-${LAB_PREFIX}-peer}"
  guard_name "$target"
  LAB_VMS=("$target")
  if [[ "$LAB_PEER" = "1" ]]; then guard_name "$peer"; LAB_VMS+=("$peer"); fi
}

# vm_ip <name> — the IPv4 address libvirt leased to the guest.
vm_ip() {
  local vm="$1" ip
  guard_name "$vm"
  ip="$(virsh -q domifaddr "$vm" 2>/dev/null | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')"
  if [[ -z "${ip:-}" ]]; then
    ip="$(virsh -q domifaddr "$vm" --source agent 2>/dev/null | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')"
  fi
  [[ -n "${ip:-}" ]] || { echo "no lease yet for $vm — wait for cloud-init and retry" >&2; return 1; }
  echo "$ip"
}

# render_user_data <hostname> <pubkey-file> — print the cloud-init user-data.
render_user_data() {
  local host="$1" keyfile="$2" key
  [[ -f "$keyfile" ]] || die "no SSH public key at $keyfile — generate one: ssh-keygen -t ed25519"
  key="$(cat "$keyfile")"
  sed -e "s|__HOSTNAME__|${host}|g" \
      -e "s|__SSH_PUBKEY__|${key}|g" \
      "$LAB_DIR/cloud-init/user-data.tmpl"
}

# sha256_of <file> — the bare hex digest.
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# shellcheck disable=SC2034  # used by the scripts that source this file
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$HOME/.ssh/known_hosts")
