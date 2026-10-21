#!/usr/bin/env bash
# check-prereqs.sh - verify the host (or the lab guest with --vm) has what the
# book's examples need. Prints one PASS/WARN/FAIL line per check, a one-line
# install hint under every WARN/FAIL, then a summary. Exit 0 if no FAIL, else 1.
#
# This script only CHECKS. It never installs, never uses sudo, and never starts
# or stops a VM.
#
#   scripts/check-prereqs.sh          # host checks
#   scripts/check-prereqs.sh --vm     # checks inside the lowlat-target guest
#   scripts/check-prereqs.sh -h
set -euo pipefail

# Pinned protoc version: read from versions.env (provenance in _plans/dependency-pins.md).
# shellcheck source=../versions.env
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/versions.env"

LOWLAT_PREFIX="${LOWLAT_PREFIX:-$HOME/.cache/lowlat/prefix}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_SSH="$SCRIPT_DIR/lab/lab-ssh.sh"
LAB_VM="${TARGET_VM:-lowlat-target}"
MIN_CMAKE="4.3"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_0=""
fi

N_PASS=0; N_WARN=0; N_FAIL=0

usage() {
  cat <<'USAGE'
Usage: check-prereqs.sh [--vm] [-h|--help]

  (no flag)   check the host: OS, C++23 toolchain, CMake, JDK 25, Maven,
              Python 3.14, uv, pinned protoc, Docker Engine, KVM/libvirt,
              perf, jq, rsync, SSH key
  --vm        check the lab guest (lowlat-target) over SSH instead: PREEMPT_RT
              kernel, cyclictest, ptp4l, phc2sys, tuned, docker, readiness marker
  -h, --help  show this help

Output is one PASS/WARN/FAIL line per check; WARN and FAIL lines carry an
install hint. Exit status is 0 when nothing FAILed, 1 otherwise.
Environment: LOWLAT_PREFIX (default ~/.cache/lowlat/prefix), NO_COLOR.
USAGE
}

# record <PASS|WARN|FAIL> <label> <detail> [hint]
record() {
  local status="$1" label="$2" detail="$3" hint="${4:-}" color
  case "$status" in
    PASS) N_PASS=$((N_PASS + 1)); color="$C_G" ;;
    WARN) N_WARN=$((N_WARN + 1)); color="$C_Y" ;;
    *)    N_FAIL=$((N_FAIL + 1)); color="$C_R"; status="FAIL" ;;
  esac
  printf '%s[%s]%s %-28s %s\n' "$color" "$status" "$C_0" "$label" "$detail"
  if [[ "$status" != PASS && -n "$hint" ]]; then
    printf '       hint: %s\n' "$hint"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# version_ge <have> <want>: true when have >= want (dotted versions).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

first_version() { grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true; }

# need_tool <label> <cmd> <severity> <install-hint>: presence check only.
need_tool() {
  local label="$1" cmd="$2" sev="$3" hint="$4"
  if have "$cmd"; then
    record PASS "$label" "$(command -v "$cmd")"
  else
    record "$sev" "$label" "not found" "$hint"
  fi
}

check_os() {
  local id="" ver="" pretty=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    { . /etc/os-release; id="${ID:-}"; ver="${VERSION_ID:-}"; pretty="${PRETTY_NAME:-}"; }
  fi
  if [[ "$id" == fedora && "$ver" == 44 ]]; then
    record PASS "OS" "$pretty"
  else
    record WARN "OS" "${pretty:-unknown}" "the book targets Fedora 44; package names and kernel features may differ"
  fi
}

# cxx_std23 <compiler>: compile and run a tiny <print> program with -std=c++23.
cxx_std23() {
  local cxx="$1" dir rc=0
  dir="$(mktemp -d)"
  printf '#include <print>\nint main() { std::println("ok {}", 23); }\n' >"$dir/t.cpp"
  if "$cxx" -std=c++23 -o "$dir/t" "$dir/t.cpp" >/dev/null 2>&1 && "$dir/t" >/dev/null 2>&1; then
    rc=0
  else
    rc=1
  fi
  rm -rf "$dir"
  return "$rc"
}

check_cxx() {
  local cxx pkg ver
  for cxx in clang++ g++; do
    pkg="gcc-c++"; [[ "$cxx" == clang++ ]] && pkg="clang"
    if ! have "$cxx"; then
      record FAIL "$cxx" "not found" "sudo dnf install $pkg"
      continue
    fi
    ver="$("$cxx" --version 2>&1 | first_version)"
    if cxx_std23 "$cxx"; then
      record PASS "$cxx -std=c++23" "$ver, <print> compiles and runs"
    else
      record FAIL "$cxx -std=c++23" "$ver, cannot build a <print> program" "sudo dnf upgrade $pkg libstdc++-devel (need GCC 14+ headers)"
    fi
  done
}

