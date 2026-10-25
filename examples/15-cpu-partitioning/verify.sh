#!/usr/bin/env bash
# Ch15 verify: does isolating CPUs 2-3 keep the tick, the scheduler, the interrupts and the JVM's helper threads off the
# measured thread, in a 4-vCPU KVM guest?
#
# Five lanes, run interleaved in ONE run (shared isolated irq-steered irq-on-measure-cpu cache-noise, three alternations,
# each from a clean snapshot), because a number from one run is never compared with a number from another. Every number
# is lane `vm`: it means "in this KVM guest, in this run". Nothing is compared with a host number, and the vCPU pins are
# pins, not host isolation. Every criterion is evaluated; each prints its measured value, its bound and the margin, and any
# miss fails the run after all of them have been evaluated. Counters labelled "exact" are deterministic and are judged in
# every alternation; a latency ratio is the median of the three alternations. The bounds are PROVISIONAL until the S11
# calibration gate has run: a criterion that does not clear 2x in all three calibration runs becomes observed, by decision.
#
#   1  (exact) /sys/devices/system/cpu/isolated and nohz_full: "2-3" in the four isolated-snapshot lanes, empty in shared.
#   2  (exact) LOC (local timer) interrupts per second on CPU 2 with one busy task and no other load: isolated <= 10,
#      shared >= 500 (HZ 1000). S1 measured 0 against about 1012.
#   3  (exact) no stress-ng or hackbench thread is ever seen on CPUs 2-3 in `isolated` and `cache-noise`; the busy decide
#      thread's involuntary context switches on CPU 2 beside the noise: isolated <= 10, shared >= 100.
#   4  cyclictest p99.9 on CPU 3 (FIFO 95, 1 ms, 300 s): isolated <= 1/2 of shared (median of 3 alternations).
#   5  (exact) virtio-blk request-queue interrupts on CPU 3 beside the disk I/O: irq-steered = 0, irq-on-measure-cpu >= 1000.
#   6  (exact) Java, Temurin by path: hot-thread-pinned has exactly 1 JVM thread on CPUs 2-3 and <= 10 involuntary switches;
#      jvm-taskset-isolated has >= 10 JVM threads on 2-3.
#   7  the line (10 kHz x 20 s, 200,000 parcels, receive/decide restricted to 2-3): count 200000, dropped 0, in shared and
#      isolated, every alternation.
#   8  harness: every report passes `lowlat-report check`, says runtime.environment.kind vm with the lane's snapshot and the
#      vCPU pins, every profile says virt.type kvm, one set of binary checksums across all lanes and equal to SHA256SUMS,
#      and each cyclictest run took at least 98 percent of its expected samples with no histogram overflow.
# Observed, not asserted: cache-noise p99.9 against the CPU-noise isolated lane; the IRQ defect's p99.9; the smp_affinity write
# (virtio-net accepted, virtio-blk managed: errno recorded); the Java placements; steal ticks; the noise threads seen on 2-3 in shared.
#
#   VM=1 ./verify.sh            build, unit tests, then vm/run.sh: revert the lab guest per lane, run the lanes interleaved, fetch,
#                               evaluate. Needs the lab-ready-r05-rt and lab-ready-r05-iso snapshots (scripts/lab/README.md)
#   RECHECK=results/<run-id>    re-evaluate a results directory without building or running anything
#   SMOKE=1 RESULTS_DIR=DIR     short lanes, one alternation, a check of this script (nothing enforced)
#   RESULTS_DIR=DIR             where reports go (default results/latest)
#   SKIP_BUILD=1                reuse existing builds
#   P999_ASSERTED=0|1           (default 1) criterion 4 asserted; 0 observes it
#   LOC_ASSERTED, IRQ_ASSERTED  likewise for criteria 2 and 5
# A plain ./verify.sh has nothing to run: the effect exists only in the guest, so it prints how to run one and exits 2.
#
# Run it under the host benchmark lock when another example measures on this host, and give flock -o so the lock
#   flock -o "$LOCK" ./verify.sh
# is not inherited by the script or anything it starts. UDP 47410-47413 (r05 owns 47400-47429). Never changes the host:
# no sudo, no sysctl, no tuned. The guest is driven by vm/run.sh and vm/guest-run.sh.
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

