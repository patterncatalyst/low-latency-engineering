#!/usr/bin/env bash
# Ch16 verify: measuring jitter with cyclictest, in the lab guest (C++; cyclictest is a C tool and the probe is C++).
#
# Five lanes, run interleaved in ONE run, each from a clean snapshot (lab-ready-r05-iso, noise on guest CPUs 0-1,
# measurement on the isolated CPUs 2-3), three alternations: naive method timerlat haltpoll-forced idle-default. A number
# from one run is never compared with a number from another. Every number means "in this KVM guest, in this run": the host
# still schedules the vCPUs, so a guest result bounds nothing about bare metal.
# Every criterion is evaluated and printed with its measured value and its bound; any miss fails the run after all of
# them have been evaluated. Counters labelled "exact" are counts the kernel, the tool or the file reports, with no median.
# A latency figure is the median of the three per-alternation values.
#
# Asserted (provisional until the S11 calibration sets the bounds):
#   1  (exact) method: cyclictest's sample count = duration / interval within 1%, at least 100,000, and no histogram
#      overflow (a stall longer than one interval records one late sample, so a count that falls short is a finding)
#   2  (exact) naive ran SCHED_OTHER with priority 0 and the default clock (CLOCK_REALTIME at v2.11); method ran
#      SCHED_FIFO 95 on CPU 3 with CLOCK_MONOTONIC; both read back with chrt -p and taskset -pc while cyclictest ran
#   3  cross-check: the C++ probe's p99 and cyclictest's method p99 within 2x of each other, same lane, median of 3
#   4  (exact) the converter's percentiles from the histfile equal an independent recomputation from the gzipped
#      histfile (check/recompute_hist.py), p50, p90, p99, p99.9 and max, in every cyclictest lane
#   5  (exact) the run's own facts: one set of binary checksums in every lane, the snapshot, the guest profile (KVM, RT
#      kernel, isolated CPUs 2-3), vCPUs 2 and 3 each pinned to one host CPU, cpuidle driver per lane, every report
#      passes lowlat-report check
# Observed, not asserted: naive against method (the direction is stated whichever way it goes), the timerlat IRQ against
# thread split, haltpoll-forced against idle-default, steal ticks, interrupt deltas on CPUs 2 and 3.
#
#   ./verify.sh                 evaluate results/latest if it is there; otherwise say how to get results (a real run needs VM=1)
#   VM=1 ./verify.sh            build, unit tests, then vm/run.sh: five lanes x 3 from lab-ready-r05-iso, evaluate
#   RECHECK=results/<run-id>    re-evaluate a results directory, run nothing
#   SMOKE=1 RESULTS_DIR=DIR     short lanes, one alternation, a check of the scripts (not a measurement, nothing enforced)
#   CRIT3_ASSERTED=0|1          (default 1) criterion 3 asserted; 0 observes it
#   SKIP_BUILD=1                reuse the existing build
#   TIMERLAT_THRESHOLD_US=N     rtla's stop threshold (default 1000; S11 sets it)
#
# Run it under the host benchmark lock when another example measures on this host:  flock -o "$LOCK" env VM=1 ./verify.sh
# Never changes the host: no sudo, no sysctl, no governor. The guest is driven by vm/run.sh and vm/guest-run.sh.
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
RECOMPUTE=$HERE/check/recompute_hist.py

# ---- bounds (provisional; a miss is reported, never loosened here) ------------------------------------------------------
SAMPLES_TOLERANCE_PERCENT=1  # 1: method's sample count against duration / interval
SAMPLES_MIN=100000           # 1: enough that p99.9 rests on 100 samples
PROBE_RATIO_MAX_MILLI=2000   # 3: probe p99 against cyclictest p99, 2x
PROBE_FLOOR_NS=1000          # 3: cyclictest reports whole microseconds, so a figure under 1 us is read as 1 us
CRIT3_ASSERTED=${CRIT3_ASSERTED:-1}
FIFO_PRIO=95
EXPECT_SNAPSHOT=$SNAPSHOT

# ---- which mode ----------------------------------------------------------------------------------------------------------
if [[ -n ${RECHECK:-} ]]; then
  [[ -d $RECHECK ]] || die "RECHECK=$RECHECK is not a directory"
  OUT=$(cd "$RECHECK" && pwd)
  RUN=0
elif [[ ${VM:-0} == 1 ]]; then
  RUN=1
  OUT=$(results_dir)
  export RESULTS_DIR=$OUT
