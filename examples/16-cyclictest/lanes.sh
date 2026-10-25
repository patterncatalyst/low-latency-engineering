# shellcheck shell=bash
# shellcheck disable=SC2034
# lanes.sh - what verify.sh and vm/run.sh agree on: the lanes, the cyclictest parameters, the durations and the
# guest layout. Source it after examples/_lib/lib.sh. vm/guest-run.sh runs in the guest on its own and is handed every
# value below through the environment, so this file never has to be deployed.
#
# A lane is one measurement from a clean snapshot (lib.sh lane_revert), with housekeeping noise on guest CPUs 0-1:
#   naive            cyclictest with its defaults: SCHED_OTHER, no -m, unpinned, CLOCK_REALTIME (the v2.11 default)
#   method           cyclictest -m -p95 --policy=fifo -a3 -i1000 -h20000 --clock=monotonic, with the C++ probe
#                    (cyclic-probe, the same parameters) running beside it on CPU 2
#   timerlat         rtla timerlat hist on CPU 3: timer IRQ latency against thread latency
#   haltpoll-forced  method's cyclictest with --default-system, after cpuidle_haltpoll.force=1 and one reboot
#   idle-default     the same cyclictest with --default-system, on the guest's default idle driver
# Every comparison is inside one run: the lanes alternate A B C D E, three times (interleave_env).

EXAMPLE=16-cyclictest
EXAMPLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LANES=(naive method timerlat haltpoll-forced idle-default)
CT_LANES=(naive method haltpoll-forced idle-default) # the lanes whose output is a cyclictest --json/--histfile pair
ROUNDS=3

# The guest: snapshot lab-ready-r05-iso (RT kernel, tuned cpu-partitioning, isolcpus=domain,managed_irq,2-3,
# irqaffinity=0-1, vCPUs 2 and 3 pinned). Noise runs on the housekeeping CPUs, the measurement on the isolated ones.
SNAPSHOT=lab-ready-r05-iso
GUEST_PROFILE_NAME=${GUEST_PROFILE:-$SNAPSHOT/isolated}
ISOLATED_CPUS=2-3
NOISE_CPUS=0-1
NOISE_KIND=${NOISE_KIND:-cpu}
MEASURE_CPU=3 # cyclictest and rtla
PROBE_CPU=2   # cyclic-probe, beside cyclictest in the method lane

# cyclictest parameters (the method lane; chapter text quotes these).
INTERVAL_US=1000
HIST_US=20000 # -h: the histogram range; a sample beyond it is an overflow and fails the lane
PRIORITY=95

# Durations in seconds. The cyclictest lanes run 300 s at 1 ms: 300,000 samples, enough for a p99.9 with 300 samples
# above it. The idle pair is observed only and runs shorter.
NAIVE_S=${NAIVE_S:-10}
METHOD_S=${METHOD_S:-300}
TIMERLAT_S=${TIMERLAT_S:-120}
IDLE_S=${IDLE_S:-120}
# rtla stops the run when the thread latency passes this and prints its auto-analysis (S11 sets the final value).
TIMERLAT_THRESHOLD_US=${TIMERLAT_THRESHOLD_US:-1000}
TIMERLAT_BUCKET_US=1
TIMERLAT_ENTRIES=9999
NOISE_MARGIN_S=15 # the noise outlasts the lane by this long, so no lane ends in a quiet guest

# SMOKE=1 is a check of the scripts: short lanes, one alternation, nothing enforced.
if [[ ${SMOKE:-0} == 1 ]]; then
  ROUNDS=1
  NAIVE_S=5
  METHOD_S=20
  TIMERLAT_S=10
  IDLE_S=10
fi

# lane_seconds LANE: how long the lane's measured program runs.
lane_seconds() {
  case $1 in
    naive) echo "$NAIVE_S" ;;
    method) echo "$METHOD_S" ;;
    timerlat) echo "$TIMERLAT_S" ;;
    haltpoll-forced | idle-default) echo "$IDLE_S" ;;
    *) die "unknown lane '$1'" ;;
  esac
}

# Where the run's files go in the guest. GUEST_BIN and GUEST_OUT are relative to the guest user's home (lane_revert
# pushes the binaries into GUEST_BIN; a revert empties everything else, so every lane starts with no output); the
# *_REL names are relative to the guest repository directory, which is where lib.sh `guest` runs a command.
GUEST_REPO=${GUEST_REPO:-low-latency-engineering}
GUEST_BIN=$GUEST_REPO/lane-bin
GUEST_OUT=$GUEST_REPO/lane-out
GUEST_RUN=lane-bin/guest-run.sh
GUEST_OUT_REL=lane-out
# The files lane_revert pushes (names only; SHA256SUMS lists their hashes).
LANE_FILES=(cyclic-probe guest-run.sh profile.sh timerlat-summary.awk)

# cyclictest's own CLI, as the reports record it. Quoted in the README; guest-run.sh builds the same arrays.
NAIVE_ARGS="-D $NAIVE_S -h $HIST_US"
METHOD_ARGS="-m -p$PRIORITY --policy=fifo -a$MEASURE_CPU -i $INTERVAL_US -D $METHOD_S -h $HIST_US --clock=monotonic"

# run_bg LOG CMD...: run CMD in the background, wait for it, and print its output afterwards. A bash trap runs only
# after a foreground command ends, so a TERM or INT to the driver would otherwise wait out a 300 s lane; a `wait`
# returns at once, the trap exits, and the EXIT handler stops the whole tree (_bg_cleanup).
run_bg() {
  local log=$1 pid rc=0
  shift
  "$@" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait "$pid" || rc=$?
  bg_forget "$pid"
  cat "$log"
  return "$rc"
}
