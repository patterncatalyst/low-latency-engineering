#!/usr/bin/env bash
# Ch13 host driver (VM=1 ../verify.sh, or this script): the six lanes in one interleaved run.
#
# One run, in this order:
#   1  revert the lab guest to snapshot lab-ready-r04 and bring it up (scripts/lab/revert-vm.sh, lab-up.sh)
#   2  deploy the repository (scripts/lab/deploy-to-vm.sh), push the two jars, check the three images against
#      containers/IMAGES.lock, and have vm/guest-run.sh prepare the guest: its profile, and the four C++ binaries
#      copied out of the place-cpp image through container_run
#   3  copy those four binaries to the host: the host, vm and container lanes run the very same files (D10)
#   4  require_quiet_host --lab-idle: the guest may be running, but only idle (load1 <= LAB_IDLE_LOAD1)
#   5  run the lanes interleaved, alternation by alternation:  host vm container-host-net container-bridge
#      container-cpu-quota container-cpuset  x 3  (lib.sh interleave_env). The host lane waits until the guest is
#      under 1 percent busy, and the guest's busy share across it is recorded. Comparisons are inside this one run (D9).
#   6  fetch the guest's results with guest_fetch and evaluate the whole results directory (verify.sh RECHECK)
#   7  shut the guest down (scripts/lab/lab-down.sh), always, unless KEEP_VM=1
#
# Nothing on the host changes: no sudo, no sysctl, no Docker. The guest is reached only through
# scripts/lab/lab-ssh.sh (ssh over vsock behind passt); it is the guest that runs Docker.
#
#   DRY_RUN=1       print each command this script would run, and the commands vm/guest-run.sh would run, and run nothing
#   SMOKE=1         2 s lanes, one alternation, nothing enforced (a check of the scripts, not a measurement); needs RESULTS_DIR
#   SKIP_BUILD=1    reuse the host builds of the two jars
#   KEEP_VM=1       leave the guest up at the end (to look at a failed run)
#   REUSE_VM=1      do not revert or deploy: use the guest as it is (it must already be prepared)
#   LAB_IDLE_LOAD1  the load1 the guest may have at the start (default 0.5)
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
# shellcheck source=../../../versions.env
# shellcheck source-path=SCRIPTDIR
. "$LOWLAT_ROOT/versions.env"

