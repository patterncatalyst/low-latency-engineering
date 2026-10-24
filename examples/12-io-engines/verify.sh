#!/usr/bin/env bash
# Ch12 verify: I/O engines and thread-per-core on the sortation line (C++, Java, Quarkus, Python).
#
# Every criterion is evaluated; each prints its measured value, its bound and the margin, and any miss fails the run
# after all of them have been evaluated. Latency ratios compare variants within THIS run: the variants alternate
# (A B C A B C A B C) and the criterion is the median of the three per-alternation ratios. Counters labelled "exact"
# are deterministic and need no median. A p50 is never compared across runs.
#   1  system calls per parcel at saturation, C++ (exact): io_uring_enter calls per parcel are at most 1/4 of epoll's
#      system calls per parcel (epoll_wait + recvmsg); recvmmsg makes fewer than 1 system call per parcel. CQEs per
#      enter are printed.
#   2  hand-offs per parcel (exact): thread-per-core 0, acceptor-pool 1.
#   3  saturation receive p99, C++, same run, median of 3: thread-per-core <= 1/2 of acceptor-pool. io-uring against
#      epoll p99 is observed.
#   4  Quarkus at lambda x W > pool (10 kHz x 2 ms = 20 in flight against 16 workers): worker-pool p99 >= 3x
#      virtual-thread p99, median of 3. event-loop against virtual-thread is observed.
#   5  defect blocking-on-event-loop: blocked-thread warnings >= 1 (exact, counted in process and from the log, and
#      the two must agree) and p99 >= 2 ms.
#   6  line, four simulator instances at 2.5 kHz x 20 s (200,000 parcels): count 200,000 and dropped 0 for every C++
#      variant, the plain-JDK variants and the Python variants. Percentiles are observed.
#   7  every report: lowlat-report check, build.flags (C++ and Java), runtime.counters, runtime.placement for pinned runs,
#      runtime.python_build for Python; the free-threaded runs kept the GIL off from start to end.
#   8  start gates: the recorded start skew of every multi-thread run is under 1 ms; every pinned thread is on the CPU it
#      was pinned to (read from /proc during the hold).
#   9  the Quarkus service counters (exact): the worker pool's active maximum equals the fixed pool size when the
#      load exceeds it; the event-loop variant uses no worker thread; the virtual-thread variant uses no worker thread;
#      the open-loop client saw no error, answered every request, and started (almost) none of them late.
# Observed, not asserted: asio-io-uring; io-uring against epoll tails; the plain-JDK variants against each other; every
# Python variant (asyncio-datagram, blocking-thread under both builds, uvloop); event-loop against virtual-thread; the
# strace -f -c cross-check (the summaries are committed, the raw output never is); CQEs per enter.
#
#   ./verify.sh                 build, run, assert
#   RECHECK=results/<run-id>    re-evaluate the committed reports without building or running anything
#   ALLOW_BUSY=1 ./verify.sh    measure while a lab VM or other load is running (noisy)
#   SKIP_BUILD=1 ./verify.sh    reuse existing builds
#   RESULTS_DIR=DIR             where reports go (default results/latest)
#   LOWLAT_BUILD=DIR            private C++ build directory
#   ONLY=cpp,java,python,quarkus   run only those lanes (a development aid: the criteria of the others are then not met)
#
# Run it under the host benchmark lock when another example measures on this host. UDP ports 47320-47323 (line),
# 47324-47327 (saturation), 47328-47331 (strace) and 47332-47335 (Python) on 127.0.0.1, TCP 47336 for the service.
# Threads are pinned to distinct physical cores with sched_setaffinity as an experiment control; that is not isolation.
# The simulators run on the cores left over, and the Quarkus server and the open-loop client get disjoint CPUs.
# Never changes the host: no sudo, no sysctl, no governor. io_uring is used only if the host allows it (read, never
# changed); on EPERM or ENOSYS the io_uring parts are skipped with the reason recorded.
# The free-threaded interpreter is a user-local download: `uv python install 3.14t`.
# shellcheck disable=SC2016
set -euo pipefail
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

EXAMPLE=12-io-engines
HERE=$(example_dir)
JAR=$HERE/java/target/io-engines-java.jar
QUARKUS_JAR=$HERE/quarkus/target/quarkus-app/quarkus-run.jar
MAIN=io.patterncatalyst.lowlat.ch12.Main

# ---- workload (override from the environment while calibrating; S10 sets the committed values) --------------------
CAMERAS=4
LINE_RATE=${LINE_RATE:-2500}                 # Hz per camera
LINE_SECONDS=${LINE_SECONDS:-20}
LINE_PER_CAMERA=$((LINE_RATE * LINE_SECONDS))
LINE_COUNT=$((LINE_PER_CAMERA * CAMERAS))
# Saturation: the highest rate (per camera) with dropped = 0 for the slowest variant of the lane. A variable, not a
# finding: S10 calibrates it. DECIDE_NS is the modelled decide work (the tracker lookup and the divert command's
# encode, which this example does not build) that gives one receive thread a capacity the simulators can exceed.
SAT_RATE_CPP=${SAT_RATE_CPP:-60000}
SAT_RATE_JAVA=${SAT_RATE_JAVA:-20000}
SAT_RATE_PY=${SAT_RATE_PY:-2000}
SAT_SECONDS=${SAT_SECONDS:-3}
DECIDE_NS=${DECIDE_NS:-3000}
JAVA_DECIDE_NS=${JAVA_DECIDE_NS:-3000}
# The service: lambda x W = Q_RATE x SERVICE_MS must exceed POOL (10 kHz x 2 ms = 20 in flight against 16 workers).
Q_RATE=${Q_RATE:-10000}
Q_SECONDS=${Q_SECONDS:-5}
Q_WARMUP_SECONDS=${Q_WARMUP_SECONDS:-3}
POOL=16                                      # quarkus.thread-pool.max-threads in application.properties
SERVICE_MS=2
ROUNDS=3
HOLD_MS=500
STRACE_RATE=2500
STRACE_SECONDS=4
# A JVM under strace -f runs far slower (every futex is a stop): the Java cross-check uses a rate it can keep up with, and
# no warm-up pass, so the summary holds the measured pass only and the counts line up with the report's.
STRACE_RATE_JAVA=250
UDP_LINE=47320
UDP_SAT=47324
UDP_STRACE=47328
UDP_PY=47332
Q_PORT=47336

