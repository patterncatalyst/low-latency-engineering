#!/usr/bin/env bash
# Ch5 verify: what the JVM costs per parcel, and how to stop paying it on the first one.
#   1. JMH -prof gc: `escaping` >= 24 B/op, `scalar-replaced` <= 1 B/op, `--no-escape-analysis` >= 24 B/op.
#   2. `--unwarmed`: first-window p99 >= 5x the steady p99 (same run).
#   3. `warmed`: first-window p99 <= 3x the steady p99 (same run).
#   4. `aot-cache`: median time to ready <= 0.8x the no-cache median (5 alternating launches); the AOT log
#      shows the cache opened.
#   5. every Java report's build.flags carries the JVM arguments it ran with.
#   6. every line run: count = 20,000, dropped = 0, lowlat-report check passes.
# Observed, not asserted: compilations and deoptimizations per window, allocated bytes per parcel, the C++
# first/steady split, the C++ allocating/value/pmr counters, the AOT first-window p99.
# Every criterion is evaluated and printed; the exit status is non-zero if any missed.
# Line runs: 1 kHz x 20 s on UDP port 47250 (47251 for the AOT training run, 47252 for time to ready).
#   RECHECK=results/<run-id>  re-evaluates the committed reports without running anything.
#   ALLOW_BUSY=1              measure while a lab VM runs or the host is loaded (numbers are noisy)
#   SKIP_BUILD=1              reuse existing builds
set -euo pipefail
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

DIR=$(example_dir)
PORT=47250
TRAIN_PORT=47251
READY_PORT=47252
RATE=1000
DURATION=20
COUNT=$((RATE * DURATION))
WINDOW=${WINDOW:-2000} # parcels in the first window (README: why the window size matters to criterion 2)
WARM_UP=20000
TRAIN_SECONDS=3
LAUNCHES=5
JAR=$DIR/java/target/benchmarks.jar
MAIN=io.patterncatalyst.lowlat.jvmcosts.Costs
JIT_TOOL=io.patterncatalyst.lowlat.jvmcosts.JitWindows
# One collector and one heap for every Java run: the variants differ in warm-up and AOT only.
JVM_ARGS=(-XX:+UseG1GC -Xms256m -Xmx256m)
JAVA_VARIANTS=(unwarmed warmed aot-cache)

FAILED=0
bad() { printf '%s✗ %s%s\n' "$_c_bad" "$*" "$_c_off"; FAILED=1; }

# verdict DESCRIPTION OP VALUE BOUND: OP is >= or <=; prints one ✓/✗ line with the measured value.
verdict() {
  local desc=$1 op=$2 value=$3 bound=$4 shown
  shown=$(awk -v v="$value" 'BEGIN { printf "%.4g", v }')
  if awk -v v="$value" -v b="$bound" -v op="$op" 'BEGIN { exit !(op == ">=" ? v >= b : v <= b) }'; then
    ok "$desc (measured $shown, bound $op $bound)"
  else
    bad "$desc (measured $shown, bound $op $bound)"
  fi
}

# ratio A B: A / B to one decimal.
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", a / b }'; }

if [[ -n ${RECHECK:-} ]]; then
  OUT=$(cd "$RECHECK" && pwd)
  export LOWLAT_PROFILE=$OUT/profile.json
else
  require_quiet_host
  OUT=$(results_dir)
  capture_profile "$OUT"

  build_cpp jvmcosts-consumer jvmcosts-bench jvm-costs-test line-simulator
  BUILD_JAVA_TESTS=1 build_java "$DIR/java" # benchmarks.jar; the unit tests run on the way
  py_sync
  [[ -f $JAR ]] || die "missing $JAR"
  step "unit tests: tracker rules"
  "$(cpp_bin jvm-costs-test)" --gtest_brief=1
  ok "C++ (GoogleTest) and Java (JUnit, ran during package) tracker tests pass"
fi

# ---- run helpers -------------------------------------------------------------------------------

# window_time KEY LOG: the ISO instant printed as `window-times: first=… boundary=… end=…`.
window_time() { sed -nE "s/^window-times:.* $1=([^ ]+).*/\1/p" "$2"; }

