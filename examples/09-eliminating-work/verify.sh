#!/usr/bin/env bash
# Ch9 verify: eliminating work in the in-flight parcel tracker (allocation, cache locality, false sharing).
#
# Criteria (every one is evaluated; each prints its measured value, its bound and the margin; any miss fails the run
# after all have been evaluated). Latency ratios compare variants within THIS run, interleaved A B A B A B and judged on
# the median of the three per-alternation ratios; counters labelled "exact" are deterministic and need no median.
#   1  allocation per insert (exact): C++ node-map >= 2 per insert, flat-map 0; JMH node-map >= 64 B/op, flat-map <= 1 B/op;
#      Python: the dict record object >= 2x the slotted record object (sys.getsizeof) and dict-per-parcel >= 2x slots-int
#      bytes per tracked parcel (tracemalloc); dict against slots-str per tracked parcel is observed
#   2  hub lookups (1,000,000 parcels): cachegrind LL read misses per lookup node-map >= 2x flat-map (exact); perf
#      LLC-load-misses:u per lookup node-map >= 2x flat-map (C++, median of 3); the p50 ratios (C++, Java, bound 2x) are
#      observed, with their margins printed
#   3  hub sweep: fat-record p50 >= 2x hot-cold p50 (C++, Java); cachegrind D1 read misses per slot fat-record >= 4x
#      hot-cold (exact)
#   4  counters, five threads on distinct physical cores (placement checked from /proc): L1-dcache-load-misses:u per
#      increment adjacent-counters >= 10x pair-padded, single-writer store increment (C++ and Java); C++ per-batch p50
#      adjacent-counters >= 3x pair-padded for the fetch_add increment. The store-increment batch times (C++, Java) and
#      the Java getAndAdd times are observed
#   5  line 10 kHz x 20 s against the preloaded hub tracker, C++: allocations per parcel from the tracker (exact):
#      node-map >= 1, flat-map 0
#   6  every report: count, dropped = 0 on the line, lowlat-report check, build.flags (Java), runtime.placement when pinned
# Observed, not asserted: the hub lookup p50 ratios, the counters' batch times for the store increment and for Java's
# getAndAdd, line-padded against pair-padded, smt-siblings, long-adder (Java), line-scale lookups, the other hardware
# counters, line end-to-end percentiles, Java allocation on the line, the Python sweep and process/thread counters,
# JOL footprint.
#
#   ./verify.sh                 build, run, assert
#   RECHECK=results/<run-id>    re-evaluate the committed reports without building or running anything
#   ALLOW_BUSY=1 ./verify.sh    measure while a lab VM or other load is running (noisy)
#   SKIP_BUILD=1 ./verify.sh    reuse existing builds
#   SKIP_CACHEGRIND=1           skip the (slow) cachegrind runs and their criteria
#   RESULTS_DIR=DIR             where reports go (default results/latest)
#   LOWLAT_BUILD=DIR            private C++ build directory
#
# UDP ports 47290 (node-map) and 47291 (flat-map) on 127.0.0.1. Threads are pinned to distinct physical cores with
# sched_setaffinity as an experiment control; that is not isolation. Never changes the host: no sudo, no sysctl, no
# governor; perf counts user space only (events end in :u).
# The jq programs handed to `holds` are single-quoted: $a, $f are jq variables, not shell ones.
# shellcheck disable=SC2016
set -euo pipefail
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

EXAMPLE=09-eliminating-work
HERE=$(example_dir)
JAR=$HERE/java/target/benchmarks.jar
HUB=1000000
LINE_SCALE=4800
RATE=10000
SECONDS_RUN=20
COUNT=$((RATE * SECONDS_RUN))
PORT_NODE=47290
PORT_FLAT=47291
ROUNDS=3
HOLD_MS=1000
BATCHES=20000
# The JVM for every Java run: a fixed, pre-touched heap so no collection starts inside a measured run, and the native
# access JNA (OpenHFT Affinity) needs. Chronicle analytics (a phone-home) is switched off.
JVM=(-Xms2g -Xmx2g -XX:+AlwaysPreTouch -XX:+UseParallelGC --enable-native-access=ALL-UNNAMED -Dchronicle.analytics.disable=true)
MAIN=io.patterncatalyst.lowlat.eliminating.Main

if [[ -n ${RECHECK:-} ]]; then
  OUT=$(cd "$RECHECK" && pwd)
  export LOWLAT_PROFILE=$OUT/profile.json
  RUN=0
else
  RUN=1
  require_quiet_host
  OUT=$(results_dir)
  [[ $OUT == /*/*/* ]] || die "refusing to clear subdirectories of $OUT"
  rm -rf "${OUT:?}"/{cpp,java,python}
  mkdir -p "$OUT"/{cpp,java,python}
  capture_profile "$OUT"
fi

# ---- helpers -----------------------------------------------------------------------------------------------------

holds() {
  local expr=$1 message=$2
  shift 2
  if jq -en "$@" "$expr" >/dev/null; then ok "$message"; else bad "$message"; fi
}

p50_of() { jget "$1" .percentiles.p50; }
per_op() { jget "$1" ".runtime.hw_counters.per_op[\"$2\"]"; }

# ratios NUMS DENS: per-alternation ratios NUM/DEN in permille (integers), one per line. Values are floats or ints.
ratios() {
  paste -d' ' <(tr ' ' '\n' <<<"$1") <(tr ' ' '\n' <<<"$2") |
    awk '{ d = ($2 > 0) ? $2 : 1e-9; printf "%d\n", 1000 * $1 / d }'
}
x_of() { awk -v p="$1" 'BEGIN { printf "%.2fx", p / 1000 }'; }

# expect_ratio ID LABEL BOUND "NUMS" "DENS" [exact]: the median of the per-alternation ratios NUM/DEN must reach BOUND
# (an integer factor). Prints the value, the bound and the margin.
expect_ratio() {
  local id=$1 label=$2 bound=$3 nums=$4 dens=$5 kind=${6:-} list median margin each
  list=$(ratios "$nums" "$dens")
  median=$(sort -n <<<"$list" | sed -n "$((($(wc -l <<<"$list") + 1) / 2))p")
  each=$(awk '{ printf "%.2fx ", $1 / 1000 }' <<<"$list")
  margin=$(awk -v m="$median" -v b="$bound" 'BEGIN { printf "%.2fx", m / (1000 * b) }')
  local text
  text="$id $label: $(x_of "$median") (${each% }), bound >= ${bound}x, margin $margin${kind:+ [$kind]}"
  if ((median >= 1000 * bound)); then ok "$text"; else bad "$text"; fi
}

