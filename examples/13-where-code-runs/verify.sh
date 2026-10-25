#!/usr/bin/env bash
# Ch13 verify: where the code runs, on bare metal, in a VM, or in a container in that VM (C++, Java, Python).
#
# Six lanes, run interleaved in ONE run (host vm container-host-net container-bridge container-cpu-quota container-cpuset,
# three alternations), because a number from one run is never compared with a number from another (D9). Every number is
# lane-labelled and means "on this laptop's KVM, in this run". Host against VM is observed, never asserted. The container
# costs are container-in-VM costs: they are measured against the VM-native lane in the same guest, not against bare metal.
# Every criterion is evaluated; each prints its measured value, its bound and the margin, and any miss fails the run after all
# of them have been evaluated. Counters labelled "exact" are deterministic and need no median; a latency ratio is the median
# of the three per-alternation ratios.
#   1  (exact) the cgroup counters the container itself reported at the end of its run: container-cpu-quota nr_throttled >= 1
#      and throttled_usec >= 1; container-cpuset nr_throttled == 0 and throttled_usec == 0. cpu.max is "200000 100000" under
#      --cpus=2 and "max 100000" under --cpuset-cpus=2,3; cpuset.cpus.effective is "2-3" there. The busy pool ran 4 workers,
#      every one of which iterated.
#   2  (exact) what each runtime thinks it has, on the 4-vCPU guest, under the quota and under the cpuset. C++
#      hardware_concurrency() = 4 in both (it is the kernel's online CPU list, which a container does not narrow); the
#      affinity mask is 4 under the quota and 2 under the cpuset; the cgroup-aware pool size is 2 in both. Python
#      os.cpu_count() = 4 in both; os.process_cpu_count() = 4 under the quota and 2 under the cpuset and equals the affinity
#      mask. Java availableProcessors() = 2 in both, and so is the most virtual threads mounted at once under a saturating spin.
#   3  (exact) io_uring_setup in a container under Docker's default seccomp profile returns EPERM (1), in every container
#      lane; the same binary in the guest outside a container returns 0. The host's value is observed. Behind CRIT3_ASSERTED.
#   4  container-cpu-quota consumer p99.9 >= 2x container-cpuset (same run, median of 3). Observed unless it shows twice the
#      margin (CRIT4_ASSERTED, default 1 since the S10 calibration; 0 makes it observed).
#   5  every lane, every alternation: count, dropped == 0, lowlat-report check, runtime.environment.kind matching the lane
#      (the bridge lane's simulator report says vm: it ran in the guest), guest profile recorded for vm and container lanes,
#      the container lanes' image digest equal to containers/IMAGES.lock, the lane's network, quota, cpuset and seccomp, the
#      consumer's pin, one set of C++ binary checksums across every lane, and a lab guest that was up and idle for the host lane.
#   -  completeness: every lane x alternation must have every report it should, and a run that did not run every lane fails
#      as partial.
# Observed, not asserted: host against VM (D9), bridge against host network, steal ticks, the simulator's emit lateness per
# lane, Quarkus p99 under the quota against the cpuset, Java ergonomics (GC threads, event loops), the pool's start skew.
#
#   ./verify.sh                 build, unit tests, run the HOST lane three times, evaluate: it ends non-zero as a partial run
#   VM=1 ./verify.sh            build, unit tests, then vm/run.sh: revert the lab guest, run all six lanes interleaved, fetch, evaluate
#   RECHECK=results/<run-id>    re-evaluate a results directory without building or running anything
#   ALLOW_BUSY=1 ./verify.sh    measure while a lab VM or other load is running (noisy)
#   SKIP_BUILD=1 ./verify.sh    reuse existing builds
#   SMOKE=1 RESULTS_DIR=DIR     small workloads, a check of this script (not a measurement, nothing enforced)
#   RESULTS_DIR=DIR             where reports go (default results/latest)
#   LOWLAT_BUILD=DIR            private C++ build directory
#   CRIT3_ASSERTED=0|1          (default 1) criterion 3 asserted; 0 observes it
#   CRIT4_ASSERTED=0|1          (default 1) criterion 4 asserted: S10 measured 14.2x to 27.0x over 9 alternations (min margin 7.1x); 0 observes it
#
# Run it under the host benchmark lock when another example measures on this host, and give flock -o so the lock
#   flock -o "$LOCK" ./verify.sh
# is not inherited by the script or anything it starts. On TERM or INT the script stops its whole process tree before it exits.
# UDP ports 47340-47343 and TCP 47344 (examples 00-12 use 47000-47336). Never changes the host: no sudo, no sysctl, no governor,
# no Docker on the host. The containers and the lab guest are driven by vm/run.sh and vm/guest-run.sh, through lib.sh's
# container_run, inside the guest.
# shellcheck disable=SC2016
set -euo pipefail
trap 'exit 143' TERM
trap 'exit 130' INT
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"
# shellcheck source=lanes.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/lanes.sh"

HERE=$EXAMPLE_DIR
CPUPROBE_JAR=$HERE/java/target/where-code-runs-java.jar
LOCK_FILE=$HERE/containers/IMAGES.lock

# ---- bounds (set from the calibration runs; a miss is reported, never loosened here) -------------------------------------
NR_THROTTLED_QUOTA_MIN=1                      # 1: exact, at least one throttled period under --cpus=2
QUOTA_P999_RATIO_MIN_PERMILLE=2000            # 4: quota p99.9 >= 2x cpuset (asserted only if CRIT4_ASSERTED)
CRIT4_ASSERTED=${CRIT4_ASSERTED:-1}           # S10: >= 14.2x in every alternation of 3 runs, so asserted (user, 2026-10-25)
CRIT3_ASSERTED=${CRIT3_ASSERTED:-1}           # 3: the EPERM and success are exact; 0 observes them if S5 finds the guest's Docker behaves otherwise
EPERM=1
GUEST_IDLE_MAX_PERMILLE=100                   # 5: workload guard, the guest's busy share across the host lane (10 percent; idle is about 0)
POOL_WORKERS=4                                # 1: the pool is sized by hardware_concurrency(), which is 4 on the guest
EXPECT_GUEST_VCPUS=4                          # 2: the lab guest has 4 vCPUs (stock-unpinned); GUEST_VCPUS below is read from its profile and must say so

