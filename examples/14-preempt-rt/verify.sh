#!/usr/bin/env bash
# Ch14 verify: PREEMPT_RT against the stock kernel's preemption models, in the 4-vCPU lab guest (C++, plus one observed Java lane).
#
# Three lanes, one kernel source (7.2.11-200.fc44), run interleaved in ONE run (stock-lazy stock-full rt, three alternations),
# each from a freshly reverted snapshot, with the same vCPU pins and no isolation. Every number is lane `vm` and means "in this
# guest, on this machine's KVM": the host can't run SCHED_FIFO work and there is no host lane. Every criterion is evaluated; each
# prints its measured value and bound, and any miss fails the run after all of them have been evaluated.
# Counters marked exact are deterministic and need no median; a latency ratio is the median of the per-alternation ratios.
#   1  (exact) the kernel and mode each lane reports: stock lanes run 7.2.11-200.fc44 with PREEMPT_DYNAMIC and no PREEMPT_RT,
#      `rt` runs the lowlatrt build with CONFIG_PREEMPT_RT=y and PREEMPT_RT in `uname -v`; /sys/kernel/debug/sched/preempt reads
#      "full (lazy)" in stock-lazy and "(full) lazy" in stock-full and rt.
#   2  (exact) irq/ kernel threads: stock 15 (driver-requested), rt 80 (every device IRQ). ktimers: stock 0, rt 4 at SCHED_FIFO 1.
#      TODO(S11): the counts come from the S1 probes; the calibration runs confirm them or correct them.
#   3  priority inversion: pi-mutex high-priority wait p99 <= 1/4 of plain-mutex's, in every lane (median of 3 alternations;
#      >= 10x by construction, because the holder runs at the waiter's priority).
#   4  OBSERVED until S11 decides: cyclictest p99.9, rt <= 1/2 of stock-lazy under load (median of 3). CRIT4_ASSERTED=1 asserts it.
#   5  the line, every lane and alternation: 200,000 parcels, dropped == 0, runtime.counters.parcels equals the count, the probe's
#      samples + missed periods equal duration / period, lowlat-report check on every report, runtime.environment.kind == vm with
#      a guest_profile that names the lane's snapshot and records the vCPU pins, the embedded profile says virt.type kvm, and
#      one set of binary checksums across every lane.
#   6  (exact) the Java hot thread is SCHED_FIFO 95 (chrt -p of its tid, taken while it ran).
#   -  completeness: every lane x alternation has every file it should, and a run that did not run every lane fails as partial.
# Observed, not asserted: stock-full against stock-lazy, the probe against cyclictest, the line's percentiles, steal ticks, the
# /proc/interrupts deltas of CPUs 2 and 3, the Java wake tail against the safepoint count and total, the ksoftirqd and rcuc threads.
#
#   ./verify.sh                 RECHECK: re-evaluate the committed results (results/*vm-run*), run nothing
#   VM=1 ./verify.sh            a real run: build, unit tests, then vm/run.sh (revert the guest per lane, three lanes x 3, fetch), evaluate
#   RECHECK=results/<run-id>    re-evaluate one results directory
#   SMOKE=1 RESULTS_DIR=DIR     (with VM=1) short durations, a check of the scripts and not a measurement; nothing is enforced
#   RESULTS_DIR=DIR             where a real run writes (default results/latest)
#   CRIT4_ASSERTED=0|1          (default 0) criterion 4 asserted; 0 observes it
#   ALLOW_BUSY=1                run while the host is busy (the numbers are then labelled noisy)
#   SKIP_BUILD=1                reuse the builds
#
# Run a real run under the host benchmark lock:  flock -o "$LOCK" env VM=1 ./verify.sh
# UDP ports 47400-47403 (r05 owns 47400-47429). Never changes the host: no sudo, no sysctl, no tuning, no VM unless VM=1.
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
VM=${VM:-0}
SMOKE=${SMOKE:-0}
scratch_dir

