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
# Redirect with >&2 for stderr.
say_bad() { printf '%s✗ %s%s\n' "$_c_bad" "$*" "$_c_off"; }
# bad MESSAGE...: say_bad and count it in FAILURES. A verify.sh that evaluates every criterion
# before it fails ends with `((FAILURES == 0)) || die ...`.
FAILURES=0
bad() { say_bad "$*"; FAILURES=$((FAILURES + 1)); }

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
# The repository is public, so a results directory must not name the machine or its owner.
# Reports and logs written by third-party tools and by the example binaries carry absolute
# paths ("report: <absolute path>"), so on exit every verify.sh scrubs its results directory with
# scripts/scrub-host-ids.py (home paths, account name, CPU model, kernel build). A log captured
# outside the script, such as verify.log, is scrubbed the same way:
#   ./verify.sh 2>&1 | ../../scripts/scrub-host-ids.py --filter | tee results/rNN-runN/verify.log
LOWLAT_CALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
scrub_results() {
  local d=${1:-${RESULTS_DIR:-$LOWLAT_CALLER_DIR/results/latest}}
  [[ -d $d ]] || return 0
  python3 "$LOWLAT_ROOT/scripts/scrub-host-ids.py" "$d" 2>/dev/null || true
}
_bg_cleanup() {
  local p
  for p in "${BG_PIDS[@]}"; do
    kill "$p" 2>/dev/null || true
  done
  scrub_results
  # Scratch (JFR recordings, FIFOs) is ours only when lib.sh created it.
  [[ -z ${_LOWLAT_SCRATCH_OWNED:-} ]] || rm -rf "${LOWLAT_SCRATCH:?}"
}
trap _bg_cleanup EXIT

# pid_descends_from PID ANCESTOR: true when PID is ANCESTOR or one of its descendants (walks PPid).
# A launcher such as `uv run` may fork the process that binds, so the socket's owner is matched to
# the tracked PID through its parents.
pid_descends_from() {
  local p=$1
  while [[ -n $p ]] && ((p > 1)); do
    [[ $p == "$2" ]] && return 0
    p=$(awk '/^PPid:/ {print $2}' "/proc/$p/status" 2>/dev/null) || return 1
  done
  return 1
}

