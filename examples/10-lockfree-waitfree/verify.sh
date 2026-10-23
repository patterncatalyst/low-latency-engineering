#!/usr/bin/env bash
# Ch10 verify: lock-free and wait-free synchronisation on the in-flight parcel tracker (C++, Java, Python).
#
# Every criterion is evaluated; each prints its measured value, its bound and the margin, and any miss fails the run
# after all of them have been evaluated. Latency ratios compare variants within THIS run: the variants alternate
# (A B C A B C A B C) and the criterion is the median of the three per-alternation ratios. Counters labelled "exact"
# are deterministic and need no median. A p50 is never compared across runs.
#   1  exactly once (exact): every synchronised claim (C++ and Java: mutex, cas-loop, fetch-add; Python: lock, in the
#      GIL and the free-threaded build) hands out each sequence 0..N-1 once, by the byte map the claimers write and
#      the log's payload check. Python --racy-claim under the free-threaded build loses or duplicates at least 1.
#   2  steps and contention (exact, then calibrated): fetch-add takes exactly 1 step per claim; cas-loop fails at least
#      1 CAS; voluntary context switches per producer: mutex, the least-switching producer >= 100; fetch-add, the
#      most-switching producer <= 10 (median of 3 runs), C++ and Java
#   3  claim p99: mutex >= 3x fetch-add (median of 3 alternations), C++ and Java. p99.9 and cas-loop are observed.
#   4  --stalled-producer (1 ms sleep between claim and publish): the consumer waits >= 0.5 ms at that sequence in the
#      fetch-add log, C++ and Java
#   5  litmus (exact): C++ seq-cst and Java volatile (jcstress) never read 0, 0; C++ release-acquire and Java
#      setRelease/getAcquire read 0, 0 at least once
#   6  read side: torn snapshots 0 in every variant (exact); writer p99 seqlock <= 1/3 of shared-mutex (C++) and
#      stamped-lock <= 1/3 of rw-lock (Java), median of 3 alternations; p99.9 is observed
#   7  line, four simulator instances at 2.5 kHz x 20 s (200,000 parcels): count 200,000, dropped 0 per camera, every
#      divert command received, for C++ mutex and fetch-add, Java blocking-queue and agrona-mpsc. End-to-end
#      percentiles are observed.
#   8  every report: lowlat-report check, count, dropped = 0, build.flags (C++ and Java), runtime.placement (pinned
#      runs), runtime.python_build (Python)
# Observed, not asserted: cas-loop tails, per-store cost (Google Benchmark, JMH), reader retries, the Python claim tail
# against sys.getswitchinterval(), itertools-count and the GIL build's racy claim, line percentiles.
#
#   ./verify.sh                 build, run, assert
#   RECHECK=results/<run-id>    re-evaluate the committed reports without building or running anything
#   ALLOW_BUSY=1 ./verify.sh    measure while a lab VM or other load is running (noisy)
#   SKIP_BUILD=1 ./verify.sh    reuse existing builds
#   SKIP_JCSTRESS=1             skip the jcstress litmus run (criterion 5, Java half, is then reported as not met)
#   RESULTS_DIR=DIR             where reports go (default results/latest)
#   LOWLAT_BUILD=DIR            private C++ build directory
#
# Run it under the host benchmark lock when another example measures on this host. UDP ports 47300-47303
# (mutex, blocking-queue) and 47304-47307 (fetch-add, agrona-mpsc) on 127.0.0.1. Threads are pinned to distinct
# physical cores with sched_setaffinity as an experiment control; that is not isolation. Never changes the host: no
# sudo, no sysctl, no governor.
# The free-threaded interpreter is a user-local download: `uv python install 3.14t`.
# shellcheck disable=SC2016
set -euo pipefail
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

EXAMPLE=10-lockfree-waitfree
HERE=$(example_dir)
JAR=$HERE/java/target/benchmarks.jar
JCSTRESS_JAR=$HERE/java/target/lockfree-waitfree-java-1.0.0-SNAPSHOT-jcstress.jar
PRODUCERS=4
CLAIMS_PER_THREAD=1000000
CLAIMS=$((PRODUCERS * CLAIMS_PER_THREAD))
PY_CLAIMS_PER_THREAD=100000
PY_CLAIMS=$((PRODUCERS * PY_CLAIMS_PER_THREAD))
TRIALS=10000000
STALLED_MIN_NS=500000
CAMERAS=4
LINE_RATE=2500
LINE_SECONDS=20
LINE_PER_CAMERA=$((LINE_RATE * LINE_SECONDS))
LINE_COUNT=$((LINE_PER_CAMERA * CAMERAS))
PORT_A=47300
PORT_B=47304
HOLD_MS=500
ROUNDS=3
CLAIM_VARIANTS=(mutex cas-loop fetch-add)
CELL_VARIANTS_CPP=(shared-mutex seqlock)
CELL_VARIANTS_JAVA=(rw-lock stamped-lock)
# The JVM for every Java run: a fixed, pre-touched heap so no collection starts inside a measured run; native access
# for the affinity calls; jdk.internal.misc is exported because Agrona's queue reaches Unsafe through it.
JVM=(-Xms1g -Xmx1g -XX:+AlwaysPreTouch -XX:+UseG1GC --enable-native-access=ALL-UNNAMED
  --add-exports=java.base/jdk.internal.misc=ALL-UNNAMED)