# ---- bounds (provisional; S11 decides which latency bounds are asserted) --------------------------------------------------------
PI_RATIO_MAX_PERMILLE=250                   # 3: pi-mutex p99 <= 1/4 of plain-mutex p99
CRIT4_ASSERTED=${CRIT4_ASSERTED:-0}         # 4: observed until S11 shows a >= 2x margin in all three runs
RT_P999_RATIO_MAX_PERMILLE=500              # 4: rt p99.9 <= 1/2 of stock-lazy
JAVA_POLICY='SCHED_FIFO'
JAVA_PRIORITY=95

# ---- what to do ------------------------------------------------------------------------------------------------------------------
if [[ -z ${RECHECK:-} && $VM != 1 ]]; then
  mapfile -t committed < <(find "$HERE/results" -maxdepth 1 -type d -name '*vm-run*' 2>/dev/null | sort)
  if ((${#committed[@]} == 0)); then
    echo "14-preempt-rt: no committed results (results/*vm-run*) to re-check." >&2
    echo "  A real run needs the lab guest:  flock -o \"\$LOCK\" env VM=1 ./verify.sh" >&2
    echo "  To re-check a results directory:  RECHECK=results/<run-id> ./verify.sh" >&2
    exit 2
  fi
  RUNS=("${committed[@]}")
elif [[ -n ${RECHECK:-} ]]; then
  [[ -d $RECHECK ]] || { echo "14-preempt-rt: RECHECK=$RECHECK is not a directory" >&2; exit 2; }
  RUNS=("$RECHECK")
else
  RUNS=()
fi

if [[ $VM == 1 ]]; then
  if ((SMOKE)) && [[ -z ${RESULTS_DIR:-} ]]; then
    echo "SMOKE=1 needs RESULTS_DIR (it must not overwrite results/latest)" >&2
    exit 2
  fi
  OUT=${RESULTS_DIR:-$HERE/results/latest}
  mkdir -p "$OUT"
  OUT=$(cd "$OUT" && pwd)
  export RESULTS_DIR=$OUT
  LOGS=$LOWLAT_SCRATCH/logs
  mkdir -p "$LOGS"
  finish_logs() {
    if [[ -d $LOGS ]]; then
      mkdir -p "$OUT/logs"
      find "$LOGS" -maxdepth 1 -name '*.log' -exec mv -t "$OUT/logs" {} + 2>/dev/null || true
    fi
  }
  trap 'finish_logs; _bg_cleanup' EXIT

  step "build the C++ binaries and the Java jar"
  build_cpp cyclic-probe cyclic-test pi-demo pi-test line-simulator io-receive
  BUILD_JAVA_TESTS=1 build_java "$HERE/java"
  step "unit tests: GoogleTest for the probe's arithmetic and the PI mutex, the CLI tests; Java ran during the build"
  "$(cpp_bin cyclic-test)" --gtest_brief=1 >"$LOGS/cpp-unit-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-unit-tests.log" >&2; die "cyclic-probe unit tests failed"; }
  "$(cpp_bin pi-test)" --gtest_brief=1 >>"$LOGS/cpp-unit-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-unit-tests.log" >&2; die "pi-mutex unit tests failed"; }
  ctest --test-dir "$LOWLAT_BUILD" -R '^(cyclic-probe|pi-demo)-' --output-on-failure >>"$LOGS/cpp-unit-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-unit-tests.log" >&2; die "CLI tests failed"; }
  ok "C++ and Java unit tests pass"

  # vm/run.sh reverts the guest per lane, runs the three lanes interleaved, fetches and shuts the guest down. It is told the builds
  # are done, and not to evaluate: this script does that below.
  VERIFY_DRIVER=1 SKIP_BUILD=1 RESULTS_DIR=$OUT "$HERE/vm/run.sh" 2>&1 | tee "$LOGS/vm-run.log"
  scrub_results "$OUT"
  RUNS=("$OUT")
