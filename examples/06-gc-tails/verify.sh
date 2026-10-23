#!/usr/bin/env bash
# Ch6 verify: the collector decides the tail.
#   1. JFR max pause: stop-the-world >= 10 ms and >= 20x zgc; zgc < 1 ms; shenandoah-gen <= 1/5 of stop-the-world.
#   2. zgc p99.9 <= 1/3 of stop-the-world p99.9.
#   3. undersized-heap (heap = 1.05x the measured live set): >= 1 ZGC allocation stall and p99.9 >= 3x
#      right-sized zgc.
#   4. Python: frozen has 0 generation-2 collections in the window; cyclic-garbage has >= 1.
#   5. C++: bulk-free max >= 10x deferred-free p99.9. Observed: deferred-free max vs the no-free control.
#   6. Every report: count = 300000, dropped = 0, lowlat-report check; every Java report names its GC and heap.
# Observed, not asserted: shenandoah, thp, jfr-off. 10 kHz x 30 s, one JVM at a time, each with a
# 4 GB heap, on UDP ports 47260 (Java), 47261 (Python), 47262 (C++). See README.md.
# RECHECK=results/<run-id> re-evaluates committed reports without running anything.
# SWEEP=1 runs the heap-multiple sweep instead (zgc at 1.30, 1.15, 1.10, 1.075 and 1.05x the live
# set, plus the right-sized reference), writes the reports and prints the table; no criteria.
set -euo pipefail
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

EXAMPLE=06-gc-tails
DIR=$(example_dir)
PORT_JAVA=47260
PORT_PY=47261
PORT_CPP=47262
RATE=10000
SECONDS_RUN=30
COUNT=$((RATE * SECONDS_RUN))
HEAP_MB=4096
UNDERSIZED_PERCENT=105 # --undersized-heap: the heap is this share of the measured live set (README: the cliff)
SWEEP_PERMILLE=(1300 1150 1100 1075 1050)
JAR=$DIR/java/target/gc-tails-java.jar

JAVA_VARIANTS=(stop-the-world g1 zgc shenandoah-gen shenandoah undersized-heap thp jfr-off)
PY_VARIANTS=(cyclic-garbage frozen)
CPP_VARIANTS=(bulk-free deferred-free no-free)

# RECHECK=DIR: evaluate the criteria on the reports already in DIR (no build, no run).
if [[ -n ${RECHECK:-} ]]; then
  out=$(cd "$RECHECK" && pwd)
  export LOWLAT_PROFILE=$out/profile.json
else
  require_quiet_host
  out=$(results_dir)
  capture_profile "$out"

  build_cpp gc-tails-consumer line-simulator
  build_java "$DIR/java"
  py_sync
fi
OUT=$out # lib.sh helpers (java_flags, jfr_pauses) write beside the reports

# gc_flags VARIANT: the JVM's collector flags for a Java variant (GC_FLAGS) and heap in MB (HEAP).
gc_flags() {
  HEAP=$HEAP_MB
  case $1 in
    stop-the-world) GC_FLAGS=(-XX:+UseParallelGC) ;;
    g1) GC_FLAGS=(-XX:+UseG1GC) ;;
    zgc | jfr-off) GC_FLAGS=(-XX:+UseZGC) ;;
    shenandoah-gen) GC_FLAGS=(-XX:+UseShenandoahGC -XX:ShenandoahGCMode=generational) ;;
    shenandoah) GC_FLAGS=(-XX:+UseShenandoahGC) ;;
    undersized-heap) GC_FLAGS=(-XX:+UseZGC) HEAP=$UNDERSIZED_MB ;;
    thp) GC_FLAGS=(-XX:+UseZGC -XX:+UseTransparentHugePages) ;;
    *) die "unknown Java variant $1" ;;
  esac
}

# heap_mb_for_permille N: the heap, in MB rounded up, that is N/1000 of the measured live set.
heap_mb_for_permille() { echo $(((LIVE_BYTES * $1 / 1000 + (1 << 20) - 1) >> 20)); }