DRY_RUN=${DRY_RUN:-0}
SMOKE=${SMOKE:-0}
DIR=$EXAMPLE_DIR
LAB=$LOWLAT_ROOT/scripts/lab
TARGET=${TARGET_VM:-lowlat-target}
SNAPSHOT=lab-ready-r04
GUEST_REPO=${GUEST_REPO:-low-latency-engineering}
export RESULTS_DIR=${RESULTS_DIR:-$DIR/results/latest}
export LIBVIRT_DEFAULT_URI=${LIBVIRT_DEFAULT_URI:-qemu:///system}
export GUEST_PROFILE=$GUEST_PROFILE_NAME
GUEST_RUN=examples/$EXAMPLE/vm/guest-run.sh # relative to the repository in the guest
GUEST_OUT=examples/$EXAMPLE/vm-out         # ... and where the guest writes
((SMOKE)) && ROUNDS=1

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
  OUT=${RESULTS_DIR:-$DIR/results/latest}
  scratch_dir
else
  OUT=$(results_dir)
  # Remove only what this script writes, and only under a real results path.
  [[ $OUT == /*/*/* ]] || die "refusing to clear subdirectories of $OUT"
  for lane in "${LANES[@]}"; do rm -rf "${OUT:?}/$lane"; done
  rm -rf "${OUT:?}/logs"
  rm -f "${OUT:?}"/*.json "${OUT:?}"/*.log
  mkdir -p "$OUT"
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
# guest_lane LANE ALT: one guest lane, its console output to a driver log outside the results.
guest_lane() {
  local lane=$1 alt=$2
  if ((DRY_RUN)); then
    gx env SMOKE="$SMOKE" LINE_RATE="$LINE_RATE" LINE_SECONDS="$LINE_SECONDS" Q_RATE="$Q_RATE" Q_SECONDS="$Q_SECONDS" \
      Q_WARMUP_SECONDS="$Q_WARMUP_SECONDS" "$GUEST_RUN" lane "$lane" "$alt"
  else
    run_bg "$LOGS/guest-$lane-alt$alt.log" gx env SMOKE="$SMOKE" LINE_RATE="$LINE_RATE" LINE_SECONDS="$LINE_SECONDS" Q_RATE="$Q_RATE" \
      Q_SECONDS="$Q_SECONDS" Q_WARMUP_SECONDS="$Q_WARMUP_SECONDS" "$GUEST_RUN" lane "$lane" "$alt"
  fi
  if ((DRY_RUN)); then
    # What the guest would run, printed by the guest script itself (it runs nothing under DRY_RUN=1).
    DRY_RUN=1 SMOKE="$SMOKE" LINE_SECONDS="$LINE_SECONDS" "$DIR/vm/guest-run.sh" lane "$lane" "$alt"
  fi
}

# ---- 1 host build -----------------------------------------------------------------------------------------------------------
CLIENT_JAR=$DIR/../12-io-engines/java/target/io-engines-java.jar
CPUPROBE_JAR=$DIR/java/target/where-code-runs-java.jar
if ((!DRY_RUN)); then
  if [[ ${VERIFY_DRIVER:-0} != 1 ]]; then
    build_java "$DIR/java"
    build_java "$DIR/../12-io-engines/java"
    py_sync
  fi
  [[ -f $CLIENT_JAR && -f $CPUPROBE_JAR ]] || die "missing $CLIENT_JAR or $CPUPROBE_JAR (build first)"
fi

# ---- 2 the guest ------------------------------------------------------------------------------------------------------------
if [[ ${REUSE_VM:-0} != 1 ]]; then
  step "revert $TARGET to $SNAPSHOT and bring it up"
  x "$LAB/revert-vm.sh" "$TARGET" "$SNAPSHOT"
  x "$LAB/lab-up.sh"
  step "deploy the repository into the guest"
  x "$LAB/deploy-to-vm.sh" "$TARGET"
else
  step "REUSE_VM=1: using the guest as it is"
fi

step "the guest: Temurin, and the three images against containers/IMAGES.lock"
if ((DRY_RUN)); then
  printf '[dry-run] lab_ssh java -version | expect Temurin-%s\n' "${TEMURIN_VERSION:-?}"
else
  java_line=$(lab_ssh 'java -version 2>&1' </dev/null | head -n2 | tr '\n' ' ')
  [[ $java_line == *"Temurin-$TEMURIN_VERSION+"* ]] || die "the guest's java is not Temurin $TEMURIN_VERSION: $java_line"
  ok "the guest runs Temurin $TEMURIN_VERSION"
fi
LOCK=$DIR/containers/IMAGES.lock
for image in "$IMAGE_CPP" "$IMAGE_JAVA" "$IMAGE_PY"; do
  want=$(awk -v ref="$image" '!/^[[:space:]]*(#|$)/ { n = split($1, a, "@"); if (a[1] == ref) { print a[2]; exit } }' "$LOCK")
  [[ $want =~ ^sha256:[0-9a-f]{64}$ ]] || die "$image has no usable digest in IMAGES.lock ('$want'): build the images in the guest (containers/build-images.sh) and commit the lock"
  if ((DRY_RUN)); then
    printf '[dry-run] lab_ssh docker image inspect --format {{.Id}} %s | expect %s\n' "$image" "$want"
  else
    have=$(lab_ssh "docker image inspect --format '{{.Id}}' $image" </dev/null 2>/dev/null) || have=missing
    [[ $have == "$want" ]] ||
      die "the guest's $image is $have, IMAGES.lock says $want: rebuild the images in the guest (containers/build-images.sh), commit the lock, and take the lab-ready-r04 snapshot again"
    ok "$image is $want"
  fi
done

step "prepare the guest: output directory, guest profile, the four C++ binaries out of the image"
# The output directory is world-writable: the containers run as uid 10001 and write their reports into it.
gx install -d -m 0777 "$GUEST_OUT" "$GUEST_OUT/jars"
push_jar() {
  if ((DRY_RUN)); then
    printf '[dry-run] lab_ssh cat \\> %s/%s/jars/%s < %s\n' "$GUEST_REPO" "$GUEST_OUT" "$2" "$1"
  else
    lab_ssh "cat >$(printf '%q' "$GUEST_REPO/$GUEST_OUT/jars/$2")" <"$1" || die "cannot push $2 into the guest"
  fi
}
push_jar "$CLIENT_JAR" io-engines-java.jar
push_jar "$CPUPROBE_JAR" where-code-runs-java.jar
if ((DRY_RUN)); then
  gx "$GUEST_RUN" prepare
else
  run_bg "$LOGS/guest-prepare.log" gx "$GUEST_RUN" prepare
fi

HOST_BIN=$LOWLAT_SCRATCH/bin
if ((DRY_RUN)); then
  printf '[dry-run] guest_fetch %s/%s/bin/ %s\n' "$GUEST_REPO" "$GUEST_OUT" "$HOST_BIN"
  printf '[dry-run] guest_fetch %s/%s/profile.json %s/guest-profile.json\n' "$GUEST_REPO" "$GUEST_OUT" "$OUT"
else
  guest_fetch "$GUEST_REPO/$GUEST_OUT/bin/" "$HOST_BIN"
  for b in "${CPP_BINARIES[@]}"; do
    [[ -f $HOST_BIN/$b ]] || die "$b was not copied out of the image"
    chmod +x "$HOST_BIN/$b"
  done
  "$HOST_BIN/place-probe" >/dev/null || die "the binary copied out of the image does not run on the host"
  ok "the host runs the same four binaries as the guest and the containers: $(cd "$HOST_BIN" && sha256sum "${CPP_BINARIES[@]}" | cut -c1-12 | tr '\n' ' ')"
  guest_fetch "$GUEST_REPO/$GUEST_OUT/profile.json" "$OUT/guest-profile.json"
fi

# ---- the host lane needs a quiet host and an idle guest -----------------------------------------------------------------------
step "require_quiet_host --lab-idle: the guest may run, but only idle"
if ((DRY_RUN)); then
  printf '[dry-run] require_quiet_host --lab-idle   (records lab_vm and lab_vm_load1 in %s)\n' "$RUN_START_JSON"
  HOST_CPU=${HOST_CPU:-1}
else
  gx "$GUEST_RUN" idle-wait 180
  # load1 decays slowly after the preparation; poll until it is under the limit, then record it in this shell.
  # Up to 6 minutes: a freshly reverted guest can run its own timers (dnf makecache, for one) for a while.
  for ((i = 0; i < 36; i++)); do
    (require_quiet_host --lab-idle) >/dev/null 2>&1 && break
    sleep 10
  done
  if ! (require_quiet_host --lab-idle) >/dev/null 2>&1; then
    echo "the guest's busiest processes:" >&2
    guest 'ps -eo pcpu,etime,comm --sort=-pcpu | head -6' </dev/null >&2 || true
  fi
  require_quiet_host --lab-idle
  capture_profile "$OUT"
  # The consumer's CPU on the host: a physical core other than CPU 0 (an experiment control, not isolation).
  HOST_CPU=$(distinct_cores 3 | awk '$1 != 0 {print; exit}')
  [[ -n $HOST_CPU ]] || die "no physical core other than CPU 0 for the host consumer"
  jq --arg ex "$EXAMPLE" --argjson host_cpu "$HOST_CPU" --argjson guest_cpu "$GUEST_CPU" --argjson rounds "$ROUNDS" --arg smoke "$SMOKE" --arg reused "${REUSE_VM:-0}" \
    '. + {example: $ex, mode: "vm", reverted: ($reused != "1"), host_consumer_cpu: $host_cpu, guest_consumer_cpu: $guest_cpu, rounds: $rounds, smoke: ($smoke == "1")}' \
    "$RUN_START_JSON" >"$RUN_START_JSON.tmp" && mv "$RUN_START_JSON.tmp" "$RUN_START_JSON"
  ok "guest state for the host lane: $(jq -r '"\(.lab_vm), load1 \(.lab_vm_load1)"' "$RUN_START_JSON")"
fi
set_lane_args

# host_lane ALT: wait for an idle guest, run the host lane, and record how busy the guest was across it.
host_lane() {
  local alt=$1 b0 t0 b1 t1 d=$OUT/host/alt$1
  if ((DRY_RUN)); then
    printf '[dry-run] host lane, alternation %s: guest idle-wait, proc-stat, host_lane_run (consumer on CPU %s), proc-stat\n' "$alt" "$HOST_CPU"
    return 0
  fi
  gx "$GUEST_RUN" idle-wait 180
  read -r b0 t0 < <(gx "$GUEST_RUN" proc-stat)
  run_bg "$LOGS/host-alt$alt.log" host_lane_run "$alt"
  read -r b1 t1 < <(gx "$GUEST_RUN" proc-stat)
  ((t1 > t0)) || die "the guest's /proc/stat did not advance across the host lane"
  jq -n --argjson b $((b1 - b0)) --argjson t $((t1 - t0)) --arg ex "$EXAMPLE" \
    '{schema: "lowlat-guest-idle/1", example: $ex, busy_ticks: $b, total_ticks: $t, busy_permille: (1000 * $b / $t | floor)}' >"$d/guest-idle.json"
  ok "the guest was $(jq -r .busy_permille "$d/guest-idle.json")/1000 busy across the host lane (alternation $alt)"
}

run_lane() {
  case $1 in
    host) host_lane "$2" ;;
    *) guest_lane "$1" "$2" ;;
  esac
}

# ---- 5 the lanes, interleaved ---------------------------------------------------------------------------------------------
if ((!DRY_RUN)); then
  # The Python probe and CpuProbe are run by host_lane_run; the host consumer pins to HOST_CPU.
  export HOST_BIN HOST_CPU CPUPROBE_JAR
fi
interleave_env "$ROUNDS" "${LANES[@]}"

# ---- 6 fetch, shut down, evaluate -----------------------------------------------------------------------------------------------
if ((DRY_RUN)); then
  printf '[dry-run] guest_fetch %s/%s/ <scratch>; move the vm and container-* lane directories into %s\n' "$GUEST_REPO" "$GUEST_OUT" "$OUT"
else
  step "fetch the guest's lane directories"
  guest_fetch "$GUEST_REPO/$GUEST_OUT/" "$LOWLAT_SCRATCH/vm-out"
  for lane in "${LANES[@]}"; do
    [[ $lane == host ]] && continue
    [[ -d $LOWLAT_SCRATCH/vm-out/$lane ]] || die "the guest produced no $lane directory"
    mv "$LOWLAT_SCRATCH/vm-out/$lane" "$OUT/$lane"
  done
  scrub_results "$OUT"
fi
down_vm

if [[ ${VERIFY_DRIVER:-0} == 1 ]] || ((DRY_RUN)); then
  ((DRY_RUN)) && printf '[dry-run] RECHECK=%s %s/verify.sh\n' "$OUT" "$DIR"
  exit 0
fi
step "evaluate the results directory (the guest is already down)"
RECHECK="$OUT" SMOKE="$SMOKE" "$DIR/verify.sh"