check_cmake() {
  local ver
  if ! have cmake; then
    record FAIL "cmake >= $MIN_CMAKE" "not found" "sudo dnf install cmake"
  else
    ver="$(cmake --version 2>&1 | first_version)"
    if [[ -n "$ver" ]] && version_ge "$ver" "$MIN_CMAKE"; then
      record PASS "cmake >= $MIN_CMAKE" "$ver"
    else
      record FAIL "cmake >= $MIN_CMAKE" "${ver:-unknown}" "sudo dnf upgrade cmake"
    fi
  fi
  need_tool "ninja" ninja FAIL "sudo dnf install ninja-build"
}

check_java() {
  local jv mv
  if ! have java; then
    record FAIL "java 25" "not found" "sudo dnf install java-25-openjdk-devel (or: sdk install java 25-tem)"
    jv=""
  else
    jv="$(java -version 2>&1 | first_version)"
    if [[ "$jv" == 25.* || "$jv" == 25 ]]; then
      record PASS "java 25" "$jv"
    else
      record FAIL "java 25" "${jv:-unknown}" "sudo dnf install java-25-openjdk-devel and select it with: sudo alternatives --config java"
    fi
  fi
  if ! have mvn; then
    record FAIL "mvn" "not found" "sudo dnf install maven (or: sdk install maven)"
  else
    mv="$(mvn -v 2>&1 | sed -n 's/^Java version: *\([0-9][0-9.]*\).*/\1/p' | head -n1)"
    if [[ "$mv" == 25* ]]; then
      record PASS "mvn runs on java 25" "Java $mv"
    else
      record WARN "mvn runs on java 25" "Maven uses Java ${mv:-unknown}${jv:+, java is $jv}" "export JAVA_HOME to the JDK 25 directory so mvn and java agree"
    fi
  fi
}

check_python() {
  local v
  if have python3.14; then
    v="$(python3.14 --version 2>&1 | first_version)"
    record PASS "python3.14" "$v"
  else
    record FAIL "python3.14" "not found" "sudo dnf install python3.14 (or: uv python install 3.14)"
  fi
  need_tool "uv" uv FAIL "sudo dnf install uv (or: curl -LsSf https://astral.sh/uv/install.sh | sh)"
}

check_protoc() {
  local pbin="$LOWLAT_PREFIX/bin/protoc" v sysv
  if [[ -x "$pbin" ]]; then
    v="$("$pbin" --version 2>&1 | first_version)"
    if [[ "$v" == "$PROTOBUF_VERSION" ]]; then
      record PASS "pinned protoc $PROTOBUF_VERSION" "$pbin ($v)"
    else
      record WARN "pinned protoc $PROTOBUF_VERSION" "$pbin is $v" "rebuild: scripts/deps/build-protobuf.sh"
    fi
  else
    record WARN "pinned protoc $PROTOBUF_VERSION" "missing: $pbin" "run scripts/deps/build-protobuf.sh"
  fi
  if [[ -x /usr/bin/protoc ]]; then
    sysv="$(/usr/bin/protoc --version 2>&1 | first_version)"
    if [[ "$sysv" != "$PROTOBUF_VERSION" ]]; then
      record WARN "system protoc" "/usr/bin/protoc is $sysv, must not be used" "the build ignores PATH protoc and uses $LOWLAT_PREFIX/bin/protoc; do not install protobuf-compiler"
    else
      record PASS "system protoc" "/usr/bin/protoc is $sysv"
    fi
  fi
}

in_group() {
  # Active in this session (id -nG) is what counts for device access.
  local groups
  groups=" $(id -nG) "
  [[ "$groups" == *" $1 "* ]]
}

check_group() {
  local g="$1"
  if in_group "$g"; then
    record PASS "group $g" "$USER is a member"
  elif [[ ",$(getent group "$g" | cut -d: -f4)," == *",$USER,"* ]]; then
    record FAIL "group $g" "member, but not active in this session" "log out and back in (or: newgrp $g)"
  else
    record FAIL "group $g" "$USER is not a member" "sudo usermod -aG $g $USER, then log out and back in"
  fi
}

check_docker() {
  local ctx sv cv
  if ! have docker; then
    record FAIL "docker" "not found" "sudo dnf install docker-ce docker-ce-cli docker-compose-plugin (Docker Engine, not Desktop)"
    return
  fi
  ctx="$(docker context show 2>/dev/null || true)"
  if [[ "$ctx" == desktop-linux ]]; then
    record FAIL "docker context" "desktop-linux (Docker Desktop)" "docker context use default; the book uses Docker Engine only"
  else
    record PASS "docker context" "${ctx:-default}"
  fi
  if sv="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" && [[ -n "$sv" ]]; then
    record PASS "docker engine" "server $sv"
  else
    record FAIL "docker engine" "daemon not reachable" "sudo systemctl enable --now docker && sudo usermod -aG docker $USER, then re-login"
  fi
  if cv="$(docker compose version --short 2>/dev/null)" && [[ -n "$cv" ]]; then
    record PASS "docker compose" "$cv"
  else
    record FAIL "docker compose" "plugin missing" "sudo dnf install docker-compose-plugin"
  fi
}