# observed_flags VARIANT: java_flags (JFR, async GC and safepoint log) with the JIT events switched on in
# the one recording: every compilation (threshold 0, the default is 100 ms) and every deoptimization.
# Sets OBSERVED_FLAGS and JFR_FILE.
observed_flags() {
  local flag
  java_flags "$1"
  OBSERVED_FLAGS=()
  for flag in "${JAVA_RUN_FLAGS[@]}"; do
    if [[ $flag == -XX:StartFlightRecording:* ]]; then
      flag+=',jdk.Compilation#threshold=0ms,jdk.Deoptimization#enabled=true'
    fi
    OBSERVED_FLAGS+=("$flag")
  done
}

# run_java VARIANT [JVM_FLAG...] -- [PROGRAM_ARG...]: one 1 kHz x 20 s run of the Java consumer with the
# observation flags and the shared JVM arguments. Reports land in $OUT/java-VARIANT{,-first-N,-steady}.json.
run_java() {
  local variant=$1 jvm=() program=() report log pid
  shift
  while [[ $1 != -- ]]; do jvm+=("$1"); shift; done
  shift
  program=("$@")
  report=$OUT/java-$variant.json
  log=$OUT/java-$variant.log
  observed_flags "$variant"
  step "java / $variant"
  printf 'java:'
  printf ' %q' java "${OBSERVED_FLAGS[@]}" "${JVM_ARGS[@]}" "${jvm[@]}" -cp "$JAR" "$MAIN" \
    --variant "$variant" --bind "127.0.0.1:$PORT" --expect "$COUNT" --window "$WINDOW" --report "$report" "${program[@]}"
  printf '\n'
  java "${OBSERVED_FLAGS[@]}" "${JVM_ARGS[@]}" "${jvm[@]}" -cp "$JAR" "$MAIN" \
    --variant "$variant" --bind "127.0.0.1:$PORT" --expect "$COUNT" --window "$WINDOW" --report "$report" \
    "${program[@]}" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_udp_bound "$PORT" "$pid" "$log" 900 # a warm-up replay runs before the bind
  simulate --rate "$RATE" --duration "$DURATION" --dest "127.0.0.1:$PORT" --quiet >>"$log"
  wait "$pid" || { cat "$log" >&2; die "java/$variant consumer failed"; }
  bg_forget "$pid"
  java -cp "$JAR" "$JIT_TOOL" --jfr "$JFR_FILE" --window "$WINDOW" \
    --first "$(window_time first "$log")" --boundary "$(window_time boundary "$log")" --end "$(window_time end "$log")" \
    "$report" "$OUT/java-$variant-first-$WINDOW.json" "$OUT/java-$variant-steady.json" | tee -a "$log"
}

# train_aot CACHE NAME [JVM_FLAG...]: a $TRAIN_SECONDS s training run at $RATE Hz; the JVM writes CACHE when it exits.
# The cache records the JVM arguments that change the module graph (JFR adds jdk.jfr), so a cache is
# trained with exactly the observation flags of the run that will use it.
train_aot() {
  local cache=$1 name=$2 log pid
  shift 2
  log=$OUT/aot-training-$name.log
  rm -f "$cache"
  java "$@" "${JVM_ARGS[@]}" "-XX:AOTCacheOutput=$cache" -cp "$JAR" "$MAIN" --variant "training-$name" \
    --bind "127.0.0.1:$TRAIN_PORT" --expect $((RATE * TRAIN_SECONDS)) --idle-timeout-ms 1000 >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_udp_bound "$TRAIN_PORT" "$pid" "$log"
  simulate --rate "$RATE" --duration "$TRAIN_SECONDS" --dest "127.0.0.1:$TRAIN_PORT" --quiet >>"$log"
  wait "$pid" || { cat "$log" >&2; die "AOT training run ($name) failed"; }
  bg_forget "$pid"
  [[ -s $cache ]] || { cat "$log" >&2; die "training run ($name) wrote no AOT cache"; }
  ok "AOT cache ($name) written: $(stat -c %s "$cache") bytes"
}

# median_ns VALUE...: the middle of an odd number of values.
median_ns() { printf '%s\n' "$@" | sort -n | sed -n "$((($# + 1) / 2))p"; }

