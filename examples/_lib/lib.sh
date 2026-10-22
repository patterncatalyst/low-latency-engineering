# shellcheck shell=bash
# examples/_lib/lib.sh - shared helpers for every examples/NN-*/verify.sh.
#
# Source it from a verify.sh:
#   . "$(dirname "$0")/../_lib/lib.sh"
#
# A verify.sh builds what it needs, captures the machine profile once, runs the
# example, writes reports into $RESULTS_DIR, checks them with lowlat-report and
# asserts the example's observable effect. It never changes the host: no sudo,
# no sysctl, no tuning. Exit 0 only when the effect was observed.
#
# Environment:
#   RESULTS_DIR   where reports go (default: <example>/results/latest)
#   ALLOW_BUSY=1  measure even if a lowlat-* VM is running (the numbers are then
#                 labelled by the profile's lab.running_domains, but are noisy)
#   SKIP_BUILD=1  reuse existing builds
#   LOWLAT_BUILD  C++ binary dir (default examples/build/release); set a private
#                 one when several builds run at once
#   LOWLAT_SCRATCH  per-run scratch dir for recordings and other untracked files; set by
#                 scratch_dir (a caller-provided value is kept)

set -euo pipefail

LOWLAT_EXAMPLES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOWLAT_ROOT="$(cd "$LOWLAT_EXAMPLES/.." && pwd)"
LOWLAT_BUILD="${LOWLAT_BUILD:-$LOWLAT_EXAMPLES/build/release}"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  _c_ok=$'\e[32m'; _c_bad=$'\e[31m'; _c_step=$'\e[36m'; _c_off=$'\e[0m'
else
  _c_ok=''; _c_bad=''; _c_step=''; _c_off=''
fi
step() { printf '%s━━ %s%s\n' "$_c_step" "$*" "$_c_off"; }
ok()   { printf '%s✓ %s%s\n' "$_c_ok" "$*" "$_c_off"; }
die()  { printf '%s✗ %s%s\n' "$_c_bad" "$*" "$_c_off" >&2; exit 1; }
# say_bad MESSAGE...: print a red ✗ line on stdout and carry on (die prints on stderr and exits).
# Redirect with >&2 for stderr. A verify.sh that counts failures wraps it:
#   bad() { say_bad "$*"; failures=$((failures + 1)); }
say_bad() { printf '%s✗ %s%s\n' "$_c_bad" "$*" "$_c_off"; }

# Background consumers: track each one so that a die mid-run (or Ctrl-C) never leaves it holding
# its UDP port. bg_track PID after starting one, bg_forget PID once it has been waited for.
BG_PIDS=()
bg_track() { BG_PIDS+=("$1"); }
bg_forget() {
  local keep=() p
  for p in "${BG_PIDS[@]}"; do
    [[ $p == "$1" ]] || keep+=("$p")
  done
  BG_PIDS=("${keep[@]}")
}
_bg_cleanup() {
  local p
  for p in "${BG_PIDS[@]}"; do
    kill "$p" 2>/dev/null || true
  done
  # Scratch (JFR recordings, FIFOs) is ours only when lib.sh created it.
  [[ -z ${_LOWLAT_SCRATCH_OWNED:-} ]] || rm -rf "${LOWLAT_SCRATCH:?}"
}
trap _bg_cleanup EXIT

# wait_udp_bound PORT PID LOG [TRIES]: wait (TRIES x 0.1 s, default 300) until a UDP socket is
# bound to PORT. Dies, printing LOG, if the background process PID exits first or never binds.
# Readiness comes from the kernel (ss), not from what the consumer prints.
wait_udp_bound() {
  local port=$1 pid=$2 log=$3 tries=${4:-300} i
  for ((i = 0; i < tries; i++)); do
    [[ -z $(ss -ulnH "sport = :$port") ]] || return 0
    kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; die "consumer exited before binding UDP $port"; }
    sleep 0.1
  done
  die "consumer never bound UDP $port within $((tries / 10)) s"
}

# wait_log_line PATTERN LOG PID [TRIES]: print the first line of LOG matching the regexp,
# polling every 20 ms; dies if PID exits first.
wait_log_line() {
  local pattern=$1 log=$2 pid=$3 tries=${4:-4500} i line
  for ((i = 0; i < tries; i++)); do
    line=$(grep -m1 -E -- "$pattern" "$log" || true)
    if [[ -n $line ]]; then
      printf '%s' "$line"
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; die "process exited before printing /$pattern/"; }
    sleep 0.02
  done
  die "no /$pattern/ line within $((tries / 50)) s"
}