# observe_ratio ID LABEL BOUND "NUMS" "DENS": the same median ratio, printed with the margin it would have against BOUND,
# but never a criterion.
observe_ratio() {
  local id=$1 label=$2 bound=$3 list median
  list=$(ratios "$4" "$5")
  median=$(sort -n <<<"$list" | sed -n "$((($(wc -l <<<"$list") + 1) / 2))p")
  printf '  observed %s %s: %s (%s), %sx would be margin %s\n' "$id" "$label" "$(x_of "$median")" \
    "$(awk '{ printf "%.2fx ", $1 / 1000 }' <<<"$list" | sed 's/ $//')" "$bound" \
    "$(awk -v m="$median" -v b="$bound" 'BEGIN { printf "%.2fx", m / (1000 * b) }')"
}

# expect_count_ge ID LABEL VALUE BOUND / expect_count_le: an exact count against a bound.
expect_count_ge() {
  local text
  text="$1 $2: $3, bound >= $4, margin $(awk -v v="$3" -v b="$4" 'BEGIN { if (b > 0) printf "%.2fx", v / b; else print "n/a" }') [exact]"
  if awk -v v="$3" -v b="$4" 'BEGIN { exit !(v >= b) }'; then ok "$text"; else bad "$text"; fi
}
expect_count_le() {
  local text="$1 $2: $3, bound <= $4 [exact]"
  if awk -v v="$3" -v b="$4" 'BEGIN { exit !(v <= b) }'; then ok "$text"; else bad "$text"; fi
}

# The measured programs append a "placement pid= tid= cpu= role=" line per pinned thread to $LOWLAT_PLACEMENT_FILE
# (perf holds the program's stdout back until it exits, so stdout cannot be read live).
# check_placement FILE N PID: wait for N lines in FILE, then assert every thread's CPU from /proc/<pid>/task/<tid>/stat
# while the process holds its threads parked. PID is the background job, for the liveness check.
check_placement() {
  local log=$1 want=$2 pid=$3 i have=0 line p t c
  for ((i = 0; i < 6000; i++)); do
    have=$(grep -c 'placement pid=' "$log" 2>/dev/null || true)
    ((have >= want)) && break
    kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; die "process exited before $want placement lines"; }
    sleep 0.02
  done
  ((have >= want)) || die "no $want placement lines in $log"
  while read -r line; do
    [[ $line =~ pid=([0-9]+)\ tid=([0-9]+)\ cpu=([0-9]+) ]] || continue
    p=${BASH_REMATCH[1]} t=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]}
    assert_placement "$p" "$t" "$c"
  done < <(grep -o 'placement pid=[0-9]* tid=[0-9]* cpu=[0-9]*' "$log" | head -n "$want")
}

# merge_hw REPORT HW: put the perf_region counts (runtime.hw_counters) into the report's runtime block.
merge_hw() {
  jq --slurpfile hw "$2" '.runtime = ((.runtime // {}) + {hw_counters: $hw[0]})' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
  rm -f "$2"
}

# counted_run REPORT PLACEMENT_LINES CMD...: CMD under perf_region (counted region = the measured loop), in the
# background; the placement of its threads is asserted while it holds; hardware counters merged into REPORT.
counted_run() {
  local report=$1 lines=$2 pid hw log placed
  shift 2
  hw=${report%.json}.hw.json
  log=${report%.json}.log
  placed=${report%.json}.placement
  : >"$placed"
  LOWLAT_PLACEMENT_FILE=$placed perf_region "$hw" -- "$@" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  check_placement "$placed" "$lines" "$pid"
  wait "$pid" || { tail -20 "$log" >&2; die "$(basename "$report"): the run failed"; }
  bg_forget "$pid"
  rm -f "$placed"
  merge_hw "$report" "$hw"
}

# pinned_bg LOG LINES CMD...: CMD in the background (output in LOG); asserts LINES placement lines while it holds.
pinned_bg() {
  local log=$1 lines=$2 pid placed=${1%.log}.placement
  shift 2
  : >"$placed"
  LOWLAT_PLACEMENT_FILE=$placed "$@" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  check_placement "$placed" "$lines" "$pid"
  wait "$pid" || { tail -20 "$log" >&2; die "$(basename "$log"): the run failed"; }
  bg_forget "$pid"
  rm -f "$placed"
}