# measure_live_set: the tracker's live set under ZGC (references are 8 bytes there, so it is the
# largest of the collectors'), from a forced collection in --probe mode. Sets LIVE_BYTES and
# UNDERSIZED_MB.
measure_live_set() {
  local line
  step "live set probe (ZGC, ${HEAP_MB} MB heap)"
  line=$(java -Xms"${HEAP_MB}m" -Xmx"${HEAP_MB}m" -XX:+UseZGC -jar "$JAR" --probe | grep '^live_set_bytes=')
  LIVE_BYTES=${line#live_set_bytes=}
  UNDERSIZED_MB=$(heap_mb_for_permille $((UNDERSIZED_PERCENT * 10)))
  ok "live set $((LIVE_BYTES >> 20)) MB; --undersized-heap runs ZGC in ${UNDERSIZED_MB} MB ($UNDERSIZED_PERCENT %)"
  echo "$LIVE_BYTES" >"$out/live-set-bytes.txt"
}

# run_java VARIANT [LABEL]: one JVM, 10 kHz x 30 s. The recording starts inside the JVM after the setup
# (see Flight.java), so java_flags' -XX:StartFlightRecording is dropped.
run_java() {
  local kind=$1 variant=${2:-$1} report log flags=() f pid jfr=()
  report="$out/java-$variant.json"
  log="$out/java-$variant.log"
  gc_flags "$kind"
  java_flags "$variant"
  for f in "${JAVA_RUN_FLAGS[@]}"; do
    [[ $f == -XX:StartFlightRecording* ]] || flags+=("$f")
  done
  [[ $variant == jfr-off ]] || jfr=(--jfr "$JFR_FILE")
  step "java / $variant (${GC_FLAGS[*]} -Xms${HEAP}m -Xmx${HEAP}m)"
  {
    printf 'java:'
    printf ' %q' "${flags[@]}" "-Xms${HEAP}m" "-Xmx${HEAP}m" -XX:+AlwaysPreTouch "${GC_FLAGS[@]}" \
      -jar "$JAR" --variant "$variant" "${jfr[@]}"
    printf '\n'
  } >"$log"
  java "${flags[@]}" "-Xms${HEAP}m" "-Xmx${HEAP}m" -XX:+AlwaysPreTouch "${GC_FLAGS[@]}" \
    -jar "$JAR" --variant "$variant" --bind "127.0.0.1:$PORT_JAVA" --expect "$COUNT" \
    --example "$EXAMPLE" --report "$report" "${jfr[@]}" >>"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_udp_bound "$PORT_JAVA" "$pid" "$log" 900 # the live set is built and the JIT warmed before the bind
  simulate --rate "$RATE" --duration "$SECONDS_RUN" --dest "127.0.0.1:$PORT_JAVA" --quiet >>"$log"
  wait "$pid" || { cat "$log" >&2; die "java/$variant failed"; }
  bg_forget "$pid"
  if [[ $variant != jfr-off ]]; then
    jfr_pauses "$JFR_FILE" "$EXAMPLE" "$variant" >>"$log"
    jfr summary "$JFR_FILE" >"$out/java-$variant.jfr-summary.txt"
  fi
  gzip -9 -f "$GC_LOG" # the unified log is the evidence; compressed it is a few kilobytes
  check_arrival "java/$variant" "$report"
}

# run_python VARIANT, run_cpp VARIANT: one consumer, 10 kHz x 30 s.
run_consumer() {
  local lang=$1 variant=$2 port=$3 tries=$4 report log pid
  shift 4
  report="$out/$lang-$variant.json"
  log="$out/$lang-$variant.log"
  step "$lang / $variant"
  (cd "$LOWLAT_EXAMPLES" && exec "$@" --variant "$variant" --bind "127.0.0.1:$port" --expect "$COUNT" \
    --example "$EXAMPLE" --report "$report") >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_udp_bound "$port" "$pid" "$log" "$tries"
  simulate --rate "$RATE" --duration "$SECONDS_RUN" --dest "127.0.0.1:$port" --quiet >>"$log"
  wait "$pid" || { cat "$log" >&2; die "$lang/$variant consumer failed"; }
  bg_forget "$pid"
  check_arrival "$lang/$variant" "$report"
}

# check_arrival NAME REPORT: every parcel arrived (criterion 6, the part that must hold at once).
check_arrival() {
  [[ $(jget "$2" .count) -eq $COUNT ]] || die "$1: count != $COUNT"
  [[ $(jget "$2" .dropped) -eq 0 ]] || die "$1: parcels were dropped (the UDP buffer overflowed during a pause)"
}

# fmt VALUE UNIT: ns as milliseconds with three decimals, anything else as is.
fmt() {
  if [[ $2 == ns ]]; then
    printf '%d.%03d ms' $(($1 / 1000000)) $(($1 % 1000000 / 1000))
  else
    printf '%d' "$1"
  fi
}

# run_sweep: ZGC at a series of heap multiples of the live set, and the right-sized reference.
# Each point is one run of the undersized-heap code path with its own heap; the reports are
# java-heap-<permille>.json and java-heap-ref.json.
run_sweep() {
  local pm label mb
  step "sweep: ZGC heap as a multiple of the live set"
  for pm in "${SWEEP_PERMILLE[@]}"; do
    UNDERSIZED_MB=$(heap_mb_for_permille "$pm")
    run_java undersized-heap "heap-$pm"
  done
  run_java zgc heap-ref
  printf '%-12s %8s %7s %14s %10s %10s %8s\n' multiple heap_MB stalls max_stall p99 p99.9 dropped
  for pm in "${SWEEP_PERMILLE[@]}" ref; do
    label=heap-$pm
    if [[ $pm == ref ]]; then
      mb=$HEAP_MB
      pm=right-sized
    else
      mb=$(heap_mb_for_permille "$pm")
      pm=$(awk -v p="$pm" 'BEGIN { printf "%.3fx", p / 1000 }')
    fi
    printf '%-12s %8d %7d %14s %10s %10s %8d\n' "$pm" "$mb" \
      "$(jget "$out/java-$label-gc-pause.json" .runtime.alloc_stalls.count)" \
      "$(fmt "$(jget "$out/java-$label-gc-pause.json" .runtime.alloc_stalls.max_ns)" ns)" \
      "$(fmt "$(jget "$out/java-$label.json" .percentiles.p99)" ns)" \
      "$(fmt "$(jget "$out/java-$label.json" .percentiles.p99_9)" ns)" \
      "$(jget "$out/java-$label.json" .dropped)"
  done
}

if [[ -z ${RECHECK:-} ]]; then
  measure_live_set
  if [[ ${SWEEP:-0} == 1 ]]; then
    run_sweep
    ok "06-gc-tails: sweep written to $out"
    exit 0
  fi
  for variant in "${JAVA_VARIANTS[@]}"; do
    run_java "$variant"
  done
  for variant in "${PY_VARIANTS[@]}"; do
    run_consumer python "$variant" "$PORT_PY" 900 uv run -q --package lowlat-gc-tails gc-tails-py
  done
  for variant in "${CPP_VARIANTS[@]}"; do
    run_consumer cpp "$variant" "$PORT_CPP" 300 "$(cpp_bin gc-tails-consumer)"
  done
else
  LIVE_BYTES=$(<"$out/live-set-bytes.txt")
  UNDERSIZED_MB=$(heap_mb_for_permille $((UNDERSIZED_PERCENT * 10)))
fi

reports=()
for variant in "${JAVA_VARIANTS[@]}"; do
  reports+=("$out/java-$variant.json")
  [[ $variant == jfr-off ]] || reports+=("$out/java-$variant-gc-pause.json")
done
for variant in "${PY_VARIANTS[@]}"; do
  reports+=("$out/python-$variant.json" "$out/python-$variant-gc-pause.json")
done
for variant in "${CPP_VARIANTS[@]}"; do
  reports+=("$out/cpp-$variant.json")
done
step "checking reports"
report_check "${reports[@]}"

# ---------------------------------------------------------------------------------------------
# Criteria. Every one is evaluated and printed; the script fails at the end if any did not hold.
# ---------------------------------------------------------------------------------------------
FAILED=0

# expect LABEL A OP B [UNIT]: print a check line for the integer comparison A OP B (OP: -ge -le -lt).
expect() {
  local label=$1 a=$2 op=$3 b=$4 unit=${5:-ns} sign
  case $op in
    -ge) sign='>=' ;;
    -le) sign='<=' ;;
    -lt) sign='<' ;;
    *) die "expect: unknown operator $op" ;;
  esac
  if test "$a" "$op" "$b"; then
    ok "$label ($(fmt "$a" "$unit") $sign $(fmt "$b" "$unit"))"
  else
    say_bad "$label ($(fmt "$a" "$unit"), need $sign $(fmt "$b" "$unit"))"
    FAILED=1
  fi
}

