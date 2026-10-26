#!/usr/bin/env bash
# Ch15 host driver (VM=1 ../verify.sh, or this script): the five lanes in one interleaved run.
#
# One run, in this order:
#   1  build once on the host (line-simulator, io-receive, placement-probe, the shaded Java jar) into one directory and write
#      SHA256SUMS; these are the bytes every lane runs (D17)
#   2  for each lane, alternation by alternation:  shared isolated irq-steered irq-on-measure-cpu cache-noise  x 3
#      (lib.sh interleave_env), with no lane sharing a boot with another:
#        require_quiet_host --lab-run     the host's load1 must be <= LAB_RUN_LOAD1 (default 2), recorded in run-start.json
#        lane_revert SNAPSHOT             revert the lab guest, wait for ssh, push the binaries and verify their sha256
#        deploy-to-vm.sh, vm/guest-run.sh prepare, facts, the lane's steps (below), fetch the guest's files
#   3  shut the guest down (scripts/lab/lab-down.sh), always, unless KEEP_VM=1
#   4  evaluate the results directory (verify.sh RECHECK)
#
# What a lane runs (CPUs 0-1 are housekeeping, 2-3 are the isolated pair in the isolated snapshot; every step is under
# timeout -s KILL in the guest, and noise only through lib.sh guest_noise, which refuses the isolated set):
#   shared | isolated   tick (one busy task on CPU 2, LOC/RES/CAL/TLB deltas), then noise (stress-ng --cpu + hackbench: CPUs 0-3
#                       in shared, 0-1 in isolated), the last-run CPU of every noise thread, the decide thread's involuntary
#                       switches on CPU 2, the line at 10 kHz, and cyclictest (FIFO 95, CPU 3) with /proc/interrupts deltas.
#                       isolated also runs the smp_affinity write demo and the two Java placements
#   irq-steered         cyclictest on CPU 3 for IRQ_SECONDS beside disk I/O submitted from CPUs 0-1
#   irq-on-measure-cpu  the same, with the disk I/O submitted by a thread on CPU 3 (the defect)
#   cache-noise         isolated, noise = stress-ng --stream and --cache on CPUs 0-1 (observed)
# The guest's facts (sysfs isolated and nohz_full, cmdline, tuned, systemd CPUAffinity), its steal ticks, the vCPU pins
# (virsh vcpupin, the host's view) and the host's load1 are written beside the measurements, per lane and alternation.
#
# Nothing on the host changes: no sudo, no sysctl, no tuned. The guest is reached only through scripts/lab/lab-ssh.sh
# (ssh over vsock behind passt); the guest does the privileged work.
#
#   DRY_RUN=1       print each command this script would run (and what vm/guest-run.sh would run), and touch no libvirt
#   SMOKE=1         1 alternation, short lanes, nothing enforced (a check of the scripts, not a measurement); needs RESULTS_DIR
#   SKIP_BUILD=1    reuse the existing builds
#   KEEP_VM=1       leave the guest up at the end (to look at a failed run)
#   LAB_RUN_LOAD1   the host load1 a lane may start at (default 2); ALLOW_BUSY=1 records it and goes on (noisy)
#   RESULTS_DIR     where the results go (default results/latest); the committed runs use results/r05-vm-run{1,2,3}
#   CT_SECONDS, IRQ_SECONDS, TICK_SECONDS, DECIDE_SECONDS, JAVA_SECONDS, LINE_SECONDS   durations (lanes.sh)
#
# Run it under the host benchmark lock:  flock -o "$LOCK" ./verify.sh   (VM=1 ./verify.sh calls this script)
set -euo pipefail
trap 'exit 143' TERM
trap 'exit 130' INT
# shellcheck source=../../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../../_lib/lib.sh"
# shellcheck source=../lanes.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../lanes.sh"