# ---- build and unit tests -----------------------------------------------------------------------------------------
if ((RUN)); then
  build_cpp tracker-bench counters-bench eliminating-line line-simulator eliminating-work-test
  BUILD_JAVA_TESTS=1 build_java "$HERE/java" # the Java tests (tracker, SSCC golden, layout, allocation) run on the way
  py_sync
  # The generated protobuf modules are git-ignored: regenerate them (pinned protoc) when they are missing.
  compgen -G "$LOWLAT_EXAMPLES/common/proto-py/src/lowlat/line/v1/*_pb2.py" >/dev/null ||
    "$LOWLAT_ROOT/scripts/gen-python-proto.sh"
  [[ -f $JAR ]] || die "missing $JAR (build_java first)"

  step "unit tests: C++ (GoogleTest) and Python (pytest); Java ran during the package step"
  "$(cpp_bin eliminating-work-test)" --gtest_brief=1
  uvrun --package lowlat-locality pytest -q "$HERE/locality-py/tests"
  ok "C++, Java and Python unit tests pass (tracker logic, SSCC packing against the parcel-v1 golden barcodes, layout)"

  # Distinct physical cores for the pinned threads, from sysfs topology.
  # CPU 0 is left alone: it takes the boot-time interrupts and OpenHFT Affinity will not bind to it.
  mapfile -t CORES < <(distinct_cores 7 | awk '$1 != 0' | head -n 6)
  ((${#CORES[@]} == 6)) || die "need six physical cores other than CPU 0, got ${#CORES[@]}"
  ok "pinned threads use physical cores ${CORES[*]} (one logical CPU per core); not isolation"
  # The two hardware threads of one of those cores, for the smt-siblings variant.
  SMT=()
  mapfile -t SMT < <(_cpu_expand "$(<"/sys/devices/system/cpu/cpu${CORES[3]}/topology/thread_siblings_list")") || true
  TB=$(cpp_bin tracker-bench)
  CB=$(cpp_bin counters-bench)
  LB=$(cpp_bin eliminating-line)
  CPUS6=$(IFS=,; echo "${CORES[*]}")
  CPU=${CORES[0]}
fi

# ---- C++ lane ----------------------------------------------------------------------------------------------------
step "C++: insert allocations (line-scale tracker, ${LINE_SCALE} in flight), 3 alternations"
if ((RUN)); then
  n=0
  for v in $(interleave "$ROUNDS" node-map flat-map); do
    n=$((n + 1))
    counted_run "$OUT/cpp/insert-$v.a$(((n + 1) / 2)).json" 1 \
      "$TB" --mode insert --variant "$v" --size "$LINE_SCALE" --cpu "$CPU" --hold-ms "$HOLD_MS" \
      --out "$OUT/cpp/insert-$v.a$(((n + 1) / 2)).json"
  done
fi
node_allocs=$(jget "$OUT/cpp/insert-node-map.a1.json" .runtime.counters.allocations)
flat_allocs=$(jget "$OUT/cpp/insert-flat-map.a1.json" .runtime.counters.allocations)
inserts=$(jget "$OUT/cpp/insert-node-map.a1.json" .runtime.counters.inserts)
printf '  per insert-and-erase pair: node-map %s allocations (%s B), flat-map %s\n' \
  "$node_allocs" "$(jget "$OUT/cpp/insert-node-map.a1.json" .runtime.counters.allocated_bytes)" "$flat_allocs"
expect_count_ge "1a" "C++ node-map allocations per insert" "$(awk -v a="$node_allocs" -v n="$inserts" 'BEGIN { printf "%.3f", a / n }')" 2
expect_count_le "1b" "C++ flat-map allocations after reserve (total over $inserts inserts)" "$flat_allocs" 0

step "C++: hub lookups of ${HUB} parcels, node-map against flat-map, 3 alternations, perf counts the lookup loop only"
if ((RUN)); then
  n=0
  for v in $(interleave "$ROUNDS" node-map flat-map); do
    n=$((n + 1))
    r="$OUT/cpp/hub-lookup-$v.a$(((n + 1) / 2)).json"
    counted_run "$r" 1 "$TB" --mode lookup --variant "$v" --size "$HUB" --cpu "$CPU" --hold-ms "$HOLD_MS" --out "$r"
  done
  for v in node-map flat-map; do
    counted_run "$OUT/cpp/line-lookup-$v.json" 1 "$TB" --mode lookup --variant "$v" --size "$LINE_SCALE" --samples 2000000 \
      --cpu "$CPU" --hold-ms "$HOLD_MS" --out "$OUT/cpp/line-lookup-$v.json"
  done
fi
collect() { # collect KIND VARIANT: p50 of each alternation, space separated
  local r out=()
  for r in $(seq "$ROUNDS"); do out+=("$(p50_of "$OUT/$1.a$r.json")"); done
  echo "${out[*]}"
}
node_p50s=$(collect cpp/hub-lookup-node-map)
flat_p50s=$(collect cpp/hub-lookup-flat-map)
printf '  hub lookup p50 (ns) by alternation: node-map %s | flat-map %s\n' "$node_p50s" "$flat_p50s"
observe_ratio "2a" "C++ hub lookup p50, node-map / flat-map (median of $ROUNDS)" 2 "$node_p50s" "$flat_p50s"
perf_alt() { # perf_alt KIND VARIANT EVENT: the per-op count of EVENT in each alternation, space separated
  local r out=()
  for r in $(seq "$ROUNDS"); do out+=("$(per_op "$OUT/$1-$2.a$r.json" "$3")"); done
  echo "${out[*]}"
}
for ev in LLC-load-misses L1-dcache-load-misses; do
  if [[ $ev == LLC-load-misses ]]; then
    expect_ratio "2d" "C++ $ev:u per lookup, node-map / flat-map (median of $ROUNDS)" 2 \
      "$(perf_alt cpp/hub-lookup node-map $ev)" "$(perf_alt cpp/hub-lookup flat-map $ev)"
  else
    observe_ratio "2d'" "C++ $ev:u per lookup, node-map / flat-map (median of $ROUNDS)" 2 \
      "$(perf_alt cpp/hub-lookup node-map $ev)" "$(perf_alt cpp/hub-lookup flat-map $ev)"
  fi
done
for v in node-map flat-map; do
  printf '  hub lookup %-9s p50 %s ns, p99 %s ns, p99.9 %s ns; L1 misses/lookup %.3f, LL misses/lookup %.4f (perf, :u)\n' "$v" \
    "$(p50_of "$OUT/cpp/hub-lookup-$v.a1.json")" "$(jget "$OUT/cpp/hub-lookup-$v.a1.json" .percentiles.p99)" \
    "$(jget "$OUT/cpp/hub-lookup-$v.a1.json" .percentiles.p99_9)" "$(per_op "$OUT/cpp/hub-lookup-$v.a1.json" L1-dcache-load-misses)" \
    "$(per_op "$OUT/cpp/hub-lookup-$v.a1.json" LLC-load-misses)"
done
printf '  line-scale lookups (%s parcels, observed; fits L2): node-map p50 %s ns, flat-map p50 %s ns\n' "$LINE_SCALE" \
  "$(p50_of "$OUT/cpp/line-lookup-node-map.json")" "$(p50_of "$OUT/cpp/line-lookup-flat-map.json")"
printf '  build footprint (bytes allocated by the hub build, exact): node-map %s, flat-map %s\n' \
  "$(jget "$OUT/cpp/hub-lookup-node-map.a1.json" .runtime.counters.build_bytes)" \
  "$(jget "$OUT/cpp/hub-lookup-flat-map.a1.json" .runtime.counters.build_bytes)"

step "C++: hub sweep over ${HUB} slots, fat-record against hot-cold, 3 alternations"
if ((RUN)); then
  n=0
  for v in $(interleave "$ROUNDS" fat-record hot-cold); do
    n=$((n + 1))
    r="$OUT/cpp/hub-sweep-$v.a$(((n + 1) / 2)).json"
    counted_run "$r" 1 "$TB" --mode sweep --variant "$v" --size "$HUB" --samples 60 --cpu "$CPU" --hold-ms "$HOLD_MS" --out "$r"
  done
fi
fat_p50s=$(collect cpp/hub-sweep-fat-record)
hot_p50s=$(collect cpp/hub-sweep-hot-cold)
printf '  hub sweep p50 (ns) by alternation: fat-record %s | hot-cold %s\n' "$fat_p50s" "$hot_p50s"
expect_ratio "3a" "C++ hub sweep p50, fat-record / hot-cold (median of $ROUNDS)" 2 "$fat_p50s" "$hot_p50s"
for v in fat-record hot-cold; do
  printf '  hub sweep %-10s p50 %s ns, p99 %s ns; L1 misses/slot %.4f, LL misses/slot %.5f (perf, :u)\n' "$v" \
    "$(p50_of "$OUT/cpp/hub-sweep-$v.a1.json")" "$(jget "$OUT/cpp/hub-sweep-$v.a1.json" .percentiles.p99)" \
    "$(per_op "$OUT/cpp/hub-sweep-$v.a1.json" L1-dcache-load-misses)" "$(per_op "$OUT/cpp/hub-sweep-$v.a1.json" LLC-load-misses)"
done

step "C++: cachegrind (simulated D1 and LL caches; deterministic): lookups and sweeps"
# Sweeps: CACHEGRIND_FUNCTION names the one flattened function, so setup is not counted. Lookups: the node map's hash and key
# compare run in libstdc++ and libc, outside any one function, so a function filter would leave their cache misses out. The
# lookups are therefore measured by difference: the whole run with 200,000 lookups minus the same run with 1, divided by the
# lookups between them (the table build and the untimed warm-up pass are identical in both and cancel).
CG_LOOKUPS=200000
CG_SWEEPS=3
if ((RUN)) && [[ ${SKIP_CACHEGRIND:-0} != 1 ]]; then
  mkdir -p "$OUT/cpp/cachegrind"
  for v in node-map flat-map; do
    for n in "$CG_LOOKUPS" 1; do
      cachegrind_run "$OUT/cpp/cachegrind/hub-lookup-$v.n$n.json" -- \
        "$TB" --mode lookup --variant "$v" --size "$HUB" --samples "$n" --untimed
    done
    jq -n --slurpfile a "$OUT/cpp/cachegrind/hub-lookup-$v.n$CG_LOOKUPS.json" --slurpfile b "$OUT/cpp/cachegrind/hub-lookup-$v.n1.json" '
      ($a[0].ops - $b[0].ops) as $n
      | {source: "cachegrind", ops: $n,
         per_op: ($a[0].totals | with_entries(.value = ((.value - $b[0].totals[.key]) / $n)))}' \
      >"$OUT/cpp/cachegrind/hub-lookup-$v.json"
  done
  for v in fat-record hot-cold; do
    CACHEGRIND_FUNCTION=cg_sweep_${v//-/_} cachegrind_run "$OUT/cpp/cachegrind/hub-sweep-$v.json" -- \
      "$TB" --mode sweep --variant "$v" --size "$HUB" --samples "$CG_SWEEPS" --untimed
  done
fi
if [[ -f $OUT/cpp/cachegrind/hub-lookup-node-map.json ]]; then
  cg() { jget "$OUT/cpp/cachegrind/$1.json" ".per_op[\"$2\"]"; }
  printf '  cachegrind per lookup (difference method): node-map D1 read misses %.3f, LL read misses %.4f | flat-map D1 %.3f, LL %.4f\n' \
    "$(cg hub-lookup-node-map D1-read-misses)" "$(cg hub-lookup-node-map LL-read-misses)" \
    "$(cg hub-lookup-flat-map D1-read-misses)" "$(cg hub-lookup-flat-map LL-read-misses)"
  expect_ratio "2c" "cachegrind LL read misses per lookup, node-map / flat-map" 2 \
    "$(cg hub-lookup-node-map LL-read-misses)" "$(cg hub-lookup-flat-map LL-read-misses)" exact
  printf '  cachegrind per slot (function-level): fat-record D1 read misses %.4f | hot-cold %.4f\n' \
    "$(cg hub-sweep-fat-record D1-read-misses)" "$(cg hub-sweep-hot-cold D1-read-misses)"
  expect_ratio "3c" "cachegrind D1 read misses per slot, fat-record / hot-cold" 4 \
    "$(cg hub-sweep-fat-record D1-read-misses)" "$(cg hub-sweep-hot-cold D1-read-misses)" exact
else
  echo "  (cachegrind skipped)"
fi

# ---- C++ counters ------------------------------------------------------------------------------------------------
step "C++: five camera counters on distinct cores: adjacent-counters against pair-padded, 3 alternations (placement checked)"
if ((RUN)); then
  for inc in store rmw; do
    sfx=''
    [[ $inc == rmw ]] && sfx=.rmw
    n=0
    for v in $(interleave "$ROUNDS" adjacent-counters pair-padded); do
      n=$((n + 1))
      r="$OUT/cpp/counters-$v$sfx.a$(((n + 1) / 2)).json"
      counted_run "$r" 6 "$CB" --variant "$v" --increment "$inc" --cpus "$CPUS6" --batches "$BATCHES" --hold-ms "$HOLD_MS" --out "$r"
    done
  done
  counted_run "$OUT/cpp/counters-line-padded.json" 6 "$CB" --variant line-padded --cpus "$CPUS6" --batches "$BATCHES" \
    --hold-ms "$HOLD_MS" --out "$OUT/cpp/counters-line-padded.json"
  # Two cameras on distinct cores against two on one core's hardware threads (adjacent layout).
  counted_run "$OUT/cpp/counters-adjacent-counters.2-cameras.json" 3 "$CB" --variant adjacent-counters --cameras 2 \
    --cpus "${CORES[0]},${CORES[1]},${CORES[2]}" --batches "$BATCHES" --hold-ms "$HOLD_MS" \
    --out "$OUT/cpp/counters-adjacent-counters.2-cameras.json"
  if ((${#SMT[@]} == 2)); then
    counted_run "$OUT/cpp/counters-smt-siblings.json" 3 "$CB" --variant smt-siblings --cameras 2 \
      --cpus "${SMT[0]},${SMT[1]},${CORES[0]}" --batches "$BATCHES" --hold-ms "$HOLD_MS" --out "$OUT/cpp/counters-smt-siblings.json"
  fi
fi
for inc in store rmw; do
  sfx=''
  [[ $inc == rmw ]] && sfx=.rmw
  adj_p50s=$(collect "cpp/counters-adjacent-counters$sfx")
  pad_p50s=$(collect "cpp/counters-pair-padded$sfx")
  printf '  [%s increment] per-batch (1,000 increments) p50 (ns) by alternation: adjacent-counters %s | pair-padded %s\n' \
    "$inc" "$adj_p50s" "$pad_p50s"
  l1_adj=() l1_pad=()
  for r in $(seq "$ROUNDS"); do
    l1_adj+=("$(per_op "$OUT/cpp/counters-adjacent-counters$sfx.a$r.json" L1-dcache-load-misses)")
    l1_pad+=("$(per_op "$OUT/cpp/counters-pair-padded$sfx.a$r.json" L1-dcache-load-misses)")
  done
  printf '  [%s increment] L1-dcache-load-misses:u per increment: adjacent-counters %s | pair-padded %s\n' "$inc" "${l1_adj[*]}" "${l1_pad[*]}"
  if [[ $inc == rmw ]]; then
    expect_ratio "4a" "C++ counters per-batch p50, adjacent-counters / pair-padded, fetch_add increment (median of $ROUNDS)" 3 "$adj_p50s" "$pad_p50s"
    observe_ratio "4b'" "C++ L1-dcache-load-misses:u per increment, fetch_add increment" 10 "${l1_adj[*]}" "${l1_pad[*]}"
  else
    observe_ratio "4a'" "C++ counters per-batch p50, adjacent-counters / pair-padded, store increment (median of $ROUNDS)" 3 "$adj_p50s" "$pad_p50s"
    expect_ratio "4b" "C++ L1-dcache-load-misses:u per increment, adjacent-counters / pair-padded, store increment (median of $ROUNDS)" 10 \
      "${l1_adj[*]}" "${l1_pad[*]}"
  fi
done
echo "  observed: p99 adjacent-counters (store) $(jget "$OUT/cpp/counters-adjacent-counters.a1.json" .percentiles.p99) ns," \
  "pair-padded $(jget "$OUT/cpp/counters-pair-padded.a1.json" .percentiles.p99) ns"
echo "  observed: line-padded (64 B) p50 $(p50_of "$OUT/cpp/counters-line-padded.json") ns against pair-padded (128 B) p50 $(p50_of "$OUT/cpp/counters-pair-padded.a1.json") ns (store increment)"
if [[ -f $OUT/cpp/counters-smt-siblings.json ]]; then
  echo "  observed: two cameras on SMT siblings p50 $(p50_of "$OUT/cpp/counters-smt-siblings.json") ns," \
    "on distinct cores $(p50_of "$OUT/cpp/counters-adjacent-counters.2-cameras.json") ns (adjacent layout, store increment)"
fi

# ---- C++ line ----------------------------------------------------------------------------------------------------
# run_line_cpp VARIANT PORT: the C++ consumer (hub tracker preloaded, receive thread pinned) against the shared simulator
# (pinned with taskset), 10 kHz x 20 s. The shared simulator and consumer library are not modified.
run_line_cpp() {
  local variant=$1 port=$2 report="$OUT/cpp/line-$1.json" log="$OUT/cpp/line-$1.log" pid sim
  step "line (C++): $variant, hub of ${HUB}, ${RATE} Hz x ${SECONDS_RUN} s, UDP $port"
  : >"${log%.log}.placement"
  LOWLAT_PLACEMENT_FILE=${log%.log}.placement "$LB" --variant "$variant" --preload "$HUB" --cpu "${CORES[0]}" \
    --bind "127.0.0.1:$port" --expect "$COUNT" --example "$EXAMPLE" --report "$report" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_udp_bound "$port" "$pid" "$log"
  check_placement "${log%.log}.placement" 1 "$pid"
  rm -f "${log%.log}.placement"
  taskset -c "${CORES[1]}" "$(cpp_bin line-simulator)" --rate "$RATE" --duration "$SECONDS_RUN" --dest "127.0.0.1:$port" \
    --quiet >>"$log" &
  sim=$!
  bg_track "$sim"
  sleep 1
  assert_placement "$sim" "$sim" "${CORES[1]}"
  wait "$sim" || { tail -20 "$log" >&2; die "the simulator failed"; }
  bg_forget "$sim"
  wait "$pid" || { tail -20 "$log" >&2; die "$variant consumer failed"; }
  bg_forget "$pid"
}
if ((RUN)); then
  run_line_cpp node-map "$PORT_NODE"
  run_line_cpp flat-map "$PORT_FLAT"
fi
step "5. line (C++): allocations per parcel from the tracker on the receive thread"
for v in node-map flat-map; do
  r="$OUT/cpp/line-$v.json"
  printf '  line-%-8s p50 %s ns, p99 %s ns, p99.9 %s ns, max %s ns; tracker allocations %s over %s parcels (%s B)\n' "$v" \
    "$(p50_of "$r")" "$(jget "$r" .percentiles.p99)" "$(jget "$r" .percentiles.p99_9)" "$(jget "$r" .percentiles.max)" \
    "$(jget "$r" .runtime.counters.tracker_allocations)" "$(jget "$r" .runtime.counters.parcels)" \
    "$(jget "$r" .runtime.counters.tracker_allocated_bytes)"
done
node_line=$(jget "$OUT/cpp/line-node-map.json" .runtime.counters.tracker_allocations)
flat_line=$(jget "$OUT/cpp/line-flat-map.json" .runtime.counters.tracker_allocations)
line_parcels=$(jget "$OUT/cpp/line-node-map.json" .runtime.counters.parcels)
expect_count_ge "5a" "C++ node-map allocations per parcel on the receive thread" \
  "$(awk -v a="$node_line" -v n="$line_parcels" 'BEGIN { printf "%.3f", a / n }')" 1
expect_count_le "5b" "C++ flat-map allocations on the receive thread (total over $line_parcels parcels)" "$flat_line" 0
echo "  line end-to-end fits the 480 ms scan-to-divert budget: the worst parcel took $(jget "$OUT/cpp/line-node-map.json" .percentiles.max) ns (node-map)," \
  "$(jget "$OUT/cpp/line-flat-map.json" .percentiles.max) ns (flat-map)"

# ---- Java lane ---------------------------------------------------------------------------------------------------
# jmh_pinned DIR METHOD [PROFILER...]: one JMH benchmark in its own fork on the pinned CPU, in the background; the
# benchmark thread's placement line is asserted while it runs. DIR gets jmh.json, console.txt and the converted reports.
jmh_pinned() {
  local dir=$1 method=$2 pid
  shift 2
  mkdir -p "$dir"
  : >"$dir/placement.txt"
  LOWLAT_PLACEMENT_FILE=$dir/placement.txt java -jar "$JAR" "\\.${method}\$" -rf json -rff "$dir/jmh.json" "$@" \
    -jvmArgsAppend "${JVM[*]} -Dlowlat.cpu=$CPU" >"$dir/console.txt" 2>&1 &
  pid=$!
  bg_track "$pid"
  check_placement "$dir/placement.txt" 1 "$pid"
  wait "$pid" || { grep -q 'Unable to acquire the JMH lock' "$dir/console.txt" && echo "another JMH instance holds /tmp/jmh.lock" >&2
    tail -30 "$dir/console.txt" >&2; die "JMH $method failed"; }
  bg_forget "$pid"
  rm -f "$dir/placement.txt"
}
# convert_jmh DIR [--per-parcel VARIANT]...: JMH json to lowlat reports with the pinned CPU in runtime.placement.
convert_jmh() {
  local dir=$1 f
  shift
  uvrun lowlat-report from-jmh "$dir/jmh.json" "$dir" --example "$EXAMPLE" "$@" >/dev/null
  for f in "$dir"/java-*.json; do
    jq --argjson cpu "$CPU" '.runtime = ((.runtime // {}) + {placement: {cpus: [$cpu], distinct_cores: true, smt_siblings: false}})' \
      "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  done
}

step "Java: JMH insert (line-scale), hub lookups and hub sweeps; 3 alternations each (about 6 minutes)"
if ((RUN)); then
  for group in "insert:InsertBenchmark:insertNodeMap:insertFlatMap" "lookup:HubLookupBenchmark:hubLookupNodeMap:hubLookupFlatMap" \
    "sweep:HubSweepBenchmark:hubSweepFatRecord:hubSweepHotCold"; do
    IFS=: read -r kind _ first second <<<"$group"
    n=0
    for m in $(interleave "$ROUNDS" "$first" "$second"); do
      n=$((n + 1))
      d="$OUT/java/$kind-a$(((n + 1) / 2))-$m"
      step "  JMH $m (alternation $(((n + 1) / 2)) of $ROUNDS)"
      jmh_pinned "$d" "$m" -prof gc
      if [[ $kind == insert ]]; then
        convert_jmh "$d" --per-parcel insert-node-map --per-parcel insert-flat-map
      else
        convert_jmh "$d"
      fi
    done
  done
  # Hardware counters for the lookups through JMH's perfnorm profiler (user-space events): observed.
  for m in hubLookupNodeMap hubLookupFlatMap; do
    d="$OUT/java/perfnorm-$m"
    jmh_pinned "$d" "$m" -prof "perfnorm:events=cycles:u,instructions:u,L1-dcache-load-misses:u,LLC-load-misses:u"
    convert_jmh "$d"
    v=$(sed -E 's/([a-z])([A-Z])/\1-\2/g' <<<"$m" | tr '[:upper:]' '[:lower:]')
    jq --slurpfile j "$d/jmh.json" '.runtime.hw_counters = {source: "perfnorm", ops: .count, per_op:
      ($j[0][0].secondaryMetrics | with_entries(select(.key | test("^(cycles|instructions|L1-dcache-load-misses|LLC-load-misses):u$"))
       | .key |= sub(":u$"; "") | .value |= .score))}' "$d/java-$v.json" >"$d/java-$v.json.tmp" && mv "$d/java-$v.json.tmp" "$d/java-$v.json"
  done
fi
jmh_report() { # jmh_report KIND ALTERNATION METHOD VARIANT
  echo "$OUT/java/$1-a$2-$3/java-$4.json"
}
jmh_collect() { # jmh_collect KIND METHOD VARIANT: p50 of each alternation
  local r out=()
  for r in $(seq "$ROUNDS"); do out+=("$(p50_of "$(jmh_report "$1" "$r" "$2" "$3")")"); done
  echo "${out[*]}"
}

step "Java: 1. allocation per insert (JMH gc profiler, B/op for one insert-and-erase pair)"
node_b=$(jget "$(jmh_report insert 1 insertNodeMap insert-node-map)" .runtime.alloc_bytes_per_parcel)
flat_b=$(jget "$(jmh_report insert 1 insertFlatMap insert-flat-map)" .runtime.alloc_bytes_per_parcel)
printf '  insert-node-map %s B/op, p50 %s ns; insert-flat-map %s B/op, p50 %s ns\n' "$node_b" \
  "$(p50_of "$(jmh_report insert 1 insertNodeMap insert-node-map)")" "$flat_b" "$(p50_of "$(jmh_report insert 1 insertFlatMap insert-flat-map)")"
expect_count_ge "1c" "JMH node-map allocated bytes per insert" "$node_b" 64
expect_count_le "1d" "JMH flat-map allocated bytes per insert" "$flat_b" 1

step "Java: 2. hub lookups, node-map against flat-map (JMH SampleTime, pinned)"
jl_node=$(jmh_collect lookup hubLookupNodeMap hub-lookup-node-map)
jl_flat=$(jmh_collect lookup hubLookupFlatMap hub-lookup-flat-map)
printf '  hub lookup p50 (ns) by alternation: node-map %s | flat-map %s\n' "$jl_node" "$jl_flat"
observe_ratio "2b" "Java hub lookup p50, node-map / flat-map (median of $ROUNDS)" 2 "$jl_node" "$jl_flat"
for pair in "hubLookupNodeMap hub-lookup-node-map" "hubLookupFlatMap hub-lookup-flat-map"; do
  read -r m v <<<"$pair"
  r=$(jmh_report lookup 1 "$m" "$v")
  printf '  %-20s p99 %s ns, p99.9 %s ns\n' "$v" "$(jget "$r" .percentiles.p99)" "$(jget "$r" .percentiles.p99_9)"
done

step "Java: 3. hub sweep, fat-record (ParcelState[]) against hot-cold (primitive arrays)"
js_fat=$(jmh_collect sweep hubSweepFatRecord hub-sweep-fat-record)
js_hot=$(jmh_collect sweep hubSweepHotCold hub-sweep-hot-cold)
printf '  hub sweep p50 (ns) by alternation: fat-record %s | hot-cold %s\n' "$js_fat" "$js_hot"
expect_ratio "3b" "Java hub sweep p50, fat-record / hot-cold (median of $ROUNDS)" 2 "$js_fat" "$js_hot"
for r in $(seq "$ROUNDS"); do
  for pair in "hubSweepFatRecord hubSweepFatRecord" "hubSweepHotCold hubSweepHotCold"; do
    read -r m _ <<<"$pair"
    collections=$(jq -er --arg m ".$m" '[.[] | select(.benchmark | endswith($m)) | .secondaryMetrics["gc.count"].score]
      | if length == 1 then .[0] else error("expected one gc.count row") end' "$OUT/java/sweep-a$r-$m/jmh.json") || die "no gc.count for $m"
    holds '$c == 0' "3 $m (alternation $r) ran without a garbage collection (gc.count $collections)" --argjson c "$collections"
  done
done

for m in hubLookupNodeMap hubLookupFlatMap; do
  f=$OUT/java/perfnorm-$m/jmh.json
  printf '  perfnorm %-18s per lookup:' "$m"
  jq -r '.[0].secondaryMetrics | to_entries[] | select(.key | test("L1-dcache|LLC|cycles|instructions")) | " \(.key) \(.value.score)"' "$f" | tr '\n' ';'
  echo
done

# ---- Java counters and line --------------------------------------------------------------------------------------
step "Java: five camera counters on distinct cores: adjacent-counters against pair-padded, 3 alternations (placement checked)"
if ((RUN)); then
  for inc in store rmw; do
    sfx=''
    [[ $inc == rmw ]] && sfx=.rmw
    n=0
    for v in $(interleave "$ROUNDS" adjacent-counters pair-padded); do
      n=$((n + 1))
      r="$OUT/java/counters-$v$sfx.a$(((n + 1) / 2)).json"
      counted_run "$r" 6 java "${JVM[@]}" -cp "$JAR" "$MAIN" counters --variant "$v" --increment "$inc" --cpus "$CPUS6" \
        --batches "$BATCHES" --hold-ms "$HOLD_MS" --out "$r"
    done
  done
  counted_run "$OUT/java/counters-line-padded.json" 6 java "${JVM[@]}" -cp "$JAR" "$MAIN" counters --variant line-padded \
    --cpus "$CPUS6" --batches "$BATCHES" --hold-ms "$HOLD_MS" --out "$OUT/java/counters-line-padded.json"
  counted_run "$OUT/java/counters-long-adder.json" 6 java "${JVM[@]}" -cp "$JAR" "$MAIN" counters --variant long-adder \
    --cpus "$CPUS6" --batches "$BATCHES" --hold-ms "$HOLD_MS" --out "$OUT/java/counters-long-adder.json"
  if ((${#SMT[@]} == 2)); then
    counted_run "$OUT/java/counters-smt-siblings.json" 3 java "${JVM[@]}" -cp "$JAR" "$MAIN" counters --variant smt-siblings \
      --cameras 2 --cpus "${SMT[0]},${SMT[1]},${CORES[0]}" --batches "$BATCHES" --hold-ms "$HOLD_MS" \
      --out "$OUT/java/counters-smt-siblings.json"
  fi
fi
for inc in store rmw; do
  sfx=''
  [[ $inc == rmw ]] && sfx=.rmw
  jc_adj=$(collect "java/counters-adjacent-counters$sfx")
  jc_pad=$(collect "java/counters-pair-padded$sfx")
  printf '  [%s increment] per-batch p50 (ns) by alternation: adjacent-counters %s | pair-padded %s\n' "$inc" "$jc_adj" "$jc_pad"
  jl1_adj=() jl1_pad=()
  for r in $(seq "$ROUNDS"); do
    jl1_adj+=("$(per_op "$OUT/java/counters-adjacent-counters$sfx.a$r.json" L1-dcache-load-misses)")
    jl1_pad+=("$(per_op "$OUT/java/counters-pair-padded$sfx.a$r.json" L1-dcache-load-misses)")
  done
  printf '  [%s increment] L1-dcache-load-misses:u per increment: adjacent-counters %s | pair-padded %s\n' "$inc" "${jl1_adj[*]}" "${jl1_pad[*]}"
  if [[ $inc == store ]]; then
    observe_ratio "4c'" "Java counters per-batch p50, adjacent-counters / pair-padded, store increment (median of $ROUNDS)" 3 "$jc_adj" "$jc_pad"
    expect_ratio "4c" "Java L1-dcache-load-misses:u per increment, adjacent-counters / pair-padded, store increment (median of $ROUNDS)" 10 \
      "${jl1_adj[*]}" "${jl1_pad[*]}"
  else
    observe_ratio "4c''" "Java counters per-batch p50, adjacent-counters / pair-padded, getAndAdd increment (median of $ROUNDS)" 3 "$jc_adj" "$jc_pad"
  fi
done
echo "  observed: line-padded p50 $(p50_of "$OUT/java/counters-line-padded.json") ns; long-adder (one shared sum) p50" \
  "$(p50_of "$OUT/java/counters-long-adder.json") ns"
if [[ -f $OUT/java/counters-smt-siblings.json ]]; then
  echo "  observed: two cameras on SMT siblings p50 $(p50_of "$OUT/java/counters-smt-siblings.json") ns"
fi

run_line_java() {
  local variant=$1 port=$2 report="$OUT/java/line-$1.json" log="$OUT/java/line-$1.log" pid sim
  step "line (Java): $variant, hub of ${HUB}, ${RATE} Hz x ${SECONDS_RUN} s, UDP $port"
  : >"${log%.log}.placement"
  LOWLAT_PLACEMENT_FILE=${log%.log}.placement java "${JVM[@]}" -cp "$JAR" "$MAIN" consume --variant "$variant" \
    --preload "$HUB" --cpu "${CORES[0]}" --bind "127.0.0.1:$port" --expect "$COUNT" --example "$EXAMPLE" \
    --report "$report" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_udp_bound "$port" "$pid" "$log" 900
  check_placement "${log%.log}.placement" 1 "$pid"
  rm -f "${log%.log}.placement"
  taskset -c "${CORES[1]}" "$(cpp_bin line-simulator)" --rate "$RATE" --duration "$SECONDS_RUN" --dest "127.0.0.1:$port" \
    --quiet >>"$log" &
  sim=$!
  bg_track "$sim"
  wait "$sim" || { tail -20 "$log" >&2; die "the simulator failed"; }
  bg_forget "$sim"
  wait "$pid" || { tail -20 "$log" >&2; die "$variant Java consumer failed"; }
  bg_forget "$pid"
}
if ((RUN)); then
  run_line_java node-map "$PORT_NODE"
  run_line_java flat-map "$PORT_FLAT"
fi
step "line (Java, observed): end-to-end percentiles and receive-thread allocation per parcel"
for v in node-map flat-map; do
  r="$OUT/java/line-$v.json"
  printf '  line-%-8s p50 %s ns, p99 %s ns, p99.9 %s ns, max %s ns; receive thread allocated %s B/parcel (decode dominates)\n' "$v" \
    "$(p50_of "$r")" "$(jget "$r" .percentiles.p99)" "$(jget "$r" .percentiles.p99_9)" "$(jget "$r" .percentiles.max)" \
    "$(jget "$r" .runtime.alloc_bytes_per_parcel)"
done

step "Java: JOL footprint (observed)"
if ((RUN)); then
  java "${JVM[@]}" -Djol.magicFieldOffset=true -Djdk.attach.allowAttachSelf=true -cp "$JAR" "$MAIN" footprint \
    >"$OUT/java/footprint.json" 2>"$OUT/java/footprint.err"
fi
jq -r '"  ParcelState \(.parcel_state_instance_bytes) B per object; \(.parcels) parcels: node-map tracker \(.node_map_bytes_per_parcel) B per parcel, flat-map tracker \(.flat_map_bytes_per_parcel) B per parcel"' "$OUT/java/footprint.json"

# ---- Python lane -------------------------------------------------------------------------------------------------
step "Python: bytes per tracked parcel, dict-per-parcel against slots (tracemalloc)"
if ((RUN)); then
  uvrun --package lowlat-locality locality-py footprint --parcels 100000 --out "$OUT/python/footprint.json"
fi
dict_b=$(jget "$OUT/python/footprint.json" '.tracked_bytes["dict-per-parcel"]')
expect_ratio "1e" "Python record object bytes (sys.getsizeof), dict / slotted record" 2 \
  "$(jget "$OUT/python/footprint.json" '.record_container_bytes["dict-per-parcel"]')" \
  "$(jget "$OUT/python/footprint.json" '.record_container_bytes["slots-int"]')" exact
expect_ratio "1f" "Python dict-per-parcel / slots-int bytes per tracked parcel" 2 "$dict_b" \
  "$(jget "$OUT/python/footprint.json" '.tracked_bytes["slots-int"]')" exact
observe_ratio "1f'" "Python dict-per-parcel / slots-str bytes per tracked parcel (the str key is a cost both share)" 2 "$dict_b" \
  "$(jget "$OUT/python/footprint.json" '.tracked_bytes["slots-str"]')"
echo "  record only (observed): dict-per-parcel $(jget "$OUT/python/footprint.json" '.record_only_bytes["dict-per-parcel"]') B," \
  "slots $(jget "$OUT/python/footprint.json" '.record_only_bytes["slots-int"]') B for $(jget "$OUT/python/footprint.json" .parcels) parcels"

step "Python (observed): due sweep, list of objects against array columns; counters in processes and threads"
if ((RUN)); then
  for v in fat-record hot-cold; do
    pinned_bg "$OUT/python/hub-sweep-$v.log" 1 uvrun --package lowlat-locality locality-py sweep --variant "$v" --size "$HUB" \
      --samples 20 --cpu "$CPU" --hold-ms "$HOLD_MS" --out "$OUT/python/hub-sweep-$v.json"
  done
  PYCPUS=$(IFS=,; echo "${CORES[*]:0:5}")
  FT=$(command -v python3.14t || true)
  for v in adjacent-counters pair-padded; do
    # The measured process writes only raw batch times (no HdrHistogram import); the report is built afterwards.
    raw="$OUT/python/counters-processes-$v.raw.json"
    pinned_bg "$OUT/python/counters-processes-$v.log" 5 uvrun --package lowlat-locality locality-py counters --layout "$v" \
      --mode processes --cpus "$PYCPUS" --batches 3000 --hold-ms "$HOLD_MS" --out "$raw"
    uvrun --package lowlat-locality locality-py counters-report "$raw" --out "$OUT/python/counters-processes-$v.json" >/dev/null
    rm -f "$raw"
    # Threads: the GIL build, then the free-threaded build.
    raw="$OUT/python/counters-threads-$v.raw.json"
    pinned_bg "$OUT/python/counters-threads-gil-$v.log" 5 uvrun --package lowlat-locality locality-py counters --layout "$v" \
      --mode threads --cpus "$PYCPUS" --batches 3000 --hold-ms "$HOLD_MS" --out "$raw"
    uvrun --package lowlat-locality locality-py counters-report "$raw" --out "$OUT/python/counters-threads-gil-$v.json" >/dev/null
    rm -f "$raw"
    if [[ -n $FT ]]; then
      PYTHONPATH="$HERE/locality-py/src" pinned_bg "$OUT/python/counters-threads-free-threaded-$v.log" 5 "$FT" -m lowlat_locality \
        counters --layout "$v" --mode threads --cpus "$PYCPUS" --batches 3000 --hold-ms "$HOLD_MS" --out "$raw"
      jq -e '.gil_enabled == false' "$raw" >/dev/null || die "the free-threaded interpreter re-enabled the GIL"
      uvrun --package lowlat-locality locality-py counters-report "$raw" \
        --out "$OUT/python/counters-threads-free-threaded-$v.json" >/dev/null
      rm -f "$raw"
    fi
  done
fi
for f in "$OUT"/python/hub-sweep-*.json "$OUT"/python/counters-*.json; do
  [[ -f $f ]] || continue
  printf '  %-40s p50 %s ns, p99 %s ns\n' "$(basename "$f" .json)" "$(p50_of "$f")" "$(jget "$f" .percentiles.p99)"
done

# ---- 6. reports ---------------------------------------------------------------------------------------------------
step "6. reports: schema, histogram decode, percentile recompute; counts, drops, JVM flags, placement"
mapfile -t reports < <(find "$OUT"/{cpp,java,python} -name '*.json' ! -name 'jmh.json' ! -name 'footprint.json' \
  -exec grep -lE '"schema" ?: ?"lowlat-report/1"' {} + | sort -u)
if report_check "${reports[@]}" >/dev/null; then
  ok "6 ${#reports[@]} reports validate (profile embedded: $(jget "${reports[0]}" .profile.host_label))"
else
  bad "6 lowlat-report check failed"
fi
line_ok=1
for lang in cpp java; do
  for v in node-map flat-map; do
    r="$OUT/$lang/line-$v.json"
    [[ $(jget "$r" .count) -eq $COUNT ]] || { bad "6 $lang line-$v: count != $COUNT"; line_ok=0; }
    [[ $(jget "$r" .dropped) -eq 0 ]] || { bad "6 $lang line-$v: parcels were dropped"; line_ok=0; }
  done
done
if ((line_ok)); then ok "6 line runs: count = $COUNT and dropped = 0 in all four (C++ and Java, both variants)"; fi
flags_ok=1
for r in "${reports[@]}"; do
  if [[ $(jget "$r" .language) == java ]]; then
    jq -e '.build.flags | length > 0' "$r" >/dev/null || { bad "6 $(basename "$r"): build.flags missing"; flags_ok=0; }
  fi
done
if ((flags_ok)); then ok "6 every Java report carries build.flags"; fi
pinned_ok=1
for r in "${reports[@]}"; do
  jq -e '.runtime.placement.cpus | length > 0' "$r" >/dev/null 2>&1 || { bad "6 $(basename "$r"): runtime.placement.cpus missing"; pinned_ok=0; }
done
if ((pinned_ok)); then ok "6 every pinned report carries runtime.placement.cpus"; fi

((FAILURES == 0)) || die "$FAILURES criteria failed: the effect was not (fully) observed"
ok "09-eliminating-work: every criterion holds; results in $OUT"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