if [[ -z ${RECHECK:-} ]]; then
  # ---- 1. JMH: bytes per decision ------------------------------------------------------------
  step "JMH -prof gc: heap bytes per decision (2 forks x (3 warm-up + 5 measured) iterations each)"
  jmh_jvm=()
  if [[ ${ALLOW_BUSY:-0} == 1 ]]; then
    jmh_jvm+=(-Djmh.ignoreLock=true) # JMH's /tmp/jmh.lock refuses a second harness; ALLOW_BUSY accepts the noise
  fi
  java "${jmh_jvm[@]}" -jar "$JAR" AllocationBenchmark -prof gc -rf json -rff "$OUT/jmh-alloc.json" >"$OUT/jmh-alloc.console.txt" 2>&1 \
    || { tail -30 "$OUT/jmh-alloc.console.txt" >&2; die "JMH failed"; }
  redact_host "$OUT/jmh-alloc.json"

  # Observed: where async-profiler's allocation event puts the same bytes. Only when the pinned release is
  # unpacked under ~/.cache/lowlat (user-local; this script installs nothing).
  ap_version=$(sed -nE 's/^ASYNC_PROFILER_VERSION="([^"]+)"/\1/p' "$LOWLAT_ROOT/versions.env")
  AP_LIB=${ASYNC_PROFILER_LIB:-$HOME/.cache/lowlat/async-profiler-$ap_version-linux-x64/lib/libasyncProfiler.so}
  if [[ -f $AP_LIB ]]; then
    step "async-profiler allocation profile of the escaping benchmark (observed)"
    rm -rf "$OUT/async-alloc"
    java "${jmh_jvm[@]}" -jar "$JAR" AllocationBenchmark.escaping -f 1 -wi 2 -i 3 \
      -prof "async:libPath=$AP_LIB;event=alloc;output=collapsed;dir=$OUT/async-alloc" >"$OUT/async-alloc.console.txt" 2>&1 \
      || { tail -30 "$OUT/async-alloc.console.txt" >&2; die "JMH with async-profiler failed"; }
  fi

  # ---- C++ benchmark and consumer ------------------------------------------------------------
  step "C++ Google Benchmark: value vs allocating vs pmr, 30 repetitions each"
  "$(cpp_bin jvmcosts-bench)" --benchmark_out="$OUT/gbench-alloc.json" --benchmark_out_format=json \
    >"$OUT/gbench-alloc.console.txt" 2>&1
  redact_host "$OUT/gbench-alloc.json"

  step "cpp / tracker"
  cpp_log=$OUT/cpp-tracker.log
  "$(cpp_bin jvmcosts-consumer)" --bind "127.0.0.1:$PORT" --expect "$COUNT" --window "$WINDOW" \
    --report "$OUT/cpp-tracker.json" >"$cpp_log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_udp_bound "$PORT" "$pid" "$cpp_log"
  simulate --rate "$RATE" --duration "$DURATION" --dest "127.0.0.1:$PORT" --quiet >>"$cpp_log"
  wait "$pid" || { cat "$cpp_log" >&2; die "cpp/tracker consumer failed"; }
  bg_forget "$pid"

  # ---- Java line runs ------------------------------------------------------------------------
  run_java unwarmed -- # the r01 behaviour: bind at once, the JIT warms on the first parcels
  run_java warmed -- --warm-up "$WARM_UP" # the JIT warms on 20,000 synthetic parcels before the bind

  step "AOT caches: two training runs ($TRAIN_SECONDS s at $RATE Hz each); the JVM writes each cache at exit"
  _scratch
  # Scratch files: a cache names the JDK build and the jar, so it is never committed.
  AOT_PLAIN=$LOWLAT_SCRATCH/jvm-costs.aot # for time to ready: no observation flags, as a service would start
  AOT_OBSERVED=$LOWLAT_SCRATCH/jvm-costs-observed.aot # for the line run: trained with its JFR and log flags
  train_aot "$AOT_PLAIN" plain
  observed_flags training-observed
  train_aot "$AOT_OBSERVED" observed "${OBSERVED_FLAGS[@]}"

  # -XX:AOTMode=on: a cache the JVM cannot use is a startup failure, never a silent fallback.
  # G1 in the training run and here: JEP 516 (JDK 26) lifts the G1-only limit on archived heap objects.
  run_java aot-cache "-XX:AOTCache=$AOT_OBSERVED" -XX:AOTMode=on "-Xlog:aot:file=$OUT/aot-cache.aot.log" --
  if grep -q 'Opened AOT cache' "$OUT/aot-cache.aot.log"; then
    for r in "$OUT/java-aot-cache.json" "$OUT/java-aot-cache-first-$WINDOW.json" "$OUT/java-aot-cache-steady.json"; do
      jq '.runtime.aot.used = true' "$r" >"$r.tmp" && mv "$r.tmp" "$r"
    done
  fi

  # ---- 4. time to ready: JVM launch to a bound socket, alternating --------------------------
  step "time to ready: $LAUNCHES alternating launches, no cache vs AOT cache (one discarded pair first)"
  ready_cmd=(java "${JVM_ARGS[@]}")
  ready_args=(-cp "$JAR" "$MAIN" --variant ready --bind "127.0.0.1:$READY_PORT")
  READY_PATTERN='ready:' time_to_ready "${ready_cmd[@]}" "${ready_args[@]}" >/dev/null # warm the page cache
  READY_PATTERN='ready:' time_to_ready "${ready_cmd[@]}" "-XX:AOTCache=$AOT_PLAIN" -XX:AOTMode=on "${ready_args[@]}" >/dev/null
  none=()
  cached=()
  for ((i = 1; i <= LAUNCHES; i++)); do
    none+=("$(READY_PATTERN='ready:' time_to_ready "${ready_cmd[@]}" "${ready_args[@]}")")
    cached+=("$(READY_PATTERN='ready:' time_to_ready "${ready_cmd[@]}" "-XX:AOTCache=$AOT_PLAIN" -XX:AOTMode=on "${ready_args[@]}")")
    printf '  launch %d: no cache %s ms, AOT cache %s ms\n' "$i" "$((${none[-1]} / 1000000))" "$((${cached[-1]} / 1000000))"
  done
  jq -n --argjson none "$(printf '%s\n' "${none[@]}" | jq -s .)" --argjson cached "$(printf '%s\n' "${cached[@]}" | jq -s .)" \
    --argjson mn "$(median_ns "${none[@]}")" --argjson mc "$(median_ns "${cached[@]}")" \
    '{unit: "ns", launches: ($none | length), order: "alternating, no cache first", no_cache: $none, aot_cache: $cached,
      median_no_cache: $mn, median_aot_cache: $mc}' >"$OUT/time-to-ready.json"
