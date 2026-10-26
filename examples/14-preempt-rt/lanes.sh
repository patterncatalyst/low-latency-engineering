# shellcheck shell=bash
# Sourced by verify.sh and vm/run.sh, which use these names.
# shellcheck disable=SC2034
# lanes.sh - what verify.sh, vm/run.sh and vm/guest-run.sh agree on: the lanes, the snapshots, the workload, the
# ports and the counts a lane's kernel must show. Source it after examples/_lib/lib.sh.
#
# A lane is one preemption model of one kernel source (7.2.11-200.fc44), always in the same 4-vCPU guest with the same
# vCPU pins and no isolation (D3, D6):
#   stock-lazy   the stock kernel as Fedora ships it: PREEMPT_DYNAMIC, boot mode lazy (snapshot lab-ready-r05-stock)
#   stock-full   the same kernel and snapshot; `echo full > /sys/kernel/debug/sched/preempt` at run time, read back
#   rt           the PREEMPT_RT build of the same source (snapshot lab-ready-r05-rt)
# The lanes alternate stock-lazy, stock-full, rt, three times (interleave_env), each from a freshly reverted snapshot (D4).

EXAMPLE=14-preempt-rt
# shellcheck source=SCRIPTDIR/../../versions.env
. "$(dirname "${BASH_SOURCE[0]}")/../../versions.env"
LANES=(stock-lazy stock-full rt)
ROUNDS=3

# lane_snapshot LANE: the snapshot the lane starts from.
lane_snapshot() {
  case $1 in
    stock-lazy | stock-full) echo lab-ready-r05-stock ;;
    rt) echo lab-ready-r05-rt ;;
    *) die "unknown lane '$1'" ;;
  esac
}
# The guest profile recorded with every number: pinned vCPUs (libvirt), no isolation, load on the shared CPUs.
GUEST_PROFILE_SUFFIX=pinned-shared
# lane_guest_profile LANE: "snapshot/profile", the string runtime.environment.guest_profile carries (the host driver
# later replaces it with the object form that adds the vCPU pins).
lane_guest_profile() { echo "$(lane_snapshot "$1")/$GUEST_PROFILE_SUFFIX"; }

# What the kernel of each lane must show (exact). Set from the S1 probes (`_plans/dependency-pins.md`, "r05 guest probes");
# the S11 calibration confirmed them in all three alternations of every lane.
lane_mode() { [[ $1 == rt ]] && echo rt || echo stock; }
IRQ_KTHREADS_STOCK=15 # 14 aerdrv (PCIe port services) + 1 acpi, all requested by the drivers themselves; none for a virtio IRQ
IRQ_KTHREADS_RT=80    # a thread for every device IRQ
KTIMERS_STOCK=0
KTIMERS_RT=4          # one per vCPU, SCHED_FIFO 1
KSOFTIRQD=4           # one per vCPU in both kernels (SCHED_OTHER)
# Built from the pinned SRPM version (versions.env LAB_STOCK_KERNEL) so the release strings live in one place.
_kver=${LAB_STOCK_KERNEL%.fc*}  # 7.2.11-200
_kdist=${LAB_STOCK_KERNEL##*.}  # fc44
KERNEL_RELEASE_STOCK="$LAB_STOCK_KERNEL.x86_64"
KERNEL_RELEASE_RT="$_kver.lowlatrt.$_kdist.x86_64+rt"
KERNEL_SERIES=$(cut -d. -f1-2 <<<"$LAB_STOCK_KERNEL") # 7.2: what a scrubbed stock release reads
unset _kver _kdist
# lane_preempt_mode LANE: what /sys/kernel/debug/sched/preempt shows (S1): the selected mode is the one in parentheses.
lane_preempt_mode() {
  case $1 in
    stock-lazy) echo 'full (lazy)' ;;
    stock-full) echo '(full) lazy' ;;
    rt) echo '(full) lazy' ;;
  esac
}

# CPUs in the 4-vCPU guest: 0-1 housekeeping (ssh, simulators), 2 the probe, the line consumer and the Java hot thread,
# 3 cyclictest and the priority-inversion demo. Never FIFO work on CPU 0.
GUEST_VCPUS=4
PROBE_CPU=2
LINE_CPU=2
JAVA_CPU=2
CT_CPU=3
PI_CPU=3
HOUSEKEEPING_CPUS=0,1

# Durations. Real-run defaults are the plan's (D13); SMOKE=1 shrinks them.
CT_SECONDS=${CT_SECONDS:-300}      # cyclictest and cyclic-probe, 1 ms, under load
INTERVAL_US=1000
CT_HIST_US=20000                   # cyclictest histogram range (20 ms, plan D10); an overflow fails the lane (no --allow-overflow)
LINE_RATE=${LINE_RATE:-2500}       # per camera; four cameras
CAMERAS=4
LINE_SECONDS=${LINE_SECONDS:-20}
DECIDE_NS=${DECIDE_NS:-3000}
HOLD_MS=${HOLD_MS:-500}
PI_ROUNDS=${PI_ROUNDS:-200}
JAVA_SECONDS=${JAVA_SECONDS:-60}
if [[ ${SMOKE:-0} == 1 ]]; then
  ROUNDS=1
  CT_SECONDS=10
  LINE_SECONDS=2
  PI_ROUNDS=20
  JAVA_SECONDS=5
fi
line_count() { echo $((LINE_RATE * LINE_SECONDS * CAMERAS)); }

# UDP ports 47400-47403 (r05 owns 47400-47429; 00-13 use 47000-47344).
UDP_BASE=47400

# The guest's tools, by path where the plan says so.
GUEST_JAVA=/opt/temurin-25.0.5/bin/java

EXAMPLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