check_virt() {
  if [[ -e /dev/kvm ]]; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
      record PASS "/dev/kvm" "accessible"
    else
      record FAIL "/dev/kvm" "exists, no read/write access" "sudo usermod -aG kvm $USER, then re-login"
    fi
  else
    record FAIL "/dev/kvm" "missing" "enable VT-x/AMD-V in firmware; sudo modprobe kvm_intel (or kvm_amd)"
  fi
  check_group libvirt
  check_group kvm
  if have virsh; then
    local netinfo
    netinfo="$(virsh -c qemu:///system net-info default 2>/dev/null || true)"
    if grep -Eq '^Active:[[:space:]]+yes' <<<"$netinfo"; then
      record PASS "libvirt network default" "active"
    else
      record FAIL "libvirt network default" "not active or libvirtd unreachable" "sudo systemctl enable --now libvirtd && sudo virsh net-start default && sudo virsh net-autostart default"
    fi
  else
    record FAIL "virsh" "not found" "sudo dnf install libvirt-client libvirt-daemon-kvm"
  fi
  need_tool "virt-install" virt-install FAIL "sudo dnf install virt-install"
  need_tool "qemu-img" qemu-img FAIL "sudo dnf install qemu-img"
  need_tool "cloud-localds" cloud-localds FAIL "sudo dnf install cloud-utils"
}

check_misc() {
  need_tool "perf" perf WARN "sudo dnf install perf"
  need_tool "jq" jq FAIL "sudo dnf install jq"
  need_tool "rsync" rsync FAIL "sudo dnf install rsync"
  if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    record PASS "ssh key" "$HOME/.ssh/id_ed25519.pub"
  else
    record FAIL "ssh key" "missing" "ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519"
  fi
}

run_host() {
  printf 'Host prerequisites (protoc pin %s, prefix %s)\n' "$PROTOBUF_VERSION" "$LOWLAT_PREFIX"
  check_os
  check_cxx
  check_cmake
  check_java
  check_python
  check_protoc
  check_docker
  check_virt
  check_misc
}

# vm <command...>: run a command in the guest via the lab ssh wrapper.
vm() { timeout 30 "$LAB_SSH" "$LAB_VM" "$@" 2>/dev/null; }

vm_need() {
  local cmd="$1" pkg="$2"
  if vm "command -v $cmd" >/dev/null; then
    record PASS "guest: $cmd" "present"
  else
    record FAIL "guest: $cmd" "not found in guest" "sudo dnf install $pkg in the guest (or re-provision: scripts/lab/provision-vm.sh $LAB_VM)"
  fi
}

run_vm() {
  local state uv rt ready
  printf 'Lab guest prerequisites (%s)\n' "$LAB_VM"
  if ! have virsh; then
    record FAIL "guest reachable" "virsh not found" "sudo dnf install libvirt-client"
    return
  fi
  state="$(virsh -c qemu:///system domstate "$LAB_VM" 2>/dev/null || true)"
  if [[ "$state" != running ]]; then
    record FAIL "guest running" "${state:-domain not defined}" "scripts/lab/lab-up.sh (first time: scripts/lab/provision-vm.sh $LAB_VM)"
    return
  fi
  if ! vm true; then
    record FAIL "guest ssh" "cannot reach $LAB_VM" "scripts/lab/lab-up.sh, then wait for cloud-init to finish"
    return
  fi
  record PASS "guest ssh" "$LAB_VM reachable"

  uv="$(vm uname -v || true)"
  rt="$(vm cat /sys/kernel/realtime || true)"
  if [[ "$uv" == *PREEMPT_RT* && "$rt" == 1 ]]; then
    record PASS "guest RT kernel" "PREEMPT_RT, /sys/kernel/realtime = 1"
  else
    record FAIL "guest RT kernel" "uname -v: ${uv:-?}; realtime=${rt:-?}" "S13 RT kernel not installed yet"
  fi
  vm_need cyclictest realtime-tests
  vm_need ptp4l linuxptp
  vm_need phc2sys linuxptp
  vm_need tuned-adm tuned
  if vm "docker version --format '{{.Server.Version}}'" >/dev/null; then
    record PASS "guest: docker" "daemon reachable"
  else
    record FAIL "guest: docker" "daemon not reachable" "in the guest: sudo systemctl enable --now docker"
  fi
  ready="$(vm cat /var/log/lab-ready || true)"
  if [[ "$ready" == *ok* ]]; then
    record PASS "guest lab-ready" "$ready"
  else
    record FAIL "guest lab-ready" "${ready:-/var/log/lab-ready missing}" "wait for cloud-init, or re-provision: scripts/lab/provision-vm.sh $LAB_VM"
  fi
}

main() {
  local mode=host
  while (($#)); do
    case "$1" in
      --vm) mode=vm ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  if [[ "$mode" == vm ]]; then run_vm; else run_host; fi
  printf '\nSummary: %d PASS, %d WARN, %d FAIL\n' "$N_PASS" "$N_WARN" "$N_FAIL"
  ((N_FAIL == 0))
}

main "$@"