fi

# ---- reports -----------------------------------------------------------------------------------
reports=("$OUT/cpp-tracker.json" "$OUT/cpp-tracker-first-$WINDOW.json" "$OUT/cpp-tracker-steady.json")
for v in "${JAVA_VARIANTS[@]}"; do
  reports+=("$OUT/java-$v.json" "$OUT/java-$v-first-$WINDOW.json" "$OUT/java-$v-steady.json")
done
step "checking reports"
report_check "${reports[@]}"

# ---- criteria ----------------------------------------------------------------------------------
step "criterion 1: JMH -prof gc, heap bytes per decision (gc.alloc.rate.norm)"
# jmh_bytes METHOD: B/op of one benchmark method.
jmh_bytes() {
  jq -er --arg m "$1" '.[] | select(.benchmark | endswith("." + $m))
                       | .secondaryMetrics | to_entries[] | select(.key | endswith("gc.alloc.rate.norm")) | .value.score' \
    "$OUT/jmh-alloc.json"
}
escaping=$(jmh_bytes escaping)
scalar=$(jmh_bytes scalarReplaced)
noea=$(jmh_bytes scalarReplacedNoEscapeAnalysis)
verdict "1: escaping allocates the decision" ">=" "$escaping" 24
verdict "1: scalar-replaced allocates nothing" "<=" "$scalar" 1
verdict "1: --no-escape-analysis allocates it again" ">=" "$noea" 24
jq -n --argjson e "$escaping" --argjson s "$scalar" --argjson n "$noea" \
  '{unit: "B/op", escaping: $e, "scalar-replaced": $s, "--no-escape-analysis": $n}' >"$OUT/alloc-per-op.json"