pause_max() { jget "$out/java-$1-gc-pause.json" .percentiles.max; }
p999() { jget "$out/$1-$2.json" .percentiles.p99_9; }
note_int() { jget "$1" ".notes | capture(\"$2=(?<v>[0-9]+)\").v | tonumber"; }

step "criteria"
stw_max=$(pause_max stop-the-world)
zgc_max=$(pause_max zgc)
sgen_max=$(pause_max shenandoah-gen)
# 1. Pauses, from JFR.
expect "1 stop-the-world max pause is at least 10 ms" "$stw_max" -ge 10000000
expect "1 stop-the-world max pause is at least 20x zgc's ($(fmt "$zgc_max" ns))" "$stw_max" -ge $((20 * zgc_max))
expect "1 zgc max pause is under 1 ms" "$zgc_max" -lt 1000000
expect "1 shenandoah-gen max pause, times 5, is at most stop-the-world's" $((5 * sgen_max)) -le "$stw_max"

# 2. The tail the line sees.
expect "2 zgc p99.9, times 3, is at most stop-the-world p99.9 ($(fmt "$(p999 java stop-the-world)" ns))" \
  $((3 * $(p999 java zgc))) -le "$(p999 java stop-the-world)"

# 3. Headroom: a heap at 1.05x the live set stalls allocations (see the README for the cliff).
stalls=$(jget "$out/java-undersized-heap-gc-pause.json" .runtime.alloc_stalls.count)
expect "3 undersized-heap ($UNDERSIZED_MB MB) has at least one ZGC allocation stall" "$stalls" -ge 1 n
expect "3 undersized-heap p99.9 is at least 3x right-sized zgc p99.9 ($(fmt "$(p999 java zgc)" ns))" \
  "$(p999 java undersized-heap)" -ge $((3 * $(p999 java zgc)))