# redact_host JSON...: replace the machine's hostname with the profile's
# host_label in third-party output (Google Benchmark, pyperf record it), so a
# committed result never names the machine.
redact_host() {
  local host label f
  host=$(hostname)
  label=$(jq -r .host_label "$LOWLAT_PROFILE")
  for f in "$@"; do
    jq --arg h "$host" --arg l "$label" \
      'walk(if type == "string" then split($h) | join($l) else . end)' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  done
}

# example_dir: absolute path of the calling example (the dir holding verify.sh).
example_dir() { cd "$(dirname "${BASH_SOURCE[-1]}")" && pwd; }

# Refuse to take host measurements while a lab VM competes for the CPUs.
require_quiet_host() {
  [[ ${ALLOW_BUSY:-0} == 1 ]] && return 0
  local running
  running=$(timeout 5 virsh -c qemu:///system list --name 2>/dev/null | grep '^lowlat-' || true)
  [[ -z $running ]] || die "lab VM running ($running): stop it (scripts/lab/lab-down.sh) or set ALLOW_BUSY=1"
}

# results_dir: create and print $RESULTS_DIR (default <example>/results/latest).
results_dir() {
  local dir=${RESULTS_DIR:-$(example_dir)/results/latest}
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# capture_profile DIR: write DIR/profile.json and export LOWLAT_PROFILE.
capture_profile() {
  "$LOWLAT_ROOT/scripts/profile.sh" --out "$1/profile.json"
  export LOWLAT_PROFILE="$1/profile.json"
  ok "profile: $(jq -r '"\(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release)"' "$LOWLAT_PROFILE")"
}

# build_cpp [TARGET...]: configure (once) and build the release preset.
build_cpp() {
  [[ ${SKIP_BUILD:-0} == 1 ]] && return 0
  step "building C++ (release preset) ${*:-all}"
  (cd "$LOWLAT_EXAMPLES" && cmake --preset release -B "$LOWLAT_BUILD" >/dev/null)
  if (($#)); then
    cmake --build "$LOWLAT_BUILD" --target "$@"
  else
    cmake --build "$LOWLAT_BUILD"
  fi
}

# cpp_bin NAME: absolute path of a built executable under the release build.
cpp_bin() {
  local bin
  bin=$(find "$LOWLAT_BUILD" -type f -name "$1" -perm -u+x -print -quit)
  [[ -n $bin ]] || die "C++ executable '$1' not found under $LOWLAT_BUILD (build_cpp first)"
  printf '%s' "$bin"
}

# build_java MODULE_DIR: package one Maven module and the sibling modules it
# depends on (-am), through the examples/pom.xml aggregator, so a clean machine
# needs no earlier `mvn install`. Tests are skipped unless BUILD_JAVA_TESTS=1.
build_java() {
  [[ ${SKIP_BUILD:-0} == 1 ]] && return 0
  local rel skip=(-DskipTests)
  [[ ${BUILD_JAVA_TESTS:-0} == 1 ]] && skip=()
  rel=$(realpath --relative-to="$LOWLAT_EXAMPLES" "$1")
  step "building Java module $rel${skip[*]:+ (tests skipped)}"
  mvn -B -q -f "$LOWLAT_EXAMPLES/pom.xml" -pl "$rel" -am "${skip[@]}" package
}

# py_sync: make sure the uv workspace is installed.
py_sync() {
  [[ ${SKIP_BUILD:-0} == 1 ]] && return 0
  step "syncing the Python workspace"
  (cd "$LOWLAT_EXAMPLES" && uv sync -q --all-packages)
}

# uvrun ARGS...: run inside the examples uv workspace.
uvrun() { (cd "$LOWLAT_EXAMPLES" && uv run -q "$@"); }

# report_check FILE...: schema-validate and recompute every report.
report_check() { uvrun lowlat-report check "$@" && uvrun lowlat-report show "$@"; }

# jget FILE JQ: read one value from a report.
jget() { jq -er "$2" "$1"; }

# assert_ge A B MESSAGE: integer A >= B, else fail with MESSAGE.
assert_ge() {
  (($1 >= $2)) || die "$3 (got $1, need >= $2)"
  ok "$3 ($1 >= $2)"
}

# assert_lt A B MESSAGE: integer A < B.
assert_lt() {
  (($1 < $2)) || die "$3 (got $1, need < $2)"
  ok "$3 ($1 < $2)"
}

# simulate ARGS...: run the reference line simulator (C++).
simulate() { "$(cpp_bin line-simulator)" "$@"; }

# ---------------------------------------------------------------------------------------------
# Java runtime observation (Part 2): JFR + unified logging, context switches, time to ready.
# ---------------------------------------------------------------------------------------------

# scratch_dir: make sure the per-run scratch dir exists and set LOWLAT_SCRATCH to it. Call it as
# a plain statement in the calling shell, never inside $(...) (the EXIT trap would not see the
# dir): `scratch_dir; AOT=$LOWLAT_SCRATCH/x.aot`. A caller-provided LOWLAT_SCRATCH is kept;
# otherwise a mktemp dir is created and removed by the EXIT trap. Recordings (*.jfr) live here
# and nowhere in the tree, so they cannot be committed.
scratch_dir() {
  if [[ -z ${LOWLAT_SCRATCH:-} ]]; then
    LOWLAT_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/lowlat-scratch.XXXXXX")
    _LOWLAT_SCRATCH_OWNED=1
  fi
  mkdir -p "$LOWLAT_SCRATCH"
}
_scratch() { scratch_dir; }  # earlier name, kept for callers that have not moved

# java_flags VARIANT: prepare the observation flags for one JVM run, without starting it. Sets
#   JFR_FILE         recording path under the scratch dir (JFR on, dumped on exit)
#   GC_LOG           $OUT/VARIANT.gc.log (unified -Xlog gc* + safepoint, async)
#   JAVA_RUN_FLAGS   array to put before -jar / the main class
# For a background JVM:  java_flags v; java "${JAVA_RUN_FLAGS[@]}" -jar x.jar & bg_track $!
# Needs $OUT (the results dir). -Xlog:async keeps the log writes off the application threads.
java_flags() {
  local variant=$1
  : "${OUT:?java_flags needs OUT (the results dir)}"
  scratch_dir
  JFR_FILE="$LOWLAT_SCRATCH/$variant.jfr"
  GC_LOG="$OUT/$variant.gc.log"
  JAVA_RUN_FLAGS=(
    -Xlog:async
    "-Xlog:gc*,safepoint:file=$GC_LOG:uptime,level,tags"
    "-XX:StartFlightRecording:filename=$JFR_FILE,dumponexit=true,settings=default"
  )
}

# java_run VARIANT JAVA_ARGS...: run java in the foreground with the observation flags first,
# echoing the full command line (that is the evidence of which flags ran). JAVA_ARGS are the
# JVM flags, then -jar JAR or a class, then the program arguments:
#   java_run zgc -XX:+UseZGC -Xmx512m -jar "$JAR" --duration 5
# Leaves JFR_FILE and GC_LOG set; the exit status is java's.
java_run() {
  local variant=$1
  shift
  java_flags "$variant"
  printf 'java:'
  printf ' %q' java "${JAVA_RUN_FLAGS[@]}" "$@"
  printf '\n'
  java "${JAVA_RUN_FLAGS[@]}" "$@"
}

# jfr_pauses JFR EXAMPLE VARIANT: write $OUT/java-VARIANT-gc-pause.json, a gc-pause report with
# one sample per jdk.GCPhasePause event (see JfrPauses). Needs LOWLAT_PROFILE (capture_profile).
jfr_pauses() {
  local jfr=$1 example=$2 variant=$3
  local jar="$LOWLAT_EXAMPLES/common/measure-java/target/measure-java-cli.jar"
  : "${OUT:?jfr_pauses needs OUT (the results dir)}"
  [[ -f $jar ]] || build_java "$LOWLAT_EXAMPLES/common/measure-java"
  [[ -f $jfr ]] || die "no recording at $jfr"
  [[ -f $jar ]] || die "missing $jar (build_java common/measure-java first)"
  java -jar "$jar" --jfr "$jfr" --example "$example" --variant "$variant" \
    --out "$OUT/java-$variant-gc-pause.json"
}

# task_ctx_switches PID TID: print "VOLUNTARY INVOLUNTARY" for one thread, from
# /proc/PID/task/TID/status. Read before and after a window and subtract.
#   read -r vol invol < <(task_ctx_switches "$pid" "$tid")
task_ctx_switches() {
  local f=/proc/$1/task/$2/status
  [[ -r $f ]] || die "no such thread: $f"
  awk '/^voluntary_ctxt_switches:/ {v = $2} /^nonvoluntary_ctxt_switches:/ {n = $2} END {print v, n}' "$f"
}

# task_io_faults PID TID: print "WRITE_SYSCALLS MINOR_FAULTS" for one thread, from
# /proc/PID/task/TID/io (syscw: write-like system calls) and .../stat (field 10, minflt). Read
# before and after a window and subtract. /proc/.../io is readable only by the thread's own user.
#   read -r wr minflt < <(task_io_faults "$pid" "$tid")
task_io_faults() {
  local writes faults
  writes=$(awk '/^syscw:/ {print $2}' "/proc/$1/task/$2/io") || die "no such thread: $1/$2"
  faults=$(sed -E 's/^.*\) //' "/proc/$1/task/$2/stat" | awk '{print $8}') # fields after "(comm) ": state is 1
  echo "$writes $faults"
}

# jmh_lock_wait MINUTES CONSOLE CMD...: run a JMH command (java ... -jar benchmarks.jar ...) with
# its output in CONSOLE, retrying every 20 s for up to MINUTES while another JMH instance holds
# the lock. JMH 1.37 takes ${java.io.tmpdir}/jmh.lock so that two benchmark runs never share the
# CPUs; the lock is the point, so it is waited for rather than moved (a per-run lock file, by
# -Djava.io.tmpdir, would let parallel runs perturb each other's numbers). The retry is around
# the run, not a probe of the lock, so two waiters cannot both pass a check and then collide.
# Returns CMD's status; any other failure ends the wait at once. Prints the tail of CONSOLE on failure.
jmh_lock_wait() {
  local minutes=$1 console=$2 attempt
  shift 2
  for ((attempt = 0; attempt < minutes * 3; attempt++)); do
    if "$@" >"$console" 2>&1; then
      return 0
    fi
    grep -q 'Unable to acquire the JMH lock' "$console" || break
    echo "another JMH instance holds /tmp/jmh.lock; retrying in 20 s"
    sleep 20
  done
  tail -30 "$console" >&2
  return 1
}

# time_to_ready CMD...: launch CMD, wait for a line containing $READY_PATTERN (default "ready")
# on its stdout/stderr, print the nanoseconds from launch to that line, then terminate CMD.
# READY_TIMEOUT seconds (default 60) bounds the wait; the output is printed if CMD dies first
# or never gets ready. A FIFO delivers the line the moment it is written, so there is no
# polling granularity in the number.
#
# Clock: EPOCHREALTIME is the wall clock (CLOCK_REALTIME), microsecond resolution. Bash has no
# monotonic clock ($SECONDS is whole seconds; /proc/uptime has 10 ms resolution, too coarse for a
# ~100 ms interval; `date +%s%N` is the same wall clock plus a fork). Wall time is acceptable
# here: NTP slews at 500 ppm at most (50 us over 100 ms), and only a clock step during the launch
# would skew one number, which shows up as an outlier among the repeated launches. The
# duration is a coarse startup figure, not a latency sample.
time_to_ready() {
  local pattern=${READY_PATTERN:-ready} timeout=${READY_TIMEOUT:-60}
  local fdir fifo fd pid line seen='' t0 t1 deadline
  # Own temp dir, removed on every path: the call is normally inside $(...), where the EXIT
  # trap of the calling script does not run.
  fdir=$(mktemp -d "${TMPDIR:-/tmp}/lowlat-ready.XXXXXX")
  fifo=$fdir/fifo
  mkfifo "$fifo"
  exec {fd}<>"$fifo"
  t0=${EPOCHREALTIME/./}
  "$@" >&"$fd" 2>&1 &
  pid=$!
  bg_track "$pid"
  deadline=$((SECONDS + timeout))
  while :; do
    if IFS= read -r -t 1 -u "$fd" line; then
      seen+="$line"$'\n'
      if [[ $line == *"$pattern"* ]]; then
        t1=${EPOCHREALTIME/./}
        break
      fi
    elif ! kill -0 "$pid" 2>/dev/null; then
      exec {fd}<&-
      rm -rf "$fdir"
      bg_forget "$pid"
      printf '%s' "$seen" >&2
      die "time_to_ready: '$*' exited before printing '$pattern'"
    elif ((SECONDS >= deadline)); then
      kill "$pid" 2>/dev/null || true
      exec {fd}<&-
      rm -rf "$fdir"
      bg_forget "$pid"
      printf '%s' "$seen" >&2
      die "time_to_ready: '$*' not ready within ${timeout} s"
    fi
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  bg_forget "$pid"
  exec {fd}<&-
  rm -rf "$fdir"
  echo $(((t1 - t0) * 1000))
}
