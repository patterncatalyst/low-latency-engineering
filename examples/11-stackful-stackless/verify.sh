#!/usr/bin/env bash
# Ch11 verify: who holds the wait, on the scan-to-divert path's 2 ms warehouse-system lookup (C++, Java, Python).
#
# Every criterion is evaluated; each prints its measured value, its bound and the margin, and any miss fails the run
# after all of them have been evaluated. Latency ratios compare variants within THIS run: the variants alternate
# (A B C A B C A B C) and the criterion is the median of the three per-alternation ratios. Counters labelled "exact"
# are deterministic and need no median; the start-gate skew is a timing bound, not an exact count. A p50 is never compared
# across runs. The bounds sit in variables below; they are provisional (S10 calibrates them, see _plans/r04-plan.md).
#   1  memory per waiting task, on the quantity that shows the gap: C++ os-thread over fiber on address space per task
#      (>= 10x); C++ fiber stack bytes over the counted coroutine frame bytes (>= 10x); C++ coroutine frame bytes (exact, a
#      counting promise operator new on frames that escape into a vector) <= 1,024 with one allocation per frame (exact);
#      Java platform-thread address space per task over virtual-thread heap per task (MemoryMXBean after a forced collection,
#      >= 10x); Python thread RSS over asyncio task bytes (measured by tracemalloc, not exact), >= 5x in each build
#   2  parked tasks armed when the memory was read: C++ fiber and coroutine, 10,000 of 10,000 (exact). Every RSS ratio
#      (a parked thread's resident cost is a page or two) is printed as observed, with the plan's 10x beside it.
#   3  voluntary context switches per round trip (exact counts from /proc): C++ os-thread >= 0.9, fiber and
#      coroutine <= 0.001
#   4  round-trip p50, median of 3 alternations: C++ os-thread over fiber and over coroutine, Java platform-thread
#      over virtual-thread
#   5  the blocking call: Python debug mode logs exactly one slow-callback warning per blocking call (exact); C++
#      --blocking-sleep-in-fiber pushes the neighbours' wake-lateness p99 to >= 1 ms for a 2 ms call (2x by construction).
#      Observed: Python p99 and its blocking/baseline ratio (asyncio rounds its epoll timeout up to 1 ms, so a baseline p99
#      already sits near 1 ms), and the fraction of wakes later than 1.5 ms, blocking against baseline.
#   6  line, one simulator instance at 10 kHz x 20 s (200,000 parcels) per variant, UDP 47310-47314: count 200,000,
#      dropped 0, every divert command received. End-to-end percentiles are observed.
#   7  every report: lowlat-report check, count > 0, dropped = 0, build.flags (C++ and Java), runtime.placement
#      (pinned runs), runtime.python_build (Python), the start gate's skew < 1 ms (a timing bound, recorded in each
#      pinned run with two or more threads), round trips served == configured (exact), free-threaded runs with the GIL off.
# Observed, not asserted: the other lanes' neighbour lateness, std::binary_semaphore against condition_variable,
# HALO on a coroutine that does not escape, Java VirtualThreadPinned counts (synchronized block against a native frame),
# Python hand-off and the free-threaded build against the GIL build, page-table and kernel-stack bytes per task,
# line percentiles.
#
#   ./verify.sh                 build, run, assert
#   RECHECK=results/<run-id>    re-evaluate the committed reports without building or running anything
#   ALLOW_BUSY=1 ./verify.sh    measure while a lab VM or other load is running (noisy)
#   SKIP_BUILD=1 ./verify.sh    reuse existing builds
#   SMOKE=1 RESULTS_DIR=DIR     small workloads, a check of this script (not a measurement, nothing enforced)
#   RESULTS_DIR=DIR             where reports go (default results/latest)
#   LOWLAT_BUILD=DIR            private C++ build directory
#
# Run it under the host benchmark lock when another example measures on this host, and give flock -o so the lock
#   flock -o "$LOCK" ./verify.sh
# is not inherited by the script or anything it starts (an orphan that outlived a run would otherwise keep the lock).
# On TERM or INT the script stops its whole process tree before it exits. UDP ports 47310 (C++ os-thread),
# 47311 (fiber), 47312 (coroutine), 47313 (platform-thread), 47314 (virtual-thread) on 127.0.0.1. Threads are pinned to
# distinct physical cores with sched_setaffinity as an experiment control; that is not isolation. Never changes the
# host: no sudo, no sysctl, no governor. The free-threaded interpreter is a user-local download: `uv python install 3.14t`.
# shellcheck disable=SC2016
set -euo pipefail
trap 'exit 143' TERM
trap 'exit 130' INT
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

EXAMPLE=11-stackful-stackless
HERE=$(example_dir)
JAR=$HERE/java/target/stackful-stackless-java.jar

# ---- workloads (plan section 2, Ch11) ---------------------------------------------------------------------------
TASKS=10000          # parked tasks per variant
WAIT_MS=1000         # their shared timer
ROUNDS=1000000       # ping-pong round trips ...
BATCH=1000           # ... in batches of this size
NEIGH_TASKS=1000     # tasks on 2 ms timers
NEIGH_ITER=500
PY_NEIGH_TASKS=50    # asyncio can't wake 1,000 tasks every 2 ms (about 75,000 wakes a second at most): same 2 ms timers, fewer tasks
LINE_RATE=10000
LINE_SECONDS=20
HOLD_MS=500          # how long pinned threads wait for the /proc check
if [[ ${SMOKE:-0} == 1 ]]; then
  # A check of this script, not a measurement: small workloads, every criterion evaluated and printed, none enforced.
  [[ -n ${RESULTS_DIR:-} ]] || { echo "SMOKE=1 needs RESULTS_DIR (it must not overwrite results/latest)" >&2; exit 2; }
  TASKS=300 WAIT_MS=300 ROUNDS=20000 NEIGH_TASKS=100 NEIGH_ITER=100 PY_NEIGH_TASKS=20 LINE_SECONDS=2 HOLD_MS=100
fi
LINE_COUNT=$((LINE_RATE * LINE_SECONDS))
PORT_CPP_OS_THREAD=47310
PORT_CPP_FIBER=47311
PORT_CPP_COROUTINE=47312
PORT_JAVA_PLATFORM=47313
PORT_JAVA_VIRTUAL=47314
ROUNDS_ALT=3
CPP_VARIANTS=(os-thread fiber coroutine)
JAVA_VARIANTS=(platform-thread virtual-thread)
PY_VARIANTS=(threads asyncio-tasks)

# ---- provisional bounds (S10 calibrates). Ratios are in thousandths. -------------------------------------------------
FRAME_BYTES_MAX=1024                    # plan 1,024
CPP_ADDRESS_THREAD_OVER_FIBER_MILLI=10000   # os-thread >= 10x fiber, on address space per task (the plan's 10x; RSS is observed)
CPP_FIBER_STACK_OVER_FRAME_MILLI=10000  # fiber stack bytes per task >= 10x the counted coroutine frame bytes
JAVA_ADDRESS_OVER_VT_HEAP_MILLI=10000   # platform-thread address space per task >= 10x virtual-thread heap per task
PY_TASK_FRACTION_MILLI=5000             # thread RSS >= 5x asyncio task bytes, in each build
CTX_OS_THREAD_MIN_MILLI=900             # plan: >= 0.9 voluntary switches per round trip
CTX_SAME_THREAD_MAX_MICRO=1000          # plan: <= 0.001 (in millionths)
PINGPONG_CPP_MILLI=5000                 # plan: os-thread >= 5x fiber and >= 5x coroutine
PINGPONG_JAVA_MILLI=2000                # plan: platform-thread >= 2x virtual-thread
NEIGHBOUR_P99_MIN_NS=1000000            # plan: >= 1 ms for a 2 ms blocking call (C++ fiber)
PY_LATE_FRACTION_RATIO_MILLI=2000       # Python wakes later than 1.5 ms, blocking over baseline; asserted only with 2x margin
PY_LATE_FRACTION_ASSERTED=1             # set from the full-size runs: 1 when the ratio clears twice this bound
START_SKEW_MAX_NS=1000000               # a timing bound: the gate's skew is < 1 ms
PLAN_RSS_MILLI=10000                    # the plan's 10x on RSS, printed beside the observed RSS ratios

# The JVM for every Java run: a fixed heap so no resize starts inside a measured run, native access for the affinity and
# FFM calls. The parked runs do not pre-touch the heap, so the RSS they read is the memory the tasks really touched.
JVM=(-Xms1g -Xmx1g -XX:+UseG1GC --enable-native-access=ALL-UNNAMED)
JVM_LATENCY=(-XX:+AlwaysPreTouch "${JVM[@]}")
VT_ONE_CARRIER=(-Djdk.virtualThreadScheduler.parallelism=1)

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
  mkdir -p "$OUT/python"
  capture_profile "$OUT"
  # Driver logs are written outside the results directory (this script clears *.log there) and moved in at the end.
  scratch_dir
  LOGS=$LOWLAT_SCRATCH/logs
  mkdir -p "$LOGS"
fi
finish_logs() {
  if [[ -n ${LOGS:-} && -d $LOGS ]]; then
    find "$LOGS" -maxdepth 1 -name '*.log' -exec mv -t "$OUT" {} + 2>/dev/null || true
  fi
}
trap 'finish_logs; _bg_cleanup' EXIT

# ---- helpers (the criterion printers follow example 10) ------------------------------------------------------------

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
# crit_ratio ID DESC "A over B" RATIO_MILLI BOUND_MILLI: ratio >= bound, both in thousandths.
crit_ratio() {
  local m
  m=$(margin "$4" "$5")
  if (($4 >= $5)); then
    ok "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x$(note_margin "$m")"
  else
    bad "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x"
  fi
}

p50() { jget "$1" .percentiles.p50; }
p99() { jget "$1" .percentiles.p99; }
counter() { jget "$1" ".runtime.counters.$2"; }
# ratio_milli NUM DEN: NUM / DEN in thousandths (DEN of 0 counts as 1).
# A zero or negative denominator is a failure of the measurement: it prints 0 (so any >= bound fails) and is recorded in
# $RATIO_FAULTS, which the end of the run turns into a failed criterion (a $(...) cannot raise the failure itself).
ratio_milli() {
  if (($2 <= 0)); then
    echo "ratio_milli: denominator $2 for numerator $1" >>"$RATIO_FAULTS"
    echo 0
  else
    echo $((1000 * $1 / $2))
  fi
}
median_of() { median_ns "$@"; }
RATIO_FAULTS=$(mktemp "${TMPDIR:-/tmp}/lowlat-ratio.XXXXXX")
min_of() { printf '%s\n' "$@" | sort -n | head -1; }
# pct_line FILE: "p50 / p99 / p99.9 / max" in ns.
pct_line() { jget "$1" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9) / \(.percentiles.max)"'; }