# 4. Python: refcounting plus gc.freeze keeps the cycle collector away.
gen2_frozen=$(note_int "$out/python-frozen.json" gen2_collections)
gen2_cyclic=$(note_int "$out/python-cyclic-garbage.json" gen2_collections)
expect "4 python frozen runs 0 generation-2 collections in the window" "$gen2_frozen" -le 0 n
expect "4 python cyclic-garbage runs at least one generation-2 collection" "$gen2_cyclic" -ge 1 n

# 5. C++: where the frees run.
bulk_max=$(jget "$out/cpp-bulk-free.json" .percentiles.max)
deferred_p999=$(p999 cpp deferred-free)
deferred_max=$(jget "$out/cpp-deferred-free.json" .percentiles.max)
nofree_max=$(jget "$out/cpp-no-free.json" .percentiles.max)
expect "5 bulk-free max is at least 10x deferred-free p99.9 ($(fmt "$deferred_p999" ns))" "$bulk_max" -ge $((10 * deferred_p999))

# 6. Every report names the collector and the heap it ran with.
flag_ok=1
for variant in "${JAVA_VARIANTS[@]}"; do
  jq -e '.build.flags | test("-XX:\\+Use(ParallelGC|G1GC|ZGC|ShenandoahGC)") and test("-Xmx[0-9]+[mg]")' \
    "$out/java-$variant.json" >/dev/null || { flag_ok=0; echo "java-$variant.json: build.flags does not name its GC and heap" >&2; }
done
expect "6 every Java report's build.flags names its collector and heap" "$flag_ok" -ge 1 n
ok "6 every report: count $COUNT, dropped 0, lowlat-report check (checked above)"

# Observed, not asserted.
step "observed (no bound)"
for variant in shenandoah thp jfr-off; do
  line="$variant: p99.9 $(fmt "$(p999 java "$variant")" ns)"
  [[ $variant == jfr-off ]] || line+=", max pause $(fmt "$(pause_max "$variant")" ns)"
  echo "$line"
done
# thp asks ZGC for large pages; the JVM's own init line says whether it got them. ZGC's heap is shared
# memory, governed by transparent_hugepage/shmem_enabled, so "Disabled (OS enforced)" is the host
# refusing, not a flag that was ignored.
large_pages=$(zcat "$out/thp.gc.log.gz" | sed -n 's/.*Large Page Support: *//p' | head -n 1)
echo "thp: large pages ${large_pages:-not reported} (GC log), shmem_enabled=$(jq -r '.memory.thp_shmem_enabled // "not recorded"' "$LOWLAT_PROFILE")"
echo "cpp deferred-free max $(fmt "$deferred_max" ns), no-free control max $(fmt "$nofree_max" ns) (both are single OS-noise events)"
echo "zgc (reference): p99.9 $(fmt "$(p999 java zgc)" ns), max pause $(fmt "$zgc_max" ns)"
echo "live set: $(($(<"$out/live-set-bytes.txt") >> 20)) MB; allocation: $(jq -r '.runtime.alloc_bytes_per_parcel | floor' "$out/java-zgc.json") B/parcel on the receive thread, $RATE parcels/s"

((FAILED == 0)) || die "06-gc-tails: a criterion did not hold"
ok "06-gc-tails: the collector, the headroom and where the frees run set the tail"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) thp=\(.memory.thp_enabled) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