# ---- bounds (provisional; S11 sets them from the calibration runs, and a miss is reported, never loosened here) ------------------
LOC_ISOLATED_MAX=10                           # 2: per second, CPU 2, one busy task (exact: S1 saw 0)
LOC_SHARED_MIN=500                            # 2: HZ 1000 on a busy CPU
SWITCHES_ISOLATED_MAX=10                      # 3: the decide thread's involuntary switches over DECIDE_SECONDS
SWITCHES_SHARED_MIN=100
P999_RATIO_MIN_PERMILLE=2000                  # 4: shared p99.9 >= 2x isolated
BLK_STEERED_EXACT=0                           # 5
BLK_ON_MEASURE_MIN=1000                       # 5: S11 sizes it
HOT_THREADS_ON_ISOLATED=1                     # 6
HOT_SWITCHES_MAX=10
JVM_THREADS_ON_ISOLATED_MIN=10
SAMPLES_MIN_PERMILLE=980                      # 8: of CT_SECONDS * 1000 samples at 1 ms
P999_ASSERTED=${P999_ASSERTED:-1}
LOC_ASSERTED=${LOC_ASSERTED:-1}
IRQ_ASSERTED=${IRQ_ASSERTED:-1}

if [[ ${SMOKE:-0} == 1 ]]; then
  # A check of this script, not a measurement: short lanes, every criterion evaluated and printed, none enforced.
  [[ -n ${RESULTS_DIR:-} ]] || { echo "SMOKE=1 needs RESULTS_DIR (it must not overwrite results/latest)" >&2; exit 2; }
fi
LINE_COUNT=$(line_count)

if [[ -n ${RECHECK:-} ]]; then
  OUT=$(cd "$RECHECK" && pwd)
  RUN=0
elif [[ ${VM:-0} == 1 ]]; then
  RUN=1
else
  cat >&2 <<MSG
15-cpu-partitioning: nothing to run here. The effect (the tick, the scheduler, interrupts and JVM threads on isolated CPUs)
exists only in the lab guest, so a real run needs the guest:
  VM=1 ./verify.sh                       build, unit tests, then vm/run.sh on lowlat-target (snapshots lab-ready-r05-rt, lab-ready-r05-iso)
  RECHECK=results/<run-id> ./verify.sh   re-evaluate a results directory, run nothing
  DRY_RUN=1 vm/run.sh                    print what a run would do, touch no VM
MSG
  exit 2
fi
LOGS=''
if ((RUN)); then
  OUT=$(results_dir)
  export RESULTS_DIR=$OUT
  scratch_dir
  LOGS=$LOWLAT_SCRATCH/logs
  mkdir -p "$LOGS"
fi
finish_logs() {
  if [[ -n $LOGS && -d $LOGS ]]; then
    mkdir -p "$OUT/logs"
    find "$LOGS" -maxdepth 1 -name '*.log' -exec mv -t "$OUT/logs" {} + 2>/dev/null || true
  fi
}
trap 'finish_logs; _bg_cleanup' EXIT
scratch_dir