else
  OUT=${RESULTS_DIR:-$HERE/results/latest}
  if [[ -f $OUT/run-start.json ]]; then
    RUN=0
  else
    cat >&2 <<EOF
16-cyclictest: no results to evaluate (looked for run-start.json in ${OUT#"$HERE"/}).
  VM=1 ./verify.sh            run the five lanes in the lab guest (needs the lowlat-target VM and the lab-ready-r05-iso snapshot)
  RECHECK=results/<run-id>    evaluate an existing results directory
A real run needs the guest: this script never measures on the host, where SCHED_FIFO is not available to it.
EOF
    exit 2
  fi
fi

scratch_dir
TABLE=()
crit() {
  # crit ID KIND DESC MEASURED BOUND PASS [ENFORCED]: print a criterion and add it to the table; PASS is 1 or 0.
  local id=$1 kind=$2 desc=$3 meas=$4 bound=$5 pass=$6 enforced=${7:-1} res
  if ((pass)); then
    res=pass
    ok "$id ($kind) $desc: measured $meas, bound $bound"
  elif [[ $enforced == 1 ]]; then
    res=FAIL
    bad "$id ($kind) $desc: measured $meas, bound $bound"
  else
    res="not met (observed)"
    printf '  observed, bound not met: %s %s: measured %s, bound %s\n' "$id" "$desc" "$meas" "$bound"
  fi
  TABLE+=("| $id | $kind | $desc | $meas | $bound | $res |")
}
crit_exact() { crit "$1" "${5:-exact}" "$2" "$3" "== $4" "$([[ $3 == "$4" ]] && echo 1 || echo 0)"; }

# val FILE JQ: one value from a JSON file; a file or a key that is not there is a failed run, named.
val() {
  local v
  [[ -f $1 ]] || die "${1#"$OUT"/} is missing"
  v=$(jq -r "$2" "$1" 2>/dev/null) || die "${1#"$OUT"/}: cannot read $2"
  [[ -n $v && $v != null ]] || die "${1#"$OUT"/}: $2 is missing or null"
  printf '%s' "$v"
}
# P LANE ALT REL: the path of one lane's file.
P() { printf '%s/vm/%s/alt%s/%s' "$OUT" "$1" "$2" "$3"; }
# us NS: nanoseconds as microseconds with one decimal.
us() { awk -v n="$1" 'BEGIN { printf "%.1f", n / 1000 }'; }
# lane_median LANE JQ FILE: the median over the alternations of one number in one file of the lane.
lane_median() {
  local lane=$1 q=$2 rel=$3 n vals=()
  for n in $(seq 1 "$ALTS"); do vals+=("$(val "$(P "$lane" "$n" "$rel")" "$q")"); done
  median_ns "${vals[@]}"
}

# ---- build, unit tests, run ----------------------------------------------------------------------------------------------
if ((RUN)); then
  LOGS=$LOWLAT_SCRATCH/logs
  mkdir -p "$LOGS"
  trap 'mkdir -p "$OUT/logs"; find "$LOGS" -maxdepth 1 -name "*.log" -exec mv -t "$OUT/logs" {} + 2>/dev/null || true; _bg_cleanup' EXIT
  build_cpp cyclic-probe cyclic-test method-test
  step "unit tests: the probe and the method parameters (GoogleTest), the recomputation and the rtla parser (pytest)"
  "$(cpp_bin cyclic-test)" --gtest_brief=1 >"$LOGS/cpp-cyclic-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-cyclic-tests.log" >&2; die "probe tests failed"; }
  "$(cpp_bin method-test)" --gtest_brief=1 >"$LOGS/cpp-method-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-method-tests.log" >&2; die "method tests failed"; }
  py_sync
  uvrun pytest -q "$HERE/tests" >"$LOGS/python-tests.log" 2>&1 || { tail -20 "$LOGS/python-tests.log" >&2; die "Python tests failed"; }
  ok "C++ and Python unit tests pass"
  VERIFY_DRIVER=1 SKIP_BUILD=1 RESULTS_DIR=$OUT "$HERE/vm/run.sh" 2>&1 | tee "$LOGS/vm-run.log"
fi

# ---- evaluate -----------------------------------------------------------------------------------------------------------
[[ -f $OUT/run-start.json ]] || die "no run-start.json in $OUT"
SMOKE_RUN=0
[[ ${SMOKE:-0} == 1 || $(jq -r '.smoke // false' "$OUT/run-start.json") == true ]] && SMOKE_RUN=1
ALTS=$(val "$OUT/run-start.json" .rounds)
SECS_METHOD=$(val "$OUT/run-start.json" .seconds.method)
INTERVAL=$(val "$OUT/run-start.json" .interval_us)
LABEL=$(<"$OUT/vm/LABEL") || die "no vm/LABEL"
step "evaluate $OUT: $ALTS alternation(s) of ${LANES[*]}$( ((SMOKE_RUN)) && echo ' (smoke: nothing is enforced)')"