fi

# ---- helpers (the house crit_* pattern of examples 11 to 13) --------------------------------------------------------------------
TOTAL_FAIL=0
declare -A CRIT_KIND=() CRIT_DESC=() CRIT_N=() CRIT_BAD=()
CRIT_ORDER=()
# crit_def ID KIND DESCRIPTION: register a criterion for the table (KIND exact, bound or observed).
crit_def() {
  CRIT_KIND[$1]=$2 CRIT_DESC[$1]=$3 CRIT_N[$1]=0 CRIT_BAD[$1]=0
  CRIT_ORDER+=("$1")
}
note_check() { CRIT_N[$1]=$((${CRIT_N[$1]:-0} + 1)); }
note_miss() { CRIT_BAD[$1]=$((${CRIT_BAD[$1]:-0} + 1)); }
margin() { awk -v a="$1" -v b="$2" 'BEGIN { if (b == 0) print "inf"; else printf "%.2f", a / b }'; }
crit_exact() {
  note_check "$1"
  if [[ $3 == "$4" ]]; then ok "$1 $2: measured $3, bound == $4 (exact)"; else bad "$1 $2: measured $3, bound == $4 (exact)"; note_miss "$1"; fi
}
crit_le() {
  note_check "$1"
  if (($3 <= $4)); then ok "$1 $2: measured $3, bound <= $4, margin $(margin "$4" "$3")x"; else bad "$1 $2: measured $3, bound <= $4, margin $(margin "$4" "$3")x"; note_miss "$1"; fi
}
crit_ge() {
  note_check "$1"
  if (($3 >= $4)); then ok "$1 $2: measured $3, bound >= $4"; else bad "$1 $2: measured $3, bound >= $4"; note_miss "$1"; fi
}
# crit_true ID DESCRIPTION CONDITION_RESULT(0|1) MEASURED: a yes/no check with the measured text.
crit_true() {
  note_check "$1"
  if (($3)); then ok "$1 $2: $4"; else bad "$1 $2: $4"; note_miss "$1"; fi
}
observed() { printf '  observed: %s\n' "$*"; }

val() {
  local v
  [[ -f $1 ]] || die "${1#"$OUT"/} is missing"
  v=$(jq -r "$2" "$1" 2>/dev/null) || die "${1#"$OUT"/}: cannot read $2"
  [[ -n $v && $v != null ]] || die "${1#"$OUT"/}: $2 is missing or null"
  printf '%s' "$v"
}
P() { printf '%s/vm/%s/alt%s/%s' "$OUT" "$1" "$2" "$3"; }
have() { [[ -f $1 ]]; }
# ct_file LANE ALT: the cyclictest report of one lane (one thread, one file).
ct_file() {
  local f
  f=$(find "$OUT/vm/$1/alt$2/cyclictest" -maxdepth 1 -name 'cyclictest-t*.json' 2>/dev/null | sort | sed -n 1p)
  [[ -n $f ]] || { echo "$OUT/vm/$1/alt$2/cyclictest/cyclictest-t0.json"; return; }
  printf '%s' "$f"
}
pkey() { val "$1" ".percentiles.$2"; }
us() { echo $(($1 / 1000)); }
# lane_median LANE KEY REPORT_FN ARGS...: median over the alternations of one percentile; REPORT_FN LANE ALT prints the file.
lane_median() {
  local lane=$1 key=$2 fn=$3 n vals=()
  shift 3
  for n in $(seq 1 "$ROUNDS_RUN"); do vals+=("$(pkey "$("$fn" "$lane" "$n" "$@")" "$key")"); done
  median_ns "${vals[@]}"
}
rel_file() { P "$1" "$2" "$3"; }
ratio_permille() { echo $((1000 * $1 / ($2 > 0 ? $2 : 1))); }