gb() { jq -er --arg n "$1" --arg c "$2" '.benchmarks[] | select(.run_name | startswith($n)) | select(.aggregate_name == "median") | .[$c]' "$OUT/gbench-alloc.json"; }
c_value=$(gb BM_Decide_Value 'B/op')
c_alloc=$(gb BM_Decide_Allocating 'B/op')
c_pmr=$(gb BM_Decide_Pmr 'B/op')
verdict "1 (C++): --allocating pays one heap allocation per parcel" ">=" "$c_alloc" 16
verdict "1 (C++): value pays none" "<=" "$c_value" 1
printf '  observed (C++): pmr arena %.2f B/op through the global allocator\n' "$c_pmr"
printf '  observed (C++) median ns/op: value %.1f, --allocating %.1f, pmr %.1f\n' \
  "$(gb BM_Decide_Value real_time)" "$(gb BM_Decide_Allocating real_time)" "$(gb BM_Decide_Pmr real_time)"

# p99_of FILE: the p99 in ns.
p99_of() { jget "$1" .percentiles.p99; }

step "criteria 2 and 3: first window (parcels 0 to $((WINDOW - 1))) against steady, same run"
for v in "${JAVA_VARIANTS[@]}"; do
  first=$(p99_of "$OUT/java-$v-first-$WINDOW.json")
  steady=$(p99_of "$OUT/java-$v-steady.json")
  echo "  java $v: p99 first $first ns, steady $steady ns, ratio $(ratio "$first" "$steady");" \
    "p99.9 ratio $(ratio "$(jget "$OUT/java-$v-first-$WINDOW.json" .percentiles.p99_9)" "$(jget "$OUT/java-$v-steady.json" .percentiles.p99_9)");" \
    "max ratio $(ratio "$(jget "$OUT/java-$v-first-$WINDOW.json" .percentiles.max)" "$(jget "$OUT/java-$v-steady.json" .percentiles.max)")"
done
first=$(p99_of "$OUT/java-unwarmed-first-$WINDOW.json")
steady=$(p99_of "$OUT/java-unwarmed-steady.json")
verdict "2: --unwarmed first-window p99 over steady p99" ">=" "$(ratio "$first" "$steady")" 5
first=$(p99_of "$OUT/java-warmed-first-$WINDOW.json")
steady=$(p99_of "$OUT/java-warmed-steady.json")
verdict "3: warmed first-window p99 over steady p99" "<=" "$(ratio "$first" "$steady")" 3

step "criterion 4: time to ready"
median_none=$(jq -r .median_no_cache "$OUT/time-to-ready.json")
median_cached=$(jq -r .median_aot_cache "$OUT/time-to-ready.json")
echo "  median time to ready: no cache $((median_none / 1000000)) ms, AOT cache $((median_cached / 1000000)) ms"
verdict "4: aot-cache median time to ready over the no-cache median" "<=" "$(ratio "$median_cached" "$median_none")" 0.8
if grep -q 'Opened AOT cache' "$OUT/aot-cache.aot.log"; then
  ok "4: the AOT log shows the cache opened ($(grep -c . "$OUT/aot-cache.aot.log") lines in aot-cache.aot.log)"
else
  bad "4: no 'Opened AOT cache' line in aot-cache.aot.log"
fi
if [[ $(jget "$OUT/java-aot-cache.json" .runtime.aot.used) == true ]]; then
  ok "4: the aot-cache report records runtime.aot.used"
else
  bad "4: runtime.aot.used is not set on the aot-cache report"
fi

