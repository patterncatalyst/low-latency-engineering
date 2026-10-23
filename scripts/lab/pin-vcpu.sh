#!/usr/bin/env bash
# pin-vcpu.sh - pin one vCPU of the lab guest to one host CPU (libvirt domain config), or undo it.
#
#   ./pin-vcpu.sh                    # pin vCPU 3 of lowlat-target to host CPU 13
#   ./pin-vcpu.sh --remove           # delete <cputune> again: the domain XML is back to unpinned
#   PIN_VCPU=3 PIN_HOST_CPU=13 ./pin-vcpu.sh [vm]
#
# This is libvirt configuration for the lab domain only (virsh vcpupin --config, plus --live when
# the guest is running). It is a PIN, not an isolation: the host kernel can still schedule other
# tasks on that host CPU, and nothing on the host is changed (no isolcpus, no cpuset, no IRQ
# steering). Default host CPU 13: on the lab host (i7-11800H, 8 cores x 2 threads, siblings N and
# N+8) core 5 (CPUs 5 and 13) had the fewest interrupts summed over both hyperthreads in
# /proc/interrupts on 2026-10-22; core 7 (CPUs 7 and 15) was second busiest. Re-check on another
# host with: lscpu -e, /sys/devices/system/cpu/cpuN/topology/thread_siblings_list, /proc/interrupts.
# The sibling (CPU 5) still runs host work. The guest-side
# counterpart is guest-profiles/isolate-cpu3.conf (guest CPU 3 = vCPU 3).
# The <cputune> block is printed before and after.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODE=pin
if [[ "${1:-}" == --remove ]]; then MODE=remove; shift; fi
VM="${1:-${TARGET_VM:-${LAB_PREFIX}-target}}"
VCPU="${PIN_VCPU:-3}"
HOST_CPU="${PIN_HOST_CPU:-13}"
guard_name "$VM"
virsh dominfo "$VM" >/dev/null 2>&1 || die "no such domain: $VM"

nhost="$(nproc --all)"
(( HOST_CPU < nhost )) || die "host CPU $HOST_CPU does not exist (host has $nhost)"
nv="$(virsh vcpucount "$VM" --maximum --config)"
(( VCPU < nv )) || die "$VM has $nv vCPUs; no vCPU $VCPU"
live=0; [[ "$(virsh domstate "$VM")" == running ]] && live=1

show() {
  local out
  out="$(virsh dumpxml "$VM" --inactive | sed -n '/<cputune>/,/<\/cputune>/p')"
  echo "-- <cputune> $1:"; echo "${out:-(none)}"
}
show before
if [[ "$MODE" == pin ]]; then
  step "pinning $VM vCPU $VCPU to host CPU $HOST_CPU"
  virsh vcpupin "$VM" "$VCPU" "$HOST_CPU" --config
  if (( live )); then virsh vcpupin "$VM" "$VCPU" "$HOST_CPU" --live; fi
else
  step "removing the pin from $VM"
  if (( live )); then virsh vcpupin "$VM" "$VCPU" "0-$((nhost - 1))" --live; fi
  xml="$(mktemp)"; trap 'rm -f "$xml"' EXIT
  virsh dumpxml "$VM" --inactive | sed '/<cputune>/,/<\/cputune>/d' >"$xml"
  virsh define "$xml" >/dev/null
fi
show after
if (( live )); then echo "-- live:"; virsh vcpupin "$VM"; fi