evaluate() {
  OUT=$1
  OUT=$(cd "$OUT" && pwd)
  FAILURES=0
  CRIT_ORDER=()
  # How many alternations the directory holds (a committed run has 3; a smoke run has 1).
  ROUNDS_RUN=$(find "$OUT/vm" -maxdepth 2 -type d -name 'alt*' 2>/dev/null | sed 's|.*/alt||' | sort -n | tail -n1)
  : "${ROUNDS_RUN:=0}"
  crit_def 1 exact "kernel and preemption mode per lane (7.2.11-200.fc44, PREEMPT_DYNAMIC lazy / full, PREEMPT_RT)"
  crit_def 2 exact "irq/ kthreads (stock 15, rt 80) and ktimers (stock 0, rt 4 at FIFO 1), per snapshot"
  crit_def 3 bound "priority inversion: pi-mutex wait p99 <= 1/4 of plain-mutex, median of $ROUNDS_RUN"
  crit_def 4 observed "cyclictest p99.9 rt <= 1/2 of stock-lazy under load, median of $ROUNDS_RUN (observed until S11)"
  crit_def 5 exact "every lane and alternation: line 200,000 parcels, none dropped, environment, checksums, report check"
  crit_def 6 exact "the Java hot thread is SCHED_FIFO 95 (chrt -p)"
  local n lane
  LINE_COUNT=$(line_count)
  step "evaluating ${OUT#"$HERE"/} ($ROUNDS_RUN alternation(s))"

  [[ -f $OUT/vm/LABEL && $(<"$OUT/vm/LABEL") == vm ]] || bad "vm/LABEL is missing or is not 'vm'"
  [[ -f $OUT/run-start.json ]] || bad "run-start.json: missing"
  [[ -f $OUT/SHA256SUMS ]] || bad "SHA256SUMS: missing"

  # ---- completeness -------------------------------------------------------------------------------------------------------------
  expected_files() {
    echo profile.json vcpupin.json interrupts.json binaries.txt steal.json mechanism.json probe.json
    echo line/consumer.json line/lateness.json pi/plain-mutex.json pi/pi-mutex.json
    echo java/java-wake.json java/chrt-hot.txt java/safepoint.log.gz
  }
  declare -A MISSING=()
  step "completeness: every lane x alternation has every file it should, and every lane ran"
  for lane in "${LANES[@]}"; do
    [[ -d $OUT/vm/$lane ]] || { bad "partial run: the $lane lane was not run"; MISSING[$lane]=1; continue; }
    for n in $(seq 1 "$ROUNDS_RUN"); do
      for rel in $(expected_files); do
        have "$(P "$lane" "$n" "$rel")" || { bad "$lane/alt$n/$rel: missing (a lane that did not run proves nothing)"; MISSING[$lane]=1; }
      done
      [[ -n $(find "$OUT/vm/$lane/alt$n/cyclictest" -maxdepth 1 -name 'cyclictest-t*.json' 2>/dev/null) ]] ||
        { bad "$lane/alt$n/cyclictest: no cyclictest report"; MISSING[$lane]=1; }
    done
  done
  ((${#MISSING[@]} > 0)) || ok "every lane ran and every expected file is present"
  ((${#MISSING[@]} == 0)) || { finish_eval; return; }
  ((ROUNDS_RUN >= 1)) || { bad "no alternations"; finish_eval; return; }

  # ---- reports ------------------------------------------------------------------------------------------------------------------
  step "reports: schema, histogram decode, percentile recompute"
  mapfile -t reports < <(find "$OUT/vm" -name '*.json' -exec grep -lE '"schema" ?: ?"lowlat-report/1"' {} + | sort)
  if ((${#reports[@]} > 0)) && report_check "${reports[@]}" >/dev/null 2>"$LOWLAT_SCRATCH/report-check.err"; then
    note_check 5
    ok "5 ${#reports[@]} reports validate"
  else
    cat "$LOWLAT_SCRATCH/report-check.err" >&2 2>/dev/null || true
    bad "5 lowlat-report check failed (or no reports)"
    note_check 5
    note_miss 5
  fi

  # ---- criterion 1 and 2: the kernel and its threads ----------------------------------------------------------------------------
  step "criteria 1 and 2: kernel, preemption mode, interrupt threads (exact)"
  for lane in "${LANES[@]}"; do
    for n in $(seq 1 "$ROUNDS_RUN"); do
      m=$(P "$lane" "$n" mechanism.json)
      rel=$(val "$m" .kernel.release) ver=$(val "$m" .kernel.version) mode=$(val "$m" .kernel.preempt_mode) cfg=$(val "$m" .kernel.config_preempt_rt)
      if [[ $lane == rt ]]; then
        crit_true 1 "$lane alt$n uname -r is the lowlatrt build of 7.2.11-200" "$([[ $rel == 7.2.11-200.*+rt ]] && echo 1 || echo 0)" "$rel"
        crit_true 1 "$lane alt$n uname -v says PREEMPT_RT" "$([[ $ver == *PREEMPT_RT* ]] && echo 1 || echo 0)" "measured '${ver:0:40}'"
        crit_exact 1 "$lane alt$n CONFIG_PREEMPT_RT=y in /boot/config" "$cfg" true
        irq_want=$IRQ_KTHREADS_RT ktim_want=$KTIMERS_RT
      else
        # The stock build is the same NVR the host runs, so scrub_results cuts its release to major.minor in every
        # committed file (host-ids). The exact NVR was asserted on the snapshot itself by check-prereqs.sh --vm --r05
        # stock when build-r05-snapshots.sh took it; here the series, the snapshot and uname -v carry the check.
        crit_exact 1 "$lane alt$n uname -r is the stock series (scrubbed to major.minor)" "$rel" "$KERNEL_SERIES"
        crit_true 1 "$lane alt$n uname -v says PREEMPT_DYNAMIC and not PREEMPT_RT" "$([[ $ver == *PREEMPT_DYNAMIC* && $ver != *PREEMPT_RT* ]] && echo 1 || echo 0)" "measured '${ver:0:40}'"
        crit_exact 1 "$lane alt$n CONFIG_PREEMPT_RT not set" "$cfg" false
        irq_want=$IRQ_KTHREADS_STOCK ktim_want=$KTIMERS_STOCK
      fi
      crit_exact 1 "$lane alt$n /sys/kernel/debug/sched/preempt" "$mode" "$(lane_preempt_mode "$lane")"
      crit_exact 2 "$lane alt$n irq/ kernel threads (TODO(S11): confirm)" "$(val "$m" .threads.irq.count)" "$irq_want"
      crit_exact 2 "$lane alt$n ktimers threads (TODO(S11): confirm)" "$(val "$m" .threads.ktimers.count)" "$ktim_want"
      [[ $lane != rt ]] || crit_exact 2 "$lane alt$n ktimers scheduling policy (class:priority)" "$(val "$m" .threads.ktimers.policies)" "FF:1"
      crit_exact 1 "$lane alt$n snapshot named in the mechanism record" "$(val "$m" .snapshot)" "$(lane_snapshot "$lane")"
    done
  done

  # ---- criterion 3: priority inversion ----------------------------------------------------------------------------------------------
  step "criterion 3: priority inversion, pi-mutex against plain-mutex (high-priority wait, median of $ROUNDS_RUN)"
  for lane in "${LANES[@]}"; do
    ratios=()
    for n in $(seq 1 "$ROUNDS_RUN"); do
      plain=$(P "$lane" "$n" pi/plain-mutex.json) pim=$(P "$lane" "$n" pi/pi-mutex.json)
      crit_exact 5 "$lane alt$n pi-demo plain-mutex waits recorded" "$(val "$plain" .count)" "$PI_ROUNDS"
      crit_exact 5 "$lane alt$n pi-demo pi-mutex waits recorded" "$(val "$pim" .count)" "$PI_ROUNDS"
      ratios+=("$(ratio_permille "$(pkey "$pim" p99)" "$(pkey "$plain" p99)")")
      observed "$lane alt$n high-priority wait p50 / p99 / max us: plain-mutex $(us "$(pkey "$plain" p50)") / $(us "$(pkey "$plain" p99)") / $(us "$(pkey "$plain" max)"), pi-mutex $(us "$(pkey "$pim" p50)") / $(us "$(pkey "$pim" p99)") / $(us "$(pkey "$pim" max)")"
    done
    crit_le 3 "$lane pi-mutex p99 over plain-mutex p99 (thousandths, per alternation: ${ratios[*]})" "$(median_ns "${ratios[@]}")" "$PI_RATIO_MAX_PERMILLE"
  done

  # ---- criterion 4: cyclictest rt against stock-lazy ----------------------------------------------------------------------------------
  step "criterion 4: cyclictest p99.9 under load, rt over stock-lazy (median of $ROUNDS_RUN)"
  ratios=()
  for n in $(seq 1 "$ROUNDS_RUN"); do
    ratios+=("$(ratio_permille "$(pkey "$(ct_file rt "$n")" p99_9)" "$(pkey "$(ct_file stock-lazy "$n")" p99_9)")")
  done
  if ((CRIT4_ASSERTED)); then
    crit_le 4 "cyclictest p99.9, rt over stock-lazy, thousandths, per alternation: ${ratios[*]}" "$(median_ns "${ratios[@]}")" "$RT_P999_RATIO_MAX_PERMILLE"
  else
    note_check 4
    observed "cyclictest p99.9, rt over stock-lazy, thousandths per alternation: ${ratios[*]} (median $(median_ns "${ratios[@]}"); the plan's bound is <= $RT_P999_RATIO_MAX_PERMILLE, asserted only with a 2x margin in all runs, S11 decides; a guest RT kernel can't remove host preemption of the vCPU)"
  fi

  # ---- criterion 5: every lane and alternation ---------------------------------------------------------------------------------------
  step "criterion 5: every lane and alternation (line count, dropped, environment, pins, checksums)"
  interval_periods=$((CT_SECONDS * 1000000 / INTERVAL_US))
  for lane in "${LANES[@]}"; do
    for n in $(seq 1 "$ROUNDS_RUN"); do
      c=$(P "$lane" "$n" line/consumer.json)
      count=$(val "$c" .count)
      crit_exact 5 "$lane alt$n line consumer count (rate x seconds x cameras)" "$count" "$LINE_COUNT"
      crit_exact 5 "$lane alt$n line consumer dropped" "$(val "$c" .dropped)" 0
      crit_exact 5 "$lane alt$n line consumer counters.parcels equals the histogram count" "$(val "$c" .runtime.counters.parcels)" "$count"
      p=$(P "$lane" "$n" probe.json)
      crit_exact 5 "$lane alt$n probe samples + missed periods equal duration / period" "$(($(val "$p" .runtime.counters.samples) + $(val "$p" .runtime.counters.missed_periods)))" "$interval_periods"
      # The environment: every report says vm and carries the lane's snapshot, the profile name and the vCPU pins.
      for f in "$c" "$(P "$lane" "$n" line/lateness.json)" "$p" "$(ct_file "$lane" "$n")" "$(P "$lane" "$n" pi/plain-mutex.json)" \
        "$(P "$lane" "$n" pi/pi-mutex.json)" "$(P "$lane" "$n" java/java-wake.json)" "$(P "$lane" "$n" mechanism.json)" "$(P "$lane" "$n" steal.json)"; do
        name=${f#"$OUT"/vm/}
        crit_exact 5 "$name runtime.environment.kind" "$(val "$f" .runtime.environment.kind)" vm
        crit_exact 5 "$name guest_profile snapshot" "$(val "$f" .runtime.environment.guest_profile.snapshot)" "$(lane_snapshot "$lane")"
        crit_exact 5 "$name guest_profile profile" "$(val "$f" .runtime.environment.guest_profile.profile)" "$GUEST_PROFILE_SUFFIX"
        crit_ge 5 "$name guest_profile vcpupin entries" "$(val "$f" '.runtime.environment.guest_profile.vcpupin | length')" "$GUEST_VCPUS"
      done
      crit_exact 5 "$lane alt$n vCPUs 2 and 3 are each pinned to one host CPU (libvirt vcpupin)" \
        "$(val "$c" '[.runtime.environment.guest_profile.vcpupin[] | select(.vcpu >= 2) | .cpus | test("^[0-9]+$")] | all')" true
      crit_exact 5 "$lane alt$n embedded profile virt.type (the guest's)" "$(val "$c" .profile.virt.type)" kvm
      crit_exact 5 "$lane alt$n line consumer pinned to CPU" "$(val "$c" '.runtime.placement.cpus | join(",")')" "$LINE_CPU"
      crit_exact 5 "$lane alt$n probe pinned to CPU" "$(val "$p" '.runtime.placement.cpus | join(",")')" "$PROBE_CPU"
      crit_exact 5 "$lane alt$n Java hot thread placement" "$(val "$(P "$lane" "$n" java/java-wake.json)" '.runtime.placement.cpus | join(",")')" "$JAVA_CPU"
    done
  done
  # One binary: the three lanes ran the same five files, and they are the ones the host summed.
  distinct=$(cat "$OUT"/vm/*/alt*/binaries.txt | awk '{print $2, $1}' | sort -u | wc -l)
  names=$(cat "$OUT"/vm/*/alt*/binaries.txt | awk '{print $2}' | sort -u | wc -l)
  crit_exact 5 "distinct (binary, checksum) pairs over every lane and alternation, one per binary (the same files everywhere)" "$distinct" "$names"
  crit_exact 5 "binaries checksummed" "$names" "$(wc -l <"$OUT/SHA256SUMS")"
  crit_exact 5 "the guest's checksums equal the host's SHA256SUMS (hash of the sorted lists)" \
    "$(cat "$OUT"/vm/*/alt*/binaries.txt | awk '{print $1, $2}' | sort -u | sha256sum | cut -c1-12)" "$(awk '{print $1, $2}' "$OUT/SHA256SUMS" | sort | sha256sum | cut -c1-12)"

  # ---- criterion 6: the Java hot thread ------------------------------------------------------------------------------------------------
  step "criterion 6: the Java hot thread's policy (chrt -p, taken while it ran)"
  for lane in "${LANES[@]}"; do
    for n in $(seq 1 "$ROUNDS_RUN"); do
      chrt=$(P "$lane" "$n" java/chrt-hot.txt)
      crit_true 6 "$lane alt$n chrt -p says policy $JAVA_POLICY" "$(grep -q "scheduling policy: $JAVA_POLICY\$" "$chrt" && echo 1 || echo 0)" "$(tr '\n' ';' <"$chrt")"
      crit_true 6 "$lane alt$n chrt -p says priority $JAVA_PRIORITY" "$(grep -q "scheduling priority: $JAVA_PRIORITY\$" "$chrt" && echo 1 || echo 0)" "$(tr '\n' ';' <"$chrt")"
    done
  done

  # ---- observed ---------------------------------------------------------------------------------------------------------------------------
  step "observed: the lanes side by side (lane vm, this guest, this run; no host lane)"
  for lane in "${LANES[@]}"; do
    printf '  %-10s cyclictest p50 / p99 / p99.9 / max us, median of %s: %s / %s / %s / %s;  probe p99.9 %s us;  line p99.9 %s us\n' "$lane" "$ROUNDS_RUN" \
      "$(us "$(lane_median "$lane" p50 ct_file)")" "$(us "$(lane_median "$lane" p99 ct_file)")" "$(us "$(lane_median "$lane" p99_9 ct_file)")" "$(us "$(lane_median "$lane" max ct_file)")" \
      "$(us "$(lane_median "$lane" p99_9 rel_file probe.json)")" "$(us "$(lane_median "$lane" p99_9 rel_file line/consumer.json)")"
  done
  observed "stock-full over stock-lazy, cyclictest p99.9 (median of $ROUNDS_RUN): $(us "$(lane_median stock-full p99_9 ct_file)") us against $(us "$(lane_median stock-lazy p99_9 ct_file)") us"
  for lane in "${LANES[@]}"; do
    for n in $(seq 1 "$ROUNDS_RUN"); do
      ctf=$(ct_file "$lane" "$n") pf=$(P "$lane" "$n" probe.json)
      observed "$lane alt$n probe p99 $(us "$(pkey "$pf" p99)") us against cyclictest p99 $(us "$(pkey "$ctf" p99)") us (the cross-check; different CPUs, same window); cyclictest overflows $(jq -r '.runtime.counters.overflows // 0' "$ctf"), probe missed periods $(val "$pf" .runtime.counters.missed_periods)"
      st=$(P "$lane" "$n" steal.json)
      observed "$lane alt$n steal ticks $(val "$st" .steal_ticks) of $(val "$st" .total_ticks) guest ticks"
      ir=$(P "$lane" "$n" interrupts.json)
      observed "$lane alt$n /proc/interrupts deltas, CPU 2 / CPU 3: LOC $(jq -r '.LOC["2"] // 0' "$ir") / $(jq -r '.LOC["3"] // 0' "$ir"), RES $(jq -r '.RES["2"] // 0' "$ir") / $(jq -r '.RES["3"] // 0' "$ir")"
      j=$(P "$lane" "$n" java/java-wake.json)
      observed "$lane alt$n Java wake lateness p99 / p99.9 / max us $(us "$(pkey "$j" p99)") / $(us "$(pkey "$j" p99_9)") / $(us "$(pkey "$j" max)"); safepoints $(val "$j" .runtime.counters.safepoints), total $(($(val "$j" .runtime.counters.safepoint_total_ns) / 1000)) us"
      m=$(P "$lane" "$n" mechanism.json)
      observed "$lane alt$n ksoftirqd $(val "$m" .threads.ksoftirqd.count) ($(val "$m" .threads.ksoftirqd.policies)), rcuc $(val "$m" .threads.rcuc.count) ($(val "$m" .threads.rcuc.policies)), sched_rt_runtime_us $(val "$m" .kernel.sched_rt_runtime_us)"
    done
  done
  finish_eval
}

# finish_eval: the criteria table, and this directory's verdict.
finish_eval() {
  local id status
  echo
  printf '%-3s %-9s %-6s %-6s %s\n' id kind checks missed "criterion (${OUT#"$HERE"/})"
  for id in "${CRIT_ORDER[@]}"; do
    status=${CRIT_BAD[$id]}
    printf '%-3s %-9s %-6s %-6s %s\n' "$id" "${CRIT_KIND[$id]}" "${CRIT_N[$id]}" "$status" "${CRIT_DESC[$id]}"
  done
  TOTAL_FAIL=$((TOTAL_FAIL + FAILURES))
  if ((FAILURES)); then say_bad "$FAILURES check(s) not met in ${OUT#"$HERE"/}"; else ok "every criterion holds in ${OUT#"$HERE"/}"; fi
}

for run in "${RUNS[@]}"; do
  evaluate "$run"
done

if ((SMOKE)); then
  ok "SMOKE: script check finished with $TOTAL_FAIL checks not met at these sizes (not enforced, not a result)"
  exit 0
fi
((TOTAL_FAIL == 0)) || die "$TOTAL_FAIL checks not met"
ok "14-preempt-rt: every criterion holds in ${#RUNS[@]} results director$([[ ${#RUNS[@]} == 1 ]] && echo y || echo ies)"
