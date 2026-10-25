#!/usr/bin/env bash
# check-prereqs.sh - verify the host (or the lab guest with --vm) has what the
# book's examples need. Prints one PASS/WARN/FAIL line per check, a one-line
# install hint under every WARN/FAIL, then a summary. Exit 0 if no FAIL, else 1.
#
# This script only CHECKS. It never installs, never uses sudo, and never starts
# or stops a VM.
#
#   scripts/check-prereqs.sh          # host checks
#   scripts/check-prereqs.sh --vm     # checks inside the lowlat-target guest (r04: stock kernel)
#   scripts/check-prereqs.sh --vm --rt   # the same guest on the PREEMPT_RT kernel (r02/r03)
#   scripts/check-prereqs.sh -h
set -euo pipefail

# Pinned protoc version: read from versions.env (provenance in _plans/dependency-pins.md).
# shellcheck source=../versions.env
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/versions.env"

LOWLAT_PREFIX="${LOWLAT_PREFIX:-$HOME/.cache/lowlat/prefix}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_SSH="$SCRIPT_DIR/lab/lab-ssh.sh"
LAB_VM="${TARGET_VM:-lowlat-target}"
IMAGES_LOCK="$SCRIPT_DIR/../examples/13-where-code-runs/containers/IMAGES.lock"
MIN_CMAKE="4.3"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_0=""
fi

N_PASS=0; N_WARN=0; N_FAIL=0