# wait_udp_bound PORT PID LOG [TRIES]: wait (TRIES x 0.1 s, default 300) until a UDP socket owned by
# PID (or a child of it) is bound to PORT. Dies, printing LOG, if the background process PID exits
# first or never binds. Readiness comes from the kernel (ss), not from what the consumer prints, and
# a socket held by some other process on the same port does not count.
wait_udp_bound() {
  local port=$1 pid=$2 log=$3 tries=${4:-300} i owner
  for ((i = 0; i < tries; i++)); do
    while read -r owner; do
      ! pid_descends_from "$owner" "$pid" || return 0
    done < <(ss -ulnpH "sport = :$port" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
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
      'walk(if type == "string" then split($h) | join($l) else . end)' "$f" >"$f.tmp" || die "redact_host: jq failed on $f"
    mv "$f.tmp" "$f"
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

# expect_ge A B MESSAGE / expect_le / expect_lt: like assert_ge and assert_lt for integers, but a
# miss is counted by bad and the run goes on, so one run shows every criterion's value against its bound.
expect_ge() { if (($1 >= $2)); then ok "$3 ($1 >= $2)"; else bad "$3 (got $1, need >= $2)"; fi; }
expect_le() { if (($1 <= $2)); then ok "$3 ($1 <= $2)"; else bad "$3 (got $1, need <= $2)"; fi; }
expect_lt() { if (($1 < $2)); then ok "$3 ($1 < $2)"; else bad "$3 (got $1, need < $2)"; fi; }

# note_of FILE KEY: the value after "KEY=" (up to the next ";") in a report's notes.
note_of() { jget "$1" ".notes | capture(\"$2=(?<v>[^;]+)\").v"; }

# median_ns VALUE...: the middle value of the sorted integers (the lower middle for an even count).
median_ns() { printf '%s\n' "$@" | sort -n | sed -n "$((($# + 1) / 2))p"; }

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

# task_cpu PID TID: print the CPU the thread last ran on, from /proc/PID/task/TID/stat (field 39).
# The comm field may hold spaces, so the line is cut after its closing parenthesis first; the
# fields after "(comm) " start at 3 (state), which puts field 39 at position 37.
task_cpu() {
  local stat
  stat=$(<"/proc/$1/task/$2/stat") || die "no such thread: $1/$2"
  awk '{print $37}' <<<"${stat##*) }"
}

# ---------------------------------------------------------------------------------------------
# Placement and hardware counters (Part 3): distinct cores, SMT pairs, a counted region,
# simulated cache misses, A/B ordering. Everything here is unprivileged: it reads sysfs and
# /proc, pins only our own processes (taskset, sched_setaffinity) and never touches sysctl,
# perf_event_paranoid or the governor. perf counts user space only (events end in :u), which is
# what perf_event_paranoid=2 allows for our own processes.
# ---------------------------------------------------------------------------------------------

_SYS_CPU=/sys/devices/system/cpu

# _cpu_expand LIST: expand a kernel CPU list ("0-3,8,10-11") to one CPU number per line.
_cpu_expand() {
  local part lo hi
  local -a parts
  IFS=, read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    [[ -n $part ]] || continue
    lo=${part%-*}
    hi=${part#*-}
    seq "$lo" "$hi"
  done
}

# _allowed_cpus: the logical CPUs this process may run on (Cpus_allowed_list), one per line.
_allowed_cpus() {
  _cpu_expand "$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status)"
}

# distinct_cores N: print N logical CPUs, one per line, each on a different physical core, so no two
# are SMT siblings (same package and core_id in sysfs topology). The lowest-numbered CPU of each core
# is taken, in ascending order, from the CPUs this process may use. Returns 1 with a message on
# stderr when fewer than N cores are available. A caller joins them for taskset:
#   cpus=$(distinct_cores 4 | paste -sd,); taskset -c "$cpus" cmd
distinct_cores() {
  local n=${1:?distinct_cores N} cpu core pkg key found=0
  local -A seen=()
  while read -r cpu; do
    core=$(<"$_SYS_CPU/cpu$cpu/topology/core_id") || continue
    pkg=$(<"$_SYS_CPU/cpu$cpu/topology/physical_package_id") || pkg=0
    key="$pkg:$core"
    [[ -z ${seen[$key]:-} ]] || continue
    seen[$key]=1
    echo "$cpu"
    ((++found < n)) || return 0
  done < <(_allowed_cpus)
  echo "distinct_cores: wanted $n physical cores, only $found available to this process" >&2
  return 1
}

# smt_pair: print two logical CPUs that are SMT siblings of one core (thread_siblings_list), one per
# line, both usable by this process. Returns 1 with a message when SMT is off or no pair is allowed.
smt_pair() {
  local cpu sib
  local -a pair
  local -A allowed=()
  while read -r cpu; do allowed[$cpu]=1; done < <(_allowed_cpus)
  while read -r cpu; do
    [[ -r $_SYS_CPU/cpu$cpu/topology/thread_siblings_list ]] || continue
    pair=()
    while read -r sib; do
      [[ -z ${allowed[$sib]:-} ]] || pair+=("$sib")
    done < <(_cpu_expand "$(<"$_SYS_CPU/cpu$cpu/topology/thread_siblings_list")")
    if ((${#pair[@]} >= 2)); then
      printf '%s\n%s\n' "${pair[0]}" "${pair[1]}"
      return 0
    fi
  done < <(printf '%s\n' "${!allowed[@]}" | sort -n)
  echo "smt_pair: no two SMT sibling CPUs are available (SMT off, or the affinity mask excludes them)" >&2
  return 1
}

# assert_placement PID TID CPU: die unless thread TID of PID last ran on CPU (field 39 of
# /proc/PID/task/TID/stat, via task_cpu). It is a snapshot of the last CPU, so call it after the
# thread has run; a thread pinned with taskset or sched_setaffinity can only report its pinned CPU.
assert_placement() {
  local pid=${1:?assert_placement PID TID CPU} tid=${2:?} want=${3:?} got
  got=$(task_cpu "$pid" "$tid")
  [[ $got == "$want" ]] || die "placement: thread $tid of process $pid last ran on CPU $got, expected CPU $want"
  ok "placement: thread $tid of process $pid on CPU $want"
}

# perf_region OUT -- CMD...: run CMD under `perf stat` and count only the region CMD marks, then
# write OUT, a runtime.hw_counters object: {"source":"perf","ops":N,"per_op":{event: count / N}}.
#
# perf starts with its counters disabled (`-D -1`) and is driven through two FIFOs
# (`--control fifo:ctl,ack`). CMD finds them in the environment and brackets the measured loop, so
# setup and teardown outside the region are not counted:
#   LOWLAT_PERF_CTL   FIFO to write "enable\n" and "disable\n" to
#   LOWLAT_PERF_ACK   FIFO to read the "ack\n" reply from (read it before going on, or the region
#                     starts late)
# From bash, perf_region_enable and perf_region_disable do that. From C, C++, Java or Python, open
# LOWLAT_PERF_CTL for writing and LOWLAT_PERF_ACK for reading once, write the word, read one line.
# Threads and children of CMD are counted (perf inherits the events).
#
# ops (the operations the counts are divided by) is the caller's to supply, because only the
# workload knows how many operations ran inside the region: set LOWLAT_OPS in the environment
# before the call, or have CMD write the integer to the file named by LOWLAT_OPS_FILE. A run with
# neither dies. Counts are per operation, never a time-average.
#
# LOWLAT_PERF_EVENTS overrides the event list (default: cycles, instructions, L1-dcache-load-misses,
# LLC-load-misses). Give every event the :u modifier. The key in per_op is the event name without
# the modifier. An event perf cannot count ("<not supported>") is left out; the run dies if none
# of them counted. perf scales a multiplexed event; a warning names any that ran under 100 % of
# the region. Exit status is non-zero when perf fails or CMD does.
PERF_REGION_DEFAULT_EVENTS=cycles:u,instructions:u,L1-dcache-load-misses:u,LLC-load-misses:u

perf_region() {
  local out=${1:?perf_region OUT -- CMD...}
  shift
  [[ ${1:-} == -- ]] || die "perf_region: usage: perf_region OUT -- CMD..."
  shift
  (($#)) || die "perf_region: no command"
  command -v perf >/dev/null || die "perf_region: perf is not installed"
  local dir ops events=${LOWLAT_PERF_EVENTS:-$PERF_REGION_DEFAULT_EVENTS} status=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/lowlat-perf.XXXXXX")
  mkfifo "$dir/ctl" "$dir/ack"
  LOWLAT_PERF_CTL=$dir/ctl LOWLAT_PERF_ACK=$dir/ack LOWLAT_OPS_FILE=$dir/ops \
    perf stat --control "fifo:$dir/ctl,$dir/ack" -D -1 -x, -e "$events" -o "$dir/stat.csv" -- "$@" \
    >"$dir/perf.stdout" 2>"$dir/perf.stderr" || status=$?
  # perf prints "Events enabled/disabled" notices; drop those and pass CMD's own output through.
  grep -v '^Events \(enabled\|disabled\)$' "$dir/perf.stdout" || true
  grep -v '^Events \(enabled\|disabled\)$' "$dir/perf.stderr" >&2 || true
  if ((status)); then
    rm -rf "$dir"
    die "perf_region: perf or the command failed (status $status)"
  fi
  ops=${LOWLAT_OPS:-}
  [[ -n $ops || ! -s $dir/ops ]] || ops=$(<"$dir/ops")
  if ! [[ $ops =~ ^[1-9][0-9]*$ ]]; then
    rm -rf "$dir"
    die "perf_region: ops unknown: set LOWLAT_OPS, or have the command write it to \$LOWLAT_OPS_FILE"
  fi
  # CSV rows: value,unit,event,run-time,percent-of-time-measured,...  Comment lines start with '#'.
  local json
  json=$(jq -Rn --argjson ops "$ops" '
    [inputs | select(length > 0 and (startswith("#") | not)) | split(",")
     | select(.[0] | test("^[0-9]+$"))
     | {event: (.[2] | sub(":[a-zA-Z]+$"; "")), count: (.[0] | tonumber), pct: (.[4] | try tonumber catch 100)}]
    | {source: "perf", ops: $ops, per_op: (map({key: .event, value: (.count / $ops)}) | from_entries),
       partial: (map(select(.pct < 100) | .event))}' <"$dir/stat.csv") || { rm -rf "$dir"; die "perf_region: cannot parse perf output"; }
  rm -rf "$dir"
  if [[ $(jq '.per_op | length' <<<"$json") -eq 0 ]]; then
    die "perf_region: perf counted none of: $events"
  fi
  jq -r 'select(.partial | length > 0) | "perf_region: warning: scaled (multiplexed) events: \(.partial | join(", "))"' <<<"$json" >&2
  jq '{source, ops, per_op}' <<<"$json" >"$out"
}

# perf_region_enable / perf_region_disable: for a bash CMD run by perf_region, start and stop the
# counted region. Each returns after perf acknowledges.
perf_region_enable() { _perf_region_ctl enable; }
perf_region_disable() { _perf_region_ctl disable; }
_perf_region_ctl() {
  : "${LOWLAT_PERF_CTL:?not running under perf_region}" "${LOWLAT_PERF_ACK:?not running under perf_region}"
  local reply
  printf '%s\n' "$1" >"$LOWLAT_PERF_CTL"
  read -r reply <"$LOWLAT_PERF_ACK"
  [[ $reply == ack ]] || die "perf_region: perf answered '$reply' to '$1'"
}

# cachegrind_run OUT -- CMD...: run CMD under `valgrind --tool=cachegrind` (cache simulation of the
# machine's real L1d and LL) and write OUT, a small JSON summary of the simulated data-cache
# misses; the raw cachegrind.out.* files live in a temporary directory that is deleted, so none
# reaches the tree (.gitignore also lists cachegrind.out.*). The counts are deterministic for a
# deterministic program, which makes them an exact counter for an assertion and an independent
# cross-check on the hardware counters. They model the cache; they are not the hardware.
#   {"source":"cachegrind","totals":{"instructions","D-reads","D-writes","D1-read-misses",
#    "D1-write-misses","LL-read-misses","LL-write-misses"}, "ops":N, "per_op":{...same keys...}}
# "ops" and "per_op" appear when ops is supplied as for perf_region (LOWLAT_OPS or the file named
# by LOWLAT_OPS_FILE). To count only one function, set CACHEGRIND_FUNCTION to its name as the
# `fn=` lines of cachegrind.out name it (a C++ name without its parameter list matches too): the
# summary then adds up the costs attributed to that function alone (cachegrind's costs are
# exclusive of callees), so setup outside it is not counted. cachegrind has no toggle option;
# callgrind has --toggle-collect, but its output is a different format. The simulator still sees
# the whole run, so the cache state the function starts from includes the setup.
# `jq '{source, ops, per_op}' OUT` gives a runtime.hw_counters object. OUT is passed through
# scripts/scrub-host-ids.py. Valgrind is 20-50x slower than native: size the workload for that.
cachegrind_run() {
  local out=${1:?cachegrind_run OUT -- CMD...}
  shift
  [[ ${1:-} == -- ]] || die "cachegrind_run: usage: cachegrind_run OUT -- CMD..."
  shift
  (($#)) || die "cachegrind_run: no command"
  command -v valgrind >/dev/null || die "cachegrind_run: valgrind is not installed"
  local dir ops status=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/lowlat-cg.XXXXXX")
  LOWLAT_OPS_FILE=$dir/ops valgrind --tool=cachegrind --cache-sim=yes \
    --cachegrind-out-file="$dir/cachegrind.out.%p" --log-file="$dir/valgrind.log" -q -- "$@" || status=$?
  if ((status)); then
    python3 "$LOWLAT_ROOT/scripts/scrub-host-ids.py" --filter <"$dir/valgrind.log" >&2 || true
    rm -rf "$dir"
    die "cachegrind_run: command or valgrind failed (status $status)"
  fi
  ops=${LOWLAT_OPS:-}
  [[ -n $ops || ! -s $dir/ops ]] || ops=$(<"$dir/ops")
  # Each file ends "events: Ir I1mr ILmr Dr D1mr DLmr Dw D1mw DLmw" and "summary: v v v ...".
  # Sum the summaries of every process the command started under valgrind.
  local files=("$dir"/cachegrind.out.*)
  [[ -e ${files[0]} ]] || { rm -rf "$dir"; die "cachegrind_run: valgrind wrote no cachegrind.out.*"; }
  jq -Rn --arg ops "$ops" --arg fn "${CACHEGRIND_FUNCTION:-}" '
    [inputs] as $l
    | ($l | map(select(startswith("events:")))[0] | ltrimstr("events: ") | split(" ")) as $names
    | (if $fn == "" then
         [$l[] | select(startswith("summary:")) | ltrimstr("summary: ") | split(" ") | map(tonumber)]
       else
         (reduce $l[] as $x ({cur: null, rows: []};
            if ($x | startswith("fn=")) then .cur = ($x | ltrimstr("fn="))
            elif (.cur != null) and ($x | test("^[0-9]"))
                 and (.cur == $fn or (.cur | startswith($fn + "(")))
              then .rows += [$x | split(" ") | .[1:] | map(tonumber)]
            else . end) | .rows)
       end) as $rows
    | if ($rows | length) == 0 then error("no cost lines for function \"\($fn)\"") else . end
    | ($rows | transpose | map(add)) as $sums
    | ([$names, $sums] | transpose | map({key: .[0], value: .[1]}) | from_entries) as $c
    | {"instructions": $c.Ir, "D-reads": $c.Dr, "D-writes": $c.Dw, "D1-read-misses": $c.D1mr,
       "D1-write-misses": $c.D1mw, "LL-read-misses": $c.DLmr, "LL-write-misses": $c.DLmw} as $t
    | {source: "cachegrind", totals: $t}
    | if ($ops | test("^[1-9][0-9]*$")) then
        (($ops | tonumber) as $n | . + {ops: $n, per_op: (.totals | map_values(. / $n))})
      else . end' < <(cat "${files[@]}") >"$out" || { rm -rf "$dir"; die "cachegrind_run: cannot parse cachegrind output"; }
  rm -rf "$dir"
  python3 "$LOWLAT_ROOT/scripts/scrub-host-ids.py" "$out" >/dev/null 2>&1 || true
}

# interleave N VARIANT...: print the order to run variants so they alternate, one name per line:
# N rounds of every variant in the order given (A B A B ... for two variants). Alternating runs
# share the machine's drift (thermal state, frequency, background load) instead of giving one
# variant the quiet start and the other the warm tail.
#   for v in $(interleave 3 old new); do run "$v"; done      # old new old new old new
interleave() {
  local n=${1:?interleave N VARIANT...} round v
  shift
  (($#)) || die "interleave: no variants"
  [[ $n =~ ^[1-9][0-9]*$ ]] || die "interleave: N must be a positive integer, got '$n'"
  for ((round = 0; round < n; round++)); do
    for v in "$@"; do
      printf '%s\n' "$v"
    done
  done
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
time_to_ready() (
  # A subshell body: its own EXIT/INT/TERM trap stops the process and removes the FIFO dir on every
  # path, a Ctrl-C included, and the call is normally inside $(...), where the calling script's
  # trap does not run. The variables are plain (no local) so the trap still sees them at exit.
  pattern=${READY_PATTERN:-ready}
  timeout=${READY_TIMEOUT:-60}
  seen=''
  fdir=$(mktemp -d "${TMPDIR:-/tmp}/lowlat-ready.XXXXXX")
  pid=''
  trap 'kill "$pid" 2>/dev/null || true; rm -rf "$fdir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkfifo "$fdir/fifo"
  exec {fd}<>"$fdir/fifo"
  t0=${EPOCHREALTIME/./}
  "$@" >&"$fd" 2>&1 &
  pid=$!
  deadline=$((SECONDS + timeout))
  while :; do
    if IFS= read -r -t 1 -u "$fd" line; then
      seen+="$line"$'\n'
      if [[ $line == *"$pattern"* ]]; then
        t1=${EPOCHREALTIME/./}
        break
      fi
    elif ! kill -0 "$pid" 2>/dev/null; then
      printf '%s' "$seen" >&2
      die "time_to_ready: '$*' exited before printing '$pattern'"
    elif ((SECONDS >= deadline)); then
      printf '%s' "$seen" >&2
      die "time_to_ready: '$*' not ready within ${timeout} s"
    fi
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo $(((t1 - t0) * 1000))
)