if [[ ${SMOKE:-0} == 1 ]]; then
  # A check of this script, not a measurement: small workloads, every criterion evaluated and printed, none enforced.
  [[ -n ${RESULTS_DIR:-} ]] || { echo "SMOKE=1 needs RESULTS_DIR (it must not overwrite results/latest)" >&2; exit 2; }
  ROUNDS=1
fi
LINE_COUNT=$(line_count)

if [[ -n ${RECHECK:-} ]]; then
  OUT=$(cd "$RECHECK" && pwd)
  export LOWLAT_PROFILE=$OUT/profile.json
  RUN=0
else
  RUN=1
  OUT=$(results_dir)
  export RESULTS_DIR=$OUT
  # Remove only what this script writes, and only under a real results path.
  [[ $OUT == /*/*/* ]] || die "refusing to clear subdirectories of $OUT"
  for lane in "${LANES[@]}"; do rm -rf "${OUT:?}/$lane"; done
  rm -rf "${OUT:?}/logs"
  rm -f "${OUT:?}"/*.json "${OUT:?}"/*.log "${OUT:?}"/*.txt
  mkdir -p "$OUT"
  # Driver logs are written outside the results directory (this script clears *.log there) and moved in at the end.
  scratch_dir
  LOGS=$LOWLAT_SCRATCH/logs
  mkdir -p "$LOGS"
fi
finish_logs() {
  if [[ -n ${LOGS:-} && -d $LOGS ]]; then
    mkdir -p "$OUT/logs"
    find "$LOGS" -maxdepth 1 -name '*.log' -exec mv -t "$OUT/logs" {} + 2>/dev/null || true
  fi
}
trap 'finish_logs; _bg_cleanup' EXIT
scratch_dir
RATIO_FAULTS=$LOWLAT_SCRATCH/ratio-faults
: >"$RATIO_FAULTS"

# ---- helpers (the house crit_* pattern of examples 11 and 12) ---------------------------------------------------------------
margin() { awk -v a="$1" -v b="$2" 'BEGIN { if (b == 0) print "inf"; else printf "%.2f", a / b }'; }
note_margin() { awk -v m="$1" 'BEGIN { if (m != "inf" && m + 0 < 2) print " [margin under 2x: value reported, bound unchanged]" }'; }
crit_ge() {
  local m
  m=$(margin "$3" "$4")
  if (($3 >= $4)); then ok "$1 $2: measured $3, bound >= $4, margin ${m}x$(note_margin "$m")"; else bad "$1 $2: measured $3, bound >= $4, margin ${m}x"; fi
}
crit_le() {
  local m
  m=$(margin "$4" "$3")
  if (($3 <= $4)); then ok "$1 $2: measured $3, bound <= $4, margin ${m}x$(note_margin "$m")"; else bad "$1 $2: measured $3, bound <= $4, margin ${m}x"; fi
}
crit_exact() {
  if [[ $3 == "$4" ]]; then ok "$1 $2: measured $3, bound == $4 (exact)"; else bad "$1 $2: measured $3, bound == $4 (exact)"; fi
}
crit_ratio_ge() {
  local m
  m=$(margin "$4" "$5")
  if (($4 >= $5)); then
    ok "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x$(note_margin "$m")"
  else
    bad "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x"
  fi
}

# val FILE JQ: one value from a JSON file; a file or a key that is not there is a failed run, named.
val() {
  local v
  [[ -f $1 ]] || die "${1#"$OUT"/} is missing"
  v=$(jq -r "$2" "$1" 2>/dev/null) || die "${1#"$OUT"/}: cannot read $2"
  [[ -n $v && $v != null ]] || die "${1#"$OUT"/}: $2 is missing or null"
  printf '%s' "$v"
}
# val_or_null FILE JQ: like val, but a null (a limit that is not set) is the text "null".
val_or_null() {
  local v
  [[ -f $1 ]] || die "${1#"$OUT"/} is missing"
  v=$(jq -r "$2 // \"null\"" "$1" 2>/dev/null) || die "${1#"$OUT"/}: cannot read $2"
  printf '%s' "$v"
}
# P LANE ALT REL: the path of one lane's file.
P() { printf '%s/%s/alt%s/%s' "$OUT" "$1" "$2" "$3"; }
have() { [[ -f $1 ]]; }
p999() { val "$1" .percentiles.p99_9; }
p99() { val "$1" .percentiles.p99; }
# pct FILE: "p50 / p99 / p99.9 / max" in microseconds.
pct() { jq -r '"\(.percentiles.p50 / 1000 | floor) / \(.percentiles.p99 / 1000 | floor) / \(.percentiles.p99_9 / 1000 | floor) / \(.percentiles.max / 1000 | floor) us"' "$1"; }
# alt_ratio NUM DEN: the ratio of two p99.9 values in thousandths. A zero denominator is a failure of the measurement: it
# prints 0 (so a >= bound fails) and is recorded in $RATIO_FAULTS, which the end of the run turns into a failed criterion.
alt_ratio() {
  local den
  den=$(p999 "$2")
  if ((den <= 0)); then
    echo "alt_ratio: p99.9 denominator $den ($2) for numerator $(p999 "$1") ($1)" >>"$RATIO_FAULTS"
    echo 0
  else
    echo $((1000 * $(p999 "$1") / den))
  fi
}
lock_digest() { awk -v ref="$1" '!/^[[:space:]]*(#|$)/ { n = split($1, a, "@"); if (a[1] == ref) { print a[2]; exit } }' "$LOCK_FILE"; }

# ---- build, unit tests, and the host lane ---------------------------------------------------------------------------------------
if ((RUN)); then
  uv python find 3.14.9t >/dev/null 2>&1 || die "no free-threaded Python: uv python install 3.14.9t (a user-local download; the tests run under both builds)"
  build_cpp place-probe busy-pool place-test io-receive line-simulator
  BUILD_JAVA_TESTS=1 build_java "$HERE/java"
  build_java "$HERE/../12-io-engines/java"
  py_sync
  [[ -f $CPUPROBE_JAR ]] || die "missing $CPUPROBE_JAR (build first)"

  step "unit tests: C++ (GoogleTest), Python under the GIL and under the free-threaded build; Java ran during the build"
  "$(cpp_bin place-test)" --gtest_brief=1 >"$LOGS/cpp-unit-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-unit-tests.log" >&2; die "C++ unit tests failed"; }
  uvrun pytest -q "$HERE/place-py/tests" >"$LOGS/python-unit-tests-gil.log" 2>&1 || { tail -20 "$LOGS/python-unit-tests-gil.log" >&2; die "Python (GIL) tests failed"; }
  (cd "$LOWLAT_EXAMPLES" && LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$LOWLAT_EXAMPLES/.venv-ft \
    uv run -q --python 3.14.9t --all-packages pytest -q "$HERE/place-py/tests") >"$LOGS/python-unit-tests-free-threaded.log" 2>&1 ||
    { tail -20 "$LOGS/python-unit-tests-free-threaded.log" >&2; die "Python (free-threaded) tests failed"; }
  ok "C++, Java and Python (both builds) unit tests pass"

  export RUN_START_JSON=$OUT/run-start.json
  if [[ ${VM:-0} == 1 ]]; then
    # vm/run.sh reverts the guest, runs all six lanes interleaved, fetches the guest's results and shuts the guest down.
    # It is told the builds are done, and not to evaluate: this script does that below.
    VERIFY_DRIVER=1 SKIP_BUILD=1 RESULTS_DIR=$OUT "$HERE/vm/run.sh" 2>&1 | tee "$LOGS/vm-run.log"
  else
    require_quiet_host
    capture_profile "$OUT"
    [[ -s $RUN_START_JSON ]] || printf '{}\n' >"$RUN_START_JSON"
    # The host lane alone, three times. The four C++ binaries are the ones just built (VM=1 uses the image's).
    HOST_BIN=$LOWLAT_SCRATCH/bin
    mkdir -p "$HOST_BIN"
    for b in "${CPP_BINARIES[@]}"; do cp "$(cpp_bin "$b")" "$HOST_BIN/$b"; done
    HOST_CPU=$(distinct_cores 3 | awk '$1 != 0 {print; exit}')
    [[ -n $HOST_CPU ]] || die "no physical core other than CPU 0 for the host consumer"
    jq --arg ex "$EXAMPLE" --argjson host_cpu "$HOST_CPU" --argjson guest_cpu "$GUEST_CPU" --argjson rounds "$ROUNDS" \
      '. + {example: $ex, mode: "host-only", host_consumer_cpu: $host_cpu, guest_consumer_cpu: $guest_cpu, rounds: $rounds}' \
      "$RUN_START_JSON" >"$RUN_START_JSON.tmp" && mv "$RUN_START_JSON.tmp" "$RUN_START_JSON"
    export HOST_BIN HOST_CPU CPUPROBE_JAR
    run_lane() { run_bg "$LOGS/host-alt$2.log" host_lane_run "$2"; }
    interleave_env "$ROUNDS" host
  fi
  scrub_results "$OUT"
fi

# ---- evaluate -----------------------------------------------------------------------------------------------------------------
[[ -f $OUT/profile.json ]] || die "no profile.json in $OUT"
# The reports this example is made of: the consumer and the simulator's lateness in every lane, and the Quarkus client in the
# limit lanes. They are named, not discovered, and each must say it is a lowlat-report/1: a file that swaps its schema string
# for something else would otherwise slip past both the discovery and the check below.
named_reports=()
for lane in "${LANES[@]}"; do
  for n in $(seq 1 "$ROUNDS"); do
    named_reports+=("$(P "$lane" "$n" cpp/consumer.json)" "$(P "$lane" "$n" cpp/lateness.json)")
    ! lane_has_pool "$lane" || named_reports+=("$(P "$lane" "$n" quarkus/client.json)")
  done
done
mapfile -t all_reports < <({
  find "$OUT" -name '*.json' ! -name profile.json ! -name guest-profile.json -exec grep -lE '"schema" ?: ?"lowlat-report/1"' {} +
  for f in "${named_reports[@]}"; do [[ -f $f ]] && echo "$f"; done
} | sort -u)
((${#all_reports[@]} > 0)) || die "no reports under $OUT"
RUN_MODE=unknown
[[ -f $OUT/run-start.json ]] && RUN_MODE=$(jq -r '.mode // "unknown"' "$OUT/run-start.json")
# The guest's CPU count comes from the guest's own profile, so the expectations below follow the machine that ran and a guest
# that was resized fails the first assertion instead of moving the others with it.
GUEST_VCPUS=$EXPECT_GUEST_VCPUS
[[ ! -f $OUT/guest-profile.json ]] || GUEST_VCPUS=$(val "$OUT/guest-profile.json" .cpu.logical_cpus)
# cpuset_count LIST: how many CPUs a list like 2,3 or 0-3 names.
cpuset_count() { local n=0 part; for part in ${1//,/ }; do if [[ $part == *-* ]]; then n=$((n + ${part#*-} - ${part%-*} + 1)); else n=$((n + 1)); fi; done; echo "$n"; }
CPUSET_COUNT=$(cpuset_count "$LIMIT_CPUSET")
# What each runtime should see on a GUEST_VCPUS guest: a quota is not a mask (Python and C++ still see every CPU; Java rounds the
# quota up), a cpuset is a mask (Python, C++ affinity and Java see it).
AWARE_QUOTA=$(( LIMIT_CPUS < GUEST_VCPUS ? LIMIT_CPUS : GUEST_VCPUS ))
AWARE_CPUSET=$(( CPUSET_COUNT < GUEST_VCPUS ? CPUSET_COUNT : GUEST_VCPUS ))

step "reports: schema (runtime.environment included), histogram decode, percentile recompute"
for f in "${named_reports[@]}"; do
  if [[ -f $f ]] && [[ $(jq -r '.schema // "none"' "$f" 2>/dev/null || echo unreadable) != "lowlat-report/1" ]]; then
    bad "5 ${f#"$OUT"/}: schema is not lowlat-report/1 (the file is not a report, so the checks below would not cover it)"
  fi
done
if report_check "${all_reports[@]}" >/dev/null 2>"$LOWLAT_SCRATCH/report-check.err"; then
  ok "5 ${#all_reports[@]} reports validate (profile embedded: $(jq -r '.profile.host_label' "${all_reports[0]}"))"
else
  cat "$LOWLAT_SCRATCH/report-check.err" >&2
  report_check "${all_reports[@]}" >&2 || true
  bad "5 lowlat-report check failed"
fi

# expected_files LANE ALT: every file this lane and alternation must have produced, relative to its directory.
expected_files() {
  local lane=$1
  echo cpp/consumer.json cpp/lateness.json cpp/probe-cpp.json python/probe-python.json java/probe-java.json
  if [[ $lane == container-bridge ]]; then echo cpp/binaries-consumer.txt cpp/binaries-sims.txt; else echo cpp/binaries-full.txt; fi
  if lane_has_pool "$lane"; then echo cpp/pool.json quarkus/client.json quarkus/service.json; fi
  if [[ $lane == host ]]; then
    echo host-quiet.json
    [[ $RUN_MODE != vm ]] || echo guest-idle.json # a host-only run has no guest to watch
  else
    echo steal.json
  fi
}
step "completeness: every lane x alternation has every file it should, and every lane ran"
declare -A MISSING=()
for f in profile.json run-start.json; do
  have "$OUT/$f" || bad "$f: missing"
done
have "$OUT/guest-profile.json" || bad "guest-profile.json: missing (the guest's own profile; a partial run has none)"
for lane in "${LANES[@]}"; do
  for n in $(seq 1 "$ROUNDS"); do
    for rel in $(expected_files "$lane"); do
      if ! have "$(P "$lane" "$n" "$rel")"; then
        bad "$lane/alt$n/$rel: missing (a lane that did not run proves nothing)"
        MISSING[$lane]=1
      fi
    done
  done
  [[ -d $OUT/$lane ]] || { bad "partial run: the $lane lane was not run"; MISSING[$lane]=1; }
done
((${#MISSING[@]} > 0)) || ok "every lane ran and every expected file is present"
# ok_lane LANE: true when none of the lane's files is missing.
ok_lane() { [[ -z ${MISSING[$1]:-} ]]; }
all_lanes_ok() { ((${#MISSING[@]} == 0)); }

# ---- criterion 5: every lane ---------------------------------------------------------------------------------------------------
IMG_CPP_DIGEST=$(lock_digest "$IMAGE_CPP")
IMG_JAVA_DIGEST=$(lock_digest "$IMAGE_JAVA")
IMG_PY_DIGEST=$(lock_digest "$IMAGE_PY")
for d in "$IMG_CPP_DIGEST" "$IMG_JAVA_DIGEST" "$IMG_PY_DIGEST"; do
  [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || die "containers/IMAGES.lock has no usable digest for one of the three images ('$d')"
done

# expect_env FILE KIND NETWORK QUOTA CPUSET IMAGE DIGEST: check the whole runtime.environment block of one file. A container
# file names the image, the digest from IMAGES.lock, seccomp "default", the network, the quota and the cpuset; vm carries the
# guest profile; host carries neither.
expect_env() {
  local f=$1 kind=$2 net=$3 quota=$4 cpuset=$5 image=$6 digest=$7 name=${1#"$OUT"/}
  crit_exact "5" "$name runtime.environment.kind" "$(val "$f" .runtime.environment.kind)" "$kind"
  case $kind in
    host) crit_exact "5" "$name has no guest_profile" "$(val_or_null "$f" .runtime.environment.guest_profile)" null ;;
    vm) crit_exact "5" "$name guest_profile" "$(val "$f" .runtime.environment.guest_profile)" "$GUEST_PROFILE_NAME" ;;
    container)
      crit_exact "5" "$name guest_profile" "$(val "$f" .runtime.environment.guest_profile)" "$GUEST_PROFILE_NAME"
      crit_exact "5" "$name container image" "$(val "$f" .runtime.environment.container.image)" "$image"
      crit_exact "5" "$name container image_digest equals IMAGES.lock" "$(val "$f" .runtime.environment.container.image_digest)" "$digest"
      crit_exact "5" "$name container network" "$(val "$f" .runtime.environment.container.network)" "$net"
      crit_exact "5" "$name container cpu_quota" "$(val_or_null "$f" .runtime.environment.container.cpu_quota)" "$quota"
      crit_exact "5" "$name container cpuset" "$(val_or_null "$f" .runtime.environment.container.cpuset)" "$cpuset"
      crit_exact "5" "$name container seccomp" "$(val "$f" .runtime.environment.container.seccomp)" default
      crit_exact "5" "$name container runtime" "$(val "$f" .runtime.environment.container.runtime)" docker
      ;;
  esac
}

# lane_limits LANE: "NETWORK QUOTA CPUSET" the lane's container was started with (container_run records the default network, bridge).
lane_limits() {
  case $1 in
    container-host-net) echo "host null null" ;;
    container-bridge) echo "bridge null null" ;;
    container-cpu-quota) echo "bridge $LIMIT_CPUS null" ;;
    container-cpuset) echo "bridge null $LIMIT_CPUSET" ;;
    *) echo "- - -" ;;
  esac
}

step "criterion 5: every lane and alternation (count, dropped, environment, digests, pin, binaries)"
for lane in "${LANES[@]}"; do
  ok_lane "$lane" || continue
  kind=$(lane_kind "$lane")
  read -r net quota cpuset <<<"$(lane_limits "$lane")"
  for n in $(seq 1 "$ROUNDS"); do
    c=$(P "$lane" "$n" cpp/consumer.json)
    count=$(val "$c" .count) dropped=$(val "$c" .dropped) parcels=$(val "$c" .runtime.counters.parcels)
    crit_exact "5" "$lane alt$n consumer count (rate x seconds x cameras)" "$count" "$LINE_COUNT"
    crit_exact "5" "$lane alt$n consumer dropped" "$dropped" 0
    crit_exact "5" "$lane alt$n consumer counters.parcels equals the histogram count" "$parcels" "$count"
    expect_env "$c" "$kind" "$net" "$quota" "$cpuset" "$IMAGE_CPP" "$IMG_CPP_DIGEST"
    # The bridge lane's simulators ran in the guest, outside the container; elsewhere they ran where the consumer did.
    if [[ $lane == container-bridge ]]; then
      expect_env "$(P "$lane" "$n" cpp/lateness.json)" vm - - - - -
    else
      expect_env "$(P "$lane" "$n" cpp/lateness.json)" "$kind" "$net" "$quota" "$cpuset" "$IMAGE_CPP" "$IMG_CPP_DIGEST"
    fi
    expect_env "$(P "$lane" "$n" cpp/probe-cpp.json)" "$kind" "$net" "$quota" "$cpuset" "$IMAGE_CPP" "$IMG_CPP_DIGEST"
    expect_env "$(P "$lane" "$n" python/probe-python.json)" "$kind" "$net" "$quota" "$cpuset" "$IMAGE_PY" "$IMG_PY_DIGEST"
    expect_env "$(P "$lane" "$n" java/probe-java.json)" "$kind" "$net" "$quota" "$cpuset" "$IMAGE_JAVA" "$IMG_JAVA_DIGEST"
    # The consumer is pinned to one CPU (an experiment control); the program confirmed with sched_getcpu() that it ran there.
    want_cpu=$GUEST_CPU
    [[ $lane == host ]] && want_cpu=$(val "$OUT/run-start.json" .host_consumer_cpu)
    crit_exact "5" "$lane alt$n consumer pinned to CPU" "$(val "$c" '.runtime.placement.cpus | join(",")')" "$want_cpu"
    # Which machine's profile each report carries.
    if [[ $lane == host ]]; then
      crit_exact "5" "$lane alt$n embedded profile virt.type" "$(val "$c" .profile.virt.type)" none
    else
      crit_exact "5" "$lane alt$n embedded profile virt.type (the guest's)" "$(val "$c" .profile.virt.type)" kvm
    fi
    if lane_has_pool "$lane"; then
      expect_env "$(P "$lane" "$n" cpp/pool.json)" "$kind" "$net" "$quota" "$cpuset" "$IMAGE_CPP" "$IMG_CPP_DIGEST"
      s=$(P "$lane" "$n" quarkus/client.json)
      crit_exact "5" "$lane alt$n Quarkus client completed every request it sent" "$(val "$s" .runtime.counters.completed)" "$(val "$s" .runtime.counters.sent)"
      crit_exact "5" "$lane alt$n Quarkus client errors" "$(val "$s" .runtime.counters.errors)" 0
      expect_env "$s" container "host" "$quota" "$cpuset" "$IMAGE_JAVA" "$IMG_JAVA_DIGEST"
      expect_env "$(P "$lane" "$n" quarkus/service.json)" container host "$quota" "$cpuset" "$IMAGE_JAVA" "$IMG_JAVA_DIGEST"
    fi
    if [[ $lane == host ]]; then
      [[ $RUN_MODE != vm ]] || crit_le "5" "host alt$n guest busy share across the host lane (guard; permille of the guest's ticks)" \
        "$(val "$(P host "$n" guest-idle.json)" .busy_permille)" "$GUEST_IDLE_MAX_PERMILLE"
    else
      crit_exact "5" "$lane alt$n steal.json says vm" "$(val "$(P "$lane" "$n" steal.json)" .runtime.environment.kind)" vm
    fi
  done
done

# One binary: the host, the guest and the containers ran the same four files.
if all_lanes_ok; then
  distinct=$(cat "$OUT"/*/alt*/cpp/binaries-*.txt | awk '{print $2, $1}' | sort -u | wc -l)
  names=$(cat "$OUT"/*/alt*/cpp/binaries-*.txt | awk '{print $2}' | sort -u | wc -l)
  crit_exact "5" "distinct (binary, checksum) pairs over every lane and alternation, one per binary (the same four files everywhere)" "$distinct" "$names"
  crit_exact "5" "binaries checksummed" "$names" "${#CPP_BINARIES[@]}"
  crit_exact "5" "the guest was reverted to the snapshot before the run (run-start.json reverted; REUSE_VM=1 would say false)" "$(val "$OUT/run-start.json" .reverted)" true
  crit_exact "5" "one Python in every lane (python.version, from examples/.python-version)" \
    "$(cat "$OUT"/*/alt*/python/probe-python.json | jq -r .python.version | sort -u | wc -l)" 1
  crit_exact "5" "that Python is the one examples/.python-version names" "$(jq -r .python.version "$(P host 1 python/probe-python.json)")" "$(<"$LOWLAT_EXAMPLES/.python-version")"
  crit_exact "5" "one JDK in every lane (java.version)" "$(cat "$OUT"/*/alt*/java/probe-java.json | jq -r .java.version | sort -u | wc -l)" 1
  crit_exact "5" "the lab guest was up and idle for the host lane (run-start.json lab_vm)" "$(val "$OUT/run-start.json" .lab_vm)" "up (idle)"
  printf '  observed: guest load1 at the start of the run %s\n' "$(val_or_null "$OUT/run-start.json" .lab_vm_load1)"