# ---- provisional bounds (S10 calibrates; a miss is reported, never loosened here) -----------------------------------
URING_ENTER_PER_EPOLL_MAX_PERMILLE=250       # 1: io_uring_enter per parcel <= 1/4 of epoll's system calls per parcel
TPC_P99_RATIO_MAX_PERMILLE=500               # 3: thread-per-core p99 <= 1/2 of acceptor-pool p99
WORKER_POOL_P99_RATIO_MIN_PERMILLE=3000      # 4: worker-pool p99 >= 3x virtual-thread p99
DEFECT_WARNINGS_MIN=1                        # 5: blocked-thread warnings
DEFECT_P99_MIN_NS=2000000                    # 5: p99 >= 2 ms
START_SKEW_MAX_NS=1000000                    # 8: start gate skew < 1 ms
CLIENT_LATE_MAX_PERMILLE=10                  # 9: requests started over 1 ms late, per thousand sent

ENGINE_VARIANTS=(epoll recvmmsg io-uring)
LAYOUT_VARIANTS=(thread-per-core acceptor-pool)
CPP_LINE_VARIANTS=(epoll recvmmsg io-uring thread-per-core acceptor-pool asio-io-uring)
JAVA_VARIANTS=(selector virtual-thread-blocking thread-per-core)
PY_GIL_VARIANTS=(asyncio-datagram blocking-thread uvloop)
PY_FT_VARIANTS=(asyncio-datagram blocking-thread)
SERVICE_VARIANTS=(event-loop worker-pool virtual-thread blocking-on-event-loop)
JAVA_RECV_EXTRA=()
JVM=(-Xms1g -Xmx1g -XX:+AlwaysPreTouch -XX:+UseG1GC --enable-native-access=ALL-UNNAMED)
SERVER_JVM=(-Xms512m -Xmx512m -XX:+AlwaysPreTouch)