DRY_RUN=${DRY_RUN:-0}
SMOKE=${SMOKE:-0}
DIR=$EXAMPLE_DIR
LAB=$LOWLAT_ROOT/scripts/lab
TARGET=${TARGET_VM:-lowlat-target}
GUEST_REPO=${GUEST_REPO:-low-latency-engineering}
export TARGET_VM=$TARGET GUEST_REPO
export LIBVIRT_DEFAULT_URI=${LIBVIRT_DEFAULT_URI:-qemu:///system}
export EXAMPLE
GUEST_RUN=examples/$EXAMPLE/vm/guest-run.sh # relative to the repository in the guest

if ((SMOKE)) && [[ -z ${RESULTS_DIR:-} ]]; then
  echo "SMOKE=1 needs RESULTS_DIR (it must not overwrite results/latest)" >&2
  exit 2
fi

scratch_dir
LOGS=$LOWLAT_SCRATCH/logs
mkdir -p "$LOGS"
export LANE_BIN_DIR=$LOWLAT_SCRATCH/lane-bin
mkdir -p "$LANE_BIN_DIR"

if ((DRY_RUN)); then
  OUT=$LOWLAT_SCRATCH/dry-results
  mkdir -p "$OUT"
else
  export RESULTS_DIR=${RESULTS_DIR:-$DIR/results/latest}
  OUT=$(results_dir)
  # Remove only what this script writes, and only under a real results path.
  [[ $OUT == /*/*/* ]] || die "refusing to clear subdirectories of $OUT"
  rm -rf "${OUT:?}/vm" "${OUT:?}/logs"
  rm -f "${OUT:?}"/*.json "${OUT:?}"/*.log "${OUT:?}"/SHA256SUMS
  mkdir -p "$OUT/vm"
  printf 'vm\n' >"$OUT/vm/LABEL"
fi
export RUN_START_JSON=$OUT/run-start.json

# ---- dry run: the lib.sh helpers that touch libvirt or the guest print instead --------------------------------------------------
if ((DRY_RUN)); then
  dry() {
    {
      printf '[dry-run]'
      printf ' %q' "$@"
      printf '\n'
    } >&2
  }
  sleep() { :; } # a dry run waits for nothing
  lab_ssh() { dry lab_ssh "$@"; }
  require_quiet_host() { dry require_quiet_host "$@"; }
  lane_revert() { dry lane_revert "$@"; }
  vcpupin_record() { dry vcpupin_record "$@"; }
  guest_fetch() { dry guest_fetch "$@"; }
  guest_noise() { dry guest_noise "$@"; echo /tmp/lowlat-noise-dry.pid; }
  guest_noise_wait() { dry guest_noise_wait "$@"; }
  cyclictest_run() { dry cyclictest_run "$@"; }
  # guest CMD...: print it, and when CMD is a guest-run.sh step, what that step would run (the script prints it itself).
  guest() {
    dry guest "$@"
    if [[ ${1:-} == "$GUEST_RUN" ]]; then DRY_RUN=1 SMOKE="$SMOKE" "$DIR/vm/guest-run.sh" "${@:2}" >&2; fi
  }
  interrupts_delta() {
    local out=$1
    shift
    local -a cpus=()
    while (($#)) && [[ $1 != -- ]]; do cpus+=("$1"); shift; done
    shift
    dry interrupts_delta "$out" "${cpus[@]}"
    guest "$@"
  }
fi

# x CMD...: run CMD, or print it under DRY_RUN=1.
x() {
  if ((DRY_RUN)); then
    dry "$@"
  else
    "$@"
  fi
}
# gx STEP...: one vm/guest-run.sh step in the guest (a failed step stops the run).
# SMOKE is passed on: guest-run.sh sources lanes.sh, which picks the durations and the line size from it.
gx() { guest env SMOKE="$SMOKE" "$GUEST_RUN" "$@" </dev/null; }

VM_DOWN=0
# down_vm: shut the guest down once (scripts/lab/lab-down.sh touches only lowlat-* domains); a failed run included.
down_vm() {
  ((VM_DOWN)) && return 0
  VM_DOWN=1
  if [[ ${KEEP_VM:-0} == 1 ]]; then
    echo "KEEP_VM=1: the guest is left up; shut it down with scripts/lab/lab-down.sh"
    return 0
  fi
  if ((DRY_RUN)); then
    x "$LAB/lab-down.sh"
    return 0
  fi
  "$LAB/lab-down.sh" >"$LOGS/lab-down.log" 2>&1 || echo "warning: lab-down.sh did not finish; check virsh list" >&2
}
finish() {
  local rc=$?
  trap - EXIT
  down_vm
  if [[ -d $LOGS ]] && ((!DRY_RUN)); then
    mkdir -p "$OUT/logs"
    find "$LOGS" -maxdepth 1 -name '*.log' -exec mv -t "$OUT/logs" {} + 2>/dev/null || true
  fi
  _bg_cleanup
  exit "$rc"
}
trap finish EXIT

# ---- 1 host build, once -----------------------------------------------------------------------------------------------------
JAR=$DIR/java/target/cpu-partitioning-java.jar
if ((DRY_RUN)); then
  printf '[dry-run] build_cpp placement-probe io-receive line-simulator; build_java %s/java; sha256sum %s > SHA256SUMS\n' "$DIR" "${LANE_BINARIES[*]}" >&2
else
  if [[ ${VERIFY_DRIVER:-0} != 1 ]]; then
    build_cpp placement-probe io-receive line-simulator
    build_java "$DIR/java"
    py_sync
  fi
  [[ -f $JAR ]] || die "missing $JAR (build first)"
  for b in io-receive line-simulator placement-probe; do cp "$(cpp_bin "$b")" "$LANE_BIN_DIR/$b"; done
  cp "$JAR" "$LANE_BIN_DIR/cpu-partitioning-java.jar"
  (cd "$LANE_BIN_DIR" && sha256sum "${LANE_BINARIES[@]}") >"$LANE_BIN_DIR/SHA256SUMS"
  cp "$LANE_BIN_DIR/SHA256SUMS" "$OUT/SHA256SUMS"
  ok "built once: $(cut -c1-12 "$LANE_BIN_DIR/SHA256SUMS" | tr '\n' ' ')"
fi

jq -n --arg ex "$EXAMPLE" --argjson rounds "$ROUNDS" --argjson smoke "$SMOKE" --arg lanes "${LANES[*]}" \
  --argjson ct "$CT_SECONDS" --argjson irq "$IRQ_SECONDS" --argjson tick "$TICK_SECONDS" --argjson decide "$DECIDE_SECONDS" \
  --argjson java "$JAVA_SECONDS" --argjson line "$LINE_SECONDS" --argjson rate "$LINE_RATE" \
  '{example: $ex, mode: "vm", rounds: $rounds, smoke: ($smoke == 1), lanes: ($lanes | split(" ")),
    seconds: {cyclictest: $ct, irq_pair: $irq, tick: $tick, decide: $decide, java: $java, line: $line}, line_rate_hz_per_camera: $rate}' \
  >"$RUN_START_JSON"

# ---- helpers for a lane --------------------------------------------------------------------------------------------------------
# revert_and_up SNAPSHOT: lane_revert's LAB_REVERT hook. A running-state snapshot comes back running; lab-up.sh starts a
# stopped one and waits for ssh (it does nothing to a running guest).
revert_and_up() {
  "$LAB/revert-vm.sh" "$@" && "$LAB/lab-up.sh"
}
if ((DRY_RUN)); then revert_and_up() { dry revert_and_up "$@"; }; fi
export LAB_REVERT=revert_and_up

# noise_stop HANDLE...: end the load guest_noise started (TERM to its timeout, which ends the whole process group), then wait.
noise_stop() {
  local h
  ((DRY_RUN)) && { dry noise_stop "$@"; return 0; }
  for h in "$@"; do
    lab_ssh "kill \$(cat $(printf '%q' "$h")) 2>/dev/null; true" </dev/null
  done
  for h in "$@"; do guest_noise_wait "$h"; done
}

# ct_window D SECONDS: cyclictest (FIFO 95, CPU 3, 1 ms) for SECONDS with /proc/interrupts read before and after, in the
# guest, around it. The bracket is a guest step that waits for a flag file; the host touches the flag when cyclictest_run
# returns, so the window covers the run to within a few seconds of ssh start-up at each end.
ct_window() {
  local d=$1 secs=$2 flag pid
  flag=/tmp/lowlat-ct-done-$$-$RANDOM
  interrupts_delta "$d/interrupts-cyclictest.json" 0 1 2 3 -- "$GUEST_RUN" hold "$flag" $((secs + 240)) &
  pid=$!
  bg_track "$pid"
  sleep 3
  CYCLICTEST_TIMEOUT=$((secs + 90)) cyclictest_run "$d/cyclictest" -q -m -p95 --policy=fifo -a "$MEASURE_CPU" -t 1 \
    -i "$CT_INTERVAL_US" -D "$secs" -h "$CT_HIST_US"
  x lab_ssh "touch $flag" </dev/null
  wait "$pid" || die "the interrupt bracket around cyclictest failed"
  bg_forget "$pid"
}

# tag_vm_env D SNAPSHOT PROFILE: record the lane's snapshot, profile and the host's vCPU pins in each report's
# runtime.environment (the guest can't see the pins; the host driver writes them).
tag_vm_env() {
  local d=$1 snap=$2 prof=$3 f
  ((DRY_RUN)) && { dry tag_vm_env "$@"; return 0; }
  while IFS= read -r f; do
    jq --slurpfile pin "$d/vcpupin.json" --arg snap "$snap" --arg prof "$prof" \
      '.runtime = ((.runtime // {}) * {environment: {kind: "vm", guest_profile: {snapshot: $snap, profile: $prof, vcpupin: $pin[0]}}})' \
      "$f" >"$f.tmp" || die "tag_vm_env: jq failed on $f"
    mv "$f.tmp" "$f"
  done < <(find "$d" -type f \( -path '*/cyclictest/*.json' -o -name consumer.json -o -name lateness.json -o -name steal.json \) | sort)
}

# ---- the lanes -------------------------------------------------------------------------------------------------------------------
# lane_main LANE D: the shared and isolated lanes; the phases run under noise and the noise is stopped at the end.
lane_main() {
  local lane=$1 d=$2 cpus total h
  local -a handles=()
  step "$lane: tick on CPU $DECIDE_CPU (one busy task, no other load)"
  interrupts_delta "$d/interrupts-tick.json" 0 1 2 3 -- "$GUEST_RUN" probe "$DECIDE_CPU" "$TICK_SECONDS" tick-probe.json </dev/null
  ((DRY_RUN)) || jq -n --argjson cpu "$DECIDE_CPU" --argjson s "$TICK_SECONDS" '{cpu: $cpu, seconds: $s}' >"$d/tick.json"
  if [[ $lane == isolated ]]; then
    gx irq-affinity irq-affinity.json
  fi
  total=$((DECIDE_SECONDS + LINE_SECONDS + CT_SECONDS + NOISE_SAMPLE_SECONDS + 2 * JAVA_SECONDS + 240))
  if [[ $lane == shared ]]; then
    cpus=0-3
    export NOISE_SHARED_LANE=1
    unset ISOLATED_CPUS
  else
    cpus=$HOUSEKEEPING_SET
    export ISOLATED_CPUS=$ISOLATED_SET
    unset NOISE_SHARED_LANE
  fi
  step "$lane: noise (stress-ng --cpu, hackbench) on CPUs $cpus"
  handles+=("$(guest_noise "$cpus" "$total" cpu)")
  handles+=("$(guest_noise "$cpus" "$total" hackbench)")
  sleep 3
  gx noise-sample "$NOISE_SAMPLE_SECONDS" noise-cpus.json
  gx probe "$DECIDE_CPU" "$DECIDE_SECONDS" decide-probe.json
  gx line line
  ct_window "$d" "$CT_SECONDS"
  if [[ $lane == isolated ]]; then
    gx java taskset "$JAVA_SECONDS" java-jvm-taskset-isolated.json
    gx java hot-thread "$JAVA_SECONDS" java-hot-thread-pinned.json
  fi
  for h in "${handles[@]}"; do noise_stop "$h"; done
}

lane_irq() {
  local lane=$1 d=$2 io_cpus defect='' pid
  export ISOLATED_CPUS=$ISOLATED_SET
  unset NOISE_SHARED_LANE
  if [[ $lane == irq-steered ]]; then
    io_cpus=$HOUSEKEEPING_SET
  else
    io_cpus=$MEASURE_CPU
    defect=defect
  fi
  step "$lane: disk I/O (stress-ng --hdd, O_DIRECT) from CPUs $io_cpus, cyclictest on CPU $MEASURE_CPU for ${IRQ_SECONDS} s"
  gx disk-io "$io_cpus" $((IRQ_SECONDS + 12)) ${defect:+"$defect"} &
  pid=$!
  bg_track "$pid"
  sleep 2
  ct_window "$d" "$IRQ_SECONDS"
  wait "$pid" || die "the disk I/O load failed"
  bg_forget "$pid"
}

lane_cache() {
  local lane=$1 d=$2 total h
  local -a handles=()
  export ISOLATED_CPUS=$ISOLATED_SET
  unset NOISE_SHARED_LANE
  total=$((CT_SECONDS + NOISE_SAMPLE_SECONDS + 240))
  step "$lane: noise (stress-ng --stream, --cache) on CPUs $HOUSEKEEPING_SET"
  handles+=("$(guest_noise "$HOUSEKEEPING_SET" "$total" stream)")
  handles+=("$(guest_noise "$HOUSEKEEPING_SET" "$total" cache)")
  sleep 3
  gx noise-sample "$NOISE_SAMPLE_SECONDS" noise-cpus.json
  ct_window "$d" "$CT_SECONDS"
  for h in "${handles[@]}"; do noise_stop "$h"; done
}

# lane_run LANE ALT: one lane, one alternation, from a clean snapshot.
lane_run() {
  local lane=$1 alt=$2 snap prof d=$OUT/vm/$1/alt$2 s0 t0 hz s1 t1 ticks
  snap=$(snapshot_of "$lane")
  prof=$(profile_of "$lane")
  step "lane $lane, alternation $alt (snapshot $snap)"
  ((DRY_RUN)) || { rm -rf "${d:?}"; mkdir -p "$d"; export LAB_RUN_LOAD1_FILE=$d/host-load1.txt; }
  require_quiet_host --lab-run
  lane_revert "$snap"
  x "$LAB/deploy-to-vm.sh" "$TARGET"
  gx prepare
  guest_fetch "$GUEST_REPO/$GUEST_OUT/profile.json" "$d/profile.json"
  export LOWLAT_PROFILE=$d/profile.json GUEST_PROFILE="$snap/$prof" CYCLICTEST_VARIANT=$lane
  vcpupin_record "$d/vcpupin.json"
  gx facts
  # A command substitution, not < <(...): a process substitution's status is lost, so a failed ssh would go unnoticed.
  ticks=$(steal_ticks)
  read -r s0 t0 hz <<<"$ticks"
  case $lane in
    shared | isolated) lane_main "$lane" "$d" ;;
    irq-steered | irq-on-measure-cpu) lane_irq "$lane" "$d" ;;
    cache-noise) lane_cache "$lane" "$d" ;;
    *) die "unknown lane '$lane'" ;;
  esac
  ticks=$(steal_ticks)
  read -r s1 t1 hz <<<"$ticks"
  if ((!DRY_RUN)); then
    jq -n --arg ex "$EXAMPLE" --argjson s $((s1 - s0)) --argjson t $((t1 - t0)) --argjson hz "$hz" \
      '{schema: "lowlat-steal/1", example: $ex, steal_ticks: $s, total_ticks: $t, clk_tck: $hz}' >"$d/steal.json"
    jq -n --arg ex "$EXAMPLE" --arg lane "$lane" --argjson alt "$alt" --arg snap "$snap" --arg prof "$prof" \
      --arg load "$(cat "$d/host-load1.txt" 2>/dev/null || echo unknown)" \
      '{schema: "lowlat-lane/1", example: $ex, lane: $lane, alternation: $alt, snapshot: $snap, profile: $prof, host_load1_at_start: $load}' >"$d/lane.json"
  fi
  guest_fetch "$GUEST_REPO/$GUEST_OUT/" "$d"
  tag_vm_env "$d" "$snap" "$prof"
}
# steal_ticks: "steal total hz" from the guest, now.
steal_ticks() {
  if ((DRY_RUN)); then
    dry guest "$GUEST_RUN" steal
    echo "0 1 100"
  else
    gx steal
  fi
}

run_lane() { lane_run "$1" "$2"; }

# ---- 2 the lanes, interleaved ---------------------------------------------------------------------------------------------------
interleave_env "$ROUNDS" "${LANES[@]}"

# ---- 3 shut down, 4 evaluate ------------------------------------------------------------------------------------------------------
if ((!DRY_RUN)); then scrub_results "$OUT"; fi
down_vm
if [[ ${VERIFY_DRIVER:-0} == 1 ]] || ((DRY_RUN)); then
  ((DRY_RUN)) && printf '[dry-run] RECHECK=%s %s/verify.sh\n' "$OUT" "$DIR" >&2
  exit 0
fi
step "evaluate the results directory (the guest is already down)"
RECHECK="$OUT" SMOKE="$SMOKE" "$DIR/verify.sh"