fi

# ---- criterion 1 ---------------------------------------------------------------------------------------------------------------
if ok_lane container-cpu-quota && ok_lane container-cpuset; then
  step "criterion 1: the cgroup counters the containers reported (exact)"
  for n in $(seq 1 "$ROUNDS"); do
    q=$(P container-cpu-quota "$n" cpp/consumer.json) c=$(P container-cpuset "$n" cpp/consumer.json)
    crit_ge "1" "container-cpu-quota alt$n nr_throttled" "$(val "$q" .runtime.environment.cgroup.nr_throttled)" "$NR_THROTTLED_QUOTA_MIN"
    crit_ge "1" "container-cpu-quota alt$n throttled_usec" "$(val "$q" .runtime.environment.cgroup.throttled_usec)" 1
    crit_exact "1" "container-cpuset alt$n nr_throttled" "$(val "$c" .runtime.environment.cgroup.nr_throttled)" 0
    crit_exact "1" "container-cpuset alt$n throttled_usec" "$(val "$c" .runtime.environment.cgroup.throttled_usec)" 0
    crit_exact "1" "container-cpu-quota alt$n cgroup cpu.max" "$(val "$q" .runtime.environment.cgroup.cpu_max)" "$((LIMIT_CPUS * 100000)) 100000"
    crit_exact "1" "container-cpuset alt$n cgroup cpu.max" "$(val "$c" .runtime.environment.cgroup.cpu_max)" "max 100000"
    crit_exact "1" "container-cpuset alt$n cpuset.cpus.effective" "$(val "$c" .runtime.environment.cgroup.cpuset_effective)" "2-3"
    for lane in container-cpu-quota container-cpuset; do
      pool=$(P "$lane" "$n" cpp/pool.json)
      crit_exact "1" "$lane alt$n busy pool workers" "$(val "$pool" .workers)" "$POOL_WORKERS"
      crit_exact "1" "$lane alt$n busy pool workers that never iterated" "$(val "$pool" .workers_with_no_iterations)" 0
    done
    printf '  observed: alt%s pool start skew, quota %s ns, cpuset %s ns (4 spinning workers on 2 CPUs: the scheduler, not the gate, spreads them; not bounded)\n' "$n" \
      "$(val "$(P container-cpu-quota "$n" cpp/pool.json)" .start_skew_ns)" "$(val "$(P container-cpuset "$n" cpp/pool.json)" .start_skew_ns)"
  done
  for lane in container-host-net container-bridge; do
    ok_lane "$lane" && printf '  observed: %s alt1 nr_throttled %s (no limit set)\n' "$lane" "$(val_or_null "$(P "$lane" 1 cpp/consumer.json)" .runtime.environment.cgroup.nr_throttled)"
  done