# check_pins LOG COUNT: every "pinned pid=P tid=T cpu=C" line of LOG is checked against /proc/P/task/T/stat.
check_pins() {
  local log=$1 want=$2 line n=0
  while read -r line; do
    [[ $line =~ pid=([0-9]+)\ tid=([0-9]+)\ cpu=([0-9]+) ]] || die "unparseable pinned line: $line"
    assert_placement "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >/dev/null
    n=$((n + 1))
  done < <(grep '^pinned ' "$log" || true)
  ((n == want)) || die "expected $want pinned threads in $log, found $n"
  ok "placement: $n threads of $(basename "$log" .log) run on the CPUs they were pinned to"
}

# run_pinned LOG COUNT CMD...: run CMD, which pins its threads, prints "pinned ..." and "placement-ready", holds, and
# goes; the pins are verified from /proc during the hold. COUNT may be 0: a run with nothing pinned prints the markers too.
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

# run_plain LOG CMD...: run CMD to the end with its output in LOG.
run_plain() {
  local log=$1
  shift
  "$@" >"$log" 2>&1 || { tail -30 "$log" >&2; die "failed: $*"; }
}

# each_alt VARIANTS...: for ROUNDS_ALT alternations of the variants, call `alt_run VARIANT N` in interleaved order.
each_alt() {
  local -A seen=()
  local v
  while read -r v; do
    seen[$v]=$((${seen[$v]:-0} + 1))
    alt_run "$v" "${seen[$v]}"
  done < <(interleave "$ROUNDS_ALT" "$@")
}