step "criterion 5: build.flags carries the JVM arguments"
for v in "${JAVA_VARIANTS[@]}"; do
  for r in "$OUT/java-$v.json" "$OUT/java-$v-first-$WINDOW.json" "$OUT/java-$v-steady.json"; do
    flags=$(jq -r '.build.flags // ""' "$r")
    case $v in
      aot-cache) want=(-XX:+UseG1GC -Xmx256m -XX:AOTCache= -XX:AOTMode=on) ;;
      *) want=(-XX:+UseG1GC -Xmx256m) ;;
    esac
    missing=()
    for w in "${want[@]}"; do [[ $flags == *"$w"* ]] || missing+=("$w"); done
    ((${#missing[@]} == 0)) || bad "5: $(basename "$r") build.flags lacks ${missing[*]}"
  done
  ok "5: java/$v reports carry ${want[*]} in build.flags"
done

step "criterion 6: every line run counted $COUNT parcels and dropped none"
for r in "$OUT"/cpp-tracker.json "$OUT"/java-{unwarmed,warmed,aot-cache}.json; do
  n=$(jget "$r" .count)
  d=$(jget "$r" .dropped)
  if ((n == COUNT && d == 0)); then
    ok "6: $(basename "$r") count=$n dropped=$d"
  else
    bad "6: $(basename "$r") count=$n dropped=$d (want $COUNT, 0)"
  fi
done
windowed=$(($(jget "$OUT/cpp-tracker-first-$WINDOW.json" .count) + $(jget "$OUT/cpp-tracker-steady.json" .count)))
if ((windowed == COUNT)); then
  ok "6: cpp/tracker windows sum to $COUNT"
else
  bad "6: cpp/tracker windows sum to $windowed, not $COUNT"
fi
ok "6: lowlat-report check passed on ${#reports[@]} reports (above)"

# ---- observed ----------------------------------------------------------------------------------
step "observed (not asserted)"
echo "allocated bytes per parcel on the receive thread (decode, tracker, completion; protobuf included):"
for v in "${JAVA_VARIANTS[@]}"; do
  printf '  java %-10s %s B/parcel\n' "$v" "$(jq -r '.runtime.alloc_bytes_per_parcel | . * 10 | round / 10' "$OUT/java-$v.json")"
done
collapsed=$(find "$OUT/async-alloc" -name 'collapsed-alloc.csv' -print -quit 2>/dev/null || true)
if [[ -n $collapsed ]]; then
  # Each line is a stack and the sampled bytes; the leaf is the last frame.
  awk '{ n = $NF; sub(/ [0-9]+$/, ""); k = split($0, f, ";"); bytes[f[k]] += n; total += n }
       END { for (leaf in bytes) printf "%.1f%% %s\n", 100 * bytes[leaf] / total, leaf }' "$collapsed" | sort -rn | head -3 |
    sed 's/^/  async-profiler alloc, escaping benchmark, share of sampled bytes by leaf frame: /'
else
  echo "async-profiler allocation profile skipped: the pinned release is not unpacked under ~/.cache/lowlat"
fi
echo "JIT events per window (JFR jdk.Compilation, jdk.Deoptimization; startup = before the first parcel):"
for v in "${JAVA_VARIANTS[@]}"; do
  jq -r --arg v "$v" '.runtime.jit | to_entries[] | "  java \($v) \(.key): \(.value.compilations) compilations (\(.value.c2_compilations) at tier 4), \(.value.deoptimizations) deoptimizations"' \
    "$OUT/java-$v.json"
done
echo "C++ (no JIT): first-window p99 $(p99_of "$OUT/cpp-tracker-first-$WINDOW.json") ns, steady p99 $(p99_of "$OUT/cpp-tracker-steady.json") ns, ratio $(ratio "$(p99_of "$OUT/cpp-tracker-first-$WINDOW.json")" "$(p99_of "$OUT/cpp-tracker-steady.json")")"
echo "aot-cache first-window p99: $(p99_of "$OUT/java-aot-cache-first-$WINDOW.json") ns (unwarmed $(p99_of "$OUT/java-unwarmed-first-$WINDOW.json") ns, warmed $(p99_of "$OUT/java-warmed-first-$WINDOW.json") ns)"

if ((FAILED)); then
  printf '%s✗ 05-jvm-costs: at least one criterion missed (see ✗ above); results in %s%s\n' "$_c_bad" "$OUT" "$_c_off" >&2
  exit 1
fi
ok "05-jvm-costs: the first parcel pays the JVM's costs; warm-up and the AOT cache move them out of the line; results in $OUT"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