fi

# ---- criterion 2 ---------------------------------------------------------------------------------------------------------------
if ok_lane container-cpu-quota && ok_lane container-cpuset && ok_lane vm; then
  step "criterion 2: what each runtime thinks it has, under the quota and under the cpuset (exact)"
  crit_exact "2" "the guest's vCPU count, from its own profile" "$GUEST_VCPUS" "$EXPECT_GUEST_VCPUS"
  for n in $(seq 1 "$ROUNDS"); do
    for lane in container-cpu-quota container-cpuset; do
      # A quota limits time, not the set of CPUs; a cpuset is the set.
      if [[ $lane == container-cpu-quota ]]; then mask=$GUEST_VCPUS py_proc=$GUEST_VCPUS jcpus=$AWARE_QUOTA; else mask=$CPUSET_COUNT py_proc=$CPUSET_COUNT jcpus=$AWARE_CPUSET; fi
      cp=$(P "$lane" "$n" cpp/probe-cpp.json) py=$(P "$lane" "$n" python/probe-python.json) jv=$(P "$lane" "$n" java/probe-java.json)
      hc=$(val "$cp" .cpus.hardware_concurrency)
      crit_exact "2" "$lane alt$n C++ hardware_concurrency (the guest's vCPUs: a container does not narrow the online list)" "$hc" "$GUEST_VCPUS"
      crit_exact "2" "$lane alt$n C++ hardware_concurrency equals the online CPU count the kernel lists" "$hc" "$(val "$cp" .cpus.online_count)"
      crit_exact "2" "$lane alt$n C++ hardware_concurrency equals the vm lane's online CPU count (the same guest)" "$hc" "$(val "$(P vm "$n" cpp/probe-cpp.json)" .cpus.online_count)"
      crit_exact "2" "$lane alt$n C++ affinity mask" "$(val "$cp" .cpus.affinity_count)" "$mask"
      crit_exact "2" "$lane alt$n C++ cgroup-aware pool size" "$(val "$cp" .pool_size.cgroup_aware)" "$jcpus"
      crit_exact "2" "$lane alt$n C++ pool size by hardware_concurrency" "$(val "$cp" .pool_size.by_hardware_concurrency)" "$GUEST_VCPUS"
      crit_exact "2" "$lane alt$n Python os.cpu_count()" "$(val "$py" .python.cpu_count)" "$GUEST_VCPUS"
      crit_exact "2" "$lane alt$n Python os.process_cpu_count()" "$(val "$py" .python.process_cpu_count)" "$py_proc"
      crit_exact "2" "$lane alt$n Python len(os.sched_getaffinity(0)) equals os.process_cpu_count()" "$(val "$py" .python.affinity_count)" "$(val "$py" .python.process_cpu_count)"
      crit_exact "2" "$lane alt$n Java availableProcessors()" "$(val "$jv" .java.available_processors)" "$jcpus"
      crit_exact "2" "$lane alt$n Java virtual-thread scheduler parallelism (VirtualThreadSchedulerMXBean)" "$(val "$jv" .java.virtual_thread_parallelism)" "$jcpus"
      crit_exact "2" "$lane alt$n Java most virtual threads mounted at once under a saturating spin (a cross-check of the parallelism)" "$(val "$jv" .java.virtual_thread_mounted_max)" "$jcpus"
    done
  done
  for lane in "${LANES[@]}"; do
    ok_lane "$lane" || continue
    printf '  observed: %s alt1: C++ hardware_concurrency %s, Python cpu_count / process_cpu_count %s / %s, Java availableProcessors %s, GC threads parallel %s concurrent %s, virtual-thread pool size after the spin %s, glibc %s\n' "$lane" \
      "$(val "$(P "$lane" 1 cpp/probe-cpp.json)" .cpus.hardware_concurrency)" "$(val "$(P "$lane" 1 python/probe-python.json)" .python.cpu_count)" \
      "$(val "$(P "$lane" 1 python/probe-python.json)" .python.process_cpu_count)" "$(val "$(P "$lane" 1 java/probe-java.json)" .java.available_processors)" \
      "$(val "$(P "$lane" 1 java/probe-java.json)" .java.parallel_gc_threads)" "$(val "$(P "$lane" 1 java/probe-java.json)" .java.conc_gc_threads)" \
      "$(val "$(P "$lane" 1 java/probe-java.json)" .java.virtual_thread_pool_size_after_spin)" "$(val "$(P "$lane" 1 cpp/probe-cpp.json)" .libc.glibc)"
  done
  for lane in container-cpu-quota container-cpuset; do
    for n in $(seq 1 "$ROUNDS"); do
      inproc=$(val "$(P "$lane" "$n" quarkus/client.json)" .runtime.counters.carrier_threads)
      procfs=$(val "$(P "$lane" "$n" quarkus/service.json)" .service.carrier_threads)
      printf '  observed: %s alt%s Quarkus service: Vert.x event loops %s, worker threads %s, carriers in the scheduler pool %s in process (the service'"'"'s own count); %s counted from /proc in the container, %s\n' \
        "$lane" "$n" "$(val "$(P "$lane" "$n" quarkus/service.json)" .service.event_loop_threads)" "$(val "$(P "$lane" "$n" quarkus/service.json)" .service.executor_threads)" \
        "$inproc" "$procfs" "$([[ $inproc == "$procfs" ]] && echo equal || echo different)"
    done
  done