# ---- helpers (the house crit_* pattern of examples 11 to 13) ---------------------------------------------------------------------
ROWS=()
margin() { awk -v a="$1" -v b="$2" 'BEGIN { if (b == 0) print "inf"; else printf "%.2f", a / b }'; }
# mx RATIO: a margin as printed ("5.00x", or "inf" when the denominator was zero).
mx() { if [[ $1 == inf ]]; then echo inf; else echo "${1}x"; fi; }
note_margin() { awk -v m="$1" 'BEGIN { if (m != "inf" && m + 0 < 2) print " [margin under 2x: value reported, bound unchanged]" }'; }
# row ID NAME MEASURED BOUND MARGIN RESULT: one line of the criteria table printed at the end.
row() { ROWS+=("$1|$2|${3:0:70}|$4|$5|$6"); }
crit_ge() { # ID NAME MEASURED BOUND
  local m
  m=$(margin "$3" "$4")
  if (($3 >= $4)); then
    ok "$1 $2: measured $3, bound >= $4, margin $(mx "$m")$(note_margin "$m")"
    row "$1" "$2" "$3" ">= $4" "$(mx "$m")" ok
  else
    bad "$1 $2: measured $3, bound >= $4, margin $(mx "$m")"
    row "$1" "$2" "$3" ">= $4" "$(mx "$m")" MISS
  fi
}
crit_le() { # ID NAME MEASURED BOUND
  local m
  m=$(margin "$4" "$3")
  if (($3 <= $4)); then
    ok "$1 $2: measured $3, bound <= $4, margin $(mx "$m")$(note_margin "$m")"
    row "$1" "$2" "$3" "<= $4" "$(mx "$m")" ok
  else
    bad "$1 $2: measured $3, bound <= $4, margin $(mx "$m")"
    row "$1" "$2" "$3" "<= $4" "$(mx "$m")" MISS
  fi
}
crit_exact() { # ID NAME MEASURED BOUND
  if [[ $3 == "$4" ]]; then
    ok "$1 $2: measured $3, bound == $4 (exact)"
    row "$1" "$2" "$3" "== $4" exact ok
  else
    bad "$1 $2: measured $3, bound == $4 (exact)"
    row "$1" "$2" "$3" "== $4" exact MISS
  fi
}
# observed ID NAME TEXT: a value reported and not asserted (or a criterion switched to observed).
observed() {
  printf '  observed: %s\n' "$2: $3"
  row "$1" "$2" "$3" "-" "-" observed
}

# val FILE JQ: one value from a JSON file; a file or a key that is not there is a failed run, named.
val() {
  local v
  [[ -f $1 ]] || die "${1#"$OUT"/} is missing"
  v=$(jq -r "$2" "$1" 2>/dev/null) || die "${1#"$OUT"/}: cannot read $2"
  [[ -n $v && $v != null ]] || die "${1#"$OUT"/}: $2 is missing or null"
  printf '%s' "$v"
}
# val_str FILE KEY: a string member that may be empty (the isolated list of a guest without isolation), but must be there.
val_str() {
  [[ -f $1 ]] || die "${1#"$OUT"/} is missing"
  jq -er --arg k "$2" 'if has($k) and (.[$k] | type) == "string" then .[$k] else error("missing") end' "$1" 2>/dev/null ||
    die "${1#"$OUT"/}: no string member $2"
}
# P LANE ALT REL: the path of one lane's file.
P() { printf '%s/vm/%s/alt%s/%s' "$OUT" "$1" "$2" "$3"; }
p999() { val "$1" .percentiles.p99_9; }
# pct FILE: "p50 / p99 / p99.9 / max" in microseconds.
pct() { jq -r '"\(.percentiles.p50 / 1000 | floor) / \(.percentiles.p99 / 1000 | floor) / \(.percentiles.p99_9 / 1000 | floor) / \(.percentiles.max / 1000 | floor) us"' "$1"; }
alts() { seq 1 "$ROUNDS"; }
# lane_median LANE REL JQ: the median over the alternations of one value.
lane_median() {
  local lane=$1 rel=$2 q=$3 a vals=()
  for a in $(alts); do vals+=("$(val "$(P "$lane" "$a" "$rel")" "$q")"); done
  median_ns "${vals[@]}"
}
# worst_of LANE REL JQ max|min: the largest or smallest of one value over the alternations.
worst_of() {
  local lane=$1 rel=$2 q=$3 which=$4 a vals=()
  for a in $(alts); do vals+=("$(val "$(P "$lane" "$a" "$rel")" "$q")"); done
  if [[ $which == max ]]; then printf '%s\n' "${vals[@]}" | sort -n | tail -n1; else printf '%s\n' "${vals[@]}" | sort -n | head -n1; fi
}
# gate ASSERTED: criteria switched to observed print instead of failing.
gate() { [[ $1 == 1 ]]; }