MAIN=io.patterncatalyst.lowlat.lockfree.Main

if [[ -n ${RECHECK:-} ]]; then
  OUT=$(cd "$RECHECK" && pwd)
  export LOWLAT_PROFILE=$OUT/profile.json
  RUN=0
else
  RUN=1
  require_quiet_host
  OUT=$(results_dir)
  # Remove only what this script writes, and only under a real results path.
  [[ $OUT == /*/*/* ]] || die "refusing to clear subdirectories of $OUT"
  rm -rf "${OUT:?}"/{cpp,java,python} "${OUT:?}"/*.json "${OUT:?}"/*.log "${OUT:?}"/*.txt
  mkdir -p "$OUT/cpp" "$OUT/java" "$OUT/python"
  capture_profile "$OUT"
fi

# ---- helpers -------------------------------------------------------------------------------------------------------

# margin NUM DEN: NUM / DEN with two decimals.
margin() { awk -v a="$1" -v b="$2" 'BEGIN { if (b == 0) print "inf"; else printf "%.2f", a / b }'; }

# note_margin MARGIN: the suffix for a criterion that clears with less than 2x.
note_margin() { awk -v m="$1" 'BEGIN { if (m != "inf" && m + 0 < 2) print " [margin under 2x: value reported, bound unchanged]" }'; }

# crit_ge ID DESC VALUE BOUND: VALUE >= BOUND (integers); prints value, bound and margin.
crit_ge() {
  local m
  m=$(margin "$3" "$4")
  if (($3 >= $4)); then
    ok "$1 $2: measured $3, bound >= $4, margin ${m}x$(note_margin "$m")"
  else
    bad "$1 $2: measured $3, bound >= $4, margin ${m}x"
  fi
}
# crit_le ID DESC VALUE BOUND: VALUE <= BOUND; the margin is BOUND / VALUE.
crit_le() {
  local m
  m=$(margin "$4" "$3")
  if (($3 <= $4)); then
    ok "$1 $2: measured $3, bound <= $4, margin ${m}x$(note_margin "$m")"
  else
    bad "$1 $2: measured $3, bound <= $4, margin ${m}x"
  fi
}
# crit_exact ID DESC VALUE WANT: VALUE == WANT, labelled exact (no margin).
crit_exact() {
  if (($3 == $4)); then ok "$1 $2: measured $3, bound == $4 (exact)"; else bad "$1 $2: measured $3, bound == $4 (exact)"; fi
}
# crit_ratio ID DESC "A over B" RATIO_MILLI BOUND_MILLI: median ratio >= bound, both in thousandths.
crit_ratio() {
  local m
  m=$(margin "$4" "$5")
  if (($4 >= $5)); then
    ok "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x$(note_margin "$m")"
  else
    bad "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x"
  fi
}

p99() { jget "$1" .percentiles.p99; }
p999() { jget "$1" .percentiles.p99_9; }
counter() { jget "$1" ".runtime.counters.$2"; }

# alt_ratio FILE_NUM FILE_DEN: the ratio of two p99 values in thousandths (the asserted tail).
alt_ratio() { echo $((1000 * $(p99 "$1") / $(p99 "$2"))); }
# alt_ratio999 FILE_NUM FILE_DEN: the same at p99.9 (observed: it sits at the host's interrupt floor, a few microseconds).
alt_ratio999() { echo $((1000 * $(p999 "$1") / $(p999 "$2"))); }

# median_of VALUE...: the middle value of the sorted integers.
median_of() { median_ns "$@"; }

# check_pins LOG COUNT: every "pinned pid=P tid=T cpu=C" line of LOG is checked against /proc/P/task/T/stat.
check_pins() {
  local log=$1 want=$2 line n=0
  while read -r line; do
    [[ $line =~ pid=([0-9]+)\ tid=([0-9]+)\ cpu=([0-9]+) ]] || die "unparseable pinned line: $line"
    assert_placement "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >/dev/null
    n=$((n + 1))
  done < <(grep '^pinned ' "$log")
  ((n == want)) || die "expected $want pinned threads in $log, found $n"
  ok "placement: $n threads of $(basename "$log" .log) run on the CPUs they were pinned to"
}

# run_pinned LOG COUNT CMD...: run CMD, which pins its threads, prints "pinned ..." and "placement-ready", holds, and
# goes; the pins are verified from /proc during the hold.
run_pinned() {
  local log=$1 count=$2 pid
  shift 2
  "$@" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_log_line '^placement-ready$' "$log" "$pid" >/dev/null
  check_pins "$log" "$count"
  wait "$pid" || { tail -30 "$log" >&2; die "failed: $*"; }
  bg_forget "$pid"
}

# each_alt VARIANTS...: for ROUNDS alternations of the variants, call `alt_run VARIANT N` in interleaved order.
each_alt() {
  local -A seen=()
  local v
  while read -r v; do
    seen[$v]=$((${seen[$v]:-0} + 1))
    alt_run "$v" "${seen[$v]}"
  done < <(interleave "$ROUNDS" "$@")
}

# ---- build and unit tests ------------------------------------------------------------------------------------------
if ((RUN)); then
  # Six distinct physical cores, the first dropped: CPU 0 takes most interrupts, so the five pinned threads start at the
  # second core (example 09 does the same).
  cores=$(distinct_cores 6) || die "need 6 distinct physical cores (5 to pin, the first left alone)"
  mapfile -t CORES <<<"$cores"
  CORES=("${CORES[@]:1}")
  cores=$(printf '%s\n' "${CORES[@]}")
  CPUS=$(paste -sd, <<<"$cores")
  uv python find 3.14t >/dev/null 2>&1 || die "no free-threaded Python: uv python install 3.14t (a user-local download)"
  build_cpp lockfree-bench lockfree-line lockfree-store-bench lockfree-test line-simulator
  BUILD_JAVA_TESTS=1 build_java "$HERE/java" # the Java tests run on the way; jcstress and benchmarks jars are packaged
  py_sync
  [[ -f $JAR && -f $JCSTRESS_JAR ]] || die "missing $JAR or $JCSTRESS_JAR (build_java first)"

  step "unit tests: C++ (GoogleTest), Python under the GIL and under the free-threaded build; Java ran during the package step"
  "$(cpp_bin lockfree-test)" --gtest_brief=1 >"$OUT/cpp-unit-tests.log" 2>&1 || { tail -20 "$OUT/cpp-unit-tests.log" >&2; die "C++ unit tests failed"; }
  uvrun pytest -q "$HERE/sync-py/tests" >"$OUT/python-unit-tests-gil.log" 2>&1 || { tail -20 "$OUT/python-unit-tests-gil.log" >&2; die "Python (GIL) tests failed"; }
  (cd "$LOWLAT_EXAMPLES" && LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$LOWLAT_EXAMPLES/.venv-ft \
    uv run -q --python 3.14t --all-packages pytest -q "$HERE/sync-py/tests") >"$OUT/python-unit-tests-free-threaded.log" 2>&1 ||
    { tail -20 "$OUT/python-unit-tests-free-threaded.log" >&2; die "Python (free-threaded) tests failed"; }
  ok "C++, Java and Python (both builds) unit tests pass"
  BENCH=$(cpp_bin lockfree-bench)
  LINE_CPP=$(cpp_bin lockfree-line)
fi

# ---- 1-4: claims, C++ then Java --------------------------------------------------------------------------------------
cpp_claim() { run_pinned "${2%.json}.log" 5 "$BENCH" claim --variant "$1" --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$2" "${@:3}"; }
java_claim() { run_pinned "${2%.json}.log" 5 java "${JVM[@]}" -cp "$JAR" "$MAIN" claim --variant "$1" --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$2" "${@:3}"; }

if ((RUN)); then
  alt_run() { step "C++ claim: $1 (alternation $2)"; cpp_claim "$1" "$OUT/cpp-$1-alt$2.json"; }
  each_alt "${CLAIM_VARIANTS[@]}"
  step "C++ claim: fetch-add with --stalled-producer"
  cpp_claim fetch-add "$OUT/cpp-fetch-add-stalled.json" --stalled-producer

  alt_run() { step "Java claim: $1 (alternation $2)"; java_claim "$1" "$OUT/java-$1-alt$2.json"; }
  each_alt "${CLAIM_VARIANTS[@]}"
  step "Java claim: fetch-add with --stalled-producer"
  java_claim fetch-add "$OUT/java-fetch-add-stalled.json" --stalled-producer
fi

# ---- 6: the read side -------------------------------------------------------------------------------------------------
if ((RUN)); then
  alt_run() { step "C++ read side: $1 (alternation $2)"; run_pinned "$OUT/cpp-cell-$1-alt$2.log" 4 "$BENCH" seqlock --variant "$1" --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$OUT/cpp-cell-$1-alt$2.json"; }
  each_alt "${CELL_VARIANTS_CPP[@]}"
  alt_run() { step "Java read side: $1 (alternation $2)"; run_pinned "$OUT/java-cell-$1-alt$2.log" 4 java "${JVM[@]}" -cp "$JAR" "$MAIN" seqlock --variant "$1" --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$OUT/java-cell-$1-alt$2.json"; }
  each_alt "${CELL_VARIANTS_JAVA[@]}"
fi

# ---- 5: litmus --------------------------------------------------------------------------------------------------------
if ((RUN)); then
  for v in release-acquire seq-cst; do
    step "C++ litmus: $v, $TRIALS trials"
    run_pinned "$OUT/cpp-litmus-$v.log" 2 "$BENCH" litmus --variant "$v" --trials "$TRIALS" --cpus "$CPUS" --hold-ms "$HOLD_MS" \
      --report "$OUT/cpp-litmus-$v.json"
  done
  if [[ ${SKIP_JCSTRESS:-0} != 1 ]]; then
    step "Java litmus: jcstress quick mode, StoreBufferVolatile and StoreBufferAcquireRelease (about 20 s, all CPUs)"
    scratch_dir
    mkdir -p "$LOWLAT_SCRATCH/jcstress"
    # jcstress writes its result files into the working directory; run it in the scratch dir. Never `-h`: the help
    # formatter fails on the managed jopt-simple version (see README); running tests is unaffected.
    (cd "$LOWLAT_SCRATCH/jcstress" && java -jar "$JCSTRESS_JAR" -jvmArgsPrepend --enable-native-access=ALL-UNNAMED -m quick -v \
      -t 'io.patterncatalyst.lowlat.lockfree.StoreBuffer.*' -r "$LOWLAT_SCRATCH/jcstress/html") >"$LOWLAT_SCRATCH/jcstress/run.log" 2>&1 ||
      { tail -30 "$LOWLAT_SCRATCH/jcstress/run.log" >&2; die "jcstress failed"; }
    # The summary: the "RUN RESULTS" section only (outcome counts per test), scrubbed; the HTML and the .bin.gz stay out.
    sed -n '/^RUN RESULTS/,$p' "$LOWLAT_SCRATCH/jcstress/run.log" | grep -v 'HTML report generated' |
      python3 "$LOWLAT_ROOT/scripts/scrub-host-ids.py" --filter >"$OUT/java-jcstress-summary.txt"
  fi
fi

# jcstress_samples TEST OUTCOME: the sample count of "OUTCOME" (e.g. "0, 0") in the results block of TEST.
jcstress_samples() {
  awk -v test="$1" -v outcome="$2" '
    /^\.+ \[/ { in_test = index($0, test) > 0 }
    in_test && index($0, outcome) > 0 && $0 ~ /^ +[0-9], [0-9] / {
      line = $0; sub(/^ +[0-9], [0-9] +/, "", line); split(line, f, " "); gsub(",", "", f[1]); print f[1]; found = 1; exit }
    END { if (!found) exit 1 }' "$OUT/java-jcstress-summary.txt"
}

# ---- Python (both builds) ----------------------------------------------------------------------------------------
# py_run BUILD VARIANT [--racy-claim]: measure in the named build (no lowlat_measure in the measuring process), then
# convert the raw samples to a report in the GIL workspace environment.
py_measure() {
  local build=$1 variant=$2 raw=$3 log=$4
  shift 4
  local cmd=(sync-py measure --variant "$variant" --threads "$PRODUCERS" --claims-per-thread "$PY_CLAIMS_PER_THREAD"
    --cpus "$CPUS" --hold-ms "$HOLD_MS" --out "$raw" "$@")
  if [[ $build == free-threaded ]]; then
    run_pinned "$log" "$PRODUCERS" env UV_PROJECT_ENVIRONMENT="$LOWLAT_EXAMPLES/.venv-ft" \
      uv --directory "$LOWLAT_EXAMPLES" run -q --python 3.14t --package lowlat-sync "${cmd[@]}"
  else
    run_pinned "$log" "$PRODUCERS" uvrun "${cmd[@]}"
  fi
}
if ((RUN)); then
  scratch_dir
  for build in gil free-threaded; do
    for spec in "lock" "itertools-count" "lock --racy-claim"; do
      read -ra words <<<"$spec"
      variant=${words[0]}
      suffix=''
      [[ ${words[1]:-} == --racy-claim ]] && suffix=-racy-claim
      step "Python claim: $variant${suffix:+ (racy)} in the $build build"
      raw=$LOWLAT_SCRATCH/py-$build-$variant$suffix
      py_measure "$build" "$variant" "$raw" "$OUT/python/python-$build-$variant$suffix.log" "${words[@]:1}"
      if [[ $build == free-threaded ]]; then
        [[ $(jget "$raw/raw.json" .gil_at_end) == false && $(jget "$raw/raw.json" .gil_at_start) == false ]] ||
          die "the free-threaded measurement ran with the GIL on ($raw/raw.json)"
      fi
      uvrun sync-py report "$raw" --out "$OUT/python/python-$build-$variant$suffix.json" >/dev/null
    done
  done
fi

# ---- observed per-store cost ------------------------------------------------------------------------------------------
if ((RUN)); then
  step "per-store cost (observed): Google Benchmark on one CPU, then JMH"
  taskset -c "${CORES[0]}" "$(cpp_bin lockfree-store-bench)" --benchmark_out="$OUT/cpp/gbench.json" --benchmark_out_format=json \
    >"$OUT/cpp/gbench.console.txt" 2>&1 || die "lockfree-store-bench failed"
  redact_host "$OUT/cpp/gbench.json"
  uvrun lowlat-report from-gbench "$OUT/cpp/gbench.json" "$OUT/cpp" --example "$EXAMPLE" >/dev/null
  jmh_lock_wait 30 "$OUT/java/jmh.console.txt" taskset -c "${CORES[0]}" java "${JVM[@]}" -jar "$JAR" StoreBenchmark \
    -f 2 -wi 3 -w 1s -i 5 -r 1s -rf json -rff "$OUT/java/jmh.json" || die "JMH failed"
  uvrun lowlat-report from-jmh "$OUT/java/jmh.json" "$OUT/java" --example "$EXAMPLE" >/dev/null
fi

# ---- 7: the line ---------------------------------------------------------------------------------------------------------
# run_line LANG VARIANT BASE_PORT: four simulator instances to BASE_PORT..BASE_PORT+3, one camera thread each.
run_line() {
  local lang=$1 variant=$2 port=$3 log=$OUT/$1-line-$2.log report=$OUT/$1-line-$2.json pid i
  local -a cmd sims=()
  step "line: $lang / $variant, $CAMERAS simulator instances at $LINE_RATE Hz x $LINE_SECONDS s, UDP $port-$((port + CAMERAS - 1))"
  case $lang in
    cpp) cmd=("$LINE_CPP" --variant "$variant") ;;
    java) cmd=(java "${JVM[@]}" -cp "$JAR" "$MAIN" line --variant "$variant") ;;
  esac
  cmd+=(--base-port "$port" --expect "$LINE_PER_CAMERA" --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$report")
  "${cmd[@]}" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_log_line '^placement-ready$' "$log" "$pid" >/dev/null
  check_pins "$log" 5
  # The receivers bind before the gate's hold ends, so a bound port does not mean the run has started. "released" is
  # printed when the hold is over and the threads go; the simulators start then, and no parcel waits in a socket buffer.
  wait_log_line '^released$' "$log" "$pid" >/dev/null
  for ((i = 0; i < CAMERAS; i++)); do
    wait_udp_bound $((port + i)) "$pid" "$log"
  done
  for ((i = 0; i < CAMERAS; i++)); do
    simulate --rate "$LINE_RATE" --duration "$LINE_SECONDS" --dest "127.0.0.1:$((port + i))" --quiet >>"$log" 2>&1 &
    sims+=($!)
    bg_track "$!"
  done
  for i in "${sims[@]}"; do
    wait "$i" || { tail -20 "$log" >&2; die "a simulator instance failed"; }
    bg_forget "$i"
  done
  wait "$pid" || { tail -30 "$log" >&2; die "$lang/$variant line run failed"; }
  bg_forget "$pid"
}
if ((RUN)); then
  run_line cpp mutex "$PORT_A"
  run_line java blocking-queue "$PORT_A"
  run_line cpp fetch-add "$PORT_B"
  run_line java agrona-mpsc "$PORT_B"
fi

# ---- evaluate ---------------------------------------------------------------------------------------------------------------
step "reports: schema, histogram decode, percentile recompute"
mapfile -t all_reports < <(find "$OUT" -name '*.json' ! -name profile.json ! -name 'jmh.json' ! -name gbench.json -exec grep -lE '"schema" ?: ?"lowlat-report/1"' {} + | sort)
if report_check "${all_reports[@]}" >/dev/null 2>"$OUT/report-check.err"; then
  ok "8 ${#all_reports[@]} reports validate (profile embedded: $(jget "${all_reports[0]}" .profile.host_label))"
else
  cat "$OUT/report-check.err" >&2
  report_check "${all_reports[@]}" >&2 || true
  bad "8 lowlat-report check failed"
fi
rm -f "$OUT/report-check.err"

step "criterion 1: exactly once (exact)"
for lang in cpp java; do
  for f in "$OUT/$lang"-{mutex,cas-loop,fetch-add}-alt{1,2,3}.json "$OUT/$lang-fetch-add-stalled.json"; do
    name=$(basename "$f" .json)
    claims=$(counter "$f" claims)
    lost=$(counter "$f" lost_or_duplicated_claims)
    mism=$(counter "$f" payload_mismatches)
    if ((claims == CLAIMS && lost == 0 && mism == 0)); then :; else bad "1 $name: claims $claims of $CLAIMS, lost or duplicated $lost, payload mismatches $mism"; fi
  done
  ok "1 $lang: all $((ROUNDS * 3 + 1)) claim runs handed out $CLAIMS sequences exactly once (byte map after join, payload checked by the consumer)"
done
for build in gil free-threaded; do
  f=$OUT/python/python-$build-lock.json
  crit_exact "1" "Python lock, $build build: lost or duplicated claims" "$(counter "$f" lost_or_duplicated_claims)" 0
  crit_exact "1" "Python lock, $build build: claims made" "$(counter "$f" claims)" "$PY_CLAIMS"
done
gil_off=1
for r in "$OUT"/python/python-free-threaded-*.json; do
  if [[ $(note_of "$r" gil_at_start) != false || $(note_of "$r" gil_at_end) != false ]]; then
    bad "1 $(basename "$r"): the free-threaded measurement ran with the GIL on (gil_at_start $(note_of "$r" gil_at_start), gil_at_end $(note_of "$r" gil_at_end))"
    gil_off=0
  fi
done
((gil_off)) && ok "1 Python free-threaded build: the GIL stayed off from start to end in every measurement"
# The racy report keeps the variant name `lock` (a §2 name); its racy_claim counter marks it, and only it.
for r in "$OUT"/python/python-*.json; do
  want=0
  [[ $r == *-racy-claim.json ]] && want=1
  [[ $(counter "$r" racy_claim) == "$want" ]] || bad "1 $(basename "$r"): counter racy_claim is $(counter "$r" racy_claim), want $want"
done
racy_ft=$(counter "$OUT/python/python-free-threaded-lock-racy-claim.json" lost_or_duplicated_claims)
crit_ge "1" "Python --racy-claim, free-threaded build: lost or duplicated claims (exact, demonstrates the race)" "$racy_ft" 1
printf '  observed: Python lost or duplicated claims, GIL build: lock %s, itertools-count %s, racy %s; free-threaded build: itertools-count %s, racy %s (of %s)\n' \
  "$(counter "$OUT/python/python-gil-lock.json" lost_or_duplicated_claims)" \
  "$(counter "$OUT/python/python-gil-itertools-count.json" lost_or_duplicated_claims)" \
  "$(counter "$OUT/python/python-gil-lock-racy-claim.json" lost_or_duplicated_claims)" \
  "$(counter "$OUT/python/python-free-threaded-itertools-count.json" lost_or_duplicated_claims)" "$racy_ft" "$PY_CLAIMS"

step "criterion 2: steps per claim and contention"
for lang in cpp java; do
  vol_mutex=() vol_fetch=() casfail=()
  for n in 1 2 3; do
    f=$OUT/$lang-fetch-add-alt$n.json
    crit_exact "2" "$lang fetch-add alt$n: claim steps ($(counter "$f" claim_steps)) per $CLAIMS claims" "$(counter "$f" claim_steps)" "$CLAIMS"
    vol_mutex+=("$(counter "$OUT/$lang-mutex-alt$n.json" producer_voluntary_ctx_min)")
    vol_fetch+=("$(counter "$f" producer_voluntary_ctx_max)")
    casfail+=("$(counter "$OUT/$lang-cas-loop-alt$n.json" cas_failures)")
  done
  crit_ge "2" "$lang cas-loop: failed CAS in the least contended of 3 runs (exact count; contention present); largest retry count in one claim, run 1: $(counter "$OUT/$lang-cas-loop-alt1.json" cas_max_retries)" "$(printf '%s\n' "${casfail[@]}" | sort -n | head -1)" 1
  crit_ge "2" "$lang mutex: voluntary context switches of the least-switching producer (median of 3 runs: ${vol_mutex[*]})" "$(median_of "${vol_mutex[@]}")" 100
  crit_le "2" "$lang fetch-add: voluntary context switches of the most-switching producer (median of 3 runs: ${vol_fetch[*]})" "$(median_of "${vol_fetch[@]}")" 10
done

step "criterion 3: claim p99, mutex against fetch-add, same run, median of 3 alternations"
for lang in cpp java; do
  ratios=() cas=() tail=()
  for n in 1 2 3; do
    ratios+=("$(alt_ratio "$OUT/$lang-mutex-alt$n.json" "$OUT/$lang-fetch-add-alt$n.json")")
    cas+=("$(alt_ratio "$OUT/$lang-cas-loop-alt$n.json" "$OUT/$lang-fetch-add-alt$n.json")")
    tail+=("$(alt_ratio999 "$OUT/$lang-mutex-alt$n.json" "$OUT/$lang-fetch-add-alt$n.json")")
  done
  crit_ratio "3" "$lang claim p99" "mutex over fetch-add, per alternation: ${ratios[*]} thousandths" "$(median_of "${ratios[@]}")" 3000
  printf '  observed: %s mutex over fetch-add p99.9 per alternation: %s thousandths (median %s)\n' "$lang" "${tail[*]}" "$(median_of "${tail[@]}")"
  printf '  observed: %s cas-loop over fetch-add p99 per alternation: %s thousandths (lock-free is not faster; wait-free bounds steps, not time)\n' "$lang" "${cas[*]}"
  for v in "${CLAIM_VARIANTS[@]}"; do
    printf '  %s %s claim p50 / p99 / p99.9 / max in ns, alternation 1: %s\n' "$lang" "$v" \
      "$(jget "$OUT/$lang-$v-alt1.json" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9) / \(.percentiles.max)"')"
  done
done

step "criterion 4: --stalled-producer, the consumer's wait at the stalled sequence"
for lang in cpp java; do
  f=$OUT/$lang-fetch-add-stalled.json
  crit_ge "4" "$lang fetch-add: consumer wait at the stalled sequence, ns (the producer slept 1 ms between claim and publish)" \
    "$(counter "$f" consumer_wait_at_stalled_seq_ns)" "$STALLED_MIN_NS"
  printf '  %s without the stall (alternation 1): largest consumer wait %s ns\n' "$lang" "$(counter "$OUT/$lang-fetch-add-alt1.json" consumer_max_wait_ns)"
done

step "criterion 5: induction-gap litmus test"
crit_exact "5" "C++ seq-cst, outcome 0, 0 in $TRIALS trials" "$(counter "$OUT/cpp-litmus-seq-cst.json" outcome_r1_0_r2_0)" 0
crit_ge "5" "C++ release-acquire, outcome 0, 0 in $TRIALS trials (exact count)" "$(counter "$OUT/cpp-litmus-release-acquire.json" outcome_r1_0_r2_0)" 1
printf '  C++ release-acquire outcomes (r1,r2): 0,0 = %s; 0,1 = %s; 1,0 = %s; 1,1 = %s; seq-cst: 0,1 = %s; 1,0 = %s; 1,1 = %s\n' \
  "$(counter "$OUT/cpp-litmus-release-acquire.json" outcome_r1_0_r2_0)" "$(counter "$OUT/cpp-litmus-release-acquire.json" outcome_r1_0_r2_1)" \
  "$(counter "$OUT/cpp-litmus-release-acquire.json" outcome_r1_1_r2_0)" "$(counter "$OUT/cpp-litmus-release-acquire.json" outcome_r1_1_r2_1)" \
  "$(counter "$OUT/cpp-litmus-seq-cst.json" outcome_r1_0_r2_1)" "$(counter "$OUT/cpp-litmus-seq-cst.json" outcome_r1_1_r2_0)" \
  "$(counter "$OUT/cpp-litmus-seq-cst.json" outcome_r1_1_r2_1)"
if [[ -f $OUT/java-jcstress-summary.txt ]]; then
  crit_exact "5" "Java volatile (jcstress), outcome 0, 0" "$(jcstress_samples StoreBufferVolatile '0, 0')" 0
  crit_ge "5" "Java setRelease/getAcquire (jcstress), outcome 0, 0 (exact count)" "$(jcstress_samples StoreBufferAcquireRelease '0, 0')" 1
  printf '  Java volatile samples with all outcomes seen: 0,1 = %s; 1,0 = %s; 1,1 = %s\n' \
    "$(jcstress_samples StoreBufferVolatile '0, 1')" "$(jcstress_samples StoreBufferVolatile '1, 0')" "$(jcstress_samples StoreBufferVolatile '1, 1')"
else
  bad "5 Java litmus not evaluated (SKIP_JCSTRESS or no summary)"
fi
printf '  per-store cost, p50 per store in ns (observed): C++ release %s, seq_cst %s; Java release %s, volatile %s\n' \
  "$(jget "$OUT/cpp/cpp-release-acquire.json" .percentiles.p50)" "$(jget "$OUT/cpp/cpp-seq-cst.json" .percentiles.p50)" \
  "$(jget "$OUT/java/java-release-acquire.json" .percentiles.p50)" "$(jget "$OUT/java/java-seq-cst.json" .percentiles.p50)"

step "criterion 6: the read side"
for lang in cpp java; do
  if [[ $lang == cpp ]]; then slow=shared-mutex fast=seqlock; else slow=rw-lock fast=stamped-lock; fi
  ratios=() tail=() torn=0
  for n in 1 2 3; do
    for v in $slow $fast; do torn=$((torn + $(counter "$OUT/$lang-cell-$v-alt$n.json" torn_snapshots))); done
    ratios+=("$(alt_ratio "$OUT/$lang-cell-$slow-alt$n.json" "$OUT/$lang-cell-$fast-alt$n.json")")
    tail+=("$(alt_ratio999 "$OUT/$lang-cell-$slow-alt$n.json" "$OUT/$lang-cell-$fast-alt$n.json")")
  done
  crit_exact "6" "$lang torn snapshots, $slow and $fast, 3 alternations each" "$torn" 0
  crit_ratio "6" "$lang writer p99" "$slow over $fast, per alternation: ${ratios[*]} thousandths" "$(median_of "${ratios[@]}")" 3000
  printf '  observed: %s writer %s over %s p99.9 per alternation: %s thousandths (median %s)\n' "$lang" "$slow" "$fast" "${tail[*]}" "$(median_of "${tail[@]}")"
  printf '  %s writer update p50 / p99 / p99.9 in ns, alternation 1: %s %s; %s %s\n' "$lang" \
    "$slow" "$(jget "$OUT/$lang-cell-$slow-alt1.json" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9)"')" \
    "$fast" "$(jget "$OUT/$lang-cell-$fast-alt1.json" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9)"')"
  printf '  %s %s: updates %s, reads %s, reader retries %s (observed)\n' "$lang" "$fast" \
    "$(counter "$OUT/$lang-cell-$fast-alt1.json" updates)" "$(counter "$OUT/$lang-cell-$fast-alt1.json" reads)" \
    "$(counter "$OUT/$lang-cell-$fast-alt1.json" reader_retries)"
done

step "criterion 7: the line"
for run in cpp-line-mutex java-line-blocking-queue cpp-line-fetch-add java-line-agrona-mpsc; do
  r=$OUT/$run.json
  count=$(jget "$r" .count)
  dropped=$(jget "$r" .dropped)
  diverts=$(counter "$r" divert_received)
  cam_ok=1
  for ((i = 0; i < CAMERAS; i++)); do
    c=$OUT/$run-camera$i.json
    [[ $(jget "$c" .count) -eq $LINE_PER_CAMERA && $(jget "$c" .dropped) -eq 0 ]] || { bad "7 $run camera $i: count $(jget "$c" .count) of $LINE_PER_CAMERA, dropped $(jget "$c" .dropped)"; cam_ok=0; }
  done
  if ((count == LINE_COUNT && dropped == 0 && diverts == LINE_COUNT && cam_ok)); then
    ok "7 $run: count $count (bound == $LINE_COUNT), dropped $dropped per camera (exact 0), divert commands received $diverts (exact $LINE_COUNT)"
  else
    bad "7 $run: count $count of $LINE_COUNT, dropped $dropped, divert commands received $diverts"
  fi
  printf '  %s end-to-end p50 / p99 / p99.9 / max in ns (observed): %s; divert command p99 %s ns\n' "$run" \
    "$(jget "$r" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9) / \(.percentiles.max)"')" \
    "$(jget "$OUT/$run-divert.json" .percentiles.p99)"
done

step "observed: Python claim tail against the interpreter's switch interval"
for build in gil free-threaded; do
  for spec in lock itertools-count lock-racy-claim; do
    r=$OUT/python/python-$build-$spec.json
    printf '  %s %s: p50 / p99 / p99.9 / max in ns = %s; voluntary ctx switches %s; %s\n' "$build" "$spec" \
      "$(jget "$r" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9) / \(.percentiles.max)"')" \
      "$(jget "$r" .runtime.ctx_switches.voluntary)" "$(note_of "$r" switch_interval_ms | sed 's/^/switch interval /; s/$/ ms/')"
  done
done

step "criterion 8: every report carries count, dropped = 0, build.flags, placement"
flags_ok=1 place_ok=1
for r in "${all_reports[@]}"; do
  name=${r#"$OUT"/}
  [[ $(jget "$r" .count) -gt 0 ]] || { bad "8 $name: count is 0"; flags_ok=0; }
  [[ $(jget "$r" .dropped) -eq 0 ]] || { bad "8 $name: dropped parcels"; flags_ok=0; }
  case $name in
    python/*)
      jq -e '.runtime.python_build | . == "gil" or . == "free-threaded"' "$r" >/dev/null || { bad "8 $name: runtime.python_build missing"; flags_ok=0; }
      jq -e '.runtime.placement.cpus | length > 0' "$r" >/dev/null || { bad "8 $name: runtime.placement missing"; place_ok=0; }
      ;;
    cpp/* | java/*) # Google Benchmark and JMH conversions: one pinned CPU, no thread placement of their own
      jq -e '.build.flags | length > 0' "$r" >/dev/null || { bad "8 $name: build.flags missing"; flags_ok=0; }
      ;;
    *)
      jq -e '.build.flags | length > 0' "$r" >/dev/null || { bad "8 $name: build.flags missing"; flags_ok=0; }
      jq -e '.runtime.placement.cpus | length > 0' "$r" >/dev/null || { bad "8 $name: runtime.placement missing"; place_ok=0; }
      ;;
  esac
done
((flags_ok)) && ok "8 ${#all_reports[@]} reports: count > 0, dropped = 0, build.flags (C++ and Java) and runtime.python_build (Python) present"
((place_ok)) && ok "8 every pinned run records runtime.placement (distinct_cores $(jget "$OUT/cpp-mutex-alt1.json" .runtime.placement.distinct_cores), smt_siblings $(jget "$OUT/cpp-mutex-alt1.json" .runtime.placement.smt_siblings))"

((FAILURES == 0)) || die "$FAILURES criteria not met; results in $OUT"
ok "10-lockfree-waitfree: every criterion holds; results in $OUT"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