fi

# ---- criterion 3 ---------------------------------------------------------------------------------------------------------------
if all_lanes_ok; then
  step "criterion 3: io_uring_setup under Docker's default seccomp profile, and outside a container"
  for n in $(seq 1 "$ROUNDS"); do
    for lane in "${CONTAINER_LANES[@]}"; do
      e=$(val "$(P "$lane" "$n" cpp/probe-cpp.json)" .io_uring.setup_errno)
      if ((CRIT3_ASSERTED)); then crit_exact "3" "$lane alt$n io_uring_setup errno (EPERM)" "$e" "$EPERM"; else printf '  observed: %s alt%s io_uring_setup errno %s\n' "$lane" "$n" "$e"; fi
    done
    e=$(val "$(P vm "$n" cpp/probe-cpp.json)" .io_uring.setup_errno)
    if ((CRIT3_ASSERTED)); then crit_exact "3" "vm alt$n io_uring_setup errno (the same binary, outside a container, succeeds)" "$e" 0; else printf '  observed: vm alt%s io_uring_setup errno %s\n' "$n" "$e"; fi
  done
  printf '  observed: host alt1 io_uring_setup errno %s (the host allows it unprivileged; read, never changed)\n' "$(val "$(P host 1 cpp/probe-cpp.json)" .io_uring.setup_errno)"