usage() {
  cat <<'USAGE'
Usage: check-prereqs.sh [--vm [--rt]] [-h|--help]

  (no flag)   check the host: OS, C++23 toolchain, CMake, JDK 25, Maven,
              Python 3.14, uv, pinned protoc, Docker Engine, KVM/libvirt,
              perf, async-profiler (optional), jq, rsync, SSH key
  --vm        check the lab guest (lowlat-target) over SSH instead, for the r04
              "ordinary VM" (snapshot lab-ready-r04): pinned stock kernel booted, no
              isolcpus/nohz_full/rcu_nocbs, pinned Temurin, stress-ng, strace, perf,
              cyclictest, ptp4l, phc2sys, tuned (active profile recorded), Docker active
              with the user in the docker group (version recorded), the images in
              examples/13-where-code-runs/containers/IMAGES.lock present with the locked
              digests, io_uring_disabled and the vPMU recorded, vcpupin state
  --rt        with --vm: check the PREEMPT_RT guest instead (lab-ready-rt/-iso): RT kernel
              required; isolation and vcpupin state (info only); no r04 checks
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
  # Output is committed as evidence: show $HOME as ~ so no absolute home path is published.
  detail="${detail//"$HOME"/\~}"
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
# One scratch directory for the compile probes, removed on exit.
scratch() {
  if [[ -z ${SCRATCH:-} ]]; then
    SCRATCH="$(mktemp -d)"
    trap 'rm -rf "$SCRATCH"' EXIT
  fi
}

cxx_std23() {
  local cxx="$1" dir rc=0
  scratch
  dir="$SCRATCH"
  printf '#include <print>\nint main() { std::println("ok {}", 23); }\n' >"$dir/t.cpp"
  if "$cxx" -std=c++23 -o "$dir/t" "$dir/t.cpp" >/dev/null 2>&1 && "$dir/t" >/dev/null 2>&1; then
    rc=0
  else
    rc=1
  fi
  rm -f "$dir/t" "$dir/t.cpp"
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

# HdrHistogram_c compresses the histograms in every report with zlib; its build needs the headers.
check_zlib() {
  local cc
  scratch
  cc=$(command -v clang || command -v gcc || true)
  if [[ -z $cc ]]; then
    record FAIL "zlib headers" "no C compiler to probe with" "sudo dnf install clang zlib-ng-compat-devel"
    return
  fi
  printf '#include <zlib.h>\nint main(void) { return zlibVersion()[0] == 0; }\n' >"$SCRATCH/z.c"
  if "$cc" -o "$SCRATCH/z" "$SCRATCH/z.c" -lz >/dev/null 2>&1 && "$SCRATCH/z"; then
    record PASS "zlib headers" "zlib.h compiles and links (-lz)"
  else
    record FAIL "zlib headers" "zlib.h or libz missing" "sudo dnf install zlib-ng-compat-devel"
  fi
  rm -f "$SCRATCH/z" "$SCRATCH/z.c"
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
      if ! version_ge "$jv" "$TEMURIN_VERSION"; then
        record WARN "java >= pinned Temurin" "$jv is below $TEMURIN_VERSION" "sdk install java ${TEMURIN_VERSION}-tem"
      fi
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
    record PASS "group $g" "you are a member"
  elif [[ ",$(getent group "$g" | cut -d: -f4)," == *",$(id -un),"* ]]; then
    record FAIL "group $g" "member, but not active in this session" "log out and back in (or: newgrp $g)"
  else
    record FAIL "group $g" "you are not a member" "sudo usermod -aG $g \$USER, then log out and back in"
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
    record FAIL "docker engine" "daemon not reachable" "sudo systemctl enable --now docker && sudo usermod -aG docker \$USER, then re-login"
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
      record FAIL "/dev/kvm" "exists, no read/write access" "sudo usermod -aG kvm \$USER, then re-login"
    fi
  else
    record FAIL "/dev/kvm" "missing" "enable VT-x/AMD-V in firmware; sudo modprobe kvm_intel (or kvm_amd)"
  fi
  check_group libvirt
  check_group kvm
  if have virsh; then
    # The lab uses passt networking and ssh over vsock: no libvirt network is involved.
    if timeout 10 virsh -c qemu:///system uri >/dev/null 2>&1; then
      record PASS "libvirt (qemu:///system)" "reachable"
    else
      record FAIL "libvirt (qemu:///system)" "libvirtd unreachable" "sudo systemctl enable --now libvirtd (and be in the libvirt group)"
    fi
  else
    record FAIL "virsh" "not found" "sudo dnf install libvirt-client libvirt-daemon-kvm"
  fi
  need_tool "passt" passt FAIL "sudo dnf install passt passt-selinux"
  if [[ -x /usr/libexec/libvirt-ssh-proxy ]]; then
    record PASS "libvirt-ssh-proxy" "/usr/libexec/libvirt-ssh-proxy"
  else
    record FAIL "libvirt-ssh-proxy" "not found" "sudo dnf install libvirt-ssh-proxy"
  fi
  need_tool "virt-install" virt-install FAIL "sudo dnf install virt-install"
  need_tool "qemu-img" qemu-img FAIL "sudo dnf install qemu-img"
  need_tool "cloud-localds" cloud-localds FAIL "sudo dnf install cloud-utils"
}

# Optional: examples/05-jvm-costs adds an allocation profile when the pinned release is unpacked.
check_async_profiler() {
  local lib="$HOME/.cache/lowlat/async-profiler-$ASYNC_PROFILER_VERSION-linux-x64/lib/libasyncProfiler.so"
  if [[ -f "$lib" ]]; then
    record PASS "async-profiler $ASYNC_PROFILER_VERSION (info)" "$lib"
  else
    record WARN "async-profiler $ASYNC_PROFILER_VERSION (info)" "not unpacked (optional; example 05 skips its allocation profile)" "run scripts/deps/install-async-profiler.sh"
  fi
}

check_misc() {
  need_tool "perf" perf WARN "sudo dnf install perf"
  check_async_profiler
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
  check_zlib
  check_cmake
  check_java
  check_python
  check_protoc
  check_docker
  check_virt
  check_misc
}

# vm <command...>: run a command in the guest via the lab ssh wrapper.
# stdin is closed so ssh cannot swallow the input of a caller's `while read` loop.
vm() { timeout 30 "$LAB_SSH" "$LAB_VM" "$@" 2>/dev/null </dev/null; }

vm_need() {
  local cmd="$1" pkg="$2"
  if vm "command -v $cmd" >/dev/null; then
    record PASS "guest: $cmd" "present"
  else
    record FAIL "guest: $cmd" "not found in guest" "sudo dnf install $pkg in the guest (or re-provision: scripts/lab/provision-vm.sh $LAB_VM)"
  fi
}

# The guest's JDK must be the pinned Temurin (versions.env), not Fedora's floating java-25-openjdk.
check_vm_java() {
  local out v
  out="$(vm 'java -version 2>&1' || true)"
  v="$(first_version <<<"$out")"
  if [[ "$v" == "$TEMURIN_VERSION" && "$out" == *Temurin* ]]; then
    # shellcheck disable=SC2016 # expands in the guest
    record PASS "guest: Temurin $TEMURIN_VERSION" "$(vm 'readlink -f "$(command -v java)"' || true)"
  else
    record FAIL "guest: Temurin $TEMURIN_VERSION" "java is ${v:-missing}$([[ "$out" == *Temurin* ]] || echo ', not Temurin')" "scripts/lab/install-guest-tools.sh $LAB_VM (or revert to snapshot lab-ready-r04)"
  fi
}

# The guest's uv must be the pinned one (versions.env): Fedora's packaged uv can lag the CPython
# that examples/.python-version pins, and Ch13's vm lane installs that CPython with it.
check_vm_uv() {
  local out
  out="$(vm 'command -v uv && uv --version' 2>/dev/null || true)"
  if [[ "$out" == *"uv $UV_VERSION"* ]]; then
    record PASS "guest: uv $UV_VERSION" "$(head -n1 <<<"$out")"
  else
    record FAIL "guest: uv $UV_VERSION" "uv is ${out:-missing}" "scripts/lab/install-guest-tools.sh $LAB_VM (or revert to snapshot lab-ready-r04)"
  fi
}

# Informational: isolation (guest cmdline) and vcpupin (libvirt) state. Neither is required,
# so absence is a WARN with the command that applies it.
check_vm_isolation() {
  local cmd pin
  cmd="$(vm cat /proc/cmdline || true)"
  if [[ " $cmd " == *" isolcpus=3 "* && " $cmd " == *" nohz_full=3 "* && " $cmd " == *" rcu_nocbs=3 "* ]]; then
    record PASS "guest isolation (info)" "isolcpus=3 nohz_full=3 rcu_nocbs=3 on the cmdline"
  else
    record WARN "guest isolation (info)" "not isolated (cmdline has no isolcpus=3)" "scripts/lab/apply-guest-profile.sh (undo: --remove)"
  fi
  pin="$(virsh -c qemu:///system vcpupin "$LAB_VM" 2>/dev/null | awk '$1 == 3 { print $2 }' || true)"
  if [[ -n "$pin" && "$pin" != 0-* ]]; then
    record PASS "guest vcpupin (info)" "vCPU 3 pinned to host CPU $pin"
  else
    record WARN "guest vcpupin (info)" "vCPU 3 is not pinned (${pin:-no data})" "scripts/lab/pin-vcpu.sh (undo: --remove)"
  fi
}

# ---- r04: the stock, unpinned guest (profile stock-unpinned, snapshot lab-ready-r04) ----------------

check_vm_stock_kernel() {
  local kr kv
  kr="$(vm uname -r || true)"
  kv="$(vm uname -v || true)"
  if [[ -n "$kr" && "$kr" == "$LAB_STOCK_KERNEL".* && "$kr" != *lowlatrt* && "$kv" != *PREEMPT_RT* ]]; then
    record PASS "guest stock kernel" "$kr (pinned $LAB_STOCK_KERNEL)"
  else
    record FAIL "guest stock kernel" "running ${kr:-?} (${kv:-?}), pinned $LAB_STOCK_KERNEL" "install and boot the pinned stock kernel: scripts/lab/apply-guest-profile.sh stock-unpinned (recipe in scripts/lab/README.md); or revert to snapshot lab-ready-r04 (or lab-ready) with scripts/lab/revert-vm.sh $LAB_VM, or boot the stock entry"
  fi
}

check_vm_cmdline() {
  local cmd bad=""
  cmd="$(vm cat /proc/cmdline || true)"
  if [[ -z "$cmd" ]]; then
    record FAIL "guest cmdline" "cannot read /proc/cmdline"
    return
  fi
  local a
  for a in $cmd; do
    case "$a" in isolcpus | isolcpus=* | nohz_full | nohz_full=* | rcu_nocbs | rcu_nocbs=*) bad+="$a " ;; esac
  done
  if [[ -z "$bad" ]]; then
    record PASS "guest no isolation" "no isolcpus, nohz_full or rcu_nocbs on the cmdline"
  else
    record FAIL "guest no isolation" "cmdline has: ${bad% }" "scripts/lab/apply-guest-profile.sh stock-unpinned, or revert to lab-ready-r04"
  fi
}

check_vm_unpinned() {
  local xml n
  if ! xml="$(virsh -c qemu:///system dumpxml "$LAB_VM" 2>/dev/null)" || [[ -z "$xml" ]]; then
    record FAIL "guest vcpupin" "virsh dumpxml $LAB_VM failed" "check libvirt access (the libvirt group)"
    return
  fi
  n="$(grep -c '<vcpupin ' <<<"$xml" || true)"
  if [[ "$n" == 0 ]]; then
    record PASS "guest vcpupin" "no <vcpupin> in the domain (unpinned)"
  else
    record WARN "guest vcpupin" "the domain pins $n vCPU(s)" "scripts/lab/pin-vcpu.sh --remove, then a full lab-down and lab-up"
  fi
}

check_vm_tuned_record() {
  local t
  t="$(vm 'tuned-adm active' || true)"
  if [[ -n "$t" ]]; then
    record PASS "guest tuned (recorded)" "${t#Current active profile: }"
  else
    record WARN "guest tuned (recorded)" "tuned-adm active printed nothing" "systemctl status tuned in the guest"
  fi
}

check_vm_docker_r04() {
  local active ver groups
  active="$(vm 'systemctl is-active docker' || true)"
  if [[ "$active" == active ]]; then
    record PASS "guest docker service" "active"
  else
    record FAIL "guest docker service" "${active:-unknown}" "in the guest: sudo systemctl enable --now docker"
  fi
  groups="$(vm 'id -nG' || true)"
  if [[ " $groups " == *" docker "* ]]; then
    record PASS "guest docker group" "the guest user is in the docker group"
  else
    record FAIL "guest docker group" "groups: ${groups:-?}" "in the guest: sudo usermod -aG docker \$USER, then log in again"
  fi
  ver="$(vm "docker version --format '{{.Server.Version}}'" || true)"
  if [[ -n "$ver" ]]; then
    record PASS "guest Docker Engine" "$ver (recorded)"
  else
    record FAIL "guest Docker Engine" "version not readable" "in the guest: docker version"
  fi
}

# Every image in IMAGES.lock must be in the guest with the locked ID (or RepoDigest). A lock that
# still has sha256:PENDING placeholders is a WARN: the images are built in S5, after this check exists.
check_vm_images() {
  local line ref want have rd pending=0 checked=0
  if [[ ! -f "$IMAGES_LOCK" ]]; then
    record WARN "guest images" "no IMAGES.lock at examples/13-where-code-runs/containers/" "see examples/13-where-code-runs/containers/README.md"
    return
  fi
  while read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    read -r line _ <<<"$line"
    ref="${line%@*}"
    want="${line#*@}"
    if [[ ! "$want" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      pending=$((pending + 1))
      continue
    fi
    checked=$((checked + 1))
    have="$(vm "docker image inspect --format '{{.Id}}' $ref" || true)"
    rd="$(vm "docker image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' $ref" || true)"
    if [[ "$have" == "$want" || " $rd " == *"@$want "* ]]; then
      record PASS "guest image $ref" "$want"
    elif [[ -z "$have" ]]; then
      record FAIL "guest image $ref" "not present in the guest" "in the guest: examples/13-where-code-runs/containers/build-images.sh"
    else
      record FAIL "guest image $ref" "id $have, locked $want" "rebuild with build-images.sh, or restore snapshot lab-ready-r04"
    fi
  done <"$IMAGES_LOCK"
  if ((pending > 0)); then
    record WARN "guest images" "$pending IMAGES.lock entr$([[ $pending == 1 ]] && echo y || echo ies) still sha256:PENDING; digests not checked" "in the guest: examples/13-where-code-runs/containers/build-images.sh"
  elif ((checked == 0)); then
    record WARN "guest images" "IMAGES.lock lists no image"
  fi
}

# Recorded, not required: the io_uring sysctl and whether the guest has a virtual PMU.
check_vm_records() {
  local iou pmu
  iou="$(vm 'cat /proc/sys/kernel/io_uring_disabled' || true)"
  if [[ -n "$iou" ]]; then
    record PASS "guest io_uring_disabled" "$iou (recorded; 0 = enabled, 1 = restricted, 2 = disabled)"
  else
    record WARN "guest io_uring_disabled" "kernel.io_uring_disabled not readable (kernel without io_uring?)"
  fi
  if pmu="$(vm 'perf stat -x, -e cycles:u true 2>&1')" && [[ "$pmu" == *cycles* && "$pmu" != *"not supported"* && "$pmu" != *"not counted"* ]]; then
    record PASS "guest vPMU (recorded)" "perf stat -e cycles:u works"
  else
    record WARN "guest vPMU (recorded)" "perf stat -e cycles:u does not count in the guest (no virtual PMU, or perf missing)" "scripts/lab/install-guest-tools.sh $LAB_VM; hardware counters are then not available to the lanes"
  fi
}

run_vm() {
  local state uv rt ready rt_mode="${1:-stock}"
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

  if [[ "$rt_mode" == rt ]]; then
    uv="$(vm uname -v || true)"
    # Mainline PREEMPT_RT has no /sys/kernel/realtime (that file came from the
    # out-of-tree RT patch set); the running kernel's own config is the evidence.
    # shellcheck disable=SC2016 # $(uname -r) must expand in the guest
    rt="$(vm 'grep -x CONFIG_PREEMPT_RT=y /boot/config-$(uname -r)' || true)"
    if [[ "$uv" == *PREEMPT_RT* && "$rt" == CONFIG_PREEMPT_RT=y ]]; then
      record PASS "guest RT kernel" "PREEMPT_RT in uname -v and the running kernel's config"
    else
      record FAIL "guest RT kernel" "uname -v: ${uv:-?}; config: ${rt:-no CONFIG_PREEMPT_RT=y}" "boot the kernel-rt entry (scripts/lab/README.md), or revert to snapshot lab-ready-rt"
    fi
  else
    check_vm_stock_kernel
    check_vm_cmdline
  fi
  check_vm_java
  vm_need stress-ng stress-ng
  if [[ "$rt_mode" == stock ]]; then
    check_vm_uv
    vm_need strace strace
    vm_need perf perf
  fi
  vm_need cyclictest realtime-tests
  vm_need ptp4l linuxptp
  vm_need phc2sys linuxptp
  vm_need tuned-adm tuned
  if vm 'test -c /dev/ptp0 && grep -qx "KVM virtual PTP" /sys/class/ptp/ptp0/clock_name'; then
    record PASS "guest: /dev/ptp0" "KVM virtual PTP clock"
  else
    record FAIL "guest: /dev/ptp0" "no KVM PTP clock" "in the guest: sudo modprobe ptp_kvm (cloud-init loads it via /etc/modules-load.d/ptp_kvm.conf)"
  fi
  if vm "docker version --format '{{.Server.Version}}'" >/dev/null; then
    record PASS "guest: docker" "daemon reachable"
  else
    record FAIL "guest: docker" "daemon not reachable" "in the guest: sudo systemctl enable --now docker"
  fi
  if [[ "$rt_mode" == rt ]]; then
    check_vm_isolation
  else
    check_vm_docker_r04
    check_vm_unpinned
    check_vm_tuned_record
    check_vm_images
    check_vm_records
  fi
  ready="$(vm head -n1 /var/log/lab-ready || true)"
  if [[ "$ready" == *ok* ]]; then
    record PASS "guest lab-ready" "$ready"
  else
    record FAIL "guest lab-ready" "${ready:-/var/log/lab-ready missing}" "wait for cloud-init, or re-provision: scripts/lab/provision-vm.sh $LAB_VM"
  fi
}

main() {
  local mode=host vm_mode=stock
  while (($#)); do
    case "$1" in
      --vm) mode=vm ;;
      --rt) vm_mode=rt ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  if [[ "$vm_mode" == rt && "$mode" != vm ]]; then
    echo "--rt only applies with --vm" >&2; usage >&2; exit 2
  fi
  if [[ "$mode" == vm ]]; then run_vm "$vm_mode"; else run_host; fi
  printf '\nSummary: %d PASS, %d WARN, %d FAIL\n' "$N_PASS" "$N_WARN" "$N_FAIL"
  ((N_FAIL == 0))
}

main "$@"
