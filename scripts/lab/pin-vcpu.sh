#!/usr/bin/env bash
# pin-vcpu.sh - pin vCPUs of the lab guest to host CPUs (libvirt domain config), or undo it.
#
#   ./pin-vcpu.sh                    # r04/r03 interface: pin vCPU 3 of lowlat-target to host CPU 13
#   PIN_VCPU=3 PIN_HOST_CPU=13 ./pin-vcpu.sh [vm]
#   PIN_MAP=r05 ./pin-vcpu.sh        # r05: vCPU 2 to host CPU 12 and vCPU 3 to host CPU 13
#   PIN_MAP="2:12 3:13" ./pin-vcpu.sh [vm]    # the same, spelled out (vCPU:hostCPU pairs)
#   ./pin-vcpu.sh --remove           # delete <cputune> again: the domain XML is back to unpinned
#
# This is libvirt configuration for the lab domain only (virsh vcpupin --config, plus --live when
# the guest is running). It is a PIN, not an isolation: the host kernel can still schedule other
# tasks on those host CPUs, and nothing on the host is changed (no isolcpus, no cpuset, no IRQ
# steering). PIN_MAP wins over PIN_VCPU / PIN_HOST_CPU; the single-pin interface and --remove work
# as they did before PIN_MAP existed. Every pair is validated: the host CPU must exist, the vCPU
# must exist in the domain, and a vCPU may appear once.
#
# How the r05 host CPUs were chosen (lab host: 8 cores x 2 threads, siblings N and N+8). The
# 2026-10-25 /proc/interrupts re-check summed the interrupt counts over both hyperthreads of every
# core: core 5 (CPUs 5 and 13) was the quietest and core 4 (CPUs 4 and 12) second. The two vCPUs go
# on CPUs 12 and 13, which sit on distinct physical cores, so the two guest measurement CPUs don't
# share a core's execution units. CPU 0 is avoided (host housekeeping lands there first). The siblings, CPUs 4 and 5, still run host work. Re-check on another host with:
# lscpu -e, /sys/devices/system/cpu/cpuN/topology/thread_siblings_list, /proc/interrupts.
# The guest-side counterparts are guest-profiles/isolate-cpu3.conf (guest CPU 3 = vCPU 3) and
# guest-profiles/isolate-cpu23.conf (guest CPUs 2-3 = vCPUs 2-3).
# The <cputune> block is printed before and after.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODE=pin
if [[ "${1:-}" == --remove ]]; then MODE=remove; shift; fi
VM="${1:-${TARGET_VM:-${LAB_PREFIX}-target}}"
PIN_MAP="${PIN_MAP:-}"
if [[ -z "$PIN_MAP" ]]; then PIN_MAP="${PIN_VCPU:-3}:${PIN_HOST_CPU:-13}"; fi
if [[ "$PIN_MAP" == r05 ]]; then PIN_MAP="2:12 3:13"; fi
guard_name "$VM"
virsh dominfo "$VM" >/dev/null 2>&1 || die "no such domain: $VM"

nhost="$(nproc --all)"
nv="$(virsh vcpucount "$VM" --maximum --config)"
VCPUS_PINNED=(); HOSTS_PINNED=()
for pair in $PIN_MAP; do
  [[ "$pair" =~ ^[0-9]+:[0-9]+$ ]] || die "bad PIN_MAP entry '$pair' (want vCPU:hostCPU, e.g. 2:12)"
  v="${pair%%:*}"; h="${pair##*:}"
  (( h < nhost )) || die "host CPU $h does not exist (host has $nhost)"
  (( v < nv )) || die "$VM has $nv vCPUs; no vCPU $v"
  for seen in "${VCPUS_PINNED[@]}"; do [[ "$seen" != "$v" ]] || die "vCPU $v appears twice in PIN_MAP"; done
  VCPUS_PINNED+=("$v"); HOSTS_PINNED+=("$h")
done
live=0; [[ "$(virsh domstate "$VM")" == running ]] && live=1

show() {
  local out
  out="$(virsh dumpxml "$VM" --inactive | sed -n '/<cputune>/,/<\/cputune>/p')"
  echo "-- <cputune> $1:"; echo "${out:-(none)}"
}
show before
if [[ "$MODE" == pin ]]; then
  for i in "${!VCPUS_PINNED[@]}"; do
    step "pinning $VM vCPU ${VCPUS_PINNED[i]} to host CPU ${HOSTS_PINNED[i]}"
    virsh vcpupin "$VM" "${VCPUS_PINNED[i]}" "${HOSTS_PINNED[i]}" --config
    if (( live )); then virsh vcpupin "$VM" "${VCPUS_PINNED[i]}" "${HOSTS_PINNED[i]}" --live; fi
  done
else
  step "removing the pin from $VM"
  if (( live )); then
    for v in "${VCPUS_PINNED[@]}"; do virsh vcpupin "$VM" "$v" "0-$((nhost - 1))" --live; done
  fi
  xml="$(mktemp)"; trap 'rm -f "$xml"' EXIT
  virsh dumpxml "$VM" --inactive | sed '/<cputune>/,/<\/cputune>/d' >"$xml"
  virsh define "$xml" >/dev/null
fi
show after
if (( live )); then echo "-- live:"; virsh vcpupin "$VM"; fi