# idle_cores N: print N logical CPUs, one per physical core, CPU 0 left out, each less than IDLE_MAX_PCT busy over a one second
# sample of /proc/stat (user, nice, system, irq, softirq and steal against the total). A pinned thread that shares its core with
# another process waits behind it for a scheduling slice at every hand-off, so a core in use isn't a measurement. ALLOW_BUSY=1
# takes the first N cores without looking.
IDLE_MAX_PCT=10
idle_cores() {
  local want=$1 total=16 all c line
  local -A busy_a tot_a
  local -a picked=()
  while ((total >= want + 1)); do
    all=$(distinct_cores "$total" 2>/dev/null) && break
    total=$((total - 1))
  done
  [[ -n ${all:-} ]] || die "need $((want + 1)) distinct physical cores (CPU 0 is left alone)"
  if [[ ${ALLOW_BUSY:-0} == 1 ]]; then
    awk '$1 != 0' <<<"$all" | head -n "$want"
    return 0
  fi
  while read -r c b t; do busy_a[$c]=$b tot_a[$c]=$t; done < <(awk '/^cpu[0-9]/ { b = $2 + $3 + $4 + $7 + $8 + $9; print substr($1, 4), b, b + $5 + $6 }' /proc/stat)
  sleep 1
  while read -r c b t; do
    [[ -n ${busy_a[$c]:-} ]] || continue
    ((t > tot_a[$c])) || continue
    pct=$((100 * (b - busy_a[$c]) / (t - tot_a[$c])))
    if grep -qx "$c" <<<"$all" && ((c != 0)); then
      if ((pct < IDLE_MAX_PCT)); then picked+=("$c"); else echo "idle_cores: CPU $c is ${pct}% busy, not using it" >&2; fi
    fi
  done < <(awk '/^cpu[0-9]/ { b = $2 + $3 + $4 + $7 + $8 + $9; print substr($1, 4), b, b + $5 + $6 }' /proc/stat)
  ((${#picked[@]} >= want)) || die "only ${#picked[@]} idle physical cores other than CPU 0 (need $want): something else is using the host; ALLOW_BUSY=1 measures anyway"
  printf '%s\n' "${picked[@]:0:$want}"
}

# pins_for MODEL: how many threads the model pins in a micro run.
cpp_pins_parked() { [[ $1 == os-thread ]] && echo 0 || echo 1; }
cpp_pins_pingpong() { [[ $1 == os-thread ]] && echo 2 || echo 1; }

# ---- build and unit tests ------------------------------------------------------------------------------------------
if ((RUN)); then
  uv python find 3.14t >/dev/null 2>&1 || die "no free-threaded Python: uv python install 3.14t (a user-local download)"
  build_cpp tasks-bench tasks-line tasks-test line-simulator
  BUILD_JAVA_TESTS=1 build_java "$HERE/java" # the Java tests run on the way
  py_sync
  [[ -f $JAR ]] || die "missing $JAR (build_java first)"

  step "unit tests: C++ (GoogleTest), Python under the GIL and under the free-threaded build; Java ran during the package step"
  "$(cpp_bin tasks-test)" --gtest_brief=1 >"$LOGS/cpp-unit-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-unit-tests.log" >&2; die "C++ unit tests failed"; }
  uvrun pytest -q "$HERE/tasks-py/tests" >"$LOGS/python-unit-tests-gil.log" 2>&1 || { tail -20 "$LOGS/python-unit-tests-gil.log" >&2; die "Python (GIL) tests failed"; }
  (cd "$LOWLAT_EXAMPLES" && LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$LOWLAT_EXAMPLES/.venv-ft \
    uv run -q --python 3.14t --all-packages pytest -q "$HERE/tasks-py/tests") >"$LOGS/python-unit-tests-free-threaded.log" 2>&1 ||
    { tail -20 "$LOGS/python-unit-tests-free-threaded.log" >&2; die "Python (free-threaded) tests failed"; }
  ok "C++, Java and Python (both builds) unit tests pass"
  BENCH=$(cpp_bin tasks-bench)
  LINE_CPP=$(cpp_bin tasks-line)
  # Two distinct physical cores, CPU 0 excluded (examples 09 and 10 do the same), that nothing else is using right now.
  mapfile -t CORES < <(idle_cores 2)
  ((${#CORES[@]} == 2)) || die "need 2 idle distinct physical cores other than CPU 0"
  CPUS=$(paste -sd, < <(printf '%s\n' "${CORES[@]}"))
  ok "pinned threads use CPUs $CPUS (distinct physical cores, idle when chosen)"
fi

# ---- (a) parked tasks ----------------------------------------------------------------------------------------------
if ((RUN)); then
  for v in "${CPP_VARIANTS[@]}"; do
    step "C++ parked: $v, $TASKS tasks on a ${WAIT_MS} ms timer"
    run_pinned "$LOGS/cpp-parked-$v.log" "$(cpp_pins_parked "$v")" "$BENCH" parked --variant "$v" --tasks "$TASKS" --wait-ms "$WAIT_MS" \
      --cpus "${CORES[0]}" --hold-ms "$HOLD_MS" --report "$OUT/cpp-parked-$v.json"
  done
  for v in "${JAVA_VARIANTS[@]}"; do
    step "Java parked: $v, $TASKS tasks on a ${WAIT_MS} ms timer"
    run_pinned "$LOGS/java-parked-$v.log" 0 java "${JVM[@]}" -jar "$JAR" parked --variant "$v" --tasks "$TASKS" --wait-ms "$WAIT_MS" \
      --hold-ms "$HOLD_MS" --report "$OUT/java-parked-$v.json"
  done
fi

# ---- Python (both builds) ----------------------------------------------------------------------------------------
# py_measure BUILD LOG PINS RAWDIR ARGS...: measure in the named build (no lowlat_measure in the measuring process).
py_measure() {
  local build=$1 log=$2 pins=$3 raw=$4
  shift 4
  local cmd=(tasks-py measure "$@" --out "$raw" --hold-ms "$HOLD_MS")
  if [[ $build == free-threaded ]]; then
    run_pinned "$log" "$pins" env UV_PROJECT_ENVIRONMENT="$LOWLAT_EXAMPLES/.venv-ft" \
      uv --directory "$LOWLAT_EXAMPLES" run -q --python 3.14t --package lowlat-tasks "${cmd[@]}"
  else
    # env -C execs uv itself, so the background PID is uv's and there is no subshell between it and python.
    run_pinned "$log" "$pins" env -C "$LOWLAT_EXAMPLES" uv run -q "${cmd[@]}"
  fi
}
# py_run BUILD NAME PINS ARGS...: measure, then convert the raw samples to python/python-BUILD-NAME.json in the GIL environment.
py_run() {
  local build=$1 name=$2 pins=$3 raw
  shift 3
  raw=$LOWLAT_SCRATCH/py-$build-$name
  step "Python $name in the $build build"
  py_measure "$build" "$LOGS/python-$build-$name.log" "$pins" "$raw" "$@"
  from_samples "$raw/samples.bin" "$raw/sidecar.json" "$OUT/python/python-$build-$name.json"
}
if ((RUN)); then
  for build in gil free-threaded; do
    py_run "$build" parked-threads 0 parked --variant threads --tasks "$TASKS" --wait-ms "$WAIT_MS"
    py_run "$build" parked-asyncio-tasks 1 parked --variant asyncio-tasks --tasks "$TASKS" --wait-ms "$WAIT_MS" --cpus "${CORES[0]}"
    py_run "$build" pingpong-threads 2 pingpong --variant threads --rounds "$ROUNDS" --batch "$BATCH" --cpus "$CPUS"
    py_run "$build" pingpong-asyncio-tasks 1 pingpong --variant asyncio-tasks --rounds "$ROUNDS" --batch "$BATCH" --cpus "${CORES[0]}"
  done
  # The blocking call (GIL build): without it, with it, and with it under asyncio's debug mode (the warning count).
  py_run gil neighbours-asyncio-tasks 1 neighbours --variant asyncio-tasks --tasks "$PY_NEIGH_TASKS" --iterations "$NEIGH_ITER" --cpus "${CORES[0]}"
  py_run gil neighbours-asyncio-tasks-blocking 1 neighbours --variant asyncio-tasks --tasks "$PY_NEIGH_TASKS" --iterations "$NEIGH_ITER" \
    --blocking-sleep-in-coroutine --cpus "${CORES[0]}"
  py_run gil neighbours-asyncio-tasks-blocking-debug 1 neighbours --variant asyncio-tasks --tasks "$PY_NEIGH_TASKS" --iterations "$NEIGH_ITER" \
    --blocking-sleep-in-coroutine --debug --cpus "${CORES[0]}"
fi

# ---- (b) hand-off --------------------------------------------------------------------------------------------------
if ((RUN)); then
  alt_run() {
    step "C++ ping-pong: $1 (alternation $2), $ROUNDS round trips"
    run_pinned "$LOGS/cpp-pingpong-$1-alt$2.log" "$(cpp_pins_pingpong "$1")" "$BENCH" pingpong --variant "$1" --rounds "$ROUNDS" --batch "$BATCH" \
      --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$OUT/cpp-pingpong-$1-alt$2.json"
  }
  each_alt "${CPP_VARIANTS[@]}"
  step "C++ ping-pong: os-thread on std::binary_semaphore (observed)"
  run_pinned "$LOGS/cpp-pingpong-os-thread-semaphore.log" 2 "$BENCH" pingpong --variant os-thread --handoff semaphore --rounds "$ROUNDS" \
    --batch "$BATCH" --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$OUT/cpp-pingpong-os-thread-semaphore.json"

  alt_run() {
    local flags=()
    [[ $1 == virtual-thread ]] && flags=("${VT_ONE_CARRIER[@]}")
    step "Java ping-pong: $1 (alternation $2), $ROUNDS round trips"
    run_pinned "$LOGS/java-pingpong-$1-alt$2.log" 2 java "${JVM_LATENCY[@]}" "${flags[@]}" -jar "$JAR" pingpong --variant "$1" \
      --rounds "$ROUNDS" --batch "$BATCH" --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$OUT/java-pingpong-$1-alt$2.json"
  }
  each_alt "${JAVA_VARIANTS[@]}"
fi

# ---- (c) the blocking call -------------------------------------------------------------------------------------------
if ((RUN)); then
  alt_run() {
    local blocking=()
    case $1 in
      fiber-blocking) blocking=(--blocking-sleep-in-fiber) ;;
    esac
    local v=${1%-blocking}
    step "C++ neighbours: $1 (alternation $2), $NEIGH_TASKS tasks on 2 ms timers"
    run_pinned "$LOGS/cpp-neighbours-$1-alt$2.log" "$(cpp_pins_parked "$v")" "$BENCH" neighbours --variant "$v" "${blocking[@]}" \
      --tasks "$NEIGH_TASKS" --iterations "$NEIGH_ITER" --cpus "${CORES[0]}" --hold-ms "$HOLD_MS" --report "$OUT/cpp-neighbours-$1-alt$2.json"
  }
  each_alt fiber fiber-blocking coroutine os-thread

  step "Java: what pins a virtual thread (JFR jdk.VirtualThreadPinned, synchronized block against a native frame)"
  run_plain "$LOGS/java-pinning.log" java "${JVM[@]}" -jar "$JAR" pinning --report "$OUT/java-pinning-virtual-thread.json"
fi

# ---- 6: the line ---------------------------------------------------------------------------------------------------------
# run_line LANG VARIANT PORT PINS: one simulator instance to PORT.
run_line() {
  local lang=$1 variant=$2 port=$3 pins=$4 log=$LOGS/$1-line-$2.log report=$OUT/$1-line-$2.json pid
  local -a cmd
  step "line: $lang / $variant, one simulator instance at $LINE_RATE Hz x $LINE_SECONDS s, UDP $port"
  case $lang in
    cpp) cmd=("$LINE_CPP" --variant "$variant" --cpus "$CPUS") ;;
    java) cmd=(java "${JVM_LATENCY[@]}" -jar "$JAR" line --variant "$variant" --cpus "${CORES[0]}") ;;
  esac
  cmd+=(--base-port "$port" --expect "$LINE_COUNT" --hold-ms "$HOLD_MS" --report "$report")
  "${cmd[@]}" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_log_line '^placement-ready$' "$log" "$pid" >/dev/null
  check_pins "$log" "$pins"
  # The receiver binds before the gate's hold ends, so a bound port does not mean the run has started. "released" is
  # printed when the hold is over and the threads go; the simulator starts then, and no parcel waits in a socket buffer.
  wait_log_line '^released$' "$log" "$pid" >/dev/null
  wait_udp_bound "$port" "$pid" "$log"
  simulate --rate "$LINE_RATE" --duration "$LINE_SECONDS" --dest "127.0.0.1:$port" --quiet >>"$log" 2>&1 || { tail -20 "$log" >&2; die "the simulator failed"; }
  wait "$pid" || { tail -30 "$log" >&2; die "$lang/$variant line run failed"; }
  bg_forget "$pid"
}
if ((RUN)); then
  run_line cpp os-thread "$PORT_CPP_OS_THREAD" 1
  run_line cpp fiber "$PORT_CPP_FIBER" 2
  run_line cpp coroutine "$PORT_CPP_COROUTINE" 2
  run_line java platform-thread "$PORT_JAVA_PLATFORM" 1
  run_line java virtual-thread "$PORT_JAVA_VIRTUAL" 1
fi

# ---- evaluate ---------------------------------------------------------------------------------------------------------------
step "reports: schema, histogram decode, percentile recompute"
mapfile -t all_reports < <(find "$OUT" -name '*.json' ! -name profile.json -exec grep -lE '"schema" ?: ?"lowlat-report/1"' {} + | sort)
if report_check "${all_reports[@]}" >/dev/null 2>"$OUT/report-check.err"; then
  ok "7 ${#all_reports[@]} reports validate (profile embedded: $(jget "${all_reports[0]}" .profile.host_label))"
else
  cat "$OUT/report-check.err" >&2
  report_check "${all_reports[@]}" >&2 || true
  bad "7 lowlat-report check failed"
fi
rm -f "$OUT/report-check.err"

step "criterion 1: memory per waiting task, on the quantity that shows the gap"
cf=$OUT/cpp-parked-coroutine.json
ot_f=$OUT/cpp-parked-os-thread.json
fb_f=$OUT/cpp-parked-fiber.json
crit_ratio "1" "C++ address space per task, os-thread over fiber (VmSize growth over $TASKS tasks)" \
  "$(counter "$ot_f" vm_size_bytes_per_task) over $(counter "$fb_f" vm_size_bytes_per_task)" \
  "$(ratio_milli "$(counter "$ot_f" vm_size_bytes_per_task)" "$(counter "$fb_f" vm_size_bytes_per_task)")" "$CPP_ADDRESS_THREAD_OVER_FIBER_MILLI"
crit_ratio "1" "C++ fiber stack bytes per task over the counted coroutine frame bytes" \
  "$(counter "$fb_f" fiber_stack_bytes) over $(counter "$cf" frame_bytes_per_task)" \
  "$(ratio_milli "$(counter "$fb_f" fiber_stack_bytes)" "$(counter "$cf" frame_bytes_per_task)")" "$CPP_FIBER_STACK_OVER_FRAME_MILLI"
crit_le "1" "C++ coroutine: frame bytes per parked task (exact, counting promise operator new, frames that escape)" "$(counter "$cf" frame_bytes_per_task)" "$FRAME_BYTES_MAX"
crit_exact "1" "C++ coroutine: frame allocations (exact), one per frame of $(counter "$cf" frames_parked)" "$(counter "$cf" frame_allocations)" "$(counter "$cf" frames_parked)"
printf '  observed: HALO on a coroutine that does not escape: %s of %s frames reached operator new (%s bytes per escaping frame)\n' \
  "$(counter "$cf" control_frame_allocations)" "$(counter "$cf" control_frames)" "$(counter "$cf" frame_bytes_per_task)"
jp=$OUT/java-parked-platform-thread.json
jv=$OUT/java-parked-virtual-thread.json
crit_ratio "1" "Java address space per task, platform-thread over virtual-thread heap per task (MemoryMXBean after System.gc())" \
  "$(counter "$jp" vm_size_bytes_per_task) over $(counter "$jv" heap_bytes_per_task)" \
  "$(ratio_milli "$(counter "$jp" vm_size_bytes_per_task)" "$(counter "$jv" heap_bytes_per_task)")" "$JAVA_ADDRESS_OVER_VT_HEAP_MILLI"
for build in gil free-threaded; do
  t=$(counter "$OUT/python/python-$build-parked-threads.json" rss_bytes_per_task)
  a=$(counter "$OUT/python/python-$build-parked-asyncio-tasks.json" tracemalloc_bytes_per_task)
  crit_ratio "1" "Python $build build: thread RSS bytes per task over asyncio task bytes (measured by tracemalloc, not exact)" "$t over $a" "$(ratio_milli "$t" "$a")" "$PY_TASK_FRACTION_MILLI"
  printf '  observed: Python %s build, asyncio RSS bytes per task %s, tracemalloc bytes per task %s, thread RSS bytes per task %s\n' "$build" \
    "$(counter "$OUT/python/python-$build-parked-asyncio-tasks.json" rss_bytes_per_task)" "$a" "$t"
done

step "criterion 2: parked tasks armed when the memory was read; RSS observed"
for f in "$OUT"/cpp-parked-fiber.json "$OUT"/cpp-parked-coroutine.json; do
  crit_exact "2" "$(basename "$f" .json): tasks that had reached their wait when the memory was read (exact)" "$(counter "$f" tasks_armed)" "$TASKS"
done
printf '  by construction (a latch or barrier opens only when all arrive, so these cannot differ; not a criterion): tasks armed %s of %s in the %s other parked runs\n' \
  "$TASKS" "$TASKS" "$(($(find "$OUT" -name '*parked-*.json' ! -name '*-fiber.json' ! -name '*-coroutine.json' | wc -l)))"
# RSS: observed. A parked thread's resident cost is a stack page or two plus its thread block, so the plan's 10x doesn't show in
# RSS; the ratios below are computed from this run, and the gap shows in the address space and kernel bytes printed with them.
ot=$(counter "$ot_f" rss_bytes_per_task)
fb=$(counter "$fb_f" rss_bytes_per_task)
co=$(counter "$cf" rss_bytes_per_task)
printf '  observed: RSS per task, C++ os-thread over fiber %s B / %s B = %sx, fiber over coroutine %s B / %s B = %sx (plan %sx)\n' \
  "$ot" "$fb" "$(margin "$ot" "$fb")" "$fb" "$co" "$(margin "$fb" "$co")" "$((PLAN_RSS_MILLI / 1000))"
printf '  observed: RSS per task, Java platform-thread over virtual-thread %s B / %s B = %sx; platform-thread RSS over virtual-thread heap %s B / %s B = %sx (plan %sx)\n' \
  "$(counter "$jp" rss_bytes_per_task)" "$(counter "$jv" rss_bytes_per_task)" "$(margin "$(counter "$jp" rss_bytes_per_task)" "$(counter "$jv" rss_bytes_per_task)")" \
  "$(counter "$jp" rss_bytes_per_task)" "$(counter "$jv" heap_bytes_per_task)" "$(margin "$(counter "$jp" rss_bytes_per_task)" "$(counter "$jv" heap_bytes_per_task)")" "$((PLAN_RSS_MILLI / 1000))"
for v in "${CPP_VARIANTS[@]}"; do
  f=$OUT/cpp-parked-$v.json
  printf '  observed: C++ %s: RSS %s B, RSS + page tables + kernel stack %s B, address space %s B per task; wake lateness p50 / p99 / p99.9 / max in ns: %s\n' \
    "$v" "$(counter "$f" rss_bytes_per_task)" "$(counter "$f" rss_page_tables_kernel_stack_bytes_per_task)" "$(counter "$f" vm_size_bytes_per_task)" "$(pct_line "$f")"
done
for v in "${JAVA_VARIANTS[@]}"; do
  f=$OUT/java-parked-$v.json
  printf '  observed: Java %s: RSS %s B, heap %s B, address space %s B, RSS + page tables + kernel stack %s B per task; wake lateness p50 / p99 / p99.9 / max in ns: %s\n' \
    "$v" "$(counter "$f" rss_bytes_per_task)" "$(counter "$f" heap_bytes_per_task)" "$(counter "$f" vm_size_bytes_per_task)" "$(counter "$f" rss_page_tables_kernel_stack_bytes_per_task)" "$(pct_line "$f")"
done
for build in gil free-threaded; do
  for v in "${PY_VARIANTS[@]}"; do
    f=$OUT/python/python-$build-parked-$v.json
    printf '  observed: Python %s build, %s: RSS %s B per task, address space %s B per task\n' "$build" "$v" "$(counter "$f" rss_bytes_per_task)" "$(counter "$f" vm_size_bytes_per_task)"
  done
done

step "criterion 3: voluntary context switches per round trip (exact counts)"
vols=()
for n in 1 2 3; do
  f=$OUT/cpp-pingpong-os-thread-alt$n.json
  vols+=("$(ratio_milli "$(jget "$f" .runtime.ctx_switches.voluntary)" "$(counter "$f" round_trips_served)")")
done
crit_ge "3" "C++ os-thread: voluntary switches per round trip in thousandths, the lowest of 3 alternations (${vols[*]}) (exact counts)" "$(min_of "${vols[@]}")" "$CTX_OS_THREAD_MIN_MILLI"
for v in fiber coroutine; do
  worst=0
  for n in 1 2 3; do
    f=$OUT/cpp-pingpong-$v-alt$n.json
    micro=$((1000000 * $(jget "$f" .runtime.ctx_switches.voluntary) / $(counter "$f" round_trips_served)))
    ((micro > worst)) && worst=$micro
  done
  crit_le "3" "C++ $v: voluntary switches per round trip in millionths, the highest of 3 alternations (exact counts)" "$worst" "$CTX_SAME_THREAD_MAX_MICRO"
done
printf '  observed: C++ os-thread on std::binary_semaphore: %s voluntary switches over %s round trips (the semaphore spins before it sleeps); p50 %s ns per round trip\n' \
  "$(jget "$OUT/cpp-pingpong-os-thread-semaphore.json" .runtime.ctx_switches.voluntary)" "$(counter "$OUT/cpp-pingpong-os-thread-semaphore.json" round_trips_served)" \
  "$(p50 "$OUT/cpp-pingpong-os-thread-semaphore.json")"
for v in "${JAVA_VARIANTS[@]}"; do
  f=$OUT/java-pingpong-$v-alt1.json
  printf '  observed: Java %s: %s voluntary switches over %s round trips\n' "$v" "$(jget "$f" .runtime.ctx_switches.voluntary)" "$(counter "$f" round_trips_served)"
done

step "criterion 4: round-trip p50, same run, median of $ROUNDS_ALT alternations"
r_fiber=() r_coro=() r_java=()
for n in 1 2 3; do
  ot=$(p50 "$OUT/cpp-pingpong-os-thread-alt$n.json")
  r_fiber+=("$(ratio_milli "$ot" "$(p50 "$OUT/cpp-pingpong-fiber-alt$n.json")")")
  r_coro+=("$(ratio_milli "$ot" "$(p50 "$OUT/cpp-pingpong-coroutine-alt$n.json")")")
  r_java+=("$(ratio_milli "$(p50 "$OUT/java-pingpong-platform-thread-alt$n.json")" "$(p50 "$OUT/java-pingpong-virtual-thread-alt$n.json")")")
done
crit_ratio "4" "C++ round-trip p50" "os-thread over fiber, per alternation: ${r_fiber[*]} thousandths" "$(median_of "${r_fiber[@]}")" "$PINGPONG_CPP_MILLI"
crit_ratio "4" "C++ round-trip p50" "os-thread over coroutine, per alternation: ${r_coro[*]} thousandths" "$(median_of "${r_coro[@]}")" "$PINGPONG_CPP_MILLI"
crit_ratio "4" "Java round-trip p50" "platform-thread over virtual-thread, per alternation: ${r_java[*]} thousandths" "$(median_of "${r_java[@]}")" "$PINGPONG_JAVA_MILLI"
for v in "${CPP_VARIANTS[@]}"; do
  printf '  C++ %s round trip p50 / p99 / p99.9 / max in ns, alternation 1: %s\n' "$v" "$(pct_line "$OUT/cpp-pingpong-$v-alt1.json")"
done
for v in "${JAVA_VARIANTS[@]}"; do
  printf '  Java %s round trip p50 / p99 / p99.9 / max in ns, alternation 1: %s\n' "$v" "$(pct_line "$OUT/java-pingpong-$v-alt1.json")"
done
for build in gil free-threaded; do
  for v in "${PY_VARIANTS[@]}"; do
    printf '  observed: Python %s build, %s round trip p50 / p99 / p99.9 / max in ns: %s\n' "$build" "$v" "$(pct_line "$OUT/python/python-$build-pingpong-$v.json")"
  done
done

step "criterion 5: a blocking call in a fiber or a coroutine, and the neighbours"
p99s=()
for n in 1 2 3; do p99s+=("$(p99 "$OUT/cpp-neighbours-fiber-blocking-alt$n.json")"); done
crit_ge "5" "C++ fiber with --blocking-sleep-in-fiber (a 2 ms std::this_thread::sleep_for): neighbours' wake lateness p99 in ns, the lowest of 3 alternations (${p99s[*]}); 2x by construction" \
  "$(min_of "${p99s[@]}")" "$NEIGHBOUR_P99_MIN_NS"
base=()
for n in 1 2 3; do base+=("$(p99 "$OUT/cpp-neighbours-fiber-alt$n.json")"); done
printf '  C++ fiber without the blocking call, wake lateness p99 in ns per alternation: %s\n' "${base[*]}"
for v in fiber fiber-blocking coroutine os-thread; do
  printf '  C++ neighbours %s wake lateness p50 / p99 / p99.9 / max in ns, alternation 1: %s\n' "$v" "$(pct_line "$OUT/cpp-neighbours-$v-alt1.json")"
done
pb=$OUT/python/python-gil-neighbours-asyncio-tasks-blocking.json
pbase=$OUT/python/python-gil-neighbours-asyncio-tasks.json
printf '  observed: Python asyncio wake lateness p50 / p99 / p99.9 / max in ns, without the blocking call: %s; with it: %s\n' "$(pct_line "$pbase")" "$(pct_line "$pb")"
printf '  observed: Python asyncio p99 with the blocking call over the baseline in the same run: %s ns / %s ns = %sx. asyncio rounds its epoll timeout up to a whole millisecond, so the baseline p99 already sits at or over 1 ms and p99 >= 1 ms does not separate the two.\n' \
  "$(p99 "$pb")" "$(p99 "$pbase")" "$(margin "$(p99 "$pb")" "$(p99 "$pbase")")"
lb=$(counter "$pb" wakes_over_1500us)
lbase=$(counter "$pbase" wakes_over_1500us)
nb=$(jget "$pb" .count)
nbase=$(jget "$pbase" .count)
# A baseline with no late wake at all counts as one, so the ratio is a floor, never a division by zero.
lr=$(ratio_milli "$((1000000 * lb / nb))" "$((1000000 * (lbase > 0 ? lbase : 1) / nbase))")
if ((PY_LATE_FRACTION_ASSERTED)); then
  crit_ratio "5" "Python asyncio: fraction of wakes later than 1.5 ms, blocking over baseline ($lb of $nb against $lbase of $nbase)" "same run" "$lr" "$PY_LATE_FRACTION_RATIO_MILLI"
else
  printf '  observed: Python asyncio wakes later than 1.5 ms: %s of %s with the blocking call, %s of %s without, ratio %sx\n' "$lb" "$nb" "$lbase" "$nbase" "$(margin "$lr" 1000)"
fi
pd=$OUT/python/python-gil-neighbours-asyncio-tasks-blocking-debug.json
crit_exact "5" "Python asyncio debug mode (slow_callback_duration 1 ms): 'Executing ... took N seconds' warnings against blocking calls (exact)" \
  "$(counter "$pd" slow_callback_warnings)" "$(counter "$pd" blocking_calls)"
for f in "$OUT"/cpp-neighbours-*.json "$OUT"/python/python-gil-neighbours-*.json; do
  crit_exact "5" "$(basename "$f" .json): tasks that started after their first deadline (exact)" "$(counter "$f" late_starts)" 0
done
jpin=$OUT/java-pinning-virtual-thread.json
printf '  observed: Java jdk.VirtualThreadPinned events (threshold 0) for %s virtual threads blocking %s ms: in a synchronized block %s (JEP 491), in a native frame %s\n' \
  "$(counter "$jpin" tasks_per_case)" "$(counter "$jpin" block_ms)" "$(counter "$jpin" pinned_events_synchronized)" "$(counter "$jpin" pinned_events_native_frame)"

step "criterion 6: the line"
for run in cpp-line-os-thread cpp-line-fiber cpp-line-coroutine java-line-platform-thread java-line-virtual-thread; do
  r=$OUT/$run.json
  count=$(jget "$r" .count)
  dropped=$(jget "$r" .dropped)
  diverts=$(counter "$r" divert_received)
  if ((count == LINE_COUNT && dropped == 0 && diverts == LINE_COUNT)); then
    ok "6 $run: count $count (bound == $LINE_COUNT), dropped $dropped (exact 0), divert commands received $diverts (exact $LINE_COUNT)"
  else
    bad "6 $run: count $count of $LINE_COUNT, dropped $dropped, divert commands received $diverts"
  fi
  printf '  %s end-to-end p50 / p99 / p99.9 / max in ns (observed): %s; divert command p99 %s ns; tasks started %s\n' "$run" "$(pct_line "$r")" \
    "$(jget "$OUT/$run-divert.json" .percentiles.p99)" "$(counter "$r" tasks_started)"
done

step "criterion 7: every report carries count, dropped = 0, build.flags, placement, python_build; the gates' skew; the round trips"
flags_ok=1 place_ok=1 skew_ok=1 gil_ok=1
for r in "${all_reports[@]}"; do
  name=${r#"$OUT"/}
  [[ $(jget "$r" .count) -gt 0 ]] || { bad "7 $name: count is 0"; flags_ok=0; }
  [[ $(jget "$r" .dropped) -eq 0 ]] || { bad "7 $name: dropped parcels"; flags_ok=0; }
  case $name in
    python/*)
      jq -e '.runtime.python_build | . == "gil" or . == "free-threaded"' "$r" >/dev/null || { bad "7 $name: runtime.python_build missing"; flags_ok=0; }
      if [[ $name == python/python-free-threaded-* ]]; then
        jq -e '.runtime.python_build == "free-threaded" and .build.gil_enabled == false' "$r" >/dev/null ||
          { bad "7 $name: the free-threaded measurement did not keep the GIL off"; gil_ok=0; }
      fi
      ;;
    *)
      jq -e '.build.flags | length > 0' "$r" >/dev/null || { bad "7 $name: build.flags missing"; flags_ok=0; }
      ;;
  esac
  # Every run that pins a thread records runtime.placement. By design nothing is pinned in the OS-thread, platform-thread and
  # Python-thread parked runs, the C++ os-thread neighbour run and the pinning run (their tasks float).
  case $name in
    cpp-parked-os-thread.json | cpp-neighbours-os-thread-* | java-parked-* | java-pinning-* | python/python-*-parked-threads.json) ;;
    *) jq -e '.runtime.placement.cpus | length > 0' "$r" >/dev/null || { bad "7 $name: runtime.placement missing"; place_ok=0; } ;;
  esac
  skew=$(jq -r '.runtime.counters.start_skew_ns // empty' "$r")
  if [[ -n $skew ]] && ((skew >= START_SKEW_MAX_NS)); then
    bad "7 $name: start gate skew $skew ns, bound < $START_SKEW_MAX_NS"
    skew_ok=0
  fi
done
((flags_ok)) && ok "7 ${#all_reports[@]} reports: count > 0, dropped = 0, build.flags (C++ and Java) and runtime.python_build (Python) present"
((place_ok)) && ok "7 every pinned run records runtime.placement (distinct_cores $(jget "$OUT/cpp-pingpong-fiber-alt1.json" .runtime.placement.distinct_cores), smt_siblings $(jget "$OUT/cpp-pingpong-fiber-alt1.json" .runtime.placement.smt_siblings))"
((skew_ok)) && ok "7 start gate skew under $START_SKEW_MAX_NS ns in every run that records it (a timing bound); C++ os-thread ping-pong $(counter "$OUT/cpp-pingpong-os-thread-alt1.json" start_skew_ns) ns, Java platform-thread $(counter "$OUT/java-pingpong-platform-thread-alt1.json" start_skew_ns) ns"
((gil_ok)) && ok "7 Python free-threaded build: the GIL stayed off from the imports to the end in every measurement"
trips_ok=1
for f in "$OUT"/cpp-pingpong-*.json "$OUT"/java-pingpong-*.json "$OUT"/python/python-*-pingpong-*.json; do
  name=$(basename "$f" .json)
  w=$(counter "$f" warmup_round_trips)
  if (($(counter "$f" round_trips) == ROUNDS && $(counter "$f" round_trips_served) == ROUNDS + w && $(counter "$f" payload_mismatch) == 0)); then :; else
    bad "7 $name: round trips $(counter "$f" round_trips) of $ROUNDS, served $(counter "$f" round_trips_served), payload mismatch $(counter "$f" payload_mismatch)"
    trips_ok=0
  fi
done
((trips_ok)) && ok "7 every ping-pong served exactly the configured round trips with the payload intact (exact)"
if [[ -s $RATIO_FAULTS ]]; then
  bad "7 a ratio had no usable denominator: $(tr '\n' ';' <"$RATIO_FAULTS")"
fi
rm -f "$RATIO_FAULTS"

if [[ ${SMOKE:-0} == 1 ]]; then
  # A check of this script, not a measurement: small workloads, every criterion evaluated and printed, none enforced.
  [[ -n ${RESULTS_DIR:-} ]] || { echo "SMOKE=1 needs RESULTS_DIR (it must not overwrite results/latest)" >&2; exit 2; }
  TASKS=300 WAIT_MS=300 ROUNDS=20000 NEIGH_TASKS=100 NEIGH_ITER=100 PY_NEIGH_TASKS=20 LINE_SECONDS=2 HOLD_MS=100
fi
LINE_COUNT=$((LINE_RATE * LINE_SECONDS))
PORT_CPP_OS_THREAD=47310
PORT_CPP_FIBER=47311
PORT_CPP_COROUTINE=47312
PORT_JAVA_PLATFORM=47313
PORT_JAVA_VIRTUAL=47314
ROUNDS_ALT=3
CPP_VARIANTS=(os-thread fiber coroutine)
JAVA_VARIANTS=(platform-thread virtual-thread)
PY_VARIANTS=(threads asyncio-tasks)

# ---- provisional bounds (S10 calibrates). Ratios are in thousandths. -------------------------------------------------
FRAME_BYTES_MAX=1024                    # plan 1,024
CPP_ADDRESS_THREAD_OVER_FIBER_MILLI=10000   # os-thread >= 10x fiber, on address space per task (the plan's 10x; RSS is observed)
CPP_FIBER_STACK_OVER_FRAME_MILLI=10000  # fiber stack bytes per task >= 10x the counted coroutine frame bytes
JAVA_ADDRESS_OVER_VT_HEAP_MILLI=10000   # platform-thread address space per task >= 10x virtual-thread heap per task
PY_TASK_FRACTION_MILLI=5000             # thread RSS >= 5x asyncio task bytes, in each build
CTX_OS_THREAD_MIN_MILLI=900             # plan: >= 0.9 voluntary switches per round trip
CTX_SAME_THREAD_MAX_MICRO=1000          # plan: <= 0.001 (in millionths)
PINGPONG_CPP_MILLI=5000                 # plan: os-thread >= 5x fiber and >= 5x coroutine
PINGPONG_JAVA_MILLI=2000                # plan: platform-thread >= 2x virtual-thread
NEIGHBOUR_P99_MIN_NS=1000000            # plan: >= 1 ms for a 2 ms blocking call (C++ fiber)
PY_LATE_FRACTION_RATIO_MILLI=2000       # Python wakes later than 1.5 ms, blocking over baseline; asserted only with 2x margin
PY_LATE_FRACTION_ASSERTED=1             # set from the full-size runs: 1 when the ratio clears twice this bound
START_SKEW_MAX_NS=1000000               # a timing bound: the gate's skew is < 1 ms
PLAN_RSS_MILLI=10000                    # the plan's 10x on RSS, printed beside the observed RSS ratios

# The JVM for every Java run: a fixed heap so no resize starts inside a measured run, native access for the affinity and
# FFM calls. The parked runs do not pre-touch the heap, so the RSS they read is the memory the tasks really touched.
JVM=(-Xms1g -Xmx1g -XX:+UseG1GC --enable-native-access=ALL-UNNAMED)
JVM_LATENCY=(-XX:+AlwaysPreTouch "${JVM[@]}")
VT_ONE_CARRIER=(-Djdk.virtualThreadScheduler.parallelism=1)

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
  mkdir -p "$OUT/python"
  capture_profile "$OUT"
  # Driver logs are written outside the results directory (this script clears *.log there) and moved in at the end.
  scratch_dir
  LOGS=$LOWLAT_SCRATCH/logs
  mkdir -p "$LOGS"
fi
finish_logs() {
  if [[ -n ${LOGS:-} && -d $LOGS ]]; then
    find "$LOGS" -maxdepth 1 -name '*.log' -exec mv -t "$OUT" {} + 2>/dev/null || true
  fi
}
trap 'finish_logs; _bg_cleanup' EXIT

# ---- helpers (the criterion printers follow example 10) ------------------------------------------------------------

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
# crit_ratio ID DESC "A over B" RATIO_MILLI BOUND_MILLI: ratio >= bound, both in thousandths.
crit_ratio() {
  local m
  m=$(margin "$4" "$5")
  if (($4 >= $5)); then
    ok "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x$(note_margin "$m")"
  else
    bad "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x"
  fi
}

p50() { jget "$1" .percentiles.p50; }
p99() { jget "$1" .percentiles.p99; }
counter() { jget "$1" ".runtime.counters.$2"; }
# ratio_milli NUM DEN: NUM / DEN in thousandths (DEN of 0 counts as 1).
# A zero or negative denominator is a failure of the measurement: it prints 0 (so any >= bound fails) and is recorded in
# $RATIO_FAULTS, which the end of the run turns into a failed criterion (a $(...) cannot raise the failure itself).
ratio_milli() {
  if (($2 <= 0)); then
    echo "ratio_milli: denominator $2 for numerator $1" >>"$RATIO_FAULTS"
    echo 0
  else
    echo $((1000 * $1 / $2))
  fi
}
median_of() { median_ns "$@"; }
RATIO_FAULTS=$(mktemp "${TMPDIR:-/tmp}/lowlat-ratio.XXXXXX")
min_of() { printf '%s\n' "$@" | sort -n | head -1; }
# pct_line FILE: "p50 / p99 / p99.9 / max" in ns.
pct_line() { jget "$1" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9) / \(.percentiles.max)"'; }

# check_pins LOG COUNT: every "pinned pid=P tid=T cpu=C" line of LOG is checked against /proc/P/task/T/stat.
check_pins() {
  local log=$1 want=$2 line n=0
  while read -r line; do
    [[ $line =~ pid=([0-9]+)\ tid=([0-9]+)\ cpu=([0-9]+) ]] || die "unparseable pinned line: $line"
    assert_placement "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >/dev/null
    n=$((n + 1))
  done < <(grep '^pinned ' "$log" || true)
  ((n == want)) || die "expected $want pinned threads in $log, found $n"
  ok "placement: $n threads of $(basename "$log" .log) run on the CPUs they were pinned to"
}

# run_pinned LOG COUNT CMD...: run CMD, which pins its threads, prints "pinned ..." and "placement-ready", holds, and
# goes; the pins are verified from /proc during the hold. COUNT may be 0: a run with nothing pinned prints the markers too.
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

# run_plain LOG CMD...: run CMD to the end with its output in LOG.
run_plain() {
  local log=$1
  shift
  "$@" >"$log" 2>&1 || { tail -30 "$log" >&2; die "failed: $*"; }
}

# each_alt VARIANTS...: for ROUNDS_ALT alternations of the variants, call `alt_run VARIANT N` in interleaved order.
each_alt() {
  local -A seen=()
  local v
  while read -r v; do
    seen[$v]=$((${seen[$v]:-0} + 1))
    alt_run "$v" "${seen[$v]}"
  done < <(interleave "$ROUNDS_ALT" "$@")
}

# idle_cores N: print N logical CPUs, one per physical core, CPU 0 left out, each less than IDLE_MAX_PCT busy over a one second
# sample of /proc/stat (user, nice, system, irq, softirq and steal against the total). A pinned thread that shares its core with
# another process waits behind it for a scheduling slice at every hand-off, so a core in use isn't a measurement. ALLOW_BUSY=1
# takes the first N cores without looking.
IDLE_MAX_PCT=10
idle_cores() {
  local want=$1 total=16 all c line
  local -A busy_a tot_a
  local -a picked=()
  while ((total >= want + 1)); do
    all=$(distinct_cores "$total" 2>/dev/null) && break
    total=$((total - 1))
  done
  [[ -n ${all:-} ]] || die "need $((want + 1)) distinct physical cores (CPU 0 is left alone)"
  if [[ ${ALLOW_BUSY:-0} == 1 ]]; then
    awk '$1 != 0' <<<"$all" | head -n "$want"
    return 0
  fi
  while read -r c b t; do busy_a[$c]=$b tot_a[$c]=$t; done < <(awk '/^cpu[0-9]/ { b = $2 + $3 + $4 + $7 + $8 + $9; print substr($1, 4), b, b + $5 + $6 }' /proc/stat)
  sleep 1
  while read -r c b t; do
    [[ -n ${busy_a[$c]:-} ]] || continue
    ((t > tot_a[$c])) || continue
    pct=$((100 * (b - busy_a[$c]) / (t - tot_a[$c])))
    if grep -qx "$c" <<<"$all" && ((c != 0)); then
      if ((pct < IDLE_MAX_PCT)); then picked+=("$c"); else echo "idle_cores: CPU $c is ${pct}% busy, not using it" >&2; fi
    fi
  done < <(awk '/^cpu[0-9]/ { b = $2 + $3 + $4 + $7 + $8 + $9; print substr($1, 4), b, b + $5 + $6 }' /proc/stat)
  ((${#picked[@]} >= want)) || die "only ${#picked[@]} idle physical cores other than CPU 0 (need $want): something else is using the host; ALLOW_BUSY=1 measures anyway"
  printf '%s\n' "${picked[@]:0:$want}"
}

# pins_for MODEL: how many threads the model pins in a micro run.
cpp_pins_parked() { [[ $1 == os-thread ]] && echo 0 || echo 1; }
cpp_pins_pingpong() { [[ $1 == os-thread ]] && echo 2 || echo 1; }

# ---- build and unit tests ------------------------------------------------------------------------------------------
if ((RUN)); then
  uv python find 3.14t >/dev/null 2>&1 || die "no free-threaded Python: uv python install 3.14t (a user-local download)"
  build_cpp tasks-bench tasks-line tasks-test line-simulator
  BUILD_JAVA_TESTS=1 build_java "$HERE/java" # the Java tests run on the way
  py_sync
  [[ -f $JAR ]] || die "missing $JAR (build_java first)"

  step "unit tests: C++ (GoogleTest), Python under the GIL and under the free-threaded build; Java ran during the package step"
  "$(cpp_bin tasks-test)" --gtest_brief=1 >"$LOGS/cpp-unit-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-unit-tests.log" >&2; die "C++ unit tests failed"; }
  uvrun pytest -q "$HERE/tasks-py/tests" >"$LOGS/python-unit-tests-gil.log" 2>&1 || { tail -20 "$LOGS/python-unit-tests-gil.log" >&2; die "Python (GIL) tests failed"; }
  (cd "$LOWLAT_EXAMPLES" && LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$LOWLAT_EXAMPLES/.venv-ft \
    uv run -q --python 3.14t --all-packages pytest -q "$HERE/tasks-py/tests") >"$LOGS/python-unit-tests-free-threaded.log" 2>&1 ||
    { tail -20 "$LOGS/python-unit-tests-free-threaded.log" >&2; die "Python (free-threaded) tests failed"; }
  ok "C++, Java and Python (both builds) unit tests pass"
  BENCH=$(cpp_bin tasks-bench)
  LINE_CPP=$(cpp_bin tasks-line)
  # Two distinct physical cores, CPU 0 excluded (examples 09 and 10 do the same), that nothing else is using right now.
  mapfile -t CORES < <(idle_cores 2)
  ((${#CORES[@]} == 2)) || die "need 2 idle distinct physical cores other than CPU 0"
  CPUS=$(paste -sd, < <(printf '%s\n' "${CORES[@]}"))
  ok "pinned threads use CPUs $CPUS (distinct physical cores, idle when chosen)"
fi

# ---- (a) parked tasks ----------------------------------------------------------------------------------------------
if ((RUN)); then
  for v in "${CPP_VARIANTS[@]}"; do
    step "C++ parked: $v, $TASKS tasks on a ${WAIT_MS} ms timer"
    run_pinned "$LOGS/cpp-parked-$v.log" "$(cpp_pins_parked "$v")" "$BENCH" parked --variant "$v" --tasks "$TASKS" --wait-ms "$WAIT_MS" \
      --cpus "${CORES[0]}" --hold-ms "$HOLD_MS" --report "$OUT/cpp-parked-$v.json"
  done
  for v in "${JAVA_VARIANTS[@]}"; do
    step "Java parked: $v, $TASKS tasks on a ${WAIT_MS} ms timer"
    run_pinned "$LOGS/java-parked-$v.log" 0 java "${JVM[@]}" -jar "$JAR" parked --variant "$v" --tasks "$TASKS" --wait-ms "$WAIT_MS" \
      --hold-ms "$HOLD_MS" --report "$OUT/java-parked-$v.json"
  done
fi

# ---- Python (both builds) ----------------------------------------------------------------------------------------
# py_measure BUILD LOG PINS RAWDIR ARGS...: measure in the named build (no lowlat_measure in the measuring process).
py_measure() {
  local build=$1 log=$2 pins=$3 raw=$4
  shift 4
  local cmd=(tasks-py measure "$@" --out "$raw" --hold-ms "$HOLD_MS")
  if [[ $build == free-threaded ]]; then
    run_pinned "$log" "$pins" env UV_PROJECT_ENVIRONMENT="$LOWLAT_EXAMPLES/.venv-ft" \
      uv --directory "$LOWLAT_EXAMPLES" run -q --python 3.14t --package lowlat-tasks "${cmd[@]}"
  else
    # env -C execs uv itself, so the background PID is uv's and there is no subshell between it and python.
    run_pinned "$log" "$pins" env -C "$LOWLAT_EXAMPLES" uv run -q "${cmd[@]}"
  fi
}
# py_run BUILD NAME PINS ARGS...: measure, then convert the raw samples to python/python-BUILD-NAME.json in the GIL environment.
py_run() {
  local build=$1 name=$2 pins=$3 raw
  shift 3
  raw=$LOWLAT_SCRATCH/py-$build-$name
  step "Python $name in the $build build"
  py_measure "$build" "$LOGS/python-$build-$name.log" "$pins" "$raw" "$@"
  from_samples "$raw/samples.bin" "$raw/sidecar.json" "$OUT/python/python-$build-$name.json"
}
if ((RUN)); then
  for build in gil free-threaded; do
    py_run "$build" parked-threads 0 parked --variant threads --tasks "$TASKS" --wait-ms "$WAIT_MS"
    py_run "$build" parked-asyncio-tasks 1 parked --variant asyncio-tasks --tasks "$TASKS" --wait-ms "$WAIT_MS" --cpus "${CORES[0]}"
    py_run "$build" pingpong-threads 2 pingpong --variant threads --rounds "$ROUNDS" --batch "$BATCH" --cpus "$CPUS"
    py_run "$build" pingpong-asyncio-tasks 1 pingpong --variant asyncio-tasks --rounds "$ROUNDS" --batch "$BATCH" --cpus "${CORES[0]}"
  done
  # The blocking call (GIL build): without it, with it, and with it under asyncio's debug mode (the warning count).
  py_run gil neighbours-asyncio-tasks 1 neighbours --variant asyncio-tasks --tasks "$PY_NEIGH_TASKS" --iterations "$NEIGH_ITER" --cpus "${CORES[0]}"
  py_run gil neighbours-asyncio-tasks-blocking 1 neighbours --variant asyncio-tasks --tasks "$PY_NEIGH_TASKS" --iterations "$NEIGH_ITER" \
    --blocking-sleep-in-coroutine --cpus "${CORES[0]}"
  py_run gil neighbours-asyncio-tasks-blocking-debug 1 neighbours --variant asyncio-tasks --tasks "$PY_NEIGH_TASKS" --iterations "$NEIGH_ITER" \
    --blocking-sleep-in-coroutine --debug --cpus "${CORES[0]}"
fi

# ---- (b) hand-off --------------------------------------------------------------------------------------------------
if ((RUN)); then
  alt_run() {
    step "C++ ping-pong: $1 (alternation $2), $ROUNDS round trips"
    run_pinned "$LOGS/cpp-pingpong-$1-alt$2.log" "$(cpp_pins_pingpong "$1")" "$BENCH" pingpong --variant "$1" --rounds "$ROUNDS" --batch "$BATCH" \
      --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$OUT/cpp-pingpong-$1-alt$2.json"
  }
  each_alt "${CPP_VARIANTS[@]}"
  step "C++ ping-pong: os-thread on std::binary_semaphore (observed)"
  run_pinned "$LOGS/cpp-pingpong-os-thread-semaphore.log" 2 "$BENCH" pingpong --variant os-thread --handoff semaphore --rounds "$ROUNDS" \
    --batch "$BATCH" --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$OUT/cpp-pingpong-os-thread-semaphore.json"

  alt_run() {
    local flags=()
    [[ $1 == virtual-thread ]] && flags=("${VT_ONE_CARRIER[@]}")
    step "Java ping-pong: $1 (alternation $2), $ROUNDS round trips"
    run_pinned "$LOGS/java-pingpong-$1-alt$2.log" 2 java "${JVM_LATENCY[@]}" "${flags[@]}" -jar "$JAR" pingpong --variant "$1" \
      --rounds "$ROUNDS" --batch "$BATCH" --cpus "$CPUS" --hold-ms "$HOLD_MS" --report "$OUT/java-pingpong-$1-alt$2.json"
  }
  each_alt "${JAVA_VARIANTS[@]}"
fi

# ---- (c) the blocking call -------------------------------------------------------------------------------------------
if ((RUN)); then
  alt_run() {
    local blocking=()
    case $1 in
      fiber-blocking) blocking=(--blocking-sleep-in-fiber) ;;
    esac
    local v=${1%-blocking}
    step "C++ neighbours: $1 (alternation $2), $NEIGH_TASKS tasks on 2 ms timers"
    run_pinned "$LOGS/cpp-neighbours-$1-alt$2.log" "$(cpp_pins_parked "$v")" "$BENCH" neighbours --variant "$v" "${blocking[@]}" \
      --tasks "$NEIGH_TASKS" --iterations "$NEIGH_ITER" --cpus "${CORES[0]}" --hold-ms "$HOLD_MS" --report "$OUT/cpp-neighbours-$1-alt$2.json"
  }
  each_alt fiber fiber-blocking coroutine os-thread

  step "Java: what pins a virtual thread (JFR jdk.VirtualThreadPinned, synchronized block against a native frame)"
  run_plain "$LOGS/java-pinning.log" java "${JVM[@]}" -jar "$JAR" pinning --report "$OUT/java-pinning-virtual-thread.json"
fi

# ---- 6: the line ---------------------------------------------------------------------------------------------------------
# run_line LANG VARIANT PORT PINS: one simulator instance to PORT.
run_line() {
  local lang=$1 variant=$2 port=$3 pins=$4 log=$LOGS/$1-line-$2.log report=$OUT/$1-line-$2.json pid
  local -a cmd
  step "line: $lang / $variant, one simulator instance at $LINE_RATE Hz x $LINE_SECONDS s, UDP $port"
  case $lang in
    cpp) cmd=("$LINE_CPP" --variant "$variant" --cpus "$CPUS") ;;
    java) cmd=(java "${JVM_LATENCY[@]}" -jar "$JAR" line --variant "$variant" --cpus "${CORES[0]}") ;;
  esac
  cmd+=(--base-port "$port" --expect "$LINE_COUNT" --hold-ms "$HOLD_MS" --report "$report")
  "${cmd[@]}" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_log_line '^placement-ready$' "$log" "$pid" >/dev/null
  check_pins "$log" "$pins"
  # The receiver binds before the gate's hold ends, so a bound port does not mean the run has started. "released" is
  # printed when the hold is over and the threads go; the simulator starts then, and no parcel waits in a socket buffer.
  wait_log_line '^released$' "$log" "$pid" >/dev/null
  wait_udp_bound "$port" "$pid" "$log"
  simulate --rate "$LINE_RATE" --duration "$LINE_SECONDS" --dest "127.0.0.1:$port" --quiet >>"$log" 2>&1 || { tail -20 "$log" >&2; die "the simulator failed"; }
  wait "$pid" || { tail -30 "$log" >&2; die "$lang/$variant line run failed"; }
  bg_forget "$pid"
}
if ((RUN)); then
  run_line cpp os-thread "$PORT_CPP_OS_THREAD" 1
  run_line cpp fiber "$PORT_CPP_FIBER" 2
  run_line cpp coroutine "$PORT_CPP_COROUTINE" 2
  run_line java platform-thread "$PORT_JAVA_PLATFORM" 1
  run_line java virtual-thread "$PORT_JAVA_VIRTUAL" 1
fi

# ---- evaluate ---------------------------------------------------------------------------------------------------------------
step "reports: schema, histogram decode, percentile recompute"
mapfile -t all_reports < <(find "$OUT" -name '*.json' ! -name profile.json -exec grep -lE '"schema" ?: ?"lowlat-report/1"' {} + | sort)
if report_check "${all_reports[@]}" >/dev/null 2>"$OUT/report-check.err"; then
  ok "7 ${#all_reports[@]} reports validate (profile embedded: $(jget "${all_reports[0]}" .profile.host_label))"
else
  cat "$OUT/report-check.err" >&2
  report_check "${all_reports[@]}" >&2 || true
  bad "7 lowlat-report check failed"
fi
rm -f "$OUT/report-check.err"

step "criterion 1: memory per waiting task, on the quantity that shows the gap"
cf=$OUT/cpp-parked-coroutine.json
ot_f=$OUT/cpp-parked-os-thread.json
fb_f=$OUT/cpp-parked-fiber.json
crit_ratio "1" "C++ address space per task, os-thread over fiber (VmSize growth over $TASKS tasks)" \
  "$(counter "$ot_f" vm_size_bytes_per_task) over $(counter "$fb_f" vm_size_bytes_per_task)" \
  "$(ratio_milli "$(counter "$ot_f" vm_size_bytes_per_task)" "$(counter "$fb_f" vm_size_bytes_per_task)")" "$CPP_ADDRESS_THREAD_OVER_FIBER_MILLI"
crit_ratio "1" "C++ fiber stack bytes per task over the counted coroutine frame bytes" \
  "$(counter "$fb_f" fiber_stack_bytes) over $(counter "$cf" frame_bytes_per_task)" \
  "$(ratio_milli "$(counter "$fb_f" fiber_stack_bytes)" "$(counter "$cf" frame_bytes_per_task)")" "$CPP_FIBER_STACK_OVER_FRAME_MILLI"
crit_le "1" "C++ coroutine: frame bytes per parked task (exact, counting promise operator new, frames that escape)" "$(counter "$cf" frame_bytes_per_task)" "$FRAME_BYTES_MAX"
crit_exact "1" "C++ coroutine: frame allocations (exact), one per frame of $(counter "$cf" frames_parked)" "$(counter "$cf" frame_allocations)" "$(counter "$cf" frames_parked)"
printf '  observed: HALO on a coroutine that does not escape: %s of %s frames reached operator new (%s bytes per escaping frame)\n' \
  "$(counter "$cf" control_frame_allocations)" "$(counter "$cf" control_frames)" "$(counter "$cf" frame_bytes_per_task)"
jp=$OUT/java-parked-platform-thread.json
jv=$OUT/java-parked-virtual-thread.json
crit_ratio "1" "Java address space per task, platform-thread over virtual-thread heap per task (MemoryMXBean after System.gc())" \
  "$(counter "$jp" vm_size_bytes_per_task) over $(counter "$jv" heap_bytes_per_task)" \
  "$(ratio_milli "$(counter "$jp" vm_size_bytes_per_task)" "$(counter "$jv" heap_bytes_per_task)")" "$JAVA_ADDRESS_OVER_VT_HEAP_MILLI"
for build in gil free-threaded; do
  t=$(counter "$OUT/python/python-$build-parked-threads.json" rss_bytes_per_task)
  a=$(counter "$OUT/python/python-$build-parked-asyncio-tasks.json" tracemalloc_bytes_per_task)
  crit_ratio "1" "Python $build build: thread RSS bytes per task over asyncio task bytes (measured by tracemalloc, not exact)" "$t over $a" "$(ratio_milli "$t" "$a")" "$PY_TASK_FRACTION_MILLI"
  printf '  observed: Python %s build, asyncio RSS bytes per task %s, tracemalloc bytes per task %s, thread RSS bytes per task %s\n' "$build" \
    "$(counter "$OUT/python/python-$build-parked-asyncio-tasks.json" rss_bytes_per_task)" "$a" "$t"
done

step "criterion 2: parked tasks armed when the memory was read; RSS observed"
for f in "$OUT"/cpp-parked-fiber.json "$OUT"/cpp-parked-coroutine.json; do
  crit_exact "2" "$(basename "$f" .json): tasks that had reached their wait when the memory was read (exact)" "$(counter "$f" tasks_armed)" "$TASKS"
done
printf '  by construction (a latch or barrier opens only when all arrive, so these cannot differ; not a criterion): tasks armed %s of %s in the %s other parked runs\n' \
  "$TASKS" "$TASKS" "$(($(find "$OUT" -name '*parked-*.json' ! -name '*-fiber.json' ! -name '*-coroutine.json' | wc -l)))"
# RSS: observed. A parked thread's resident cost is a stack page or two plus its thread block, so the plan's 10x doesn't show in
# RSS; the ratios below are computed from this run, and the gap shows in the address space and kernel bytes printed with them.
ot=$(counter "$ot_f" rss_bytes_per_task)
fb=$(counter "$fb_f" rss_bytes_per_task)
co=$(counter "$cf" rss_bytes_per_task)
printf '  observed: RSS per task, C++ os-thread over fiber %s B / %s B = %sx, fiber over coroutine %s B / %s B = %sx (plan %sx)\n' \
  "$ot" "$fb" "$(margin "$ot" "$fb")" "$fb" "$co" "$(margin "$fb" "$co")" "$((PLAN_RSS_MILLI / 1000))"
printf '  observed: RSS per task, Java platform-thread over virtual-thread %s B / %s B = %sx; platform-thread RSS over virtual-thread heap %s B / %s B = %sx (plan %sx)\n' \
  "$(counter "$jp" rss_bytes_per_task)" "$(counter "$jv" rss_bytes_per_task)" "$(margin "$(counter "$jp" rss_bytes_per_task)" "$(counter "$jv" rss_bytes_per_task)")" \
  "$(counter "$jp" rss_bytes_per_task)" "$(counter "$jv" heap_bytes_per_task)" "$(margin "$(counter "$jp" rss_bytes_per_task)" "$(counter "$jv" heap_bytes_per_task)")" "$((PLAN_RSS_MILLI / 1000))"
for v in "${CPP_VARIANTS[@]}"; do
  f=$OUT/cpp-parked-$v.json
  printf '  observed: C++ %s: RSS %s B, RSS + page tables + kernel stack %s B, address space %s B per task; wake lateness p50 / p99 / p99.9 / max in ns: %s\n' \
    "$v" "$(counter "$f" rss_bytes_per_task)" "$(counter "$f" rss_page_tables_kernel_stack_bytes_per_task)" "$(counter "$f" vm_size_bytes_per_task)" "$(pct_line "$f")"
done
for v in "${JAVA_VARIANTS[@]}"; do
  f=$OUT/java-parked-$v.json
  printf '  observed: Java %s: RSS %s B, heap %s B, address space %s B, RSS + page tables + kernel stack %s B per task; wake lateness p50 / p99 / p99.9 / max in ns: %s\n' \
    "$v" "$(counter "$f" rss_bytes_per_task)" "$(counter "$f" heap_bytes_per_task)" "$(counter "$f" vm_size_bytes_per_task)" "$(counter "$f" rss_page_tables_kernel_stack_bytes_per_task)" "$(pct_line "$f")"
done
for build in gil free-threaded; do
  for v in "${PY_VARIANTS[@]}"; do
    f=$OUT/python/python-$build-parked-$v.json
    printf '  observed: Python %s build, %s: RSS %s B per task, address space %s B per task\n' "$build" "$v" "$(counter "$f" rss_bytes_per_task)" "$(counter "$f" vm_size_bytes_per_task)"
  done
done

step "criterion 3: voluntary context switches per round trip (exact counts)"
vols=()
for n in 1 2 3; do
  f=$OUT/cpp-pingpong-os-thread-alt$n.json
  vols+=("$(ratio_milli "$(jget "$f" .runtime.ctx_switches.voluntary)" "$(counter "$f" round_trips_served)")")
done
crit_ge "3" "C++ os-thread: voluntary switches per round trip in thousandths, the lowest of 3 alternations (${vols[*]}) (exact counts)" "$(min_of "${vols[@]}")" "$CTX_OS_THREAD_MIN_MILLI"
for v in fiber coroutine; do
  worst=0
  for n in 1 2 3; do
    f=$OUT/cpp-pingpong-$v-alt$n.json
    micro=$((1000000 * $(jget "$f" .runtime.ctx_switches.voluntary) / $(counter "$f" round_trips_served)))
    ((micro > worst)) && worst=$micro
  done
  crit_le "3" "C++ $v: voluntary switches per round trip in millionths, the highest of 3 alternations (exact counts)" "$worst" "$CTX_SAME_THREAD_MAX_MICRO"
done
printf '  observed: C++ os-thread on std::binary_semaphore: %s voluntary switches over %s round trips (the semaphore spins before it sleeps); p50 %s ns per round trip\n' \
  "$(jget "$OUT/cpp-pingpong-os-thread-semaphore.json" .runtime.ctx_switches.voluntary)" "$(counter "$OUT/cpp-pingpong-os-thread-semaphore.json" round_trips_served)" \
  "$(p50 "$OUT/cpp-pingpong-os-thread-semaphore.json")"
for v in "${JAVA_VARIANTS[@]}"; do
  f=$OUT/java-pingpong-$v-alt1.json
  printf '  observed: Java %s: %s voluntary switches over %s round trips\n' "$v" "$(jget "$f" .runtime.ctx_switches.voluntary)" "$(counter "$f" round_trips_served)"
done

step "criterion 4: round-trip p50, same run, median of $ROUNDS_ALT alternations"
r_fiber=() r_coro=() r_java=()
for n in 1 2 3; do
  ot=$(p50 "$OUT/cpp-pingpong-os-thread-alt$n.json")
  r_fiber+=("$(ratio_milli "$ot" "$(p50 "$OUT/cpp-pingpong-fiber-alt$n.json")")")
  r_coro+=("$(ratio_milli "$ot" "$(p50 "$OUT/cpp-pingpong-coroutine-alt$n.json")")")
  r_java+=("$(ratio_milli "$(p50 "$OUT/java-pingpong-platform-thread-alt$n.json")" "$(p50 "$OUT/java-pingpong-virtual-thread-alt$n.json")")")
done
crit_ratio "4" "C++ round-trip p50" "os-thread over fiber, per alternation: ${r_fiber[*]} thousandths" "$(median_of "${r_fiber[@]}")" "$PINGPONG_CPP_MILLI"
crit_ratio "4" "C++ round-trip p50" "os-thread over coroutine, per alternation: ${r_coro[*]} thousandths" "$(median_of "${r_coro[@]}")" "$PINGPONG_CPP_MILLI"
crit_ratio "4" "Java round-trip p50" "platform-thread over virtual-thread, per alternation: ${r_java[*]} thousandths" "$(median_of "${r_java[@]}")" "$PINGPONG_JAVA_MILLI"
for v in "${CPP_VARIANTS[@]}"; do
  printf '  C++ %s round trip p50 / p99 / p99.9 / max in ns, alternation 1: %s\n' "$v" "$(pct_line "$OUT/cpp-pingpong-$v-alt1.json")"
done
for v in "${JAVA_VARIANTS[@]}"; do
  printf '  Java %s round trip p50 / p99 / p99.9 / max in ns, alternation 1: %s\n' "$v" "$(pct_line "$OUT/java-pingpong-$v-alt1.json")"
done
for build in gil free-threaded; do
  for v in "${PY_VARIANTS[@]}"; do
    printf '  observed: Python %s build, %s round trip p50 / p99 / p99.9 / max in ns: %s\n' "$build" "$v" "$(pct_line "$OUT/python/python-$build-pingpong-$v.json")"
  done
done

step "criterion 5: a blocking call in a fiber or a coroutine, and the neighbours"
p99s=()
for n in 1 2 3; do p99s+=("$(p99 "$OUT/cpp-neighbours-fiber-blocking-alt$n.json")"); done
crit_ge "5" "C++ fiber with --blocking-sleep-in-fiber (a 2 ms std::this_thread::sleep_for): neighbours' wake lateness p99 in ns, the lowest of 3 alternations (${p99s[*]}); 2x by construction" \
  "$(min_of "${p99s[@]}")" "$NEIGHBOUR_P99_MIN_NS"
base=()
for n in 1 2 3; do base+=("$(p99 "$OUT/cpp-neighbours-fiber-alt$n.json")"); done
printf '  C++ fiber without the blocking call, wake lateness p99 in ns per alternation: %s\n' "${base[*]}"
for v in fiber fiber-blocking coroutine os-thread; do
  printf '  C++ neighbours %s wake lateness p50 / p99 / p99.9 / max in ns, alternation 1: %s\n' "$v" "$(pct_line "$OUT/cpp-neighbours-$v-alt1.json")"
done
pb=$OUT/python/python-gil-neighbours-asyncio-tasks-blocking.json
pbase=$OUT/python/python-gil-neighbours-asyncio-tasks.json
printf '  observed: Python asyncio wake lateness p50 / p99 / p99.9 / max in ns, without the blocking call: %s; with it: %s\n' "$(pct_line "$pbase")" "$(pct_line "$pb")"
printf '  observed: Python asyncio p99 with the blocking call over the baseline in the same run: %s ns / %s ns = %sx. asyncio rounds its epoll timeout up to a whole millisecond, so the baseline p99 already sits at or over 1 ms and p99 >= 1 ms does not separate the two.\n' \
  "$(p99 "$pb")" "$(p99 "$pbase")" "$(margin "$(p99 "$pb")" "$(p99 "$pbase")")"
lb=$(counter "$pb" wakes_over_1500us)
lbase=$(counter "$pbase" wakes_over_1500us)
nb=$(jget "$pb" .count)
nbase=$(jget "$pbase" .count)
# A baseline with no late wake at all counts as one, so the ratio is a floor, never a division by zero.
lr=$(ratio_milli "$((1000000 * lb / nb))" "$((1000000 * (lbase > 0 ? lbase : 1) / nbase))")
if ((PY_LATE_FRACTION_ASSERTED)); then
  crit_ratio "5" "Python asyncio: fraction of wakes later than 1.5 ms, blocking over baseline ($lb of $nb against $lbase of $nbase)" "same run" "$lr" "$PY_LATE_FRACTION_RATIO_MILLI"
else
  printf '  observed: Python asyncio wakes later than 1.5 ms: %s of %s with the blocking call, %s of %s without, ratio %sx\n' "$lb" "$nb" "$lbase" "$nbase" "$(margin "$lr" 1000)"
fi
pd=$OUT/python/python-gil-neighbours-asyncio-tasks-blocking-debug.json
crit_exact "5" "Python asyncio debug mode (slow_callback_duration 1 ms): 'Executing ... took N seconds' warnings against blocking calls (exact)" \
  "$(counter "$pd" slow_callback_warnings)" "$(counter "$pd" blocking_calls)"
for f in "$OUT"/cpp-neighbours-*.json "$OUT"/python/python-gil-neighbours-*.json; do
  crit_exact "5" "$(basename "$f" .json): tasks that started after their first deadline (exact)" "$(counter "$f" late_starts)" 0
done
jpin=$OUT/java-pinning-virtual-thread.json
printf '  observed: Java jdk.VirtualThreadPinned events (threshold 0) for %s virtual threads blocking %s ms: in a synchronized block %s (JEP 491), in a native frame %s\n' \
  "$(counter "$jpin" tasks_per_case)" "$(counter "$jpin" block_ms)" "$(counter "$jpin" pinned_events_synchronized)" "$(counter "$jpin" pinned_events_native_frame)"

step "criterion 6: the line"
for run in cpp-line-os-thread cpp-line-fiber cpp-line-coroutine java-line-platform-thread java-line-virtual-thread; do
  r=$OUT/$run.json
  count=$(jget "$r" .count)
  dropped=$(jget "$r" .dropped)
  diverts=$(counter "$r" divert_received)
  if ((count == LINE_COUNT && dropped == 0 && diverts == LINE_COUNT)); then
    ok "6 $run: count $count (bound == $LINE_COUNT), dropped $dropped (exact 0), divert commands received $diverts (exact $LINE_COUNT)"
  else
    bad "6 $run: count $count of $LINE_COUNT, dropped $dropped, divert commands received $diverts"
  fi
  printf '  %s end-to-end p50 / p99 / p99.9 / max in ns (observed): %s; divert command p99 %s ns; tasks started %s\n' "$run" "$(pct_line "$r")" \
    "$(jget "$OUT/$run-divert.json" .percentiles.p99)" "$(counter "$r" tasks_started)"
done

step "criterion 7: every report carries count, dropped = 0, build.flags, placement, python_build; the gates' skew; the round trips"
flags_ok=1 place_ok=1 skew_ok=1 gil_ok=1
for r in "${all_reports[@]}"; do
  name=${r#"$OUT"/}
  [[ $(jget "$r" .count) -gt 0 ]] || { bad "7 $name: count is 0"; flags_ok=0; }
  [[ $(jget "$r" .dropped) -eq 0 ]] || { bad "7 $name: dropped parcels"; flags_ok=0; }
  case $name in
    python/*)
      jq -e '.runtime.python_build | . == "gil" or . == "free-threaded"' "$r" >/dev/null || { bad "7 $name: runtime.python_build missing"; flags_ok=0; }
      if [[ $name == python/python-free-threaded-* ]]; then
        jq -e '.runtime.python_build == "free-threaded" and .build.gil_enabled == false' "$r" >/dev/null ||
          { bad "7 $name: the free-threaded measurement did not keep the GIL off"; gil_ok=0; }
      fi
      ;;
    *)
      jq -e '.build.flags | length > 0' "$r" >/dev/null || { bad "7 $name: build.flags missing"; flags_ok=0; }
      ;;
  esac
  # Every run that pins a thread records runtime.placement. By design nothing is pinned in the OS-thread, platform-thread and
  # Python-thread parked runs, the C++ os-thread neighbour run and the pinning run (their tasks float).
  case $name in
    cpp-parked-os-thread.json | cpp-neighbours-os-thread-* | java-parked-* | java-pinning-* | python/python-*-parked-threads.json) ;;
    *) jq -e '.runtime.placement.cpus | length > 0' "$r" >/dev/null || { bad "7 $name: runtime.placement missing"; place_ok=0; } ;;
  esac
  skew=$(jq -r '.runtime.counters.start_skew_ns // empty' "$r")
  if [[ -n $skew ]] && ((skew >= START_SKEW_MAX_NS)); then
    bad "7 $name: start gate skew $skew ns, bound < $START_SKEW_MAX_NS"
    skew_ok=0
  fi
done
((flags_ok)) && ok "7 ${#all_reports[@]} reports: count > 0, dropped = 0, build.flags (C++ and Java) and runtime.python_build (Python) present"
((place_ok)) && ok "7 every pinned run records runtime.placement (distinct_cores $(jget "$OUT/cpp-pingpong-fiber-alt1.json" .runtime.placement.distinct_cores), smt_siblings $(jget "$OUT/cpp-pingpong-fiber-alt1.json" .runtime.placement.smt_siblings))"
((skew_ok)) && ok "7 start gate skew under $START_SKEW_MAX_NS ns in every run that records it (a timing bound); C++ os-thread ping-pong $(counter "$OUT/cpp-pingpong-os-thread-alt1.json" start_skew_ns) ns, Java platform-thread $(counter "$OUT/java-pingpong-platform-thread-alt1.json" start_skew_ns) ns"
((gil_ok)) && ok "7 Python free-threaded build: the GIL stayed off from the imports to the end in every measurement"
for f in "$OUT"/cpp-pingpong-*.json "$OUT"/java-pingpong-*.json "$OUT"/python/python-*-pingpong-*.json; do
  name=$(basename "$f" .json)
  w=$(counter "$f" warmup_round_trips)
  if (($(counter "$f" round_trips) == ROUNDS && $(counter "$f" round_trips_served) == ROUNDS + w && $(counter "$f" payload_mismatch) == 0)); then :; else
    bad "7 $name: round trips $(counter "$f" round_trips) of $ROUNDS, served $(counter "$f" round_trips_served), payload mismatch $(counter "$f" payload_mismatch)"
  fi
done
ok "7 every ping-pong served exactly the configured round trips with the payload intact (exact)"

if [[ ${SMOKE:-0} == 1 ]]; then
  ok "SMOKE: script check finished with $FAILURES criteria not met at these sizes (not enforced, not a result); output in $OUT"
  exit 0
fi
((FAILURES == 0)) || die "$FAILURES criteria not met; results in $OUT"
ok "11-stackful-stackless: every criterion holds; results in $OUT"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