ONLY=${ONLY:-cpp,java,python,quarkus}
lane_on() { [[ ,$ONLY, == *,"$1",* ]]; }

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
  rm -rf "${OUT:?}"/{cpp,java,python,quarkus,strace} "${OUT:?}"/*.json "${OUT:?}"/*.log "${OUT:?}"/*.txt
  mkdir -p "$OUT/cpp" "$OUT/java" "$OUT/python" "$OUT/quarkus" "$OUT/strace"
  capture_profile "$OUT"
  scratch_dir
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
# crit_ratio_ge ID DESC DETAIL RATIO_MILLI BOUND_MILLI: median ratio >= bound, both in thousandths.
crit_ratio_ge() {
  local m
  m=$(margin "$4" "$5")
  if (($4 >= $5)); then
    ok "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x$(note_margin "$m")"
  else
    bad "$1 $2: measured $(margin "$4" 1000)x ($3), bound >= $(margin "$5" 1000)x, margin ${m}x"
  fi
}
# crit_ratio_le ID DESC DETAIL RATIO_MILLI BOUND_MILLI: median ratio <= bound; the margin is BOUND / RATIO.
crit_ratio_le() {
  local m
  m=$(margin "$5" "$4")
  if (($4 <= $5)); then
    ok "$1 $2: measured $(margin "$4" 1000)x ($3), bound <= $(margin "$5" 1000)x, margin ${m}x$(note_margin "$m")"
  else
    bad "$1 $2: measured $(margin "$4" 1000)x ($3), bound <= $(margin "$5" 1000)x, margin ${m}x"
  fi
}

p99() { jget "$1" .percentiles.p99; }
counter() { jget "$1" ".runtime.counters.$2"; }
# pct FILE: "p50 / p99 / p99.9 / max" in microseconds.
pct() { jget "$1" '"\(.percentiles.p50 / 1000 | floor) / \(.percentiles.p99 / 1000 | floor) / \(.percentiles.p99_9 / 1000 | floor) / \(.percentiles.max / 1000 | floor) us"'; }
# alt_ratio FILE_NUM FILE_DEN: the ratio of two p99 values in thousandths.
alt_ratio() { echo $((1000 * $(p99 "$1") / $(p99 "$2"))); }
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
  ok "placement: $n pinned threads of $(basename "$log" .log) run on the CPUs they were pinned to"
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

# ---- machine layout ----------------------------------------------------------------------------------------------------
# Five distinct physical cores other than CPU 0 for the pinned threads; the simulators and the open-loop client get the
# CPUs of the cores that are left (neither a pinned core nor its SMT sibling nor CPU 0's core), so the load generators
# never share a core with a thread under test. Fewer than two such CPUs: they run unpinned.
SIM_PREFIX=()
CLIENT_PREFIX=()
SERVER_PREFIX=()
if ((RUN)); then
  cores=$(distinct_cores 7) || die "need 6 distinct physical cores (5 to pin, CPU 0 left alone)"
  mapfile -t CORES < <(awk '$1 != 0' <<<"$cores" | head -n 5)
  ((${#CORES[@]} == 5)) || die "need 5 distinct physical cores other than CPU 0, found ${#CORES[@]}"
  CPUS=$(paste -sd, < <(printf '%s\n' "${CORES[@]}"))
  declare -A taken=()
  for cpu in 0 "${CORES[@]}"; do
    while read -r sib; do taken[$sib]=1; done < <(_cpu_expand "$(<"$_SYS_CPU/cpu$cpu/topology/thread_siblings_list")")
  done
  spare=()
  while read -r cpu; do [[ -n ${taken[$cpu]:-} ]] || spare+=("$cpu"); done < <(_allowed_cpus)
  if ((${#spare[@]} >= 2)); then
    SPARE_LIST=$(paste -sd, < <(printf '%s\n' "${spare[@]}"))
    SIM_PREFIX=(taskset -c "$SPARE_LIST")
    CLIENT_PREFIX=(taskset -c "$SPARE_LIST")
  fi
  SERVER_PREFIX=(taskset -c "$(paste -sd, < <(printf '%s\n' "${CORES[@]:0:4}"))")
  ok "layout: pinned threads on CPUs $CPUS; load generators on ${SPARE_LIST:-any CPU (too few spare cores to separate)}; service on 4 of the pinned cores"
fi

# ---- build and unit tests ------------------------------------------------------------------------------------------
if ((RUN)); then
  uv python find 3.14t >/dev/null 2>&1 || die "no free-threaded Python: uv python install 3.14t (a user-local download)"
  build_cpp io-receive io-receive-asio io-test line-simulator
  RECV=$(cpp_bin io-receive)
  RECV_ASIO=$(cpp_bin io-receive-asio)
  SIM_BIN=$(cpp_bin line-simulator)
  BUILD_JAVA_TESTS=1 build_java "$HERE/java"
  if [[ ${SKIP_BUILD:-0} != 1 ]]; then
    step "building the Quarkus service on the plain JVM (fast-jar), with its @QuarkusTests"
    mvn -B -q -f "$HERE/quarkus/pom.xml" verify >"$OUT/quarkus-build.log" 2>&1 || { tail -30 "$OUT/quarkus-build.log" >&2; die "Quarkus build or tests failed"; }
    rm -f "$OUT/quarkus-build.log"
  fi
  [[ -f $JAR && -f $QUARKUS_JAR ]] || die "missing $JAR or $QUARKUS_JAR (build first)"
  py_sync

  step "unit tests: C++ (GoogleTest), Python under the GIL and under the free-threaded build; Java and Quarkus ran during the build"
  "$(cpp_bin io-test)" --gtest_brief=1 >"$OUT/cpp-unit-tests.log" 2>&1 || { tail -20 "$OUT/cpp-unit-tests.log" >&2; die "C++ unit tests failed"; }
  uvrun pytest -q "$HERE/io-py/tests" >"$OUT/python-unit-tests-gil.log" 2>&1 || { tail -20 "$OUT/python-unit-tests-gil.log" >&2; die "Python (GIL) tests failed"; }
  (cd "$LOWLAT_EXAMPLES" && LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$LOWLAT_EXAMPLES/.venv-ft \
    uv run -q --python 3.14t --all-packages pytest -q "$HERE/io-py/tests") >"$OUT/python-unit-tests-free-threaded.log" 2>&1 ||
    { tail -20 "$OUT/python-unit-tests-free-threaded.log" >&2; die "Python (free-threaded) tests failed"; }
  ok "C++, Java, Quarkus and Python (both builds) unit tests pass"

  URING_OK=1
  set +e
  "$RECV" --probe-uring >"$OUT/uring-probe.txt" 2>&1
  uring_rc=$?
  set -e
  if ((uring_rc != 0)); then
    URING_OK=0
    ok "io_uring unavailable on this host ($(tr -d '\n' <"$OUT/uring-probe.txt")): the io_uring parts are skipped"
    echo "skipped: $(tr -d '\n' <"$OUT/uring-probe.txt")" >"$OUT/uring-skipped.txt"
    ((uring_rc == 77)) || die "io_uring probe failed with status $uring_rc, which is neither success nor a skip"
  else
    ok "io_uring available here ($(tr -d '\n' <"$OUT/uring-probe.txt"))"
  fi
  STRACE_OK=1
  set +e
  strace_summary "$LOWLAT_SCRATCH/strace-probe.txt" -- true >/dev/null 2>"$LOWLAT_SCRATCH/strace-probe.err"
  strace_rc=$?
  set -e
  if ((strace_rc == 77)); then
    STRACE_OK=0
    echo "skipped: $(tr -d '\n' <"$LOWLAT_SCRATCH/strace-probe.err")" >"$OUT/strace-skipped.txt"
    ok "strace cross-check skipped: $(tr -d '\n' <"$LOWLAT_SCRATCH/strace-probe.err")"
  fi
else
  URING_OK=1
  [[ -f $OUT/uring-skipped.txt ]] && URING_OK=0
fi

# ---- running one pass ----------------------------------------------------------------------------------------------------
# run_load LOG PINS BASE RATE SECONDS CMD...: start CMD (which pins its threads, prints "pinned ..." lines,
# "placement-ready", holds, prints "released"), check the pins from /proc during the hold, then start the four
# simulators at RATE for SECONDS and wait for everything. The receivers bind before the hold ends, so a bound port does
# not mean the run has started; "released" does. Returns CMD's status.
run_load() {
  local log=$1 pins=$2 base=$3 rate=$4 seconds=$5 pid i rc=0
  shift 5
  local -a sims=()
  "$@" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_log_line '^placement-ready$' "$log" "$pid" >/dev/null
  check_pins "$log" "$pins"
  wait_log_line '^released$' "$log" "$pid" >/dev/null
  for ((i = 0; i < CAMERAS; i++)); do
    wait_udp_bound $((base + i)) "$pid" "$log"
  done
  for ((i = 0; i < CAMERAS; i++)); do
    "${SIM_PREFIX[@]}" "$SIM_BIN" --rate "$rate" --duration "$seconds" --dest "127.0.0.1:$((base + i))" --wire flat --quiet >>"$log" 2>&1 &
    sims+=($!)
    bg_track "$!"
  done
  for i in "${sims[@]}"; do
    wait "$i" || { tail -20 "$log" >&2; die "a simulator instance failed"; }
    bg_forget "$i"
  done
  wait "$pid" || rc=$?
  bg_forget "$pid"
  return "$rc"
}

# pins_cpp VARIANT: how many threads the C++ variant pins.
pins_cpp() {
  case $1 in
    thread-per-core) echo 4 ;;
    acceptor-pool) echo 5 ;;
    *) echo 1 ;;
  esac
}

# cpp_run VARIANT RATE SECONDS BASE REPORT [WRAP...]: one C++ pass; WRAP (e.g. strace_summary OUT --) goes in front of the command.
cpp_run() {
  local variant=$1 rate=$2 seconds=$3 base=$4 report=$5 log
  shift 5
  log=${report%.json}.log
  local -a cmd=("$RECV" --variant "$variant") wrap=("$@")
  [[ $variant == asio-io-uring ]] && cmd=("$RECV_ASIO")
  cmd+=(--base-port "$base" --expect $((rate * seconds)) --cpus "$CPUS" --hold-ms "$HOLD_MS" --decide-ns "$DECIDE_NS" --report "$report")
  run_load "$log" "$(pins_cpp "$variant")" "$base" "$rate" "$seconds" "${wrap[@]}" "${cmd[@]}" ||
    { tail -30 "$log" >&2; die "C++ $variant failed"; }
}

# java_run VARIANT RATE SECONDS BASE REPORT [WRAP...]
java_run() {
  local variant=$1 rate=$2 seconds=$3 base=$4 report=$5 log pins=1
  shift 5
  log=${report%.json}.log
  local -a jvm=("${JVM[@]}") wrap=("$@")
  case $variant in
    virtual-thread-blocking) jvm+=(-Djdk.virtualThreadScheduler.parallelism=1 -Djdk.virtualThreadScheduler.maxPoolSize=1); pins=4 ;;
    thread-per-core) pins=4 ;;
  esac
  run_load "$log" "$pins" "$base" "$rate" "$seconds" "${wrap[@]}" java "${jvm[@]}" -cp "$JAR" "$MAIN" receive --variant "$variant" \
    --base-port "$base" --expect $((rate * seconds)) --cpus "$CPUS" --hold-ms "$HOLD_MS" --decide-ns "$JAVA_DECIDE_NS" --report "$report" \
    "${JAVA_RECV_EXTRA[@]}" ||
    { tail -30 "$log" >&2; die "Java $variant failed"; }
}

# py_run BUILD VARIANT RATE SECONDS BASE REPORT [WRAP...]: measure in the named build (no lowlat_measure in the measuring
# process), then convert the raw samples and the sidecar to a report in the GIL workspace environment.
py_run() {
  local build=$1 variant=$2 rate=$3 seconds=$4 base=$5 report=$6 log pins=1 raw
  shift 6
  log=${report%.json}.log
  raw=$LOWLAT_SCRATCH/py-$build-$variant-$(basename "$report" .json)
  [[ $variant == blocking-thread ]] && pins=4
  local -a wrap=("$@") cmd
  # The environments' own interpreters, so that neither `uv run` nor its start-up sits between the process under test and strace.
  if [[ $build == free-threaded ]]; then
    cmd=("$LOWLAT_EXAMPLES/.venv-ft/bin/python" -m lowlat_io)
  else
    cmd=("$LOWLAT_EXAMPLES/.venv/bin/python" -m lowlat_io)
  fi
  cmd+=(receive --variant "$variant" --base-port "$base" --expect $((rate * seconds)) --cpus "$CPUS" --hold-ms "$HOLD_MS" --out "$raw")
  run_load "$log" "$pins" "$base" "$rate" "$seconds" "${wrap[@]}" "${cmd[@]}" || { tail -30 "$log" >&2; die "Python $build $variant failed"; }
  from_samples "$raw/samples.bin" "$raw/sidecar.json" "$report"
}

# ---- C++: saturation (criteria 1-3), line (6), strace ------------------------------------------------------------------
if ((RUN)) && lane_on cpp; then
  if ((URING_OK)); then
    sat_variants=("${ENGINE_VARIANTS[@]}" "${LAYOUT_VARIANTS[@]}")
  else
    sat_variants=(epoll recvmmsg)
  fi
  alt_run() { step "C++ saturation: $1 at $SAT_RATE_CPP Hz x $CAMERAS cameras (alternation $2)"; cpp_run "$1" "$SAT_RATE_CPP" "$SAT_SECONDS" "$UDP_SAT" "$OUT/cpp/$1-sat-alt$2.json"; }
  each_alt "${sat_variants[@]}"
  if ((URING_OK)); then
    step "C++ saturation: asio-io-uring (observed)"
    cpp_run asio-io-uring "$SAT_RATE_CPP" "$SAT_SECONDS" "$UDP_SAT" "$OUT/cpp/asio-io-uring-sat.json"
  fi
  for v in "${CPP_LINE_VARIANTS[@]}"; do
    if ((!URING_OK)) && [[ $v == io-uring || $v == thread-per-core || $v == acceptor-pool || $v == asio-io-uring ]]; then continue; fi
    step "C++ line: $v, $CAMERAS simulator instances at $LINE_RATE Hz x $LINE_SECONDS s, UDP $UDP_LINE-$((UDP_LINE + CAMERAS - 1))"
    cpp_run "$v" "$LINE_RATE" "$LINE_SECONDS" "$UDP_LINE" "$OUT/cpp/$v-line.json"
  done
  if ((STRACE_OK)); then
    for v in epoll recvmmsg io-uring asio-io-uring; do
      if ((!URING_OK)) && [[ $v == io-uring || $v == asio-io-uring ]]; then continue; fi
      step "C++ strace -f -c cross-check: $v at $STRACE_RATE Hz x $STRACE_SECONDS s"
      cpp_run "$v" "$STRACE_RATE" "$STRACE_SECONDS" "$UDP_STRACE" "$OUT/cpp/$v-strace.json" strace_summary "$OUT/strace/cpp-$v.txt" --
    done
  fi
fi

# ---- Java: plain-JDK micro lane ---------------------------------------------------------------------------------------------
if ((RUN)) && lane_on java; then
  alt_run() { step "Java saturation: $1 at $SAT_RATE_JAVA Hz x $CAMERAS cameras (alternation $2)"; java_run "$1" "$SAT_RATE_JAVA" "$SAT_SECONDS" "$UDP_SAT" "$OUT/java/$1-sat-alt$2.json"; }
  each_alt "${JAVA_VARIANTS[@]}"
  for v in "${JAVA_VARIANTS[@]}"; do
    step "Java line: $v, $CAMERAS simulator instances at $LINE_RATE Hz x $LINE_SECONDS s"
    java_run "$v" "$LINE_RATE" "$LINE_SECONDS" "$UDP_LINE" "$OUT/java/$v-line.json"
  done
  if ((STRACE_OK)); then
    for v in selector virtual-thread-blocking; do
      step "Java strace -f -c cross-check: $v at $STRACE_RATE_JAVA Hz x $STRACE_SECONDS s, no warm-up pass"
      JAVA_RECV_EXTRA=(--warmup-parcels-per-camera 0)
      java_run "$v" "$STRACE_RATE_JAVA" "$STRACE_SECONDS" "$UDP_STRACE" "$OUT/java/$v-strace.json" strace_summary "$OUT/strace/java-$v.txt" --
      JAVA_RECV_EXTRA=()
    done
  fi
fi

# ---- Python (both builds) ------------------------------------------------------------------------------------------------
if ((RUN)) && lane_on python; then
  for build in gil free-threaded; do
    if [[ $build == gil ]]; then variants=("${PY_GIL_VARIANTS[@]}"); else variants=("${PY_FT_VARIANTS[@]}"); fi
    for v in "${variants[@]}"; do
      step "Python line: $v in the $build build, $CAMERAS simulator instances at $LINE_RATE Hz x $LINE_SECONDS s"
      py_run "$build" "$v" "$LINE_RATE" "$LINE_SECONDS" "$UDP_PY" "$OUT/python/$build-$v-line.json"
      step "Python saturation (observed): $v in the $build build at $SAT_RATE_PY Hz x $CAMERAS cameras"
      py_run "$build" "$v" "$SAT_RATE_PY" "$SAT_SECONDS" "$UDP_PY" "$OUT/python/$build-$v-sat.json"
    done
  done
  if ((STRACE_OK)); then
    for spec in "gil asyncio-datagram" "gil blocking-thread" "gil uvloop" "free-threaded blocking-thread"; do
      read -r build v <<<"$spec"
      step "Python strace -f -c cross-check: $v in the $build build at $STRACE_RATE Hz x $STRACE_SECONDS s"
      py_run "$build" "$v" "$STRACE_RATE" "$STRACE_SECONDS" "$UDP_PY" "$OUT/python/$build-$v-strace.json" strace_summary "$OUT/strace/python-$build-$v.txt" --
    done
  fi
fi

# ---- Quarkus service (criteria 4, 5, 9) -----------------------------------------------------------------------------------------
# quarkus_run VARIANT ALT: start the service (fast-jar, plain JVM) on four pinned cores, drive it with the open-loop client
# on the spare CPUs, stop it, and count the blocked-thread warnings in its log. The server log stays out of the results
# directory (a defect run logs thousands of warnings); only the counts and a short sample are kept.
quarkus_run() {
  local variant=$1 alt=$2 server_log client_log spid i rc=0
  local -a profile=()
  server_log=$LOWLAT_SCRATCH/server-$variant-alt$alt.log
  client_log=$OUT/quarkus/$variant-alt$alt.log
  [[ $variant == blocking-on-event-loop ]] && profile=(-Dquarkus.profile=defect)
  "${SERVER_PREFIX[@]}" java "${SERVER_JVM[@]}" "${profile[@]}" -Dquarkus.http.port="$Q_PORT" -jar "$QUARKUS_JAR" >"$server_log" 2>&1 &
  spid=$!
  bg_track "$spid"
  for ((i = 0; i < 300; i++)); do
    curl -sf "http://127.0.0.1:$Q_PORT/stats" >/dev/null 2>&1 && break
    kill -0 "$spid" 2>/dev/null || { tail -30 "$server_log" >&2; die "the service exited before it was ready"; }
    sleep 0.1
  done
  ((i < 300)) || die "the service did not answer on $Q_PORT within 30 s"
  "${CLIENT_PREFIX[@]}" java -Xms256m -Xmx256m -cp "$JAR" "$MAIN" client --variant "$variant" --base-url "http://127.0.0.1:$Q_PORT" \
    --rate "$Q_RATE" --seconds "$Q_SECONDS" --warmup-seconds "$Q_WARMUP_SECONDS" --pool "$POOL" --service-time-ms "$SERVICE_MS" \
    --report "$OUT/quarkus/$variant-alt$alt.json" >"$client_log" 2>&1 || rc=$?
  kill "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null || true
  bg_forget "$spid"
  ((rc == 0)) || { tail -30 "$client_log" >&2; die "the open-loop client failed for $variant"; }
  local in_log
  in_log=$(grep -c 'has been blocked for' "$server_log" || true)
  printf '%s alt%s %s\n' "$variant" "$alt" "$in_log" >>"$OUT/quarkus/blocked-thread-warnings-in-log.txt"
  if [[ $variant == blocking-on-event-loop && $alt == 1 ]]; then
    grep -m3 'has been blocked for' "$server_log" | python3 "$LOWLAT_ROOT/scripts/scrub-host-ids.py" --filter >"$OUT/quarkus/blocked-thread-warning-sample.txt" || true
  fi
}
if ((RUN)) && lane_on quarkus; then
  alt_run() { step "Quarkus service: $1 at $Q_RATE Hz (alternation $2): $Q_RATE Hz x $SERVICE_MS ms = $((Q_RATE * SERVICE_MS / 1000)) in flight against a pool of $POOL"; quarkus_run "$1" "$2"; }
  each_alt "${SERVICE_VARIANTS[@]}"
fi

# ---- evaluate ---------------------------------------------------------------------------------------------------------------
mapfile -t all_reports < <(find "$OUT" -name '*.json' ! -name profile.json -exec grep -lE '"schema" ?: ?"lowlat-report/1"' {} + | sort)
((${#all_reports[@]} > 0)) || die "no reports under $OUT"

step "reports: schema, histogram decode, percentile recompute"
if report_check "${all_reports[@]}" >/dev/null 2>"$OUT/report-check.err"; then
  ok "7 ${#all_reports[@]} reports validate (profile embedded: $(jget "${all_reports[0]}" .profile.host_label))"
else
  cat "$OUT/report-check.err" >&2
  report_check "${all_reports[@]}" >&2 || true
  bad "7 lowlat-report check failed"
fi
rm -f "$OUT/report-check.err"

have() { [[ -f $1 ]]; }

if lane_on cpp && have "$OUT/cpp/epoll-sat-alt1.json"; then
  step "criterion 1: system calls per parcel at saturation, C++ (exact)"
  if ((URING_OK)); then
    for n in 1 2 3; do
      e=$OUT/cpp/epoll-sat-alt$n.json u=$OUT/cpp/io-uring-sat-alt$n.json m=$OUT/cpp/recvmmsg-sat-alt$n.json
      ep=$(counter "$e" parcels) es=$(counter "$e" syscalls) up=$(counter "$u" parcels) ue=$(counter "$u" io_uring_enter_calls)
      uc=$(counter "$u" cqes) mp=$(counter "$m" parcels) ms=$(counter "$m" syscalls)
      per_epoll=$((es * 1000 / ep)) per_enter=$((ue * 1000 / up))
      # enters/parcel <= (bound/1000) x epoll syscalls/parcel, cross-multiplied so it stays exact in integers
      if ((ue * ep * 1000 <= URING_ENTER_PER_EPOLL_MAX_PERMILLE * es * up)); then
        ok "1 alt$n: io_uring_enter per parcel ${per_enter}/1000 <= $URING_ENTER_PER_EPOLL_MAX_PERMILLE/1000 x epoll's system calls per parcel ${per_epoll}/1000 (exact counters; margin $(margin $((URING_ENTER_PER_EPOLL_MAX_PERMILLE * es * up)) $((ue * ep * 1000)))x)"
      else
        bad "1 alt$n: io_uring_enter per parcel ${per_enter}/1000 > $URING_ENTER_PER_EPOLL_MAX_PERMILLE/1000 x epoll's system calls per parcel ${per_epoll}/1000 (exact counters)"
      fi
      if ((ms < mp)); then
        ok "1 alt$n: recvmmsg makes $ms system calls for $mp parcels, ${ms}x1000/${mp} = $((ms * 1000 / mp))/1000 per parcel < 1 (exact)"
      else
        bad "1 alt$n: recvmmsg makes $ms system calls for $mp parcels, not fewer than 1 per parcel (exact)"
      fi
      printf '  observed (exact): alt%s CQEs per io_uring_enter %s.%02d; epoll_wait per parcel %s/1000, recvmsg per parcel %s/1000\n' "$n" \
        $((uc / ue)) $((uc * 100 / ue % 100)) "$(($(counter "$e" epoll_wait_calls) * 1000 / ep))" "$(($(counter "$e" recvmsg_calls) * 1000 / ep))"
    done
  else
    for n in 1 2 3; do
      e=$OUT/cpp/epoll-sat-alt$n.json m=$OUT/cpp/recvmmsg-sat-alt$n.json
      ms=$(counter "$m" syscalls) mp=$(counter "$m" parcels)
      ((ms < mp)) && ok "1 alt$n: recvmmsg $ms system calls for $mp parcels (< 1 per parcel, exact); io_uring skipped" ||
        bad "1 alt$n: recvmmsg $ms system calls for $mp parcels (not < 1 per parcel)"
    done
  fi

  if ((URING_OK)); then
    step "criterion 2: cross-thread hand-offs per parcel (exact)"
    for n in 1 2 3; do
      t=$OUT/cpp/thread-per-core-sat-alt$n.json p=$OUT/cpp/acceptor-pool-sat-alt$n.json
      crit_exact "2" "thread-per-core alt$n: hand-offs" "$(counter "$t" handoffs)" 0
      crit_exact "2" "acceptor-pool alt$n: hand-offs, one per parcel ($(counter "$p" parcels) parcels)" "$(counter "$p" handoffs)" "$(counter "$p" parcels)"
    done

    step "criterion 3: saturation receive p99, thread-per-core against acceptor-pool, same run, median of 3"
    ratios=() e_vs_u=()
    for n in 1 2 3; do
      ratios+=("$(alt_ratio "$OUT/cpp/thread-per-core-sat-alt$n.json" "$OUT/cpp/acceptor-pool-sat-alt$n.json")")
      e_vs_u+=("$(alt_ratio "$OUT/cpp/io-uring-sat-alt$n.json" "$OUT/cpp/epoll-sat-alt$n.json")")
    done
    crit_ratio_le "3" "C++ saturation p99" "thread-per-core over acceptor-pool, per alternation: ${ratios[*]} thousandths" "$(median_of "${ratios[@]}")" "$TPC_P99_RATIO_MAX_PERMILLE"
    printf '  observed: C++ io-uring over epoll p99 per alternation: %s thousandths (median %s)\n' "${e_vs_u[*]}" "$(median_of "${e_vs_u[@]}")"
  fi
  for v in epoll recvmmsg io-uring thread-per-core acceptor-pool; do
    have "$OUT/cpp/$v-sat-alt1.json" || continue
    printf '  C++ saturation %s p50 / p99 / p99.9 / max, alternation 1: %s; dropped %s\n' "$v" "$(pct "$OUT/cpp/$v-sat-alt1.json")" "$(jget "$OUT/cpp/$v-sat-alt1.json" .dropped)"
  done
  have "$OUT/cpp/asio-io-uring-sat.json" && printf '  observed: C++ saturation asio-io-uring p50 / p99 / p99.9 / max: %s; dropped %s\n' "$(pct "$OUT/cpp/asio-io-uring-sat.json")" "$(jget "$OUT/cpp/asio-io-uring-sat.json" .dropped)"
fi

if lane_on quarkus && have "$OUT/quarkus/virtual-thread-alt1.json"; then
  step "criterion 4: Quarkus p99 at lambda x W > pool, worker-pool against virtual-thread, same run, median of 3"
  ratios=() el=()
  for n in 1 2 3; do
    ratios+=("$(alt_ratio "$OUT/quarkus/worker-pool-alt$n.json" "$OUT/quarkus/virtual-thread-alt$n.json")")
    el+=("$(alt_ratio "$OUT/quarkus/event-loop-alt$n.json" "$OUT/quarkus/virtual-thread-alt$n.json")")
  done
  crit_ratio_ge "4" "Quarkus p99" "worker-pool over virtual-thread, per alternation: ${ratios[*]} thousandths" "$(median_of "${ratios[@]}")" "$WORKER_POOL_P99_RATIO_MIN_PERMILLE"
  printf '  observed: Quarkus event-loop over virtual-thread p99 per alternation: %s thousandths (median %s)\n' "${el[*]}" "$(median_of "${el[@]}")"
  for v in "${SERVICE_VARIANTS[@]}"; do
    printf '  Quarkus %s p50 / p99 / p99.9 / max, alternation 1: %s\n' "$v" "$(pct "$OUT/quarkus/$v-alt1.json")"
  done

  step "criterion 5: defect blocking-on-event-loop"
  for n in 1 2 3; do
    f=$OUT/quarkus/blocking-on-event-loop-alt$n.json
    w=$(counter "$f" blocked_thread_warnings)
    in_log=$(awk -v a="alt$n" '$1 == "blocking-on-event-loop" && $2 == a {print $3}' "$OUT/quarkus/blocked-thread-warnings-in-log.txt")
    crit_ge "5" "alt$n blocked-thread warnings (exact, counted in process)" "$w" "$DEFECT_WARNINGS_MIN"
    crit_exact "5" "alt$n warnings counted in process equal the log's 'has been blocked for' lines" "$w" "$in_log"
    crit_ge "5" "alt$n p99 in ns" "$(p99 "$f")" "$DEFECT_P99_MIN_NS"
  done
  for v in event-loop worker-pool virtual-thread; do
    for n in 1 2 3; do
      in_log=$(awk -v v="$v" -v a="alt$n" '$1 == v && $2 == a {print $3}' "$OUT/quarkus/blocked-thread-warnings-in-log.txt")
      ((in_log == 0)) || bad "5 $v alt$n: $in_log blocked-thread warnings in the log of a variant that never blocks the loop"
    done
  done

  step "criterion 9: Quarkus service counters (exact) and the open-loop client"
  for n in 1 2 3; do
    for v in "${SERVICE_VARIANTS[@]}"; do
      f=$OUT/quarkus/$v-alt$n.json
      sent=$(counter "$f" sent)
      [[ $(counter "$f" completed) -eq $sent && $(counter "$f" errors) -eq 0 ]] || bad "9 $v alt$n: completed $(counter "$f" completed) of $sent, errors $(counter "$f" errors)"
      late=$(counter "$f" late_starts_over_1ms)
      ((late * 1000 <= CLIENT_LATE_MAX_PERMILLE * sent)) || bad "9 $v alt$n: the client started $late of $sent requests over 1 ms late (bound $CLIENT_LATE_MAX_PERMILLE per thousand): a request may have waited in the client"
      ((n == 1)) && printf '  %s: client max in flight %s (Little'"'"'s law %s), late starts over 1 ms %s of %s, service in-handler max %s, event-loop threads %s, worker threads %s (active max %s), carrier threads %s\n' \
        "$v" "$(counter "$f" max_in_flight)" "$((Q_RATE * SERVICE_MS / 1000))" "$late" "$sent" "$(counter "$f" service_in_handler_max)" \
        "$(counter "$f" event_loop_threads_seen)" "$(counter "$f" worker_threads_seen)" "$(counter "$f" worker_active_max)" "$(counter "$f" carrier_threads)"
    done
    f=$OUT/quarkus/worker-pool-alt$n.json
    crit_exact "9" "worker-pool alt$n: worker pool active maximum equals the fixed pool size (load exceeds it)" "$(counter "$f" worker_active_max)" "$POOL"
    crit_le "9" "worker-pool alt$n: worker threads seen" "$(counter "$f" worker_threads_seen)" "$POOL"
    crit_exact "9" "event-loop alt$n: worker threads seen" "$(counter "$OUT/quarkus/event-loop-alt$n.json" worker_threads_seen)" 0
    crit_exact "9" "virtual-thread alt$n: worker threads seen" "$(counter "$OUT/quarkus/virtual-thread-alt$n.json" worker_threads_seen)" 0
    crit_ge "9" "virtual-thread alt$n: carrier threads (at least one)" "$(counter "$OUT/quarkus/virtual-thread-alt$n.json" carrier_threads)" 1
    crit_ge "9" "virtual-thread alt$n: client max in flight exceeds the pool (lambda x W > $POOL)" "$(counter "$OUT/quarkus/virtual-thread-alt$n.json" max_in_flight)" $((POOL + 1))
  done
fi

step "criterion 6: the line"
for f in "$OUT"/cpp/*-line.json "$OUT"/java/*-line.json "$OUT"/python/*-line.json; do
  have "$f" || continue
  name=${f#"$OUT"/}
  count=$(jget "$f" .count) dropped=$(jget "$f" .dropped)
  if ((count == LINE_COUNT && dropped == 0)); then
    ok "6 $name: count $count (bound == $LINE_COUNT), dropped $dropped (exact 0); p50 / p99 / p99.9 / max (observed): $(pct "$f")"
  else
    bad "6 $name: count $count of $LINE_COUNT, dropped $dropped"
  fi
done

step "criterion 8: start gates"
for f in "${all_reports[@]}"; do
  name=${f#"$OUT"/}
  case $name in quarkus/* | *-lateness.json | *-strace.json) continue ;; esac
  threads=$(counter "$f" threads)
  skew=$(counter "$f" start_skew_ns)
  if ((threads > 1)); then
    if ((skew < START_SKEW_MAX_NS)); then :; else bad "8 $name: start skew $skew ns over $threads threads (bound < $START_SKEW_MAX_NS)"; fi
  fi
done
skews=$(for f in "${all_reports[@]}"; do case ${f#"$OUT"/} in quarkus/* | *-lateness.json | *-strace.json) continue ;; esac; [[ $(counter "$f" threads) -gt 1 ]] && counter "$f" start_skew_ns; done | sort -n | tail -1)
[[ -z $skews ]] || ok "8 largest start skew over every multi-thread run: $skews ns (bound < $START_SKEW_MAX_NS)"

step "criterion 7: every report carries build.flags, counters, placement, python_build"
flags_ok=1 place_ok=1
for r in "${all_reports[@]}"; do
  name=${r#"$OUT"/}
  case $name in *-lateness.json) continue ;; esac
  jq -e '.runtime.counters | length > 0' "$r" >/dev/null || { bad "7 $name: runtime.counters missing"; flags_ok=0; }
  case $name in
    python/*)
      jq -e '.runtime.python_build | . == "gil" or . == "free-threaded"' "$r" >/dev/null || { bad "7 $name: runtime.python_build missing"; flags_ok=0; }
      jq -e '.runtime.placement.cpus | length > 0' "$r" >/dev/null || { bad "7 $name: runtime.placement missing"; place_ok=0; }
      if [[ $name == python/free-threaded-* ]]; then
        jq -e '.build.gil_enabled == false and .runtime.python_build == "free-threaded"' "$r" >/dev/null || { bad "7 $name: the free-threaded run had the GIL on"; flags_ok=0; }
      fi
      ;;
    quarkus/*)
      jq -e '.build.flags | length > 0' "$r" >/dev/null || { bad "7 $name: build.flags missing"; flags_ok=0; }
      ;;
    *)
      jq -e '.build.flags | length > 0' "$r" >/dev/null || { bad "7 $name: build.flags missing"; flags_ok=0; }
      jq -e '.runtime.placement.cpus | length > 0' "$r" >/dev/null || { bad "7 $name: runtime.placement missing"; place_ok=0; }
      ;;
  esac
done
((flags_ok)) && ok "7 ${#all_reports[@]} reports: runtime.counters, build.flags (C++ and Java), runtime.python_build (Python), GIL off in the free-threaded runs"
((place_ok)) && ok "7 every pinned run records runtime.placement"

# ---- observed: strace cross-check ---------------------------------------------------------------------------------------------
# strace_calls FILE SYSCALL: the calls column of a strace -c summary line (the name is the last field).
strace_calls() { awk -v s="$2" '$NF == s {print $4; found = 1} END {if (!found) print 0}' "$1"; }
step "observed: strace -f -c against the in-program counters (the same run: the program under strace is the one that wrote the report)"
if [[ -f $OUT/strace-skipped.txt ]]; then
  printf '  skipped: %s\n' "$(cat "$OUT/strace-skipped.txt")"
else
  for v in epoll recvmmsg io-uring; do
    s=$OUT/strace/cpp-$v.txt
    have "$s" || continue
    r=$OUT/cpp/$v-strace.json
    parcels=$(counter "$r" parcels)
    printf '  C++ %s (%s parcels): strace epoll_wait %s recvmsg %s recvmmsg %s io_uring_enter %s; in-program epoll_wait %s recvmsg %s recvmmsg %s io_uring_enter %s\n' "$v" "$parcels" \
      "$(strace_calls "$s" epoll_wait)" "$(strace_calls "$s" recvmsg)" "$(strace_calls "$s" recvmmsg)" "$(strace_calls "$s" io_uring_enter)" \
      "$(counter "$r" epoll_wait_calls)" "$(counter "$r" recvmsg_calls)" "$(counter "$r" recvmmsg_calls)" "$(counter "$r" io_uring_enter_calls)"
  done
  if have "$OUT/strace/cpp-asio-io-uring.txt"; then
    s=$OUT/strace/cpp-asio-io-uring.txt
    printf '  C++ asio-io-uring (%s parcels): strace io_uring_enter %s epoll_wait %s recvmsg %s recvfrom %s\n' "$(counter "$OUT/cpp/asio-io-uring-strace.json" parcels)" \
      "$(strace_calls "$s" io_uring_enter)" "$(strace_calls "$s" epoll_wait)" "$(strace_calls "$s" recvmsg)" "$(strace_calls "$s" recvfrom)"
  fi
  for s in "$OUT"/strace/java-*.txt; do
    have "$s" || continue
    v=$(basename "$s" .txt)
    v=${v#java-}
    printf '  Java %s (%s parcels): strace epoll_wait %s epoll_pwait %s recvfrom %s recvmsg %s read %s\n' "$v" "$(counter "$OUT/java/$v-strace.json" parcels)" \
      "$(strace_calls "$s" epoll_wait)" "$(strace_calls "$s" epoll_pwait)" "$(strace_calls "$s" recvfrom)" "$(strace_calls "$s" recvmsg)" "$(strace_calls "$s" read)"
  done
  for s in "$OUT"/strace/python-*.txt; do
    have "$s" || continue
    v=$(basename "$s" .txt)
    v=${v#python-}
    parcels=$(counter "$OUT/python/$v-strace.json" parcels)
    calls=$(($(strace_calls "$s" recvfrom) + $(strace_calls "$s" recvmsg)))
    printf '  Python %s (%s parcels): strace epoll_wait %s recvfrom %s (receive calls per parcel %s/1000)\n' "$v" "$parcels" \
      "$(strace_calls "$s" epoll_wait)" "$(strace_calls "$s" recvfrom)" "$((calls * 1000 / parcels))"
  done
fi

step "observed: the plain-JDK and Python lanes"
for f in "$OUT"/java/*-sat-alt1.json "$OUT"/python/*-sat.json; do
  have "$f" || continue
  printf '  %s p50 / p99 / p99.9 / max: %s; dropped %s\n' "${f#"$OUT"/}" "$(pct "$f")" "$(jget "$f" .dropped)"
done

((FAILURES == 0)) || die "$FAILURES criteria not met; results in $OUT"
ok "12-io-engines: every criterion holds; results in $OUT"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
