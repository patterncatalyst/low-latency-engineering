#!/usr/bin/env bash
# Ch12 verify: I/O engines and thread-per-core on the sortation line (C++, Java, Quarkus, Python).
#
# Every criterion is evaluated; each prints its measured value, its bound and the margin, and any miss fails the run
# after all of them have been evaluated. Latency ratios compare variants within THIS run: the variants alternate
# (A B C A B C A B C) and the criterion is the median of the three per-alternation ratios. Counters labelled "exact"
# are deterministic and need no median. A p50 is never compared across runs.
#   1  system calls per parcel at saturation, C++ (program counters): io_uring_enter calls per parcel are at most 1/4 of
#      epoll's system calls per parcel (epoll_wait + recvmsg). The ratio depends on how many completions queue up at the
#      load, so it is load-dependent, not a constant. CQEs per enter and recvmmsg's system calls per parcel (with the
#      margin under 1) are printed, not bounded.
#   2  hand-offs per parcel (exact): thread-per-core 0, acceptor-pool 1.
#   3  the layout pair at a loaded acceptor (about 80-85 percent of its receive window on a CPU): dropped == 0 for both in
#      every alternation (exact), the acceptor's busy share inside a guard band, and the p99 ratio thread-per-core over
#      acceptor-pool, median of 3, observed unless it clears the plan's 1/2 twice over (CRIT3_ASSERTED).
#   4  Quarkus at lambda x W > pool (5 kHz x 2 ms = 10 in flight against 8 workers): worker-pool p99 >= 3x
#      virtual-thread p99, median of 3. event-loop against virtual-thread is observed.
#   5  defect blocking-on-event-loop at its own rate (1.85 kHz): blocked-thread warnings logged during the measured run >= 1
#      (exact; counted in process and in the log, two views of the same JUL records, which must agree), requests in a
#      handler at once <= event-loop threads (exact), and the p99 against the event-loop variant at the same rate (observed
#      unless it clears the bound twice over, CRIT5_CTL_ASSERTED). p99 >= 2 ms is observed: the sleep alone meets it.
#   6  line, four simulator instances at 2.5 kHz x 20 s (200,000 parcels): count 200,000 and dropped 0 for every C++
#      variant, the plain-JDK variants and the Python variants. Percentiles are observed.
#   7  every report: lowlat-report check, build.flags (C++ and Java), runtime.counters, runtime.placement for pinned runs,
#      runtime.python_build for Python; the free-threaded runs kept the GIL off from start to end.
#   8  start gates: the recorded start skew of every multi-thread run is under 1 ms (the single-carrier JDK
#      virtual-thread-blocking receive is exempt: its skew is printed); every pinned thread is on the CPU it was pinned to
#      (read from /proc during the hold).
#   9  the Quarkus service counters (exact): the worker pool's active maximum equals the fixed pool size when the load
#      exceeds it; the event-loop variant uses no worker thread; the virtual-thread variant uses no worker thread; the
#      open-loop client saw no error and answered every request. Requests started over 1 ms late are observed.
#   -  completeness: every variant x alternation report must exist, each saturation run must carry its full count with
#      dropped == 0, and a run with ONLY= (a lane left out) always ends non-zero as partial.
# Observed, not asserted: asio-io-uring; io-uring against epoll tails; the plain-JDK variants against each other; every
# Python variant (asyncio-datagram, blocking-thread under both builds, uvloop); event-loop against virtual-thread; the
# strace -f -c cross-check (the summaries are committed, the raw output never is); CQEs per enter.
#
#   ./verify.sh                 build, run, assert
#   RECHECK=results/<run-id>    re-evaluate the committed reports without building or running anything
#   ALLOW_BUSY=1 ./verify.sh    measure while a lab VM or other load is running (noisy)
#   SKIP_BUILD=1 ./verify.sh    reuse existing builds
#   SMOKE=1 RESULTS_DIR=DIR     small workloads, a check of this script (not a measurement, nothing enforced)
#   RESULTS_DIR=DIR             where reports go (default results/latest)
#   LOWLAT_BUILD=DIR            private C++ build directory
#   ONLY=cpp,java,python,quarkus   run only those lanes (a development aid: the criteria of the others are then not met)
#
# Run it under the host benchmark lock when another example measures on this host, and give flock -o so the lock
#   flock -o "$LOCK" ./verify.sh
# is not inherited by the script or anything it starts (an orphan that outlived a run would otherwise keep the lock).
# On TERM or INT the script stops its whole process tree before it exits. UDP ports 47320-47323 (line),
# 47324-47327 (saturation), 47328-47331 (strace) and 47332-47335 (Python) on 127.0.0.1, TCP 47336 for the service.
# Threads are pinned to distinct physical cores with sched_setaffinity as an experiment control; that is not isolation.
# The simulators run on the cores left over, and the Quarkus server and the open-loop client get disjoint CPUs.
# Never changes the host: no sudo, no sysctl, no governor. io_uring is used only if the host allows it (read, never
# changed); on EPERM or ENOSYS the io_uring parts are skipped with the reason recorded.
# The free-threaded interpreter is a user-local download: `uv python install 3.14t`.
# shellcheck disable=SC2016
set -euo pipefail
trap 'exit 143' TERM
trap 'exit 130' INT
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
SAT_RATE_CPP=${SAT_RATE_CPP:-60000}          # the three single-thread engines: 240 kHz offered against 1 / 3 us of modelled decide work
SAT_RATE_LAYOUT=${SAT_RATE_LAYOUT:-52000}    # thread-per-core against acceptor-pool: 208 kHz offered, about 80-85 percent of what one acceptor thread carries
RECEIVE_NS_LAYOUT=${RECEIVE_NS_LAYOUT:-3500} # modelled receive-side work per datagram in the layout runs (the thread that receives does it)
SAT_RATE_JAVA=${SAT_RATE_JAVA:-20000}
SAT_RATE_PY=${SAT_RATE_PY:-2000}
SAT_SECONDS=${SAT_SECONDS:-3}
DECIDE_NS=${DECIDE_NS:-3000}
JAVA_DECIDE_NS=${JAVA_DECIDE_NS:-3000}
# The service: lambda x W = Q_RATE x SERVICE_MS must exceed POOL (5 kHz x 2 ms = 10 in flight against 8 workers). The plan's
# example (12 kHz against 16) is out of reach of a JDK HTTP/1.1 client and a four-core Quarkus service on this host: above about
# 6 kHz the service falls behind in every variant, the pool or not. The defect variant runs at DEFECT_RATE: four event loops
# blocked for 2 ms each can serve 2 kHz, so it is driven below that and the queue it shows is the loop's, not the client's.
Q_RATE=${Q_RATE:-5000}
DEFECT_RATE=${DEFECT_RATE:-1850}
Q_SECONDS=${Q_SECONDS:-5}
Q_WARMUP_SECONDS=${Q_WARMUP_SECONDS:-3}
POOL=8                                       # quarkus.thread-pool.max-threads in application.properties
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
TPC_P99_RATIO_MAX_PERMILLE=500               # 3: thread-per-core p99 <= 1/2 of acceptor-pool p99 (asserted only if CRIT3_ASSERTED)
CRIT3_ASSERTED=${CRIT3_ASSERTED:-0}          # 1 only when the ratio clears the bound twice over (<= 1/4) in every calibration run
ACCEPTOR_BUSY_MIN_PERMILLE=750               # 3: workload guard, the acceptor's CPU share of its receive window
ACCEPTOR_BUSY_MAX_PERMILLE=900
CTL_P99_RATIO_MIN_PERMILLE=2000              # 5: defect p99 >= 2x the event-loop control's at the same rate (asserted only if CRIT5_CTL_ASSERTED)
CRIT5_CTL_ASSERTED=${CRIT5_CTL_ASSERTED:-0}  # 1 only when the ratio clears the bound twice over (>= 4x) in every calibration run
WORKER_POOL_P99_RATIO_MIN_PERMILLE=3000      # 4: worker-pool p99 >= 3x virtual-thread p99
DEFECT_WARNINGS_MIN=1                        # 5: blocked-thread warnings
DEFECT_P99_MIN_NS=2000000                    # 5: p99 >= 2 ms (observed: the 2 ms sleep alone meets it)
START_SKEW_MAX_NS=1000000                    # 8: start gate skew < 1 ms

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
if [[ ${SMOKE:-0} == 1 ]]; then
  # A check of this script, not a measurement: small workloads, every criterion evaluated and printed, none enforced.
  [[ -n ${RESULTS_DIR:-} ]] || { echo "SMOKE=1 needs RESULTS_DIR (it must not overwrite results/latest)" >&2; exit 2; }
  LINE_SECONDS=2 SAT_SECONDS=1 Q_SECONDS=2 Q_WARMUP_SECONDS=1 STRACE_SECONDS=2 HOLD_MS=100
  LINE_PER_CAMERA=$((LINE_RATE * LINE_SECONDS))
  LINE_COUNT=$((LINE_PER_CAMERA * CAMERAS))
