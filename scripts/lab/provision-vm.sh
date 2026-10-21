#!/usr/bin/env bash
#
# provision-vm.sh — provision the Fedora 44 KVM guest for the low-latency lab.
#
#   ./provision-vm.sh lowlat-target          # the lab guest
#   ./provision-vm.sh lowlat-peer            # optional 2nd host (LAB_PEER=1 to manage it)
#   RENDER_ONLY=1 ./provision-vm.sh lowlat-target   # print the cloud-init user-data and exit
#
# Refuses any name not starting with 'lowlat-'. Refuses to clobber an existing
# domain; run ./destroy-vm.sh <name> first for a clean rebuild.
#
# Requires (host): virt-install, qemu-img, cloud-localds, libvirtd running, your
# user in the `libvirt` group (or wrap via `sg libvirt -c '...'`).
#
# Downloads the Fedora Cloud Base qcow2 once into ~/.cache, verifies its sha256
# (BASE_SHA256 in lab.env), then layers a per-VM overlay disk so re-provisioning
# is cheap and the base stays pristine.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

VM_NAME="${1:?usage: provision-vm.sh <vm-name>  (e.g. ${LAB_PREFIX}-target)}"
guard_name "$VM_NAME"

if [[ "${RENDER_ONLY:-0}" = "1" ]]; then
  render_user_data "$VM_NAME" "$SSH_PUBKEY"
  exit 0
fi

# ---- Pre-flight -------------------------------------------------------------
command -v virt-install >/dev/null || die "virt-install not found (dnf install virt-install)"
command -v cloud-localds >/dev/null || die "cloud-localds not found (dnf install cloud-utils)"
command -v qemu-img >/dev/null || die "qemu-img not found (dnf install qemu-img)"
[[ -f "$SSH_PUBKEY" ]] || die "no SSH public key at $SSH_PUBKEY — generate one: ssh-keygen -t ed25519"
case "$BASE_IMG$BASE_SHA256" in
  *TODO*) die "BASE_IMG / BASE_SHA256 in lab.env still hold the TODO(S0) placeholder — fill them from the S0 survey" ;;
  *) ;;
esac
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  die "domain '$VM_NAME' already exists — run ./destroy-vm.sh $VM_NAME first"
fi

mkdir -p "$LAB_CACHE"

# ---- Base image -------------------------------------------------------------
step "ensuring Fedora ${FEDORA_VER} Cloud Base image is cached and verified"
if [[ ! -f "$LAB_CACHE/$BASE_IMG" ]]; then
  warn "downloading $BASE_IMG from $BASE_URL"
  curl -fL --retry 3 -o "$LAB_CACHE/$BASE_IMG" "$BASE_URL/$BASE_IMG"
fi
if [[ "$(sha256_of "$LAB_CACHE/$BASE_IMG")" != "$BASE_SHA256" ]]; then
  die "sha256 mismatch for $LAB_CACHE/$BASE_IMG (expected $BASE_SHA256) — delete it and retry, or fix lab.env"
fi
ok "base image present and sha256 verified: $LAB_CACHE/$BASE_IMG"

# ---- Per-VM overlay disk ----------------------------------------------------
step "creating ${DISK_GB}G overlay disk for $VM_NAME"
OVERLAY="$LAB_CACHE/${VM_NAME}.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$LAB_CACHE/$BASE_IMG" "$OVERLAY" "${DISK_GB}G"
ok "overlay: $OVERLAY"

# ---- cloud-init seed --------------------------------------------------------
step "building cloud-init seed for $VM_NAME"
TMP_USERDATA="$(mktemp)"
trap 'rm -f "$TMP_USERDATA"' EXIT
render_user_data "$VM_NAME" "$SSH_PUBKEY" > "$TMP_USERDATA"
SEED="$LAB_CACHE/${VM_NAME}-seed.img"
cloud-localds "$SEED" "$TMP_USERDATA" "$LAB_DIR/cloud-init/meta-data"
ok "seed: $SEED"

# ---- Boot the domain --------------------------------------------------------
step "starting domain $VM_NAME ($VCPUS vCPU / ${RAM_MB}MB / ${DISK_GB}G) on network '$NETWORK'"
virt-install \
  --name "$VM_NAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --cpu host-passthrough \
  --import \
  --disk "path=$OVERLAY,format=qcow2,bus=virtio" \
  --disk "path=$SEED,device=cdrom" \
  --os-variant fedora-unknown \
  --network "network=$NETWORK,model=virtio" \
  --graphics none \
  --noautoconsole

ok "domain $VM_NAME created"
echo
echo "Wait for cloud-init (a few minutes: it installs Docker and the RT toolset), then:"
echo "    $SCRIPT_DIR/vm-ip.sh $VM_NAME"
echo "confirm it's ready (expect 'lab-ready: ok'):"
echo "    $SCRIPT_DIR/lab-ssh.sh $VM_NAME cat /var/log/lab-ready"
echo "then snapshot the tooled baseline:"
echo "    $SCRIPT_DIR/snapshot-vm.sh $VM_NAME"