fi

# ---- criterion 4 ---------------------------------------------------------------------------------------------------------------
if ok_lane container-cpu-quota && ok_lane container-cpuset; then
  step "criterion 4: consumer p99.9, container-cpu-quota over container-cpuset, same run, median of $ROUNDS"
  ratios=()
  for n in $(seq 1 "$ROUNDS"); do
    ratios+=("$(alt_ratio "$(P container-cpu-quota "$n" cpp/consumer.json)" "$(P container-cpuset "$n" cpp/consumer.json)")")
  done
  if ((CRIT4_ASSERTED)); then
    crit_ratio_ge "4" "consumer p99.9" "quota over cpuset, per alternation: ${ratios[*]} thousandths" "$(median_ns "${ratios[@]}")" "$QUOTA_P999_RATIO_MIN_PERMILLE"
  else
    printf '  observed: consumer p99.9, container-cpu-quota over container-cpuset, per alternation: %s thousandths (median %s; the plan'"'"'s bound is >= %s, asserted only when it clears twice over)\n' \
      "${ratios[*]}" "$(median_ns "${ratios[@]}")" "$QUOTA_P999_RATIO_MIN_PERMILLE"
  fi
fi

# ---- observed: the lanes, labelled -----------------------------------------------------------------------------------------------
# lane_median LANE REL KEY: the median over the alternations of a percentile of one report.
lane_median() {
  local lane=$1 rel=$2 key=$3 n vals=()
  for n in $(seq 1 "$ROUNDS"); do vals+=("$(val "$(P "$lane" "$n" "$rel")" ".percentiles.$key")"); done
  median_ns "${vals[@]}"
}
if ok_lane host; then
  step "observed: how quiet the host was (an untuned shared laptop; recorded, never a reason to refuse)"
  for n in $(seq 1 "$ROUNDS"); do
    hq=$(P host "$n" host-quiet.json)
    printf '  observed: host alt%s load1 %s before, %s after; host busy %s/1000 across the lane; consumer on CPU %s, simulators on CPUs %s\n' "$n" \
      "$(val "$hq" .load1_before)" "$(val "$hq" .load1_after)" "$(val_or_null "$hq" .busy_permille)" "$(val "$hq" .consumer_cpu)" "$(val_or_null "$hq" .simulator_cpus)"
    sims=$(val_or_null "$hq" .simulator_cpus)
    cpu=$(val "$hq" .consumer_cpu)
    if [[ $sims == null || -z $sims ]]; then
      printf '  observed: host alt%s simulators were unpinned (no CPU left beside the consumer'"'"'s core)\n' "$n"
    else
      crit_exact "5" "host alt$n the simulators' mask leaves out the consumer's CPU $cpu" "$([[ ,$sims, == *,"$cpu",* ]] && echo included || echo excluded)" excluded
    fi
  done