# ---- build, unit tests, and the guest run ------------------------------------------------------------------------------------------
if ((RUN)); then
  build_cpp placement-probe placement-test io-receive line-simulator
  BUILD_JAVA_TESTS=1 build_java "$HERE/java"
  step "unit tests: C++ (GoogleTest); Java ran during the build"
  "$(cpp_bin placement-test)" --gtest_brief=1 >"$LOGS/cpp-unit-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-unit-tests.log" >&2; die "C++ unit tests failed"; }
  ok "C++ and Java unit tests pass"
  py_sync
  # vm/run.sh reverts the guest per lane, runs the lanes interleaved, fetches the guest's results and shuts the guest down.
  # It is told the builds are done, and not to evaluate: this script does that below.
  VERIFY_DRIVER=1 SKIP_BUILD=1 RESULTS_DIR=$OUT "$HERE/vm/run.sh" 2>&1 | tee "$LOGS/vm-run.log"
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "vm/run.sh failed"
  scrub_results "$OUT"
fi

# ---- evaluate -------------------------------------------------------------------------------------------------------------------------
[[ $(<"$OUT/vm/LABEL") == vm ]] || die "vm/LABEL is not 'vm'"
for lane in "${LANES[@]}"; do
  for a in $(alts); do
    [[ -d $(P "$lane" "$a" .) ]] || die "no results for lane $lane alternation $a under $OUT/vm"
  done
done

