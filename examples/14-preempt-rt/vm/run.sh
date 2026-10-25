#!/usr/bin/env bash
# Ch14 host driver (VM=1 ../verify.sh, or this script): three preemption lanes in one interleaved run.
#
# One run, in this order:
#   1  build the C++ binaries and the Java jar once, on the host, and write SHA256SUMS (D17: one set of bytes in every lane)
#   2  run-start.json: the host's load1, the commit, the lab VM's state, the snapshot of every lane
#   3  for alternation 1..3 and lane stock-lazy, stock-full, rt (lib.sh interleave_env), each lane in this order:
#        require_quiet_host --lab-run         the host may run the guest, but must not be busy (load1 <= 2)
#        lane_revert SNAPSHOT                 revert the guest, push the binaries, check every sha256 in the guest
#        scripts/lab/deploy-to-vm.sh          the repository's scripts into the guest (guest-run.sh, profile.sh)
#        guest-run.sh begin                   guest profile; stock-full writes `full` to the preempt knob and reads it back
#        vcpupin_record                       where libvirt pins the guest's vCPUs (the guest can't see it)
#        guest_noise x2 + cyclictest_run + guest-run.sh probe
#                                             hackbench and stress-ng --cpu on all 4 vCPUs (the shared lane's load) for the
#                                             whole window; cyclictest FIFO 95 on CPU 3 from here (it needs the host's
#                                             lowlat-report), cyclic-probe FIFO 95 on CPU 2 in the guest, both with the same
#                                             period and duration; /proc/interrupts deltas for the window
#        guest-run.sh line | pi | java | end  the line, the priority-inversion demo, the Java lane, the mechanism counters
#        guest_fetch                          the lane's results into results/<run>/vm/<lane>/altN/, environment objects added
#   4  shut the guest down (scripts/lab/lab-down.sh), always, unless KEEP_VM=1
#   5  evaluate the results directory (verify.sh RECHECK)
#
# cyclictest is the one tool started from the host: lib.sh cyclictest_run runs it over lab_ssh and converts its output with
# lowlat-report on the host. Everything else that needs only the guest is in vm/guest-run.sh.
# Nothing on the host changes: no sudo, no sysctl, no tuning. The guest is reached only through scripts/lab/lab-ssh.sh (ssh
# over vsock behind passt). The host can't run SCHED_FIFO work (RLIMIT_RTPRIO is 0) and doesn't: every number is lane `vm`.
#
#   DRY_RUN=1       print each command this script would run, and the commands vm/guest-run.sh would run; touches no VM and no libvirt
#   SMOKE=1         one alternation, short durations (cyclictest 10 s, line 2 s, pi-demo 20 rounds, Java 5 s), nothing enforced;
#                   needs RESULTS_DIR (a check of the scripts, not a measurement)
#   SKIP_BUILD=1    reuse the host builds
#   KEEP_VM=1       leave the guest up at the end (to look at a failed run)
#   RESULTS_DIR     where the results go (default results/latest)
#   CT_SECONDS, LINE_SECONDS, PI_ROUNDS, JAVA_SECONDS   override the durations of lanes.sh
#
# Run it under the host benchmark lock:  flock -o "$LOCK" ./verify.sh   (VM=1 ./verify.sh calls this script)
# shellcheck disable=SC2016
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
export TARGET_VM=${TARGET_VM:-lowlat-target}
export GUEST_REPO=${GUEST_REPO:-low-latency-engineering}
RESULTS_DIR_GIVEN=${RESULTS_DIR:-}
export RESULTS_DIR=${RESULTS_DIR:-$DIR/results/latest}
export LIBVIRT_DEFAULT_URI=${LIBVIRT_DEFAULT_URI:-qemu:///system}
export EXAMPLE
GUEST_RUN=examples/$EXAMPLE/vm/guest-run.sh # relative to the repository in the guest

if ((SMOKE)) && [[ -z $RESULTS_DIR_GIVEN ]]; then
  echo "SMOKE=1 needs RESULTS_DIR (it must not overwrite results/latest)" >&2
  exit 2
fi

# jq_edit FILE JQ_ARGS...: rewrite FILE in place with jq (the last argument is the filter).
jq_edit() {
  local f=$1
  shift
  jq "$@" "$f" >"$f.tmp" || die "jq failed on $f"
  mv "$f.tmp" "$f"
}

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

OUT=$RESULTS_DIR
VMOUT=$OUT/vm
if ((!DRY_RUN)); then
  # Remove only what this script writes, and only under a real results path.
  [[ $OUT == /*/*/* ]] || die "refusing to clear subdirectories of $OUT"
  rm -rf "${VMOUT:?}" "${OUT:?}/logs"
  rm -f "${OUT:?}"/*.json "${OUT:?}"/SHA256SUMS
  mkdir -p "$VMOUT"
  echo vm >"$VMOUT/LABEL"
fi
scratch_dir
LOGS=$LOWLAT_SCRATCH/logs
mkdir -p "$LOGS"
export RUN_START_JSON=$OUT/run-start.json
export LANE_BIN_DIR=$LOWLAT_SCRATCH/lane-bin

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
# guest_step LANE ALT STEP [ARGS...]: one guest-run.sh step, with the settings the guest needs, console output to a driver log.
guest_step() {
  local lane=$1 alt=$2 step_name=$3
  shift 3
  if ((DRY_RUN)); then
    gx env SMOKE="$SMOKE" CT_SECONDS="$CT_SECONDS" LINE_SECONDS="$LINE_SECONDS" PI_ROUNDS="$PI_ROUNDS" JAVA_SECONDS="$JAVA_SECONDS" "$GUEST_RUN" "$step_name" "$@"
    # What the guest would run, printed by the guest script itself (it runs nothing under DRY_RUN=1). In full for alternation 1 of
    # stock-lazy, and for the begin step of the other lanes (stock-full's debugfs write); the rest repeat it.
    if [[ $alt == 1 && ( $lane == stock-lazy || $step_name == begin ) ]]; then
      DRY_RUN=1 GUEST_LANE=$lane SMOKE="$SMOKE" CT_SECONDS="$CT_SECONDS" LINE_SECONDS="$LINE_SECONDS" PI_ROUNDS="$PI_ROUNDS" JAVA_SECONDS="$JAVA_SECONDS" \
        "$DIR/vm/guest-run.sh" "$step_name" "$@" | sed 's/^/    /'
    fi
  else
    run_bg "$LOGS/guest-$lane-alt$alt-$step_name.log" gx env SMOKE="$SMOKE" CT_SECONDS="$CT_SECONDS" LINE_SECONDS="$LINE_SECONDS" \
      PI_ROUNDS="$PI_ROUNDS" JAVA_SECONDS="$JAVA_SECONDS" "$GUEST_RUN" "$step_name" "$@"
  fi
}

# ---- 1 build the binaries once ------------------------------------------------------------------------------------------------
BINARIES=(cyclic-probe pi-demo line-simulator io-receive)
JAR=$DIR/java/target/preempt-rt-java.jar
step "build once, on the host; the same bytes go into every lane (sha256 checked in the guest by lane_revert)"
if ((DRY_RUN)); then
  printf '[dry-run] build_cpp %s; build_java java; SHA256SUMS of %s preempt-rt-java.jar\n' "${BINARIES[*]}" "${BINARIES[*]}"
else
  if [[ ${VERIFY_DRIVER:-0} != 1 ]]; then
    build_cpp "${BINARIES[@]}"
    build_java "$DIR/java"
    py_sync
  fi
  [[ -f $JAR ]] || die "missing $JAR (build first)"
  mkdir -p "$LANE_BIN_DIR"
  for b in "${BINARIES[@]}"; do cp "$(cpp_bin "$b")" "$LANE_BIN_DIR/$b"; done
  cp "$JAR" "$LANE_BIN_DIR/preempt-rt-java.jar"
  (cd "$LANE_BIN_DIR" && sha256sum "${BINARIES[@]}" preempt-rt-java.jar) >"$LANE_BIN_DIR/SHA256SUMS"
  cp "$LANE_BIN_DIR/SHA256SUMS" "$OUT/SHA256SUMS"
  ok "binaries: $(cut -c1-12 "$LANE_BIN_DIR/SHA256SUMS" | tr '\n' ' ')"
fi

# ---- 2 run-start.json -------------------------------------------------------------------------------------------------------------
step "run-start.json: commit, lab VM state, host load1 (per lane too), the snapshot of every lane"
if ((DRY_RUN)); then
  printf '[dry-run] virsh domstate %s; git rev-parse HEAD; require_quiet_host --lab-run (records host_load1); snapshots:' "$TARGET_VM"
  for lane in "${LANES[@]}"; do printf ' %s=%s' "$lane" "$(lane_snapshot "$lane")"; done
  printf '\n'
else
  lab_state=unknown
  command -v virsh >/dev/null 2>&1 && lab_state=$(timeout 10 virsh domstate "$TARGET_VM" 2>/dev/null | head -n1 || echo unknown)
  commit=$(git -C "$LOWLAT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
  dirty=false
  [[ -z $(git -C "$LOWLAT_ROOT" status --porcelain -- examples/14-preempt-rt scripts examples/_lib examples/common 2>/dev/null) ]] || dirty=true
  snaps=$(for lane in "${LANES[@]}"; do jq -n --arg l "$lane" --arg s "$(lane_snapshot "$lane")" '{($l): $s}'; done | jq -s add)
  printf '{}\n' >"$RUN_START_JSON"
  require_quiet_host --lab-run
  jq_edit "$RUN_START_JSON" --arg ex "$EXAMPLE" --arg commit "$commit" --argjson dirty "$dirty" --arg lab "$lab_state" --argjson snaps "$snaps" --argjson rounds "$ROUNDS" \
    --argjson ct "$CT_SECONDS" --argjson line "$LINE_SECONDS" --argjson pi "$PI_ROUNDS" --argjson java "$JAVA_SECONDS" --arg smoke "$SMOKE" \
    '. + {schema: "lowlat-run-start/1", example: $ex, mode: "vm", commit: $commit, tree_dirty: $dirty, lab_vm: $lab, snapshots: $snaps, rounds: $rounds,
          durations: {cyclictest_s: $ct, line_s: $line, pi_rounds: $pi, java_s: $java}, smoke: ($smoke == "1")}'
fi

# ---- 3 the lanes ------------------------------------------------------------------------------------------------------------------
# finalize_lane LANE D: the object form of runtime.environment.guest_profile (snapshot, profile, vcpu pins) on every file that has
# an environment block, and the /proc/interrupts deltas of the measured window on the two latency reports that ran in it.
finalize_lane() {
  local lane=$1 d=$2 f snap
  snap=$(lane_snapshot "$lane")
  while IFS= read -r f; do
    jq -e '.runtime.environment' "$f" >/dev/null 2>&1 || continue
    jq_edit "$f" --arg snap "$snap" --arg prof "$GUEST_PROFILE_SUFFIX" --slurpfile pins "$d/vcpupin.json" \
      '.runtime.environment.guest_profile = {snapshot: $snap, profile: $prof, vcpupin: $pins[0]}'
  done < <(find "$d" -name '*.json' | sort)
  for f in "$d"/cyclictest/*.json "$d/probe.json"; do
    [[ -f $f ]] || die "$lane: ${f#"$VMOUT"/} was not produced"
    jq_edit "$f" --slurpfile irq "$d/interrupts.json" '.runtime.counters.interrupts = $irq[0]'
  done
}

plan_lane() {
  local lane=$1 alt=$2 snap
  snap=$(lane_snapshot "$lane")
  step "lane $lane, alternation $alt (snapshot $snap)"
  printf '[dry-run] require_quiet_host --lab-run   (host load1 <= %s; ALLOW_BUSY=1 only records it)\n' "${LAB_RUN_LOAD1:-2}"
  printf '[dry-run] lane_revert %s   (revert-vm.sh, then push and sha256-check %s files into ~/%s/lane-bin)\n' "$snap" "$((${#BINARIES[@]} + 1))" "$GUEST_REPO"
  x "$LAB/deploy-to-vm.sh" "$TARGET_VM"
  guest_step "$lane" "$alt" begin "$lane" "$alt"
  guest_step "$lane" "$alt" idle-wait 180
  printf '[dry-run] guest_fetch %s/lane-out/profile.json <results>/%s/alt%s/profile.json; vcpupin_record <results>/%s/alt%s/vcpupin.json\n' "$GUEST_REPO" "$lane" "$alt" "$lane" "$alt"
  printf '[dry-run] guest_noise 0-3 %s hackbench; guest_noise 0-3 %s cpu   (NOISE_SHARED_LANE=1: the load is on every vCPU)\n' "$((CT_SECONDS + 20))" "$((CT_SECONDS + 20))"
  printf '[dry-run] cyclictest_run --allow-overflow <results>/%s/alt%s/cyclictest -q -m -p 95 -a %s -t 1 -i %s -D %s -h %s  (in the background; GUEST_PROFILE=%s)\n' \
    "$lane" "$alt" "$CT_CPU" "$INTERVAL_US" "$CT_SECONDS" "$CT_HIST_US" "$(lane_guest_profile "$lane")"
  printf '[dry-run] interrupts_delta <results>/%s/alt%s/interrupts.json 0 1 2 3 -- guest-run.sh probe\n' "$lane" "$alt"
  guest_step "$lane" "$alt" probe
  printf '[dry-run] wait for cyclictest_run; guest_noise_wait both\n'
  for s in line pi java end; do guest_step "$lane" "$alt" "$s"; done
  printf '[dry-run] guest_fetch %s/lane-out/ <results>/%s/alt%s; finalize_lane (guest_profile object with vcpupin, interrupts deltas)\n' "$GUEST_REPO" "$lane" "$alt"
}

run_lane() {
  local lane=$1 alt=$2 snap d h_hack h_cpu ct noise_secs rc=0
  if ((DRY_RUN)); then
    plan_lane "$lane" "$alt"
    return 0
  fi
  snap=$(lane_snapshot "$lane")
  d=$VMOUT/$lane/alt$alt
  mkdir -p "$d/cyclictest"
  step "lane $lane, alternation $alt (snapshot $snap)"
  LAB_RUN_LOAD1_FILE=$d/host-load1.txt require_quiet_host --lab-run
  lane_revert "$snap"
  "$LAB/deploy-to-vm.sh" "$TARGET_VM" >"$LOGS/deploy-$lane-alt$alt.log" 2>&1 || { tail -n 20 "$LOGS/deploy-$lane-alt$alt.log" >&2; die "deploy-to-vm.sh failed"; }
  guest_step "$lane" "$alt" begin "$lane" "$alt"
  guest_step "$lane" "$alt" idle-wait 180
  guest_fetch "$GUEST_REPO/lane-out/profile.json" "$d/profile.json"
  export LOWLAT_PROFILE=$d/profile.json
  vcpupin_record "$d/vcpupin.json"
  # The pins are libvirt configuration, the same in every lane: run-start.json keeps the first lane's record, each lane its own.
  jq -e 'has("vcpupin")' "$RUN_START_JSON" >/dev/null ||
    jq_edit "$RUN_START_JSON" --slurpfile p "$d/vcpupin.json" '.vcpupin = $p[0]'

  # The load: hackbench and stress-ng --cpu on all four vCPUs for the whole window, SCHED_OTHER, timeout -s KILL (guest_noise).
  noise_secs=$((CT_SECONDS + 20))
  export NOISE_SHARED_LANE=1
  h_hack=$(guest_noise 0-3 "$noise_secs" hackbench)
  h_cpu=$(guest_noise 0-3 "$noise_secs" cpu)

  # cyclictest on CPU 3 from the host (lib.sh cyclictest_run), cyclic-probe on CPU 2 in the guest; the same window, the same period.
  export GUEST_PROFILE
  GUEST_PROFILE=$(lane_guest_profile "$lane")
  export CYCLICTEST_VARIANT=cyclictest CYCLICTEST_TIMEOUT=$((CT_SECONDS + 60))
  cyclictest_run --allow-overflow "$d/cyclictest" -q -m -p 95 -a "$CT_CPU" -t 1 -i "$INTERVAL_US" -D "$CT_SECONDS" -h "$CT_HIST_US" \
    >"$LOGS/cyclictest-$lane-alt$alt.log" 2>&1 &
  ct=$!
  bg_track "$ct"
  # interrupts_delta runs the probe through `guest`, so the probe's own output goes to its log, not the console.
  interrupts_delta "$d/interrupts.json" 0 1 2 3 -- env "SMOKE=$SMOKE" "CT_SECONDS=$CT_SECONDS" "$GUEST_RUN" probe \
    >"$LOGS/guest-$lane-alt$alt-probe.log" 2>&1 || rc=$?
  wait "$ct" || { tail -n 20 "$LOGS/cyclictest-$lane-alt$alt.log" >&2; die "cyclictest_run failed in lane $lane alternation $alt"; }
  bg_forget "$ct"
  ((rc == 0)) || { tail -n 20 "$LOGS/guest-$lane-alt$alt-probe.log" >&2; die "the guest probe step failed in lane $lane alternation $alt"; }
  guest_noise_wait "$h_hack"
  guest_noise_wait "$h_cpu"
  ok "$lane alt$alt: cyclictest $(jq -r '"p99.9 \(.percentiles.p99_9 / 1000 | floor) us, max \(.percentiles.max / 1000 | floor) us"' "$d"/cyclictest/*.json | head -n1)"

  for s in line pi java end; do guest_step "$lane" "$alt" "$s"; done
  guest_fetch "$GUEST_REPO/lane-out/" "$d"
  finalize_lane "$lane" "$d"
}

interleave_env "$ROUNDS" "${LANES[@]}"

# ---- 4 shut down, 5 evaluate --------------------------------------------------------------------------------------------------------
if ((!DRY_RUN)); then scrub_results "$OUT"; fi
down_vm
if [[ ${VERIFY_DRIVER:-0} == 1 ]] || ((DRY_RUN)); then
  ((DRY_RUN)) && printf '[dry-run] RECHECK=%s %s/verify.sh\n' "$OUT" "$DIR"
  exit 0
fi
step "evaluate the results directory (the guest is already down)"
RECHECK="$OUT" SMOKE="$SMOKE" "$DIR/verify.sh"