fi
step "observed: the lanes side by side (D9: on this laptop's KVM, in this run, lane-labelled; host against VM is not asserted)"
for lane in "${LANES[@]}"; do
  ok_lane "$lane" || continue
  printf '  %-20s consumer p50 / p99 / p99.9 us, median of %s: %s / %s / %s;  simulator emit lateness p50 / p99 / p99.9 us: %s / %s / %s\n' "$lane" "$ROUNDS" \
    "$(($(lane_median "$lane" cpp/consumer.json p50) / 1000))" "$(($(lane_median "$lane" cpp/consumer.json p99) / 1000))" "$(($(lane_median "$lane" cpp/consumer.json p99_9) / 1000))" \
    "$(($(lane_median "$lane" cpp/lateness.json p50) / 1000))" "$(($(lane_median "$lane" cpp/lateness.json p99) / 1000))" "$(($(lane_median "$lane" cpp/lateness.json p99_9) / 1000))"
done
if ok_lane container-bridge && ok_lane container-host-net; then
  hn=$(lane_median container-host-net cpp/consumer.json p99) br=$(lane_median container-bridge cpp/consumer.json p99)
  printf '  observed: bridge against host network, consumer p99 (median of %s): %s us against %s us\n' "$ROUNDS" "$((br / 1000))" "$((hn / 1000))"