step "harness: reports, environment labels, profiles, pins, binaries, sample counts"
mapfile -t all_reports < <(find "$OUT/vm" -name '*.json' -exec grep -lE '"schema" ?: ?"lowlat-report/1"' {} + | sort)
((${#all_reports[@]} > 0)) || die "no reports under $OUT"
if report_check "${all_reports[@]}" >/dev/null 2>"$LOWLAT_SCRATCH/report-check.err"; then
  ok "8 ${#all_reports[@]} reports validate"
  row 8 "lowlat-report check, ${#all_reports[@]} reports" ok "pass" exact ok
else
  cat "$LOWLAT_SCRATCH/report-check.err" >&2
  bad "8 lowlat-report check failed"
fi
harness_faults=0
for lane in "${LANES[@]}"; do
  snap=$(snapshot_of "$lane")
  for a in $(alts); do
    prof=$(P "$lane" "$a" profile.json)
    [[ $(val "$prof" .virt.type) == kvm ]] || { bad "8 $lane alt$a: profile.virt.type is not kvm"; harness_faults=$((harness_faults + 1)); }
    pins=$(jq 'map(.vcpu) | contains([2, 3])' "$(P "$lane" "$a" vcpupin.json)")
    [[ $pins == true ]] || { bad "8 $lane alt$a: vcpupin.json has no pin for vCPUs 2 and 3"; harness_faults=$((harness_faults + 1)); }
    got_sums=$(sed 's/  */ /' "$(P "$lane" "$a" binaries.txt)" | cut -d' ' -f1,2)
    [[ $got_sums == "$(sed 's/  */ /' "$OUT/SHA256SUMS" | cut -d' ' -f1,2)" ]] || { bad "8 $lane alt$a: the guest ran other binaries than SHA256SUMS lists"; harness_faults=$((harness_faults + 1)); }
    while IFS= read -r rep; do
      env_ok=$(jq --arg s "$snap" '.runtime.environment.kind == "vm" and .runtime.environment.guest_profile.snapshot == $s and (.runtime.environment.guest_profile.vcpupin | length) >= 2' "$rep")
      [[ $env_ok == true ]] || { bad "8 ${rep#"$OUT"/}: runtime.environment is not vm / $snap / vcpupin"; harness_faults=$((harness_faults + 1)); }
    done < <(find "$(P "$lane" "$a" .)" \( -path '*/cyclictest/*.json' -o -name consumer.json -o -name lateness.json \) -type f | sort)
    ct=$(P "$lane" "$a" "cyclictest/$lane-t0.json")
    samples=$(val "$ct" .runtime.counters.samples)
    over=$(val "$ct" .runtime.counters.overflows)
    secs=$CT_SECONDS
    [[ $lane == irq-* ]] && secs=$IRQ_SECONDS
    ((1000 * samples >= SAMPLES_MIN_PERMILLE * secs)) || { bad "8 $lane alt$a: $samples cyclictest samples, expected about $((secs * 1000))"; harness_faults=$((harness_faults + 1)); }
    ((over == 0)) || { bad "8 $lane alt$a: $over histogram overflow(s)"; harness_faults=$((harness_faults + 1)); }
  done
done
if ((harness_faults == 0)); then
  ok "8 profiles say kvm, vCPU 2 and 3 pinned, reports labelled vm with their snapshot, one set of binaries ($(cut -c1-12 "$OUT/SHA256SUMS" | tr '\n' ' ')), samples complete, no overflow"
  row 8 "harness (profiles, pins, labels, binaries, samples)" "0 faults" "== 0" exact ok
else
  row 8 "harness (profiles, pins, labels, binaries, samples)" "$harness_faults fault(s)" "== 0" exact MISS
fi

step "1 (exact) isolated and nohz_full per lane"
sysfs_faults=0
for lane in "${LANES[@]}"; do
  want=''
  lane_isolated "$lane" && want=$ISOLATED_SET
  for a in $(alts); do
    f=$(P "$lane" "$a" facts.json)
    got_i=$(val_str "$f" isolated)
    got_n=$(val_str "$f" nohz_full)
    if [[ $got_i != "$want" || $got_n != "$want" ]]; then
      bad "1 $lane alt$a: isolated='$got_i' nohz_full='$got_n', expected '$want'"
      sysfs_faults=$((sysfs_faults + 1))
    fi
  done
done
crit_exact 1 "lanes whose isolated/nohz_full sysfs differ from the snapshot's (2-3 in the isolated snapshot, empty in shared)" "$sysfs_faults" 0

step "2 (exact) LOC interrupts per second on CPU $DECIDE_CPU with one busy task and no other load"
loc_rate() { # LANE ALT -> LOC per second, rounded down
  local d s
  d=$(val "$(P "$1" "$2" interrupts-tick.json)" ".LOC[\"$DECIDE_CPU\"]")
  s=$(val "$(P "$1" "$2" tick.json)" .seconds)
  echo $((d / s))
}
iso_worst=0 sh_best=''
for a in $(alts); do
  r=$(loc_rate isolated "$a")
  ((r <= iso_worst)) || iso_worst=$r
  r=$(loc_rate shared "$a")
  if [[ -z $sh_best ]] || ((r < sh_best)); then sh_best=$r; fi
  printf '    alt%s: isolated %s/s, shared %s/s (RES/CAL/TLB deltas for CPUs 0-3 are in interrupts-tick.json)\n' "$a" "$(loc_rate isolated "$a")" "$r"
done
if gate "$LOC_ASSERTED"; then
  crit_le 2 "LOC/s on CPU $DECIDE_CPU, isolated, worst alternation" "$iso_worst" "$LOC_ISOLATED_MAX"
  crit_ge 2 "LOC/s on CPU $DECIDE_CPU, shared, lowest alternation" "$sh_best" "$LOC_SHARED_MIN"
else
  observed 2 "LOC/s on CPU $DECIDE_CPU" "isolated worst $iso_worst, shared lowest $sh_best (observed: LOC_ASSERTED=0)"
fi

step "3 (exact) noise threads on the isolated CPUs; the decide thread's involuntary switches"
noise_seen=0
for lane in isolated cache-noise; do
  for a in $(alts); do noise_seen=$((noise_seen + $(val "$(P "$lane" "$a" noise-cpus.json)" .threads_on_isolated))); done
done
crit_exact 3 "noise threads ever seen on CPUs $ISOLATED_SET (isolated and cache-noise, all alternations)" "$noise_seen" 0
shared_noise=$(worst_of shared noise-cpus.json .threads_on_isolated max)
shared_total=$(worst_of shared noise-cpus.json .threads max)
observed 3 "noise threads seen on CPUs $ISOLATED_SET in shared (worst alternation)" "$shared_noise of $shared_total"
inv_iso=$(worst_of isolated decide-probe.json .context_switches.involuntary max)
inv_sh=$(worst_of shared decide-probe.json .context_switches.involuntary min)
crit_le 3 "decide thread involuntary switches over ${DECIDE_SECONDS} s, isolated, worst alternation" "$inv_iso" "$SWITCHES_ISOLATED_MAX"
crit_ge 3 "decide thread involuntary switches over ${DECIDE_SECONDS} s, shared, lowest alternation" "$inv_sh" "$SWITCHES_SHARED_MIN"

step "4 cyclictest p99.9 on CPU $MEASURE_CPU (FIFO 95, ${CT_SECONDS} s, 1 ms), median of $ROUNDS alternation(s)"
for lane in shared isolated cache-noise irq-steered irq-on-measure-cpu; do
  for a in $(alts); do
    printf '    %s alt%s: %s (worst of the samples labelled max)\n' "$lane" "$a" "$(pct "$(P "$lane" "$a" "cyclictest/$lane-t0.json")")"
  done
done
sh_p=$(lane_median shared "cyclictest/shared-t0.json" .percentiles.p99_9)
is_p=$(lane_median isolated "cyclictest/isolated-t0.json" .percentiles.p99_9)
if ((is_p > 0)); then ratio=$((1000 * sh_p / is_p)); else ratio=0; fi
if gate "$P999_ASSERTED"; then
  if ((ratio >= P999_RATIO_MIN_PERMILLE)); then
    ok "4 p99.9 shared $((sh_p / 1000)) us against isolated $((is_p / 1000)) us: $(margin "$ratio" 1000)x, bound >= $(margin "$P999_RATIO_MIN_PERMILLE" 1000)x, margin $(margin "$ratio" "$P999_RATIO_MIN_PERMILLE")x"
    row 4 "cyclictest p99.9 shared / isolated (median of $ROUNDS alternation(s))" "$(margin "$ratio" 1000)x" ">= $(margin "$P999_RATIO_MIN_PERMILLE" 1000)x" "$(margin "$ratio" "$P999_RATIO_MIN_PERMILLE")x" ok
  else
    bad "4 p99.9 shared $((sh_p / 1000)) us against isolated $((is_p / 1000)) us: $(margin "$ratio" 1000)x, bound >= $(margin "$P999_RATIO_MIN_PERMILLE" 1000)x"
    row 4 "cyclictest p99.9 shared / isolated (median of $ROUNDS alternation(s))" "$(margin "$ratio" 1000)x" ">= $(margin "$P999_RATIO_MIN_PERMILLE" 1000)x" "$(margin "$ratio" "$P999_RATIO_MIN_PERMILLE")x" MISS
  fi
else
  observed 4 "cyclictest p99.9, shared against isolated (median of $ROUNDS alternation(s))" "$((sh_p / 1000)) us against $((is_p / 1000)) us, $(margin "$ratio" 1000)x (observed: P999_ASSERTED=0)"
fi
cn_p=$(lane_median cache-noise "cyclictest/cache-noise-t0.json" .percentiles.p99_9)
observed 4 "cache noise (--stream, --cache on CPUs $HOUSEKEEPING_SET) against CPU noise, p99.9, isolated snapshot (median of $ROUNDS alternation(s))" "$((cn_p / 1000)) us against $((is_p / 1000)) us; isolation doesn't partition the last-level cache or memory bandwidth"

step "5 (exact) virtio-blk request-queue interrupts on CPU $MEASURE_CPU beside the disk I/O"
blk_on_cpu3() { # LANE ALT -> the sum over the virtio-blk request-queue rows of the CPU 3 delta
  jq --arg re "$BLK_IRQ_REGEX" --arg c "$MEASURE_CPU" '[to_entries[] | select(.key | test($re)) | .value[$c] // 0] | add // empty' "$(P "$1" "$2" interrupts-cyclictest.json)"
}
blk_steered_max=0 blk_on_min=''
for a in $(alts); do
  s=$(blk_on_cpu3 irq-steered "$a")
  m=$(blk_on_cpu3 irq-on-measure-cpu "$a")
  [[ -n $s && -n $m ]] || die "no virtio-blk request-queue row (names like 29-virtio1-req.3) in interrupts-cyclictest.json of alternation $a"
  ((s <= blk_steered_max)) || blk_steered_max=$s
  if [[ -z $blk_on_min ]] || ((m < blk_on_min)); then blk_on_min=$m; fi
  printf '    alt%s: irq-steered %s, irq-on-measure-cpu %s; cyclictest p99.9 %s us against %s us\n' "$a" "$s" "$m" \
    "$(($(p999 "$(P irq-steered "$a" cyclictest/irq-steered-t0.json)") / 1000))" "$(($(p999 "$(P irq-on-measure-cpu "$a" cyclictest/irq-on-measure-cpu-t0.json)") / 1000))"
done
if gate "$IRQ_ASSERTED"; then
  crit_exact 5 "virtio-blk interrupts on CPU $MEASURE_CPU, irq-steered, worst alternation" "$blk_steered_max" "$BLK_STEERED_EXACT"
  crit_ge 5 "virtio-blk interrupts on CPU $MEASURE_CPU, irq-on-measure-cpu, lowest alternation" "$blk_on_min" "$BLK_ON_MEASURE_MIN"
else
  observed 5 "virtio-blk interrupts on CPU $MEASURE_CPU" "irq-steered worst $blk_steered_max, irq-on-measure-cpu lowest $blk_on_min (observed: IRQ_ASSERTED=0)"
fi
fstype=$(val "$(P irq-steered 1 facts.json)" .var_tmp_fstype)
observed 5 "filesystem under the disk I/O" "/var/tmp is $fstype"
ia=$(P isolated 1 irq-affinity.json)
observed 5 "smp_affinity write, alternation 1" "$(jq -r '"virtio-net IRQ \(.virtio_net.irq) (\(.virtio_net.name)): wrote \(.target_list), result \(.virtio_net.errno_name), effective \(.virtio_net.effective_before) -> \(.virtio_net.effective_after); virtio-blk IRQ \(.virtio_blk.irq) (\(.virtio_blk.name)): result \(.virtio_blk.errno_name) (errno \(.virtio_blk.errno))"' "$ia")"

step "6 (exact) Java, Temurin by path: which JVM threads ran on CPUs $ISOLATED_SET"
hot_sw_max=0 tj_min=''
for a in $(alts); do
  h=$(P isolated "$a" java-hot-thread-pinned.json)
  t=$(P isolated "$a" java-jvm-taskset-isolated.json)
  on=$(val "$h" .threads_on_isolated)
  sw=$(val "$h" '.hot_threads[0].involuntary_switches')
  tj=$(val "$t" .threads_on_isolated)
  printf '    alt%s: hot-thread-pinned %s thread on 2-3 (of %s), %s involuntary switches; jvm-taskset-isolated %s of %s threads on 2-3, the two busy threads on %s distinct CPU(s), involuntary %s / %s\n' \
    "$a" "$on" "$(val "$h" .threads_total)" "$sw" "$tj" "$(val "$t" .threads_total)" "$(val "$t" .hot_distinct_cpus)" \
    "$(val "$t" '.hot_threads[0].involuntary_switches')" "$(val "$t" '.hot_threads[1].involuntary_switches')"
  crit_exact 6 "hot-thread-pinned alt$a: JVM threads on CPUs $ISOLATED_SET" "$on" "$HOT_THREADS_ON_ISOLATED"
  ((sw <= hot_sw_max)) || hot_sw_max=$sw
  if [[ -z $tj_min ]] || ((tj < tj_min)); then tj_min=$tj; fi
done
crit_le 6 "hot-thread-pinned: the hot thread's involuntary switches over ${JAVA_SECONDS} s, worst alternation" "$hot_sw_max" "$HOT_SWITCHES_MAX"
crit_ge 6 "jvm-taskset-isolated: JVM threads on CPUs $ISOLATED_SET, lowest alternation" "$tj_min" "$JVM_THREADS_ON_ISOLATED_MIN"

step "7 the line: ${LINE_COUNT} parcels, receive/decide restricted to CPUs $ISOLATED_SET"
for lane in shared isolated; do
  for a in $(alts); do
    c=$(P "$lane" "$a" line/consumer.json)
    crit_exact 7 "$lane alt$a parcels counted" "$(val "$c" .count)" "$LINE_COUNT"
    crit_exact 7 "$lane alt$a parcels dropped" "$(val "$c" .dropped)" 0
  done
  printf '    %s alt1 consumer p50 / p99 / p99.9 / max: %s; steal %s of %s ticks\n' "$lane" "$(pct "$(P "$lane" 1 line/consumer.json)")" \
    "$(val "$(P "$lane" 1 steal.json)" .steal_ticks)" "$(val "$(P "$lane" 1 steal.json)" .total_ticks)"
done

step "observed: the guest and the lanes"
for lane in "${LANES[@]}"; do
  a=1
  f=$(P "$lane" "$a" facts.json)
  printf '  %s: kernel %s, preempt %s, tuned %s, systemd %s, PID 1 on CPUs %s, default_smp_affinity %s; cmdline: %s\n' "$lane" \
    "$(val "$f" .kernel_release)" "$(val "$f" .preempt)" "$(val "$f" .tuned_profile)" "$(val "$f" .systemd_cpu_affinity)" \
    "$(val "$f" .pid1_affinity)" "$(val "$f" .default_smp_affinity)" "$(val_str "$f" cmdline)"
done
for lane in "${LANES[@]}"; do
  steal=() total=() load=()
  for a in $(alts); do
    steal+=("$(val "$(P "$lane" "$a" steal.json)" .steal_ticks)")
    total+=("$(val "$(P "$lane" "$a" steal.json)" .total_ticks)")
    load+=("$(val "$(P "$lane" "$a" lane.json)" .host_load1_at_start)")
  done
  printf '  observed: %s steal ticks per alternation: %s (of %s guest ticks); host load1 at each lane start: %s\n' "$lane" "${steal[*]}" "${total[*]}" "${load[*]}"
done

# ---- the criteria table -------------------------------------------------------------------------------------------------------
step "criteria table (lane vm; provisional bounds until the S11 calibration gate)"
{
  printf '%s\n' "id|criterion|measured|bound|margin|result"
  printf '%s\n' "${ROWS[@]}" | sort -t'|' -k1,1n -s
} | column -t -s'|'

if [[ ${SMOKE:-0} == 1 ]]; then
  ok "SMOKE: script check finished with $FAILURES criteria not met at these sizes (not enforced, not a result); output in $OUT"
  exit 0
fi
((FAILURES == 0)) || die "$FAILURES criteria not met; results in $OUT"
ok "15-cpu-partitioning: every criterion holds; results in $OUT, lane vm (never compare with a host number)"
profile=$(P isolated 1 profile.json)
jq -r '"profile (guest, isolated lane): virt=\(.virt.type) kernel=\(.kernel.release) tuned=\(.tuned)"' "$profile"
