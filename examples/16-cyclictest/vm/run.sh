#!/usr/bin/env bash
# Ch16 host driver (VM=1 ../verify.sh, or this script): five lanes, interleaved, each from a clean snapshot.
#
# One run, in this order:
#   1  build cyclic-probe once, put it with vm/guest-run.sh, scripts/profile.sh and vm/timerlat-summary.awk into one
#      directory and write SHA256SUMS (lane_revert pushes these and checks the hashes in the guest, so every lane runs
#      the same bytes)
#   2  for every lane of every alternation, in the order  naive method timerlat haltpoll-forced idle-default  x 3
#      (lib.sh interleave_env):
#        require_quiet_host --lab-run   the host must be quiet (load1 <= LAB_RUN_LOAD1, default 2)
#        lane_revert lab-ready-r05-iso  snapshot revert, binaries pushed and hashed
#        vcpupin_record                 where libvirt pinned the guest's vCPUs
#        [haltpoll-forced]  add cpuidle_haltpoll.force=1 with grubby in the guest, reboot once, and check that the
#                           idle driver is haltpoll; [idle-default] check that it is none
#        guest_noise                    stress-ng on guest CPUs 0-1 (ISOLATED_CPUS=2-3 is refused)
#        interrupts_delta               the guest's /proc/interrupts for CPUs 2 and 3 around the lane
#        guest-run.sh lane              the measured program under sudo timeout -s KILL
#        guest_fetch, then lowlat-report from-cyclictest on the host
#   3  evaluate the results directory (verify.sh RECHECK)
#   4  shut the guest down (scripts/lab/lab-down.sh), always, unless KEEP_VM=1
#
# Nothing on the host changes: no sudo, no sysctl, no tuning. The guest is reached only through scripts/lab/lab-ssh.sh
# (ssh over vsock behind passt). The host's CPUs are not isolated: the guest's vCPUs 2 and 3 are pinned (libvirt
# configuration of the snapshot), the host still schedules and can preempt them, and every number says vm.
#
#   DRY_RUN=1       print each command this script would run, and the commands vm/guest-run.sh would run, and run nothing
#                   (no libvirt call, no ssh)
#   SMOKE=1         1 alternation, short lanes, nothing enforced (a check of the scripts, not a measurement); needs RESULTS_DIR
#   SKIP_BUILD=1    reuse the existing cyclic-probe build
#   KEEP_VM=1       leave the guest up at the end (to look at a failed run)
#   NOISE_KIND      stress-ng workload on guest CPUs 0-1: cpu (default), hdd, stream, cache or hackbench
#   TIMERLAT_THRESHOLD_US  rtla stops and prints its auto-analysis when a thread latency passes this (default 1000)
#   RESULTS_DIR     where the results go (default results/latest)
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
export TARGET_VM=$TARGET
export LIBVIRT_DEFAULT_URI=${LIBVIRT_DEFAULT_URI:-qemu:///system}
export RESULTS_DIR=${RESULTS_DIR:-$DIR/results/latest}
export GUEST_REPO GUEST_PROFILE=$GUEST_PROFILE_NAME ISOLATED_CPUS EXAMPLE
export LANE_GUEST_BIN=$GUEST_BIN
REBOOT_TRIES=${REBOOT_TRIES:-90} # x 5 s

# x CMD...: run CMD, or print it under DRY_RUN=1.
x() {
  if ((DRY_RUN)); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

if ((SMOKE)) && [[ -z ${RESULTS_DIR:-} ]]; then
  echo "SMOKE=1 needs RESULTS_DIR (it must not overwrite results/latest)" >&2
  exit 2
fi

if ((DRY_RUN)); then
  OUT=$RESULTS_DIR
  scratch_dir
else
  OUT=$(results_dir)
  # Remove only what this script writes, and only under a real results path.
  [[ $OUT == /*/*/* ]] || die "refusing to clear subdirectories of $OUT"
  rm -rf "${OUT:?}/vm" "${OUT:?}/logs"
  rm -f "${OUT:?}"/*.json "${OUT:?}"/*.log "${OUT:?}"/SHA256SUMS
  mkdir -p "$OUT/vm"
  scratch_dir
fi
LOGS=$LOWLAT_SCRATCH/logs
mkdir -p "$LOGS"
export RUN_START_JSON=$OUT/run-start.json

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

# gx CMD...: CMD in the guest from the repository root (lib.sh guest), or printed under DRY_RUN=1.
gx() {
  if ((DRY_RUN)); then
    printf '[dry-run] guest'
    printf ' %q' "$@"
    printf '\n'
  else
    guest "$@" </dev/null # no stdin: an ssh that reads it would swallow whatever the caller is reading
  fi
}

# The environment guest-run.sh needs for a lane (it sources nothing from the repository).
GUEST_ENV=(
  LANE_OUT="$GUEST_OUT_REL" GUEST_PROFILE="$GUEST_PROFILE_NAME" SNAPSHOT="$SNAPSHOT" MEASURE_CPU="$MEASURE_CPU"
  PROBE_CPU="$PROBE_CPU" INTERVAL_US="$INTERVAL_US" HIST_US="$HIST_US" PRIORITY="$PRIORITY" NAIVE_S="$NAIVE_S"
  METHOD_S="$METHOD_S" TIMERLAT_S="$TIMERLAT_S" IDLE_S="$IDLE_S" TIMERLAT_THRESHOLD_US="$TIMERLAT_THRESHOLD_US"
  TIMERLAT_BUCKET_US="$TIMERLAT_BUCKET_US" TIMERLAT_ENTRIES="$TIMERLAT_ENTRIES"
)

# ---- 1 build once, hash once -------------------------------------------------------------------------------------------
BINDIR=$LOWLAT_SCRATCH/lane-bin
step "build cyclic-probe once; SHA256SUMS of the files every lane runs"
if ((DRY_RUN)); then
  printf '[dry-run] build_cpp cyclic-probe; copy it, vm/guest-run.sh, scripts/profile.sh, vm/timerlat-summary.awk to %s; sha256sum > SHA256SUMS\n' "$BINDIR"
else
  build_cpp cyclic-probe
  mkdir -p "$BINDIR"
  cp "$(cpp_bin cyclic-probe)" "$BINDIR/cyclic-probe"
  cp "$DIR/vm/guest-run.sh" "$DIR/vm/timerlat-summary.awk" "$LOWLAT_ROOT/scripts/profile.sh" "$BINDIR/"
  chmod +x "$BINDIR"/*
  (cd "$BINDIR" && sha256sum "${LANE_FILES[@]}" >SHA256SUMS)
  cp "$BINDIR/SHA256SUMS" "$OUT/SHA256SUMS"
  ok "built once: $(cut -c1-12 "$BINDIR/SHA256SUMS" | tr '\n' ' ')"
fi
export LANE_BIN_DIR=$BINDIR

# ---- run-start.json ----------------------------------------------------------------------------------------------------
if ((DRY_RUN)); then
  printf '[dry-run] write %s (example, snapshot, durations, noise, pinning request)\n' "$RUN_START_JSON"
else
  jq -n --arg ex "$EXAMPLE" --arg snap "$SNAPSHOT" --arg prof "$GUEST_PROFILE_NAME" --argjson rounds "$ROUNDS" --arg smoke "$SMOKE" \
    --argjson naive "$NAIVE_S" --argjson method "$METHOD_S" --argjson timerlat "$TIMERLAT_S" --argjson idle "$IDLE_S" \
    --argjson interval "$INTERVAL_US" --argjson hist "$HIST_US" --argjson prio "$PRIORITY" --argjson mcpu "$MEASURE_CPU" \
    --argjson pcpu "$PROBE_CPU" --arg iso "$ISOLATED_CPUS" --arg noise_cpus "$NOISE_CPUS" --arg noise_kind "$NOISE_KIND" \
    --argjson thr "$TIMERLAT_THRESHOLD_US" --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson lanes "$(printf '%s\n' "${LANES[@]}" | jq -R . | jq -s .)" \
    '{example: $ex, mode: "vm", snapshot: $snap, guest_profile: $prof, reverted: true, rounds: $rounds, smoke: ($smoke == "1"), lanes: $lanes,
      seconds: {naive: $naive, method: $method, timerlat: $timerlat, "haltpoll-forced": $idle, "idle-default": $idle},
      interval_us: $interval, hist_us: $hist, priority: $prio, measure_cpu: $mcpu, probe_cpu: $pcpu, isolated_cpus: $iso,
      noise: {cpus: $noise_cpus, kind: $noise_kind}, timerlat_threshold_us: $thr, started: $started}' >"$RUN_START_JSON"
  printf 'vm\n' >"$OUT/vm/LABEL"
fi

# ---- helpers for the lanes ----------------------------------------------------------------------------------------------
# force_haltpoll: arm cpuidle_haltpoll.force=1 on the guest's RT boot entry, reboot once, and wait for the new boot.
force_haltpoll() {
  local boot0 boot1='' i
  step "haltpoll-forced: cpuidle_haltpoll.force=1 on the boot entry, one reboot"
  if ((DRY_RUN)); then
    printf '[dry-run] lab_ssh cat /proc/sys/kernel/random/boot_id; guest %s haltpoll-arm; wait for a new boot_id (up to %s s)\n' "$GUEST_RUN" $((REBOOT_TRIES * 5))
    return 0
  fi
  boot0=$(lab_ssh cat /proc/sys/kernel/random/boot_id </dev/null) || die "cannot read the guest's boot id"
  gx "$GUEST_RUN" haltpoll-arm
  for ((i = 0; i < REBOOT_TRIES; i++)); do
    sleep 5
    boot1=$(timeout 20 "${LAB_SSH:-$LAB/lab-ssh.sh}" "$TARGET" cat /proc/sys/kernel/random/boot_id </dev/null 2>/dev/null) || boot1=''
    [[ -n $boot1 && $boot1 != "$boot0" ]] && break
  done
  [[ -n $boot1 && $boot1 != "$boot0" ]] || die "the guest did not come back from the reboot within $((REBOOT_TRIES * 5)) s"
  ok "rebooted (new boot id)"
}

# check_idle_driver WANT: the cpuidle driver the lane is about to measure under.
check_idle_driver() {
  local have
  if ((DRY_RUN)); then
    printf '[dry-run] guest %s idle-driver | expect %s\n' "$GUEST_RUN" "$1"
    return 0
  fi
  have=$(gx "$GUEST_RUN" idle-driver | tr -d '[:space:]')
  [[ $have == "$1" ]] || die "the cpuidle driver is '$have', this lane needs '$1'"
  ok "cpuidle driver: $have"
}

# convert_lane LANE ALT: cyclictest --json plus --histfile to a lowlat-report/1 (the converter reads the histogram, never the
# average), then the host-side facts: the vCPU pins into the guest_profile and the interrupt deltas into the counters.
convert_lane() {
  local lane=$1 d=$2 conv n
  local -a files
  conv=$LOWLAT_SCRATCH/conv-$lane-$(basename "$d")
  rm -rf "$conv"
  mkdir -p "$conv"
  gzip -dc "$d/cyclictest.hist.gz" >"$conv/ct.hist"
  LOWLAT_PROFILE="$d/profile.json" uvrun lowlat-report from-cyclictest "$d/cyclictest-run.json" "$conv/ct.hist" "$conv/out" \
    --example "$EXAMPLE" --variant cyclictest --guest-profile "$GUEST_PROFILE_NAME" >/dev/null ||
    die "$lane $(basename "$d"): lowlat-report from-cyclictest failed (a histogram overflow fails it: raise -h)"
  n=$(find "$conv/out" -name '*.json' | wc -l)
  ((n == 1)) || die "$lane $(basename "$d"): expected one measurement thread, the converter wrote $n reports"
  jq --slurpfile pin "$d/vcpupin.json" --slurpfile irq "$d/interrupts.json" '
    .runtime.environment.guest_profile |= (if type == "string" then (split("/") | {snapshot: .[0], profile: .[1], vcpupin: $pin[0]}) else . end)
    | .runtime.counters.interrupts = $irq[0]' "$conv"/out/*.json >"$d/cyclictest.json"
  if [[ -f $d/cpp/cyclic-probe.json ]]; then
    jq --slurpfile pin "$d/vcpupin.json" \
      '.runtime.environment.guest_profile |= (if type == "string" then (split("/") | {snapshot: .[0], profile: .[1], vcpupin: $pin[0]}) else . end)' \
      "$d/cpp/cyclic-probe.json" >"$d/cpp/cyclic-probe.json.tmp" || die "$lane $(basename "$d"): jq failed on cyclic-probe.json"
    mv "$d/cpp/cyclic-probe.json.tmp" "$d/cpp/cyclic-probe.json"
  fi
  files=("$d/cyclictest.json")
  [[ ! -f $d/cpp/cyclic-probe.json ]] || files+=("$d/cpp/cyclic-probe.json")
  uvrun lowlat-report check "${files[@]}" >/dev/null ||
    die "$lane $(basename "$d"): lowlat-report check failed"
}

# host_lane LANE ALT: one lane from a clean snapshot.
host_lane() {
  local lane=$1 alt=$2 d=$OUT/vm/$1/alt$2 secs noise_s handle want_driver=none
  secs=$(lane_seconds "$lane")
  noise_s=$((secs + NOISE_MARGIN_S + 20))
  [[ $lane != haltpoll-forced ]] || want_driver=haltpoll
  step "lane $lane, alternation $alt: $secs s, from $SNAPSHOT"
  if ((DRY_RUN)); then
    printf '[dry-run] require_quiet_host --lab-run\n'
    x "$LAB/revert-vm.sh" "$TARGET" "$SNAPSHOT"
    printf '[dry-run] lane_revert %s   (LANE_BIN_DIR=%s: push %s to ~/%s, sha256 checked)\n' "$SNAPSHOT" "$BINDIR" "${LANE_FILES[*]}" "$GUEST_BIN"
    printf '[dry-run] vcpupin_record %s/vcpupin.json\n' "$d"
    [[ $lane != haltpoll-forced ]] || force_haltpoll
    check_idle_driver "$want_driver"
    gx "$GUEST_RUN" preflight
    gx "$GUEST_RUN" idle-wait 180
    printf '[dry-run] guest_noise %s %s %s\n' "$NOISE_CPUS" "$noise_s" "$NOISE_KIND"
    printf '[dry-run] interrupts_delta %s/interrupts.json 2 3 -- env <lane environment> %s lane %s %s\n' "$d" "$GUEST_RUN" "$lane" "$alt"
    printf '[dry-run] guest_noise_wait <noise handle>; guest_fetch %s/%s/alt%s/ %s\n' "$GUEST_OUT" "$lane" "$alt" "$d"
    # What the guest would run, printed by the guest script itself (it runs nothing under DRY_RUN=1).
    env DRY_RUN=1 "${GUEST_ENV[@]}" "$DIR/vm/guest-run.sh" lane "$lane" "$alt"
    [[ $lane == timerlat ]] || printf '[dry-run] lowlat-report from-cyclictest <fetched json> <hist> -> %s/cyclictest.json\n' "$d"
    return 0
  fi
  mkdir -p "$d"
  LAB_RUN_LOAD1_FILE=$LOGS/load1 require_quiet_host --lab-run
  jq -n --arg l "$(<"$LOGS/load1")" '{host_load1: ($l | tonumber)}' >"$d/host-quiet.json"
  lane_revert "$SNAPSHOT"
  vcpupin_record "$d/vcpupin.json"
  [[ $lane != haltpoll-forced ]] || force_haltpoll
  check_idle_driver "$want_driver"
  gx "$GUEST_RUN" preflight >"$LOGS/preflight-$lane-alt$alt.log"
  gx "$GUEST_RUN" idle-wait 180
  handle=$(guest_noise "$NOISE_CPUS" "$noise_s" "$NOISE_KIND") || die "the noise did not start"
  sleep 2
  run_bg "$LOGS/guest-$lane-alt$alt.log" interrupts_delta "$d/interrupts.json" 2 3 -- env "${GUEST_ENV[@]}" "$GUEST_RUN" lane "$lane" "$alt"
  guest_noise_wait "$handle"
  guest_fetch "$GUEST_OUT/$lane/alt$alt/" "$d"
  [[ $lane == timerlat ]] || convert_lane "$lane" "$d"
  ok "lane $lane alternation $alt done"
}

run_lane() { host_lane "$1" "$2"; }

# ---- 2 the lanes, interleaved ---------------------------------------------------------------------------------------------
step "lanes: ${LANES[*]} x $ROUNDS, noise ($NOISE_KIND) on guest CPUs $NOISE_CPUS, measurement on $ISOLATED_CPUS"
interleave_env "$ROUNDS" "${LANES[@]}"

# ---- 3 scrub, shut down, evaluate -------------------------------------------------------------------------------------------
if ((!DRY_RUN)); then
  scrub_results "$OUT"
fi
down_vm

if [[ ${VERIFY_DRIVER:-0} == 1 ]] || ((DRY_RUN)); then
  ((DRY_RUN)) && printf '[dry-run] RECHECK=%s %s/verify.sh\n' "$OUT" "$DIR"
  exit 0
fi
step "evaluate the results directory (the guest is already down)"
RECHECK="$OUT" SMOKE="$SMOKE" "$DIR/verify.sh"