# Structure: every file the criteria read is there.
missing=()
for lane in "${LANES[@]}"; do
  for n in $(seq 1 "$ALTS"); do
    need=(profile.json lane.json cpuidle.json steal.json vcpupin.json interrupts.json host-quiet.json)
    case $lane in
      timerlat) need+=(sched.json timerlat.json timerlat.txt) ;;
      method) need+=(sched.json cyclictest.json cyclictest-run.json cyclictest.hist.gz cpp/cyclic-probe.json cpp/sched.json) ;;
      *) need+=(sched.json cyclictest.json cyclictest-run.json cyclictest.hist.gz) ;;
    esac
    for f in "${need[@]}"; do [[ -s $(P "$lane" "$n" "$f") ]] || missing+=("vm/$lane/alt$n/$f"); done
  done
done
((${#missing[@]} == 0)) || { printf '  missing: %s\n' "${missing[@]}" >&2; die "${#missing[@]} result file(s) missing from $OUT"; }
crit_exact "S" "vm/LABEL" "$LABEL" vm structure

# ---- criterion 1: method's samples, duration / interval, no overflow ---------------------------------------------------------
step "criterion 1: method sample count and histogram overflow"
want=$((SECS_METHOD * 1000000 / INTERVAL))
samples=() overflows=()
for n in $(seq 1 "$ALTS"); do
  f=$(P method "$n" cyclictest.json)
  s=$(val "$f" .runtime.counters.samples)
  o=$(val "$f" .runtime.counters.overflows)
  samples+=("$s")
  overflows+=("$o")
  diff=$((s > want ? s - want : want - s))
  crit 1 exact "alt$n method samples (expected $want = $SECS_METHOD s / $INTERVAL us, within ${SAMPLES_TOLERANCE_PERCENT}%)" "$s" "$((want * (100 - SAMPLES_TOLERANCE_PERCENT) / 100)) to $((want * (100 + SAMPLES_TOLERANCE_PERCENT) / 100))" \
    "$((diff * 100 <= want * SAMPLES_TOLERANCE_PERCENT))"
  crit 1 exact "alt$n method samples at least $SAMPLES_MIN (p99.9 then rests on $((s / 1000)) samples above it)" "$s" ">= $SAMPLES_MIN" "$((s >= SAMPLES_MIN))" "$((!SMOKE_RUN))"
  crit_exact 1 "alt$n method histogram overflow (-h $(val "$OUT/run-start.json" .hist_us) us)" "$o" 0
done

# ---- criterion 2: policy, priority, CPU, clock ----------------------------------------------------------------------------------
step "criterion 2: policy, priority, affinity and clock actually in effect"
for n in $(seq 1 "$ALTS"); do
  sched=$(P naive "$n" sched.json)
  notes=$(val "$(P naive "$n" cyclictest.json)" .notes)
  crit_exact 2 "alt$n naive tasks not SCHED_OTHER with priority 0 (chrt -p)" "$(jq '[.[] | select(.policy != "SCHED_OTHER" or .priority != 0)] | length' "$sched")" 0
  crit_exact 2 "alt$n naive has a task to read" "$(jq 'length > 0' "$sched")" true
  crit_exact 2 "alt$n naive clock in the report (v2.11 default, no --clock)" "$([[ $notes == *"clock realtime;"* ]] && echo realtime || echo "other: $notes")" realtime
  sched=$(P method "$n" sched.json)
  notes=$(val "$(P method "$n" cyclictest.json)" .notes)
  crit_exact 2 "alt$n method tasks that are SCHED_FIFO $FIFO_PRIO with affinity 3" "$(jq --argjson p "$FIFO_PRIO" '[.[] | select(.policy == "SCHED_FIFO" and .priority == $p and .affinity == "3")] | length > 0' "$sched")" true
  crit_exact 2 "alt$n method clock in the report (--clock=monotonic)" "$([[ $notes == *"clock monotonic;"* ]] && echo monotonic || echo "other: $notes")" monotonic
  crit_exact 2 "alt$n method measurement thread ran on CPU (cyclictest --json)" "$(val "$(P method "$n" cyclictest-run.json)" '.thread["0"].cpu')" 3
  crit_exact 2 "alt$n probe task SCHED_FIFO $FIFO_PRIO with affinity 2" "$(jq --argjson p "$FIFO_PRIO" '[.[] | select(.policy == "SCHED_FIFO" and .priority == $p and .affinity == "2")] | length > 0' "$(P method "$n" cpp/sched.json)")" true
done

# ---- criterion 3: probe against cyclictest, same lane --------------------------------------------------------------------------
step "criterion 3: probe p99 against cyclictest p99, method lane, median of $ALTS"
ratios=()
for n in $(seq 1 "$ALTS"); do
  c=$(val "$(P method "$n" cyclictest.json)" .percentiles.p99)
  p=$(val "$(P method "$n" cpp/cyclic-probe.json)" .percentiles.p99)
  ratios+=("$(awk -v a="$c" -v b="$p" -v f="$PROBE_FLOOR_NS" 'BEGIN { if (a < f) a = f; if (b < f) b = f; hi = a > b ? a : b; lo = a > b ? b : a; printf "%d", 1000 * hi / lo }')")
  printf '  alt%s: cyclictest p99 %s us, probe p99 %s us (probe samples %s, missed periods %s)\n' "$n" "$(us "$c")" "$(us "$p")" \
    "$(val "$(P method "$n" cpp/cyclic-probe.json)" .runtime.counters.samples)" "$(val "$(P method "$n" cpp/cyclic-probe.json)" .runtime.counters.missed_periods)"
done
med=$(median_ns "${ratios[@]}")
crit 3 "cross-check (provisional)" "probe p99 against cyclictest p99, larger over smaller (per alternation: ${ratios[*]} thousandths)" \
  "$(awk -v m="$med" 'BEGIN { printf "%.2fx", m / 1000 }')" "<= $(awk -v m="$PROBE_RATIO_MAX_MILLI" 'BEGIN { printf "%.2fx", m / 1000 }'), margin $(awk -v m="$med" -v b="$PROBE_RATIO_MAX_MILLI" 'BEGIN { printf "%.2fx", b / m }')" \
  "$((med <= PROBE_RATIO_MAX_MILLI))" "$CRIT3_ASSERTED"

# ---- criterion 4: the converter against an independent recomputation ------------------------------------------------------
step "criterion 4: converter percentiles against an independent recomputation from the gzipped histfile"
mismatch=0 checked=0
for lane in "${CT_LANES[@]}"; do
  for n in $(seq 1 "$ALTS"); do
    if python3 "$RECOMPUTE" "$(P "$lane" "$n" cyclictest.hist.gz)" "$(P "$lane" "$n" cyclictest.json)" >"$LOWLAT_SCRATCH/recompute.out" 2>&1; then
      checked=$((checked + 1))
    else
      mismatch=$((mismatch + 1))
      printf '  %s alt%s: %s\n' "$lane" "$n" "$(cat "$LOWLAT_SCRATCH/recompute.out")" >&2
    fi
  done
done
crit_exact 4 "lanes x alternations whose report differs from the recomputation (of $((${#CT_LANES[@]} * ALTS)), p50 p90 p99 p99.9 max)" "$mismatch" 0

# ---- criterion 5: the run's own facts ---------------------------------------------------------------------------------------------
step "criterion 5: binaries, snapshot, guest profile, pins, idle driver, report checks"
# One binary set: every lane of every alternation ran the files SHA256SUMS lists.
sums_of_run=$(LC_ALL=C awk '{print $2 " " $1}' "$OUT/SHA256SUMS" | LC_ALL=C sort | paste -sd';')
sums_of() { jq -r '.binaries | map(.name + " " + .sha256) | sort | join(";")' "$1"; }
distinct=$(for lane in "${LANES[@]}"; do for n in $(seq 1 "$ALTS"); do sums_of "$(P "$lane" "$n" lane.json)"; done; done | sort -u | wc -l)
crit_exact 5 "distinct binary checksum sets over every lane and alternation" "$distinct" 1
crit_exact 5 "that set equals SHA256SUMS, which lane_revert checked" "$([[ $(sums_of "$(P naive 1 lane.json)") == "$sums_of_run" ]] && echo equal || echo differs)" equal
crit_exact 5 "run-start.json says the guest was reverted" "$(val "$OUT/run-start.json" .reverted)" true
files=()
for lane in "${LANES[@]}"; do
  for n in $(seq 1 "$ALTS"); do
    lp=$(P "$lane" "$n" lane.json)
    pj=$(P "$lane" "$n" profile.json)
    tag="$lane alt$n"
    [[ $(val "$lp" .snapshot) == "$EXPECT_SNAPSHOT" ]] || bad "5 $tag: snapshot is $(val "$lp" .snapshot), not $EXPECT_SNAPSHOT"
    [[ $(val "$pj" .virt.type) == kvm ]] || bad "5 $tag: profile virt.type is $(val "$pj" .virt.type), not kvm"
    [[ $(val "$pj" .kernel.version) == *PREEMPT_RT* ]] || bad "5 $tag: the guest kernel is not PREEMPT_RT ($(val "$pj" .kernel.version))"
    [[ $(val "$pj" .kernel.sys_isolated) == 2-3 ]] || bad "5 $tag: /sys/devices/system/cpu/isolated is $(val "$pj" .kernel.sys_isolated), not 2-3"
    pins=$(jq '[.[] | select(.vcpu == 2 or .vcpu == 3) | select(.cpus | test("^[0-9]+$"))] | length' "$(P "$lane" "$n" vcpupin.json)")
    [[ $pins == 2 ]] || bad "5 $tag: vCPUs 2 and 3 are not each pinned to one host CPU ($(jq -c . "$(P "$lane" "$n" vcpupin.json)"))"
    case $lane in
      haltpoll-forced) drv=haltpoll ;;
      *) drv=none ;;
    esac
    [[ $(val "$(P "$lane" "$n" cpuidle.json)" .before.driver) == "$drv" ]] || bad "5 $tag: cpuidle driver is $(val "$(P "$lane" "$n" cpuidle.json)" .before.driver), not $drv"
    [[ $lane == timerlat ]] || files+=("$(P "$lane" "$n" cyclictest.json)")
    [[ $lane != method ]] || files+=("$(P "$lane" "$n" cpp/cyclic-probe.json)")
  done
done
if uvrun lowlat-report check "${files[@]}" >"$LOWLAT_SCRATCH/report-check.out" 2>&1; then
  crit_exact 5 "reports that fail lowlat-report check (of ${#files[@]})" 0 0
else
  cat "$LOWLAT_SCRATCH/report-check.out" >&2
  crit_exact 5 "reports that fail lowlat-report check (of ${#files[@]})" "see above" 0
fi

# ---- observed ---------------------------------------------------------------------------------------------------------------------
step "observed: naive against method, the timerlat split, haltpoll-forced against idle-default"
dir_word() { awk -v a="$1" -v b="$2" -v x="$3" -v y="$4" 'BEGIN { if (a > b) print x " is higher than " y; else if (a < b) print x " is lower than " y; else print x " equals " y }'; }
lane_line() {
  local lane=$1
  printf '  %-16s p50 / p99 / p99.9 / max us, median of %s: %s / %s / %s / %s;  samples %s\n' "$lane" "$ALTS" \
    "$(us "$(lane_median "$lane" .percentiles.p50 cyclictest.json)")" "$(us "$(lane_median "$lane" .percentiles.p99 cyclictest.json)")" \
    "$(us "$(lane_median "$lane" .percentiles.p99_9 cyclictest.json)")" "$(us "$(lane_median "$lane" .percentiles.max cyclictest.json)")" \
    "$(lane_median "$lane" .runtime.counters.samples cyclictest.json)"
}
for lane in "${CT_LANES[@]}"; do lane_line "$lane"; done
np=$(lane_median naive .percentiles.p99_9 cyclictest.json) mp=$(lane_median method .percentiles.p99_9 cyclictest.json)
nx=$(lane_median naive .percentiles.max cyclictest.json) mx=$(lane_median method .percentiles.max cyclictest.json)
printf '  observed: naive against method, p99.9: %s us against %s us, %s; max: %s us against %s us, %s (naive: CLOCK_REALTIME, SCHED_OTHER, unpinned, %s s; method: CLOCK_MONOTONIC, FIFO %s on CPU 3, %s s)\n' \
  "$(us "$np")" "$(us "$mp")" "$(dir_word "$np" "$mp" naive method)" "$(us "$nx")" "$(us "$mx")" "$(dir_word "$nx" "$mx" naive method)" \
  "$(val "$OUT/run-start.json" .seconds.naive)" "$FIFO_PRIO" "$SECS_METHOD"
printf '  observed: p99.9 rests on the samples above it: naive %s, method %s (samples / 1000)\n' \
  "$(($(lane_median naive .runtime.counters.samples cyclictest.json) / 1000))" "$(($(lane_median method .runtime.counters.samples cyclictest.json) / 1000))"

tl() { # tl KIND KEY: median over alternations of timerlat.json KIND.KEY; "over range" when a value is outside rtla's histogram
  local n vals=() v
  for n in $(seq 1 "$ALTS"); do
    v=$(jq -r ".$1.$2 // \"null\"" "$(P timerlat "$n" timerlat.json)")
    [[ $v =~ ^[0-9]+$ ]] || { echo "over range"; return; }
    vals+=("$v")
  done
  median_ns "${vals[@]}"
}
printf '  timerlat (rtla, CPU 3, %s s, microseconds, median of %s):  IRQ p50 / p99 / p99.9 / max: %s / %s / %s / %s;  thread: %s / %s / %s / %s\n' \
  "$(val "$OUT/run-start.json" .seconds.timerlat)" "$ALTS" "$(tl irq p50)" "$(tl irq p99)" "$(tl irq p99_9)" "$(tl irq max)" \
  "$(tl thread p50)" "$(tl thread p99)" "$(tl thread p99_9)" "$(tl thread max)"
stopped=0 fallback=0
for n in $(seq 1 "$ALTS"); do
  [[ $(jq -r .stopped_at_threshold "$(P timerlat "$n" timerlat.json)") == true ]] && stopped=$((stopped + 1))
  fallback=$((fallback + $(jq -r .tracefs_fallback_lines "$(P timerlat "$n" timerlat.json)")))
done
printf '  observed: timerlat runs that stopped at the %s us threshold: %s of %s (rtla then printed its auto-analysis, kept in timerlat.txt); stderr lines about BTF or tracefs: %s\n' \
  "$(val "$OUT/run-start.json" .timerlat_threshold_us)" "$stopped" "$ALTS" "$fallback"
printf '  observed: timerlat thread p99 %s us against cyclictest method p99 %s us (different programs on the same CPU, not the same samples)\n' \
  "$(tl thread p99)" "$(us "$(lane_median method .percentiles.p99 cyclictest.json)")"

hp=$(lane_median haltpoll-forced .percentiles.p99_9 cyclictest.json) id=$(lane_median idle-default .percentiles.p99_9 cyclictest.json)
printf '  observed: haltpoll-forced against idle-default, p99.9: %s us against %s us, %s (both --default-system; drivers haltpoll and none)\n' \
  "$(us "$hp")" "$(us "$id")" "$(dir_word "$hp" "$id" haltpoll-forced idle-default)"
for lane in haltpoll-forced idle-default; do
  printf '  cpuidle %-16s driver %s, governor %s, state usage on CPU 3 over the lane: %s\n' "$lane" \
    "$(val "$(P "$lane" 1 cpuidle.json)" .after.driver)" "$(val "$(P "$lane" 1 cpuidle.json)" .after.governor)" \
    "$(jq -c '.before.states["3"] as $b | (.after.states["3"] // {}) | to_entries | map({(.key): (.value.usage - ($b[.key].usage // 0))}) | add // {}' "$(P "$lane" 1 cpuidle.json)" 2>/dev/null || echo unreadable)"
done
for lane in "${LANES[@]}"; do
  st=() irq=()
  for n in $(seq 1 "$ALTS"); do
    st+=("$(val "$(P "$lane" "$n" steal.json)" .measure_cpu_steal_ticks)")
    irq+=("$(jq -r '(.LOC["3"] // 0)' "$(P "$lane" "$n" interrupts.json)")")
  done
  printf '  %-16s steal ticks on CPU 3 per alternation: %s;  LOC interrupts on CPU 3 per alternation: %s\n' "$lane" "${st[*]}" "${irq[*]}"
done

# ---- criteria table ------------------------------------------------------------------------------------------------------------------
printf '\n| id | kind | criterion | measured | bound | result |\n|---|---|---|---|---|---|\n'
printf '%s\n' "${TABLE[@]}"
echo

if ((SMOKE_RUN)); then
  ok "SMOKE: script check finished with $FAILURES criteria not met at these sizes (not enforced, not a result); output in $OUT"
  exit 0
fi
((FAILURES == 0)) || die "$FAILURES criteria not met; results in $OUT"
ok "16-cyclictest: every criterion holds; results in $OUT"
jq -r '"guest profile: virt=\(.virt.type) kernel=\(.kernel.release) preempt=\(.kernel.version) isolated=\(.kernel.sys_isolated)"' "$(P method 1 profile.json)"