fi

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
  rm -rf "${OUT:?}"/{cpp,java,python,quarkus,strace,logs} "${OUT:?}"/*.json "${OUT:?}"/*.log "${OUT:?}"/*.txt
  mkdir -p "$OUT/cpp" "$OUT/java" "$OUT/python" "$OUT/quarkus" "$OUT/strace"
  capture_profile "$OUT"
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

# ---- helpers -------------------------------------------------------------------------------------------------------
scratch_dir # removed with the scratch dir on exit (also when the run stops early)
RATIO_FAULTS=$LOWLAT_SCRATCH/ratio-faults
: >"$RATIO_FAULTS"

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
# counter FILE KEY: a runtime counter, or an error that names the file and the key (a bare jq failure names neither).
counter() {
  local v
  v=$(jq -er ".runtime.counters.$2" "$1" 2>/dev/null) || die "counter '$2' is missing from ${1#"${OUT:-}"/}"
  echo "$v"
}
# pct FILE: "p50 / p99 / p99.9 / max" in microseconds.
pct() { jget "$1" '"\(.percentiles.p50 / 1000 | floor) / \(.percentiles.p99 / 1000 | floor) / \(.percentiles.p99_9 / 1000 | floor) / \(.percentiles.max / 1000 | floor) us"'; }
# alt_ratio FILE_NUM FILE_DEN: the ratio of two p99 values in thousandths.
# A zero denominator is a failure of the measurement: it prints 0 (so a >= bound fails) and is recorded in $RATIO_FAULTS,
# which the end of the run turns into a failed criterion (a $(...) cannot raise the failure itself).
alt_ratio() {
  local den
  den=$(p99 "$2")
  if ((den <= 0)); then
    echo "alt_ratio: p99 denominator $den ($2) for numerator $(p99 "$1") ($1)" >>"$RATIO_FAULTS"
    echo 0
  else
    echo $((1000 * $(p99 "$1") / den))
  fi
}
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
    mvn -B -q -f "$HERE/quarkus/pom.xml" verify >"$LOGS/quarkus-build.log" 2>&1 || { tail -30 "$LOGS/quarkus-build.log" >&2; die "Quarkus build or tests failed"; }
  fi
  [[ -f $JAR && -f $QUARKUS_JAR ]] || die "missing $JAR or $QUARKUS_JAR (build first)"
  py_sync

  step "unit tests: C++ (GoogleTest), Python under the GIL and under the free-threaded build; Java and Quarkus ran during the build"
  "$(cpp_bin io-test)" --gtest_brief=1 >"$LOGS/cpp-unit-tests.log" 2>&1 || { tail -20 "$LOGS/cpp-unit-tests.log" >&2; die "C++ unit tests failed"; }
  uvrun pytest -q "$HERE/io-py/tests" >"$LOGS/python-unit-tests-gil.log" 2>&1 || { tail -20 "$LOGS/python-unit-tests-gil.log" >&2; die "Python (GIL) tests failed"; }
  (cd "$LOWLAT_EXAMPLES" && LOWLAT_EXPECT_FREE_THREADED=1 UV_PROJECT_ENVIRONMENT=$LOWLAT_EXAMPLES/.venv-ft \
    uv run -q --python 3.14t --all-packages pytest -q "$HERE/io-py/tests") >"$LOGS/python-unit-tests-free-threaded.log" 2>&1 ||
    { tail -20 "$LOGS/python-unit-tests-free-threaded.log" >&2; die "Python (free-threaded) tests failed"; }
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
  if [[ -f $OUT/uring-skipped.txt ]]; then
    # A skip is believed only if the probe that came with the reports says io_uring really failed and no io_uring report exists.
    URING_OK=0
    if [[ ! -f $OUT/uring-probe.txt ]]; then
      bad "uring-skipped.txt without a uring-probe.txt: a skip nothing backs up"
      URING_OK=1
    elif grep -q 'errno 0' "$OUT/uring-probe.txt"; then
      bad "uring-skipped.txt, but uring-probe.txt says io_uring_setup worked (errno 0): the skip is not believed"
      URING_OK=1
    elif compgen -G "$OUT/cpp/io-uring-*.json" >/dev/null; then
      bad "uring-skipped.txt, but io_uring reports exist: the skip is not believed"
      URING_OK=1
    fi
  fi
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
  log=$LOGS/cpp-$(basename "$report" .json).log
  local -a cmd=("$RECV" --variant "$variant") wrap=("$@")
  [[ $variant == asio-io-uring ]] && cmd=("$RECV_ASIO")
  cmd+=(--base-port "$base" --expect $((rate * seconds)) --cpus "$CPUS" --hold-ms "$HOLD_MS" --decide-ns "$DECIDE_NS" --report "$report")
  [[ $variant == asio-io-uring ]] || cmd+=(--receive-ns "${RECEIVE_NS:-0}")
  run_load "$log" "$(pins_cpp "$variant")" "$base" "$rate" "$seconds" "${wrap[@]}" "${cmd[@]}" ||
    { tail -30 "$log" >&2; die "C++ $variant failed"; }
}

# java_run VARIANT RATE SECONDS BASE REPORT [WRAP...]
java_run() {
  local variant=$1 rate=$2 seconds=$3 base=$4 report=$5 log pins=1
  shift 5
  log=$LOGS/java-$(basename "$report" .json).log
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
  log=$LOGS/python-$(basename "$report" .json).log
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
  alt_run() {
    local rate=$SAT_RATE_CPP receive_ns=0
    [[ $1 == thread-per-core || $1 == acceptor-pool ]] && { rate=$SAT_RATE_LAYOUT; receive_ns=$RECEIVE_NS_LAYOUT; }
    step "C++ saturation: $1 at $rate Hz x $CAMERAS cameras, $receive_ns ns of modelled receive work (alternation $2)"
    RECEIVE_NS=$receive_ns cpp_run "$1" "$rate" "$SAT_SECONDS" "$UDP_SAT" "$OUT/cpp/$1-sat-alt$2.json"
  }
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
  # VARIANT may be event-loop-ctl: the event-loop variant driven at DEFECT_RATE, the same-rate control for the defect.
  local variant=$1 alt=$2 server_log client_log spid cpid i rc=0 rate=$Q_RATE final in_log plan=${1%-ctl}
  local -a profile=()
  server_log=$LOWLAT_SCRATCH/server-$variant-alt$alt.log
  client_log=$LOGS/quarkus-$variant-alt$alt.log
  [[ $variant == blocking-on-event-loop ]] && profile=(-Dquarkus.profile=defect)
  [[ $variant == blocking-on-event-loop || $variant == event-loop-ctl ]] && rate=$DEFECT_RATE
  "${SERVER_PREFIX[@]}" java "${SERVER_JVM[@]}" "${profile[@]}" -Dquarkus.http.port="$Q_PORT" -jar "$QUARKUS_JAR" >"$server_log" 2>&1 &
  spid=$!
  bg_track "$spid"
  for ((i = 0; i < 300; i++)); do
    curl -sf "http://127.0.0.1:$Q_PORT/stats" >/dev/null 2>&1 && break
    kill -0 "$spid" 2>/dev/null || { tail -30 "$server_log" >&2; die "the service exited before it was ready"; }
    sleep 0.1
  done
  ((i < 300)) || die "the service did not answer on $Q_PORT within 30 s"
  # In the background and waited for, so that a TERM to this script is handled at once (bash runs a trap only after a
  # foreground command ends). The client also ends on its own: request timeouts, an error limit and a hard deadline.
  "${CLIENT_PREFIX[@]}" java -Xms256m -Xmx1g -XX:+ExitOnOutOfMemoryError -cp "$JAR" "$MAIN" client --variant "$plan" --base-url "http://127.0.0.1:$Q_PORT" \
    --rate "$rate" --seconds "$Q_SECONDS" --warmup-seconds "$Q_WARMUP_SECONDS" --pool "$POOL" --service-time-ms "$SERVICE_MS" \
    --report "$OUT/quarkus/$variant-alt$alt.json" >"$client_log" 2>&1 &
  cpid=$!
  bg_track "$cpid"
  wait "$cpid" || rc=$?
  bg_forget "$cpid"
  # The blocked-thread warnings of the measured run (after the warm-up, from the service's stats reset), read once more now that
  # the client is done: counted in process, and counted in the log after the line the reset wrote. Vert.x logs about twenty
  # more while the service starts, which is why neither is the lifetime count.
  sleep 0.3
  final=$(curl -sf -m 5 "http://127.0.0.1:$Q_PORT/stats" | awk '$1 == "blocked_thread_warnings_in_run" {print $2}') || final=-1
  [[ -n $final ]] || final=-1
  in_log=$(awk '/measured run begins/ {on = 1; next} on && /has been blocked for/ {n++} END {print n + 0}' "$server_log")
  kill "$spid" 2>/dev/null || true
  for ((i = 0; i < 50; i++)); do _alive "$spid" || break; sleep 0.1; done
  _alive "$spid" && kill -KILL "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null || true
  bg_forget "$spid"
  ((rc == 0)) || { tail -30 "$client_log" >&2; die "the open-loop client failed for $variant"; }
  printf '%s alt%s %s %s\n' "$variant" "$alt" "$in_log" "$final" >>"$OUT/quarkus/blocked-thread-warnings-in-log.txt"
  if [[ $variant == blocking-on-event-loop && $alt == 1 ]]; then
    grep -m3 'has been blocked for' "$server_log" | python3 "$LOWLAT_ROOT/scripts/scrub-host-ids.py" --filter >"$OUT/quarkus/blocked-thread-warning-sample.txt" || true
  fi
}
if ((RUN)) && lane_on quarkus; then
  alt_run() {
    local rate=$Q_RATE
    [[ $1 == blocking-on-event-loop || $1 == event-loop-ctl ]] && rate=$DEFECT_RATE
    step "Quarkus service: $1 at $rate Hz (alternation $2): $rate Hz x $SERVICE_MS ms = $((rate * SERVICE_MS / 1000)) in flight against a pool of $POOL"
    quarkus_run "$1" "$2"
  }
  each_alt "${SERVICE_VARIANTS[@]}" event-loop-ctl
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

# expected_reports: every report this run must have produced, one relative path per line (variant x alternation).
expected_reports() {
  local n v
  if lane_on cpp; then
    for n in 1 2 3; do for v in epoll recvmmsg; do echo "cpp/$v-sat-alt$n.json"; done; done
    if ((URING_OK)); then
      for n in 1 2 3; do for v in io-uring thread-per-core acceptor-pool; do echo "cpp/$v-sat-alt$n.json"; done; done
      echo "cpp/asio-io-uring-sat.json"
    fi
    for v in "${CPP_LINE_VARIANTS[@]}"; do
      if ((!URING_OK)) && [[ $v == io-uring || $v == thread-per-core || $v == acceptor-pool || $v == asio-io-uring ]]; then continue; fi
      echo "cpp/$v-line.json"
    done
  fi
  if lane_on java; then
    for v in "${JAVA_VARIANTS[@]}"; do
      for n in 1 2 3; do echo "java/$v-sat-alt$n.json"; done
      echo "java/$v-line.json"
    done
  fi
  if lane_on python; then
    for v in "${PY_GIL_VARIANTS[@]}"; do echo "python/gil-$v-line.json"; echo "python/gil-$v-sat.json"; done
    for v in "${PY_FT_VARIANTS[@]}"; do echo "python/free-threaded-$v-line.json"; echo "python/free-threaded-$v-sat.json"; done
  fi
  if lane_on quarkus; then
    for v in "${SERVICE_VARIANTS[@]}" event-loop-ctl; do for n in 1 2 3; do echo "quarkus/$v-alt$n.json"; done; done
    echo "quarkus/blocked-thread-warnings-in-log.txt"
  fi
}
step "completeness: every variant x alternation report is present, and every lane ran"
declare -A MISSING=()
while read -r rel; do
  if ! have "$OUT/$rel"; then
    bad "$rel: report missing (a variant that did not run proves nothing)"
    MISSING[${rel%%/*}]=1
  fi
done < <(expected_reports)
for lane in cpp java python quarkus; do
  lane_on "$lane" || bad "partial run: the $lane lane was not run (ONLY=$ONLY)"
done
((${#MISSING[@]} > 0)) || ok "every expected report is present"
# ok_lane LANE: true when the lane ran and none of its reports is missing.
ok_lane() { lane_on "$1" && [[ -z ${MISSING[$1]:-} ]]; }

step "saturation runs carried their load: count == rate x seconds x cameras and dropped == 0, before any ratio is taken"
for f in "$OUT"/cpp/*-sat*.json "$OUT"/java/*-sat*.json "$OUT"/python/*-sat*.json; do
  have "$f" || continue
  name=${f#"$OUT"/}
  case $name in
    cpp/thread-per-core-* | cpp/acceptor-pool-*) rate=$SAT_RATE_LAYOUT ;;
    cpp/*) rate=$SAT_RATE_CPP ;;
    java/*) rate=$SAT_RATE_JAVA ;;
    *) rate=$SAT_RATE_PY ;;
  esac
  want=$((rate * SAT_SECONDS * CAMERAS))
  count=$(jget "$f" .count) dropped=$(jget "$f" .dropped)
  parcels=$(counter "$f" parcels)
  if ((parcels != count)); then
    bad "sat $name: counters.parcels $parcels differs from count $count (the program's own count and the histogram's must agree)"
  fi
  if ((count == want && dropped == 0)); then
    ok "sat $name: count $count (bound == $want), dropped $dropped (exact 0)"
  else
    bad "sat $name: count $count of $want, dropped $dropped (a saturation run must receive every parcel)"
  fi
done

if ok_lane cpp; then
  step "criterion 1: system calls per parcel at saturation, C++ (program counters, load-dependent)"
  if ((URING_OK)); then
    for n in 1 2 3; do
      e=$OUT/cpp/epoll-sat-alt$n.json u=$OUT/cpp/io-uring-sat-alt$n.json m=$OUT/cpp/recvmmsg-sat-alt$n.json
      ep=$(counter "$e" parcels) es=$(counter "$e" syscalls) up=$(counter "$u" parcels) ue=$(counter "$u" io_uring_enter_calls)
      uc=$(counter "$u" cqes) mp=$(counter "$m" parcels) ms=$(counter "$m" syscalls)
      if ((ep <= 0 || up <= 0 || mp <= 0 || ue <= 0)); then bad "1 alt$n: a saturation run decided no parcels (epoll $ep, io-uring $up, recvmmsg $mp)"; continue; fi
      per_epoll=$((es * 1000 / ep)) per_enter=$((ue * 1000 / up))
      # enters/parcel <= (bound/1000) x epoll syscalls/parcel, cross-multiplied so it stays exact in integers
      if ((ue * ep * 1000 <= URING_ENTER_PER_EPOLL_MAX_PERMILLE * es * up)); then
        ok "1 alt$n: io_uring_enter per parcel ${per_enter}/1000 <= $URING_ENTER_PER_EPOLL_MAX_PERMILLE/1000 x epoll's system calls per parcel ${per_epoll}/1000 (counters read in the program, so exact for this run, but the ratio depends on how many completions queue up at this load; margin $(margin $((URING_ENTER_PER_EPOLL_MAX_PERMILLE * es * up)) $((ue * ep * 1000)))x)"
      else
        bad "1 alt$n: io_uring_enter per parcel ${per_enter}/1000 > $URING_ENTER_PER_EPOLL_MAX_PERMILLE/1000 x epoll's system calls per parcel ${per_epoll}/1000 (exact counters)"
      fi
      # observed: how many datagrams a batch finds ready depends on load, so the margin under 1 call per parcel is printed, not bounded
      printf '  observed: alt%s recvmmsg makes %s system calls for %s parcels, %s/1000 per parcel (1 per parcel would be 1000; margin %sx, load-dependent)\n' "$n" "$ms" "$mp" "$((ms * 1000 / mp))" "$(margin $((mp)) $((ms)))"
      printf '  observed (exact): alt%s CQEs per io_uring_enter %s.%02d; epoll_wait per parcel %s/1000, recvmsg per parcel %s/1000\n' "$n" \
        $((uc / ue)) $((uc * 100 / ue % 100)) "$(($(counter "$e" epoll_wait_calls) * 1000 / ep))" "$(($(counter "$e" recvmsg_calls) * 1000 / ep))"
    done
  else
    for n in 1 2 3; do
      e=$OUT/cpp/epoll-sat-alt$n.json m=$OUT/cpp/recvmmsg-sat-alt$n.json
      ms=$(counter "$m" syscalls) mp=$(counter "$m" parcels)
      printf '  observed: alt%s recvmmsg makes %s system calls for %s parcels (io_uring skipped)\n' "$n" "$ms" "$mp"
    done
  fi

  if ((URING_OK)); then
    step "criterion 2: cross-thread hand-offs per parcel (exact)"
    for n in 1 2 3; do
      t=$OUT/cpp/thread-per-core-sat-alt$n.json p=$OUT/cpp/acceptor-pool-sat-alt$n.json
      crit_ge "2" "thread-per-core alt$n: parcels decided (the zero below is about something)" "$(counter "$t" parcels)" 1
      crit_exact "2" "thread-per-core alt$n: hand-offs" "$(counter "$t" handoffs)" 0
      crit_exact "2" "acceptor-pool alt$n: hand-offs, one per parcel ($(counter "$p" parcels) parcels)" "$(counter "$p" handoffs)" "$(counter "$p" parcels)"
    done

    step "criterion 3: the layout pair at a loaded acceptor (dropped == 0 both; p99 ratio, median of 3)"
    ratios=() e_vs_u=()
    for n in 1 2 3; do
      for v in thread-per-core acceptor-pool; do
        crit_exact "3" "$v alt$n: dropped" "$(jget "$OUT/cpp/$v-sat-alt$n.json" .dropped)" 0
      done
      busy=$(counter "$OUT/cpp/acceptor-pool-sat-alt$n.json" receiver_busy_permille_max)
      # a workload guard, not a performance bound: the acceptor must be loaded to about 80-85 percent (CPU time over the receive window)
      if ((busy >= ACCEPTOR_BUSY_MIN_PERMILLE && busy <= ACCEPTOR_BUSY_MAX_PERMILLE)); then
        ok "3 alt$n: the acceptor was $busy/1000 busy over its receive window (guard $ACCEPTOR_BUSY_MIN_PERMILLE-$ACCEPTOR_BUSY_MAX_PERMILLE)"
      else
        bad "3 alt$n: the acceptor was $busy/1000 busy, outside the $ACCEPTOR_BUSY_MIN_PERMILLE-$ACCEPTOR_BUSY_MAX_PERMILLE guard (retune SAT_RATE_LAYOUT)"
      fi
      printf '  observed: alt%s thread-per-core busiest receiver %s/1000 busy\n' "$n" "$(counter "$OUT/cpp/thread-per-core-sat-alt$n.json" receiver_busy_permille_max)"
      ratios+=("$(alt_ratio "$OUT/cpp/thread-per-core-sat-alt$n.json" "$OUT/cpp/acceptor-pool-sat-alt$n.json")")
      e_vs_u+=("$(alt_ratio "$OUT/cpp/io-uring-sat-alt$n.json" "$OUT/cpp/epoll-sat-alt$n.json")")
    done
    if ((CRIT3_ASSERTED)); then
      crit_ratio_le "3" "C++ saturation p99" "thread-per-core over acceptor-pool, per alternation: ${ratios[*]} thousandths" "$(median_of "${ratios[@]}")" "$TPC_P99_RATIO_MAX_PERMILLE"
    else
      printf '  observed: C++ saturation p99, thread-per-core over acceptor-pool, per alternation: %s thousandths (median %s; the plan'"'"'s bound is <= %s, asserted only when it clears twice over)\n' \
        "${ratios[*]}" "$(median_of "${ratios[@]}")" "$TPC_P99_RATIO_MAX_PERMILLE"
    fi
    printf '  observed: the hand-off cost at line rate (2.5 kHz per camera): thread-per-core p50 / p99 / p99.9 / max %s; acceptor-pool %s\n' \
      "$(pct "$OUT/cpp/thread-per-core-line.json")" "$(pct "$OUT/cpp/acceptor-pool-line.json")"
    printf '  observed: C++ io-uring over epoll p99 per alternation: %s thousandths (median %s)\n' "${e_vs_u[*]}" "$(median_of "${e_vs_u[@]}")"
  fi
  for v in epoll recvmmsg io-uring thread-per-core acceptor-pool; do
    have "$OUT/cpp/$v-sat-alt1.json" || continue
    printf '  C++ saturation %s p50 / p99 / p99.9 / max, alternation 1: %s; dropped %s\n' "$v" "$(pct "$OUT/cpp/$v-sat-alt1.json")" "$(jget "$OUT/cpp/$v-sat-alt1.json" .dropped)"
  done
  have "$OUT/cpp/asio-io-uring-sat.json" && printf '  observed: C++ saturation asio-io-uring p50 / p99 / p99.9 / max: %s; dropped %s\n' "$(pct "$OUT/cpp/asio-io-uring-sat.json")" "$(jget "$OUT/cpp/asio-io-uring-sat.json" .dropped)"
fi

if ok_lane quarkus; then
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

  step "criterion 5: defect blocking-on-event-loop at $DEFECT_RATE Hz, against the event-loop control at the same rate"
  ratios=() shares=()
  for n in 1 2 3; do
    f=$OUT/quarkus/blocking-on-event-loop-alt$n.json c=$OUT/quarkus/event-loop-ctl-alt$n.json
    w=$(counter "$f" blocked_thread_warnings_in_run)
    read -r in_log final < <(awk -v a="alt$n" '$1 == "blocking-on-event-loop" && $2 == a {print $3, $4}' "$OUT/quarkus/blocked-thread-warnings-in-log.txt")
    crit_ge "5" "alt$n blocked-thread warnings logged during the measured run (exact, counted in process)" "$w" "$DEFECT_WARNINGS_MIN"
    crit_exact "5" "alt$n the in-process count and the log's 'has been blocked for' lines are two views of the same JUL records" "$final" "$in_log"
    crit_exact "5" "alt$n the client's report and the final read of the in-process count agree" "$w" "$final"
    inh=$(counter "$f" service_in_handler_max) loops=$(counter "$f" event_loop_threads_seen)
    if ((loops >= 1 && inh <= loops)); then
      ok "5 alt$n: requests in a handler at once $inh <= event-loop threads $loops (exact: a blocked loop runs one at a time)"
    else
      bad "5 alt$n: requests in a handler at once $inh against $loops event-loop threads (exact bound: <=, and at least one loop)"
    fi
    ratios+=("$(alt_ratio "$f" "$c")")
    cinh=$(counter "$c" service_in_handler_max) cloops=$(counter "$c" event_loop_threads_seen)
    crit_ge "5" "alt$n control: event-loop at the defect's rate has more requests in a handler at once ($cinh) than event-loop threads (exact; the defect's <= $cloops signature discriminates)" "$cinh" "$((cloops + 1))"
    printf '  observed: alt%s defect p99 %s us (the 2 ms sleep alone meets a 2 ms bound); event-loop control at %s Hz p99 %s us\n' "$n" "$(($(p99 "$f") / 1000))" "$DEFECT_RATE" "$(($(p99 "$c") / 1000))"
  done
  if ((CRIT5_CTL_ASSERTED)); then
    crit_ratio_ge "5" "defect p99 over the event-loop control at the same rate" "per alternation: ${ratios[*]} thousandths" "$(median_of "${ratios[@]}")" "$CTL_P99_RATIO_MIN_PERMILLE"
  else
    printf '  observed: defect p99 over the event-loop control at %s Hz, per alternation: %s thousandths (median %s; bound >= %s, asserted only when it clears twice over)\n' \
      "$DEFECT_RATE" "${ratios[*]}" "$(median_of "${ratios[@]}")" "$CTL_P99_RATIO_MIN_PERMILLE"
  fi
  for v in event-loop worker-pool virtual-thread event-loop-ctl; do
    for n in 1 2 3; do
      read -r in_log final < <(awk -v v="$v" -v a="alt$n" '$1 == v && $2 == a {print $3, $4}' "$OUT/quarkus/blocked-thread-warnings-in-log.txt")
      ((in_log == 0 && final == 0)) || bad "5 $v alt$n: $in_log blocked-thread warnings in the log, $final counted, for a variant that never blocks the loop"
    done
  done

  step "criterion 9: Quarkus service counters (exact) and the open-loop client"
  for n in 1 2 3; do
    for v in "${SERVICE_VARIANTS[@]}" event-loop-ctl; do
      f=$OUT/quarkus/$v-alt$n.json
      sent=$(counter "$f" sent)
      [[ $(counter "$f" completed) -eq $sent && $(counter "$f" errors) -eq 0 ]] || bad "9 $v alt$n: completed $(counter "$f" completed) of $sent, errors $(counter "$f" errors)"
      late=$(counter "$f" late_starts_over_1ms)
      ((n == 1)) && printf '  %s: client max in flight %s (Little'"'"'s law %s at %s Hz), late starts over 1 ms %s of %s, service in-handler max %s, event-loop threads %s, worker threads %s (active max %s), carrier threads %s\n' \
        "$v" "$(counter "$f" max_in_flight)" "$(jget "$f" .model.littles_law_in_flight)" "$(jget "$f" .model.lambda_hz)" "$late" "$sent" "$(counter "$f" service_in_handler_max)" \
        "$(counter "$f" event_loop_threads_seen)" "$(counter "$f" worker_threads_seen)" "$(counter "$f" worker_active_max)" "$(counter "$f" carrier_threads)"
    done
    f=$OUT/quarkus/worker-pool-alt$n.json
    crit_exact "9" "worker-pool alt$n: worker pool active maximum equals the fixed pool size (load exceeds it)" "$(counter "$f" worker_active_max)" "$POOL"
    crit_exact "9" "worker-pool alt$n: worker threads seen equal the fixed pool (prefilled, all used)" "$(counter "$f" worker_threads_seen)" "$POOL"
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
vt_skews=()
for f in "${all_reports[@]}"; do
  name=${f#"$OUT"/}
  case $name in quarkus/* | *-lateness.json | *-strace.json) continue ;; esac
  threads=$(counter "$f" threads)
  skew=$(counter "$f" start_skew_ns)
  if [[ $name == java/virtual-thread-blocking-* ]]; then
    # One carrier runs all four virtual threads, so each leaves the gate only after the one before it parks: the skew is the carrier
    # serializing them, not a gate fault (the Ch11 single-carrier ping-pong precedent). Observed, not bounded.
    vt_skews+=("$skew")
  elif ((threads > 1)); then
    if ((skew < START_SKEW_MAX_NS)); then :; else bad "8 $name: start skew $skew ns over $threads threads (bound < $START_SKEW_MAX_NS)"; fi
  fi
done
printf '  observed: start skew of the single-carrier virtual-thread-blocking runs, ns: %s (one carrier serializes the four virtual threads, so it is not bounded)\n' "${vt_skews[*]:-none}"
skews=$(for f in "${all_reports[@]}"; do case ${f#"$OUT"/} in quarkus/* | *-lateness.json | *-strace.json | java/virtual-thread-blocking-*) continue ;; esac; [[ $(counter "$f" threads) -gt 1 ]] && counter "$f" start_skew_ns; done | sort -n | tail -1)
[[ -z $skews ]] || crit_le "8" "largest start skew over every multi-thread run, ns (a timing bound)" "$skews" "$((START_SKEW_MAX_NS - 1))"

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
    printf '  Python %s (%s parcels): strace epoll_wait %s epoll_pwait %s recvfrom %s recvmsg %s (receive calls per parcel %s/1000)\n' "$v" "$parcels" \
      "$(strace_calls "$s" epoll_wait)" "$(strace_calls "$s" epoll_pwait)" "$(strace_calls "$s" recvfrom)" "$(strace_calls "$s" recvmsg)" "$((calls * 1000 / parcels))"
  done
fi

step "observed: the plain-JDK and Python lanes"
for f in "$OUT"/java/*-sat-alt1.json "$OUT"/python/*-sat.json; do
  have "$f" || continue
  printf '  %s p50 / p99 / p99.9 / max: %s; dropped %s\n' "${f#"$OUT"/}" "$(pct "$f")" "$(jget "$f" .dropped)"
done

if [[ -s $RATIO_FAULTS ]]; then
  bad "a ratio had no usable denominator: $(tr '\n' ';' <"$RATIO_FAULTS")"
fi

if [[ ${SMOKE:-0} == 1 ]]; then
  ok "SMOKE: script check finished with $FAILURES criteria not met at these sizes (not enforced, not a result); output in $OUT"
  exit 0
fi
((FAILURES == 0)) || die "$FAILURES criteria not met; results in $OUT"
ok "12-io-engines: every criterion holds; results in $OUT"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
