#!/usr/bin/env bash
# install-guest-tools.sh - install the pinned Temurin JDK, stress-ng, strace and perf into the lab guest.
#
#   ./install-guest-tools.sh [vm]        # default lowlat-target
#
# Temurin: the tarball named by TEMURIN_URL / TEMURIN_SHA256 in versions.env is downloaded on the
# host into ~/.cache/lowlat/downloads (sha256-checked), copied over ssh/vsock, checked again in the
# guest and unpacked to /opt/temurin-<TEMURIN_VERSION>. It is made the guest's java and javac by
# `alternatives` (so non-login ssh commands see it) and JAVA_HOME/PATH via /etc/profile.d.
# Fedora's java-25-openjdk stays installed but is no longer selected. stress-ng, strace and perf
# come from dnf, only when absent.
# Idempotent. Guest-only: nothing on the host changes. cloud-init does the same for a rebuilt guest.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=../../versions.env
. "$SCRIPT_DIR/../../versions.env"
VM="${1:-${TARGET_VM:-${LAB_PREFIX}-target}}"
guard_name "$VM"
DEST="$(ssh_dest "$VM")"
# shellcheck disable=SC2029  # callers expand on the client by design
gssh() { ssh "${SSH_OPTS[@]}" "$DEST" "$@"; }

DL="${LOWLAT_DOWNLOADS:-$HOME/.cache/lowlat/downloads}"
mkdir -p "$DL"
tgz="$DL/${TEMURIN_URL##*/}"
if [[ ! -f "$tgz" || "$(sha256_of "$tgz")" != "$TEMURIN_SHA256" ]]; then
  step "downloading ${TEMURIN_URL##*/}"
  curl -fL --retry 3 -o "$tgz.part" "$TEMURIN_URL"
  mv "$tgz.part" "$tgz"
fi
[[ "$(sha256_of "$tgz")" = "$TEMURIN_SHA256" ]] || die "sha256 mismatch for $tgz"
ok "tarball sha256 verified ($TEMURIN_VERSION)"

wait_ssh "$VM" || die "cannot reach $VM over vsock (scripts/lab/lab-up.sh)"
JDK_DIR="/opt/temurin-$TEMURIN_VERSION"
if gssh "test -x $JDK_DIR/bin/java"; then
  ok "$JDK_DIR already in the guest"
else
  step "copying the tarball into $VM"
  scp -q "${SSH_OPTS[@]}" "$tgz" "$DEST:temurin.tar.gz"
  # shellcheck disable=SC2029  # expands on the client by design
  gssh "set -e
    echo '$TEMURIN_SHA256  temurin.tar.gz' | sha256sum --quiet -c -
    sudo mkdir -p $JDK_DIR
    sudo tar -xzf temurin.tar.gz -C $JDK_DIR --strip-components=1
    rm -f temurin.tar.gz"
fi
# shellcheck disable=SC2029
gssh "set -e
  for t in java javac jar jcmd jfr; do
    sudo alternatives --install /usr/bin/\$t \$t $JDK_DIR/bin/\$t 99000
    sudo alternatives --set \$t $JDK_DIR/bin/\$t
  done
  printf 'export JAVA_HOME=$JDK_DIR\\nexport PATH=\$JAVA_HOME/bin:\$PATH\\n' | sudo tee /etc/profile.d/temurin.sh >/dev/null"

step "stress-ng, strace, perf"
gssh 'for p in stress-ng strace perf; do rpm -q "$p" >/dev/null 2>&1 || sudo dnf -y -q install "$p"; done'

jv="$(gssh 'java -version 2>&1')"
[[ "$jv" == *"\"$TEMURIN_VERSION\""* && "$jv" == *Temurin* ]] || die "guest java is not Temurin $TEMURIN_VERSION: $jv"
ok "guest java: $(head -n1 <<<"$jv") ($(grep -o 'Temurin[^ ]*' <<<"$jv" | head -n1))"
ok "stress-ng: $(gssh 'stress-ng --version' | head -n1)"
ok "strace: $(gssh 'strace -V' | head -n1)"
ok "perf: $(gssh 'perf --version' | head -n1)"