fi
if ok_lane host && ok_lane vm; then
  printf '  observed: host against vm, consumer p99.9 (median of %s): %s us against %s us (different clocks, kernels and CPUs; labelled, never compared as a claim)\n' "$ROUNDS" \
    "$(($(lane_median host cpp/consumer.json p99_9) / 1000))" "$(($(lane_median vm cpp/consumer.json p99_9) / 1000))"
fi
for lane in "${LANES[@]}"; do
  [[ $lane == host ]] && continue
  ok_lane "$lane" || continue
  steal=() total=()
  for a in $(seq 1 "$ROUNDS"); do
    steal+=("$(val "$(P "$lane" "$a" steal.json)" .steal_ticks)")
    total+=("$(val "$(P "$lane" "$a" steal.json)" .total_ticks)")
  done
  printf '  observed: %s steal ticks over the lane, per alternation: %s (of %s guest ticks)\n' "$lane" \
    "${steal[*]}" "${total[*]}"
done
if ok_lane container-cpu-quota && ok_lane container-cpuset; then
  printf '  observed: Quarkus (virtual-thread variant, %s Hz) p50 / p99 / p99.9 / max, alternation 1: container-cpu-quota %s; container-cpuset %s\n' "$Q_RATE" \
    "$(pct "$(P container-cpu-quota 1 quarkus/client.json)")" "$(pct "$(P container-cpuset 1 quarkus/client.json)")"
  q=() s=()
  for n in $(seq 1 "$ROUNDS"); do
    q+=("$(p99 "$(P container-cpu-quota "$n" quarkus/client.json)")")
    s+=("$(p99 "$(P container-cpuset "$n" quarkus/client.json)")")
  done
  printf '  observed: Quarkus p99 ns, median of %s: container-cpu-quota %s; container-cpuset %s\n' "$ROUNDS" "$(median_ns "${q[@]}")" "$(median_ns "${s[@]}")"
fi

if [[ -s $RATIO_FAULTS ]]; then
  bad "a ratio had no usable denominator: $(tr '\n' ';' <"$RATIO_FAULTS")"
fi

if [[ ${SMOKE:-0} == 1 ]]; then
  ok "SMOKE: script check finished with $FAILURES criteria not met at these sizes (not enforced, not a result); output in $OUT"
  exit 0
fi
((FAILURES == 0)) || die "$FAILURES criteria not met; results in $OUT"
ok "13-where-code-runs: every criterion holds; results in $OUT"
jq -r '"profile (host): \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$OUT/profile.json"
[[ ! -f $OUT/guest-profile.json ]] || jq -r '"profile (guest): virt=\(.virt.type) kernel=\(.kernel.release) tuned=\(.tuned)"' "$OUT/guest-profile.json"
