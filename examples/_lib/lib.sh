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
#   TARGET_VM     the lab guest the `guest` helpers talk to (default lowlat-target); its name must
#                 start with LAB_GUARD_PREFIX (default lowlat-)
#   GUEST_REPO    repo path in the guest, relative to the guest user's home
#                 (default low-latency-engineering)
#   LAB_SSH       the vsock ssh wrapper (default scripts/lab/lab-ssh.sh); tests point it at a shim
#   CONTAINER_OUT_DIR  the one guest directory container_run may bind-mount from (-v/--mount):
#                 absolute, canonical, strictly under LOWLAT_GUEST_ROOT
#   LOWLAT_GUEST_ROOT  the guest's checkout, as an absolute path (default: GUEST_USER's home plus GUEST_REPO,
#                 GUEST_USER from scripts/lab/lab.env, default fedora); the only tree mounts and
#                 seccomp profiles may come from
#   GUEST_PROFILE guest snapshot/profile name (like lab-ready-r04/stock-unpinned) that
#                 container_run records in runtime.environment
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
# _descendants PID: the PIDs of every descendant of PID (children first, then theirs), from /proc.
_descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do
    echo "$c"
    _descendants "$c"
  done
}

# _alive PID: true while PID is a live process (a zombie awaiting its parent's wait counts as gone).
_alive() {
  local state
  state=$(awk '/^State:/ {print $2}' "/proc/$1/status" 2>/dev/null) || return 1
  [[ -n $state && $state != Z ]]
}

# _bg_cleanup: runs on EXIT. Stops every tracked background PID and then the whole descendant tree of this shell (a launcher
# such as `uv run` or `env` leaves grandchildren that BG_PIDS never saw; one that outlives the script keeps its inherited
# lock descriptors, and a flock held that way blocks every later run): TERM, up to LOWLAT_KILL_GRACE seconds (default 3) for
# them to go, then KILL for whatever is left. Then scrubs the results and removes the scratch dir.
_bg_cleanup() {
  local p kids i left
  trap - TERM INT
  for p in "${BG_PIDS[@]}"; do
    kill "$p" 2>/dev/null || true
  done
  # shellcheck disable=SC2207
  kids=($(_descendants $$))
  ((${#kids[@]} == 0)) || kill -TERM "${kids[@]}" 2>/dev/null || true
  for ((i = 0; i < ${LOWLAT_KILL_GRACE:-3} * 10; i++)); do
    left=0
    for p in "${kids[@]}"; do _alive "$p" && left=1; done
    ((left)) || break
    sleep 0.1
  done
  for p in "${kids[@]}"; do
    ! _alive "$p" || kill -KILL "$p" 2>/dev/null || true
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

# require_quiet_host [--lab-idle]: refuse to take host measurements while a lab VM competes for
# the CPUs. Without the flag any running lowlat-* VM refuses the run, and so does a libvirt that
# cannot be read (no virsh installed counts as no lab).
#   --lab-idle   the lowlat-target VM may be running, but only idle: its load1 (read
#                through `lab_ssh`) must be <= LAB_IDLE_LOAD1 (default 0.5). Any other running
#                domain (an ebpf-* or systems-* VM, a lowlat peer) refuses the run: this check
#                reads libvirt's domain list and talks only to the lowlat target, and never
#                starts, stops or touches another VM. The state is exported as LOWLAT_LAB_VM
#                ("down" or "up (idle)") and, when RUN_START_JSON names a file, merged into it as
#                "lab_vm" with "lab_vm_load1" (the run-start.json the driver writes).
# ALLOW_BUSY=1 skips the check in both forms (with --lab-idle it records "unchecked (ALLOW_BUSY)").
require_quiet_host() {
  local lab_idle=0 running domains others
  if [[ ${1:-} == --lab-idle ]]; then lab_idle=1; shift; fi
  (($# == 0)) || die "require_quiet_host: unknown argument '$1' (only --lab-idle)"
  if [[ ${ALLOW_BUSY:-0} == 1 ]]; then
    ((!lab_idle)) || _run_start_record "unchecked (ALLOW_BUSY)" ''
    return 0
  fi
  if ((!lab_idle)); then
    # No virsh at all means no libvirt and so no lab VM (a CI container). A virsh that fails or
    # times out is an error: "quiet" must be known, not assumed.
    command -v virsh >/dev/null 2>&1 || return 0
    domains=$(timeout 5 virsh -c qemu:///system list --name 2>/dev/null) ||
      die "cannot read the libvirt domain list (virsh failed or timed out), so the host cannot be called quiet: fix libvirt access or set ALLOW_BUSY=1"
    running=$(grep '^lowlat-' <<<"$domains" || true)
    [[ -z $running ]] || die "lab VM running ($running): stop it (scripts/lab/lab-down.sh) or set ALLOW_BUSY=1"
    return 0
  fi
  local prefix=${LAB_GUARD_PREFIX:-lowlat-} target=${TARGET_VM:-lowlat-target} load1=''
  [[ $target == "$prefix"* ]] || die "require_quiet_host: '$target' is not a $prefix* domain; the lab helpers never touch it"
  # A failed or timed-out virsh is "unknown", never "down".
  if ! domains=$(timeout 5 virsh -c qemu:///system list --name 2>/dev/null); then
    _run_start_record "unknown" ''
    die "--lab-idle: cannot read the libvirt domain list (virsh failed or timed out); not assuming the lab is down"
  fi
  domains=$(sed '/^$/d' <<<"$domains")
  running=$(grep "^$prefix" <<<"$domains" || true)
  others=$(grep -v "^$prefix" <<<"$domains" || true)
  [[ -z $others ]] || die "--lab-idle: a non-lab VM is running ($(tr '\n' ' ' <<<"$others")): stop it or set ALLOW_BUSY=1"
  if [[ -z $running ]]; then
    _run_start_record "down (require_quiet_host)" ''
    return 0
  fi
  [[ $running == "$target" ]] || die "--lab-idle: running lab domains are ($(tr '\n' ' ' <<<"$running")), expected only $target"
  load1=$(lab_ssh cat /proc/loadavg | awk '{print $1}') || die "--lab-idle: cannot read the guest load average (is $target reachable over vsock ssh?)"
  [[ $load1 =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--lab-idle: unreadable guest load1 '$load1'"
  awk -v l="$load1" -v m="${LAB_IDLE_LOAD1:-0.5}" 'BEGIN { exit !(l <= m) }' ||
    die "--lab-idle: $target is not idle (load1 $load1 > ${LAB_IDLE_LOAD1:-0.5}); wait, or stop it with scripts/lab/lab-down.sh"
  _run_start_record "up (idle)" "$load1"
}

# _run_start_record STATE LOAD1: export LOWLAT_LAB_VM and merge lab_vm (and the guest load1) into
# $RUN_START_JSON when it is set (the file is created as {} if absent).
_run_start_record() {
  export LOWLAT_LAB_VM=$1
  [[ -n ${RUN_START_JSON:-} ]] || return 0
  [[ -s $RUN_START_JSON ]] || printf '{}\n' >"$RUN_START_JSON"
  jq --arg s "$1" --arg l "$2" \
    '.lab_vm = $s | if $l == "" then . else .lab_vm_load1 = ($l | tonumber) end' \
    "$RUN_START_JSON" >"$RUN_START_JSON.tmp" || die "run-start: jq failed on $RUN_START_JSON"
  mv "$RUN_START_JSON.tmp" "$RUN_START_JSON"
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
  local n=${1:?distinct_cores N} cpu core pkg key
  local -a picked=()
  local -A seen_core=()
  [[ $n =~ ^[1-9][0-9]*$ ]] || die "distinct_cores: N must be a positive integer, got '$n'"
  while read -r cpu; do
    core=$(<"$_SYS_CPU/cpu$cpu/topology/core_id") || continue
    pkg=$(<"$_SYS_CPU/cpu$cpu/topology/physical_package_id") || pkg=0
    key="$pkg:$core"
    [[ -z ${seen_core[$key]:-} ]] || continue
    seen_core[$key]=1
    picked+=("$cpu")
    ((${#picked[@]} < n)) || break
  done < <(_allowed_cpus)
  if ((${#picked[@]} < n)); then
    echo "distinct_cores: wanted $n physical cores, only ${#picked[@]} available to this process" >&2
    return 1
  fi
  printf '%s\n' "${picked[@]}"
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
  local pid=${1:?assert_placement PID TID CPU} tid=${2:?assert_placement PID TID CPU} want=${3:?assert_placement PID TID CPU} got
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

# Stopping a run: press Ctrl-C, or `kill -- -PGID` (the whole process group). A TERM sent to the
# calling script alone leaves the helper running in the background to finish: bash defers a trap
# while a foreground command runs. The helper's traps kill the workload and remove the temp dir.
perf_region() (
  # A subshell body, like time_to_ready: the EXIT/INT/TERM traps remove the temp dir on every path,
  # an interrupted run included, and OUT is written only after perf succeeded and parsed.
  out=${1:?perf_region OUT -- CMD...}
  shift
  [[ ${1:-} == -- ]] || die "perf_region: usage: perf_region OUT -- CMD..."
  shift
  (($#)) || die "perf_region: no command"
  command -v perf >/dev/null || die "perf_region: perf is not installed"
  events=${LOWLAT_PERF_EVENTS:-$PERF_REGION_DEFAULT_EVENTS}
  status=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/lowlat-perf.XXXXXX")
  pid=''
  # perf runs in the background and is waited for: bash runs a trap only after a foreground
  # command ends, but `wait` returns at once when a trapped signal arrives.
  trap '[[ -z $pid ]] || { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; } || true; rm -rf "$dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkfifo "$dir/ctl" "$dir/ack"
  LOWLAT_PERF_CTL=$dir/ctl LOWLAT_PERF_ACK=$dir/ack LOWLAT_OPS_FILE=$dir/ops \
    perf stat --control "fifo:$dir/ctl,$dir/ack" -D -1 -x, -e "$events" -o "$dir/stat.csv" -- "$@" \
    <&0 >"$dir/perf.stdout" 2>"$dir/perf.stderr" &
  pid=$!
  wait "$pid" || status=$?
  # perf prints "Events enabled/disabled" notices; drop those and pass CMD's own output through.
  grep -v '^Events \(enabled\|disabled\)$' "$dir/perf.stdout" || true
  grep -v '^Events \(enabled\|disabled\)$' "$dir/perf.stderr" >&2 || true
  ((status == 0)) || die "perf_region: perf or the command failed (status $status)"
  ops=${LOWLAT_OPS:-}
  [[ -n $ops || ! -s $dir/ops ]] || ops=$(<"$dir/ops")
  [[ $ops =~ ^[1-9][0-9]*$ ]] ||
    die "perf_region: ops unknown: set LOWLAT_OPS, or have the command write it to \$LOWLAT_OPS_FILE"
  # CSV rows: value,unit,event,run-time,percent-of-time-measured,...  Comment lines start with '#'.
  jq -Rn --argjson ops "$ops" '
    [inputs | select(length > 0 and (startswith("#") | not)) | split(",")
     | select(.[0] | test("^[0-9]+$"))
     | {event: (.[2] | sub(":[a-zA-Z]+$"; "")), count: (.[0] | tonumber), pct: (.[4] | try tonumber catch 100)}]
    | {source: "perf", ops: $ops, per_op: (map({key: .event, value: (.count / $ops)}) | from_entries),
       partial: (map(select(.pct < 100) | .event))}' <"$dir/stat.csv" >"$dir/region.json" ||
    die "perf_region: cannot parse perf output"
  [[ $(jq '.per_op | length' "$dir/region.json") -gt 0 ]] || die "perf_region: perf counted none of: $events"
  jq -r 'select(.partial | length > 0) | "perf_region: warning: scaled (multiplexed) events: \(.partial | join(", "))"' \
    "$dir/region.json" >&2
  jq '{source, ops, per_op}' "$dir/region.json" >"$dir/out.json"
  mv "$dir/out.json" "$out"
)

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
# exclusive of callees), so setup outside it is not counted. cachegrind has no --toggle-collect
# (that is callgrind's). Since valgrind 3.22 it offers --instr-at-start=no with the
# CACHEGRIND_START_INSTRUMENTATION and CACHEGRIND_STOP_INSTRUMENTATION client requests, but those
# come from a header in valgrind-devel, a package this repository does not require (and the host
# gets no installs); CACHEGRIND_FUNCTION needs no header. The simulator still sees the whole run,
# so the cache state the function starts from includes the setup. CACHEGRIND_ARGS (a
# space-separated string) is passed through to valgrind, e.g. a different --D1=size,assoc,line.
# `jq '{source, ops, per_op}' OUT` gives a runtime.hw_counters object. OUT is passed through
# scripts/scrub-host-ids.py. Valgrind is 20-50x slower than native: size the workload for that.
# Stopping a run: press Ctrl-C, or `kill -- -PGID` (the whole process group). A TERM sent to the
# calling script alone leaves the helper running in the background to finish: bash defers a trap
# while a foreground command runs. The helper's traps kill the workload and remove the temp dir.
cachegrind_run() (
  # A subshell body with traps, as perf_region: no temp dir survives an interrupt and OUT appears
  # only once the summary parsed.
  out=${1:?cachegrind_run OUT -- CMD...}
  shift
  [[ ${1:-} == -- ]] || die "cachegrind_run: usage: cachegrind_run OUT -- CMD..."
  shift
  (($#)) || die "cachegrind_run: no command"
  command -v valgrind >/dev/null || die "cachegrind_run: valgrind is not installed"
  status=0
  dir=$(mktemp -d "${TMPDIR:-/tmp}/lowlat-cg.XXXXXX")
  pid=''
  trap '[[ -z $pid ]] || { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; } || true; rm -rf "$dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  read -ra extra <<<"${CACHEGRIND_ARGS:-}"
  LOWLAT_OPS_FILE=$dir/ops valgrind --tool=cachegrind --cache-sim=yes "${extra[@]}" \
    --cachegrind-out-file="$dir/cachegrind.out.%p" --log-file="$dir/valgrind.log" -q -- "$@" <&0 &
  pid=$!
  wait "$pid" || status=$?
  if ((status)); then
    [[ -s $dir/valgrind.log ]] &&
      python3 "$LOWLAT_ROOT/scripts/scrub-host-ids.py" --filter <"$dir/valgrind.log" >&2 || true
    die "cachegrind_run: command or valgrind failed (status $status)"
  fi
  ops=${LOWLAT_OPS:-}
  [[ -n $ops || ! -s $dir/ops ]] || ops=$(<"$dir/ops")
  # Each file ends "events: Ir I1mr ILmr Dr D1mr DLmr Dw D1mw DLmw" and "summary: v v v ...".
  # Sum the summaries of every process the command started under valgrind.
  files=("$dir"/cachegrind.out.*)
  [[ -e ${files[0]} ]] || die "cachegrind_run: valgrind wrote no cachegrind.out.*"
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
      else . end' < <(cat "${files[@]}") >"$dir/summary.json" || die "cachegrind_run: cannot parse cachegrind output"
  python3 "$LOWLAT_ROOT/scripts/scrub-host-ids.py" "$dir/summary.json" >/dev/null 2>&1 || true
  mv "$dir/summary.json" "$out"
)

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

# ---- the lab guest, containers in the guest, environment lanes -------------------------------
# Everything below reaches the guest through scripts/lab/lab-ssh.sh (ssh over vsock, never NAT)
# and only ever to a domain whose name starts with LAB_GUARD_PREFIX (default lowlat-). Nothing
# here starts or stops a VM, and nothing runs docker on the host.

# lab_ssh CMD...: run CMD in the guest's login shell; refuses a target outside the lab prefix.
lab_ssh() {
  local prefix=${LAB_GUARD_PREFIX:-lowlat-} target=${TARGET_VM:-lowlat-target}
  [[ $target == "$prefix"* ]] || die "lab_ssh: '$target' is not a $prefix* domain; refusing"
  "${LAB_SSH:-$LOWLAT_ROOT/scripts/lab/lab-ssh.sh}" "$target" "$@"
}

# guest CMD...: run CMD in the guest from the repo root (GUEST_REPO under the guest user's home),
# each word quoted for the guest shell (printf %q output is bash syntax: it relies on the guest
# user's login shell being bash, the Fedora default). Returns CMD's status.
#   guest examples/build/release/line-simulator --help
guest() { lab_ssh "cd ${GUEST_REPO:-low-latency-engineering} && $(printf '%q ' "$@")"; }

# guest_fetch REMOTE LOCAL: copy a file out of the guest (REMOTE relative to the guest user's
# home) to LOCAL. A REMOTE ending in / is a directory: its contents are unpacked into LOCAL
# (created if needed) through tar, as the calling user, without the archive's owners or
# permission bits. An archive with a symlink, hard link or device member is refused before
# anything is extracted (a guest is not trusted not to plant ../ links).
guest_fetch() {
  local remote=${1:?guest_fetch REMOTE LOCAL} local_path=${2:?guest_fetch REMOTE LOCAL} tar_file bad
  if [[ $remote == */ ]]; then
    tar_file=$(mktemp "${TMPDIR:-/tmp}/lowlat-fetch.XXXXXX")
    if ! lab_ssh "tar -C $(printf '%q' "$remote") -cf - ." >"$tar_file"; then
      rm -f "$tar_file"
      die "guest_fetch: cannot fetch $remote"
    fi
    bad=$(tar -tvf "$tar_file" | grep -v '^[-d]' || true)
    if [[ -n $bad ]]; then
      rm -f "$tar_file"
      die "guest_fetch: $remote holds a link or special file, refusing to extract: $(head -n1 <<<"$bad")"
    fi
    mkdir -p "$local_path"
    tar -C "$local_path" --no-same-owner --no-same-permissions -xf "$tar_file" || { rm -f "$tar_file"; die "guest_fetch: cannot unpack $remote"; }
    rm -f "$tar_file"
  else
    lab_ssh "cat $(printf '%q' "$remote")" >"$local_path" || die "guest_fetch: cannot fetch $remote"
  fi
}

# _scrub_ids: stdin to stdout through scripts/scrub-host-ids.py --filter.
_scrub_ids() { python3 "$LOWLAT_ROOT/scripts/scrub-host-ids.py" --filter; }

# The guest-side reader behind cgroup_stat, POSIX sh run as
#   sh -c "$_CGROUP_SH" sh CONTAINER CGROUP_ROOT
# It prints four lines: cpu.max, cpuset.cpus.effective, nr_throttled, throttled_usec (an empty
# line for a file it could not read). Docker 29 with the systemd cgroup driver puts the container
# at <root>/system.slice/docker-<id>.scope; the cgroupfs driver at <root>/docker/<id>.
_CGROUP_SH=$(
  cat <<'SCRIPT'
name=$1 root=$2
id=$(docker inspect --format '{{.Id}}' "$name") || exit 1
for d in "$root/system.slice/docker-$id.scope" "$root/docker/$id"; do
  [ -d "$d" ] && break
  d=
done
[ -n "$d" ] && [ -r "$d/cpu.stat" ] || { echo "no cgroup for container $name (not running?)" >&2; exit 3; }
cm=$(cat "$d/cpu.max" 2>/dev/null) || cm=
cs=$(cat "$d/cpuset.cpus.effective" 2>/dev/null) || cs=
nr=$(awk '$1 == "nr_throttled" { print $2 }' "$d/cpu.stat")
us=$(awk '$1 == "throttled_usec" { print $2 }' "$d/cpu.stat")
printf '%s\n%s\n%s\n%s\n' "$cm" "$cs" "$nr" "$us"
SCRIPT
)

# _cgroup_json < four lines: the JSON object cgroup_stat prints (null for an empty line).
_cgroup_json() {
  local -a v
  mapfile -t v
  jq -n --arg cm "${v[0]:-}" --arg cs "${v[1]:-}" --arg nr "${v[2]:-}" --arg us "${v[3]:-}" \
    '{nr_throttled: ($nr | if . == "" then null else tonumber end),
      throttled_usec: ($us | if . == "" then null else tonumber end),
      cpu_max: ($cm | if . == "" then null else . end),
      cpuset_effective: ($cs | if . == "" then null else . end)}'
}

# cgroup_stat CONTAINER: print {nr_throttled, throttled_usec, cpu_max, cpuset_effective} as JSON
# for a RUNNING container in the guest, read from its cgroup (CGROUP_ROOT, default /sys/fs/cgroup).
# A stopped container has no cgroup (the kernel removes it at exit), so this returns 3 with a
# message instead of guessing. container_run does not use it: it reads the container's own view.
cgroup_stat() {
  local name=${1:?cgroup_stat CONTAINER} out
  out=$(guest sh -c "$_CGROUP_SH" sh "$name" "${CGROUP_ROOT:-/sys/fs/cgroup}") || return 3
  _cgroup_json <<<"$out"
}

# The wrapper the container runs as its entrypoint (sh -c WRAPPER sh CMD...): CMD, then, as the
# very last output, its own cgroup files between sentinels. With Docker's default private cgroup
# namespace on cgroup v2 (https://docs.docker.com/engine/containers/runmetrics/) the container's
# /sys/fs/cgroup is its own cgroup, so these are the container's own cpu.stat, cpu.max and
# cpuset.cpus.effective, read while the cgroup still exists. The leading newline ends a workload
# line that has no newline of its own; the parser drops exactly one empty line before BEGIN. container_run passes
# --cgroupns=private explicitly so the daemon default cannot drift. The image needs sh and cat
# (ubi10/ubi-minimal ships bash and coreutils-single; S5 confirms it in the guest).
_CGROUP_WRAP=$(
  cat <<'SCRIPT'
"$@"; rc=$?
printf '\n@@LOWLAT_CGROUP_BEGIN\n'
echo "rc $rc"
cat /sys/fs/cgroup/cpu.stat 2>/dev/null
echo "cpu.max $(cat /sys/fs/cgroup/cpu.max 2>/dev/null)"
echo "cpuset.cpus.effective $(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null)"
echo @@LOWLAT_CGROUP_END
exit $rc
SCRIPT
)

# _container_deny OPT WHY: refuse a docker option that is not on container_run's allowlist.
_container_deny() { die "container_run: $1 is refused: $2"; }

# _guest_root: the guest checkout as an absolute path: LOWLAT_GUEST_ROOT, else the guest user's
# home (lab.env GUEST_USER) plus GUEST_REPO.
_guest_root() {
  printf '%s' "${LOWLAT_GUEST_ROOT:-$(printf '/%s' home "${GUEST_USER:-fedora}" "${GUEST_REPO:-low-latency-engineering}")}"
}

# _path_canonical P: succeed if P is absolute with no //, no . or .. component (so no spelling
# can reach a protected path lexically that the checks below do not see).
_path_canonical() {
  [[ $1 == /* && $1 != *//* && $1/ != */./* && $1/ != */../* ]]
}

# _system_tree P: succeed if P is / or one of the system trees (or beneath them), which a guest
# checkout never is.
_system_tree() {
  case $1 in
    / | /etc | /etc/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /run | /run/* | /var | /var/* \
      | /usr | /usr/* | /boot | /boot/* | /root | /root/* | /bin | /bin/* | /sbin | /sbin/* \
      | /lib | /lib/* | /lib64 | /lib64/* | /opt | /opt/*) return 0 ;;
  esac
  return 1
}

# _container_out_dir: print the validated, guest-resolved CONTAINER_OUT_DIR, or die. It must be
# absolute, canonical, not /, strictly under LOWLAT_GUEST_ROOT (default: the guest user's home plus GUEST_REPO),
# and (resolved in the guest, symlinks followed) still under the resolved root.
_container_out_dir() {
  local out=${CONTAINER_OUT_DIR:-} root res_out res_root
  root=$(_guest_root)
  [[ -n $out ]] || _container_deny "a mount" "set CONTAINER_OUT_DIR to the declared output directory"
  _path_canonical "$out" && [[ $out != / ]] || _container_deny "CONTAINER_OUT_DIR '${CONTAINER_OUT_DIR}'" "must be an absolute canonical path (no //, ., .. or relative)"
  out=${out%/}
  _path_canonical "$root" || die "container_run: LOWLAT_GUEST_ROOT '$root' is not an absolute canonical path"
  _system_tree "$root" && die "container_run: LOWLAT_GUEST_ROOT '$root' is a system tree, not a checkout"
  [[ $out == "${root%/}"/* ]] || _container_deny "CONTAINER_OUT_DIR '$out'" "is not under the guest checkout $root"
  res_out=$(guest realpath -e -- "$out") || _container_deny "CONTAINER_OUT_DIR '$out'" "does not exist in the guest"
  res_root=$(guest realpath -e -- "$root") || _container_deny "LOWLAT_GUEST_ROOT '$root'" "does not exist in the guest"
  _system_tree "$res_root" && die "container_run: LOWLAT_GUEST_ROOT '$root' resolves to the system tree $res_root"
  [[ $res_out == "$res_root"/* ]] || _container_deny "CONTAINER_OUT_DIR '$out'" "resolves to $res_out, outside $res_root"
  printf '%s' "$res_out"
}

# _container_mount_ok SRC DST: die unless a bind mount's source is under the validated
# CONTAINER_OUT_DIR (canonical, and still under it once symlinks are resolved in the guest) and its
# target is canonical and not /, /proc, /sys, /dev, /run, /var/run, /etc, /bin, /sbin, /usr, /lib, /lib64,
# /opt/venv (or beneath them: the wrapper's sh and cat must not be overmounted) or a docker/containerd socket.
_container_mount_ok() {
  local src=$1 dst=$2 res_out res_src
  res_out=$(_container_out_dir)
  _path_canonical "$src" || _container_deny "mount source '$src'" "must be an absolute canonical path (no //, ., ..)"
  _path_canonical "$dst" || _container_deny "mount target '$dst'" "must be an absolute canonical path (no //, ., ..)"
  case $src in *docker.sock* | *containerd*.sock | */run/*) _container_deny "mount source '$src'" "is a protected path" ;; esac
  res_src=$(guest realpath -e -- "$src") || _container_deny "mount source '$src'" "does not exist in the guest"
  [[ $res_src == "$res_out" || $res_src == "$res_out"/* ]] || _container_deny "mount source '$src'" "is not under CONTAINER_OUT_DIR ($res_out)"
  case $res_src in *docker.sock* | *containerd*.sock | */run/*) _container_deny "mount source '$src'" "resolves to a protected path" ;; esac
  dst=${dst%/}
  case $dst in
    "" | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /run | /run/* | /var/run | /var/run/* | /etc | /etc/* \
      | /bin | /bin/* | /sbin | /sbin/* | /usr | /usr/* | /lib | /lib/* | /lib64 | /lib64/* | /opt/venv | /opt/venv/* \
      | *docker.sock* | *containerd*.sock)
      _container_deny "mount target '${dst:-/}'" "is a protected path" ;;
  esac
}

# container_run NAME --env-out FILE [OPTION...] -- IMAGE CMD...
# Run CMD in IMAGE as a container named NAME INSIDE THE GUEST (docker through `guest`), wait for
# it, print its stdout and stderr (scrubbed of host identifiers) and return its exit status.
# Writes FILE (required) with the environment block for the report:
#   {"runtime": {"environment": {kind: "container", guest_profile: $GUEST_PROFILE,
#      container: {runtime docker, image name:tag, image_digest, network, cpu_quota, cpuset,
#      seccomp}, cgroup: {cpu_max, cpuset_effective, nr_throttled, throttled_usec}}}}
# which a caller merges into a report's runtime with `jq -s '.[0] * .[1]'`. GUEST_PROFILE
# (snapshot/profile) must be set.
#
# OPTIONs are an ALLOWLIST; anything else is refused before any docker call. Both "--opt=value"
# and "--opt value" are read, values are trimmed and compared case-insensitively, and combined
# short flags (-dit) are expanded and refused. Allowed:
#   --cpus N, --cpuset-cpus LIST, --memory SIZE
#   --network|--net host|bridge|none
#   --security-opt seccomp=NAME.json | no-new-privileges[=true]   (case-sensitive; NAME.json is read
#       from examples/13-where-code-runs/containers/seccomp/ in the guest checkout, recorded by name)
#   -e|--env KEY=VALUE, --hostname NAME, --init, -u|--user USER, -w|--workdir /ABS
#   -v|--volume SRC:DST[:ro|rw|z|Z], --mount type=bind,src=SRC,dst=DST[,readonly]
#       SRC must be under $CONTAINER_OUT_DIR (symlinks resolved in the guest); DST must be canonical
#       and not /, /proc, /sys, /dev, /run, /var/run, /etc, /bin, /sbin, /usr, /lib, /lib64, /opt/venv
#       (or beneath them) or a docker/containerd socket
# --name is internal; --hostname defaults to NAME (so the container ID cannot show up as the
# hostname); --cgroupns=private and --entrypoint sh are added (any image ENTRYPOINT is bypassed:
# CMD is the whole command). The image needs sh and cat (see _CGROUP_WRAP).
#
# The block also carries `rc N`, the workload's exit status, which must equal docker wait's (a
# workload that kills sh and forges a block cannot know it). The container's own cpu.stat, cpu.max
# and cpuset.cpus.effective are printed by the wrapper as
# the last output between sentinels and parsed into the block's cgroup (exact final counters,
# not a sample); the fenced block is removed from the printed log. If the block is missing or
# unparsable the run fails with status 4 when --cpus or --cpuset-cpus was passed (a limited lane
# without its throttle counters is not a result); otherwise cgroup is all null.
#
# IMAGE is name:tag or name:tag@sha256:digest (a tagless or :latest reference is refused, as the
# schema does). If examples/13-where-code-runs/containers/IMAGES.lock exists, the reference must
# be listed there and its digest, when listed, must match the image; if the file is absent a
# warning is printed. seccomp is "default" unless a seccomp FILE.json is passed (then its base
# name). The container is removed on every exit path, a failure or a signal included, and its ID
# is never printed. Returns 2 for a bad call (die), 3 if create/start/wait/inspect failed,
# 4 for the missing cgroup block above, otherwise the container's status.
container_run() (
  local name=${1:?container_run NAME --env-out FILE [option...] -- IMAGE CMD...} image='' env_out=''
  local seccomp=default network=bridge host_set=0 has_limit=0
  local -a run_args=()
  shift
  local arg opt val have_val rest c
  while (($#)); do
    arg=$1
    shift
    [[ $arg == -- ]] && break
    opt='' val='' have_val=0
    if [[ $arg == --*=* ]]; then
      opt=${arg%%=*} val=${arg#*=} have_val=1
    elif [[ $arg == --* ]]; then
      opt=$arg
    elif [[ $arg =~ ^-[A-Za-z][A-Za-z]+$ && ! $arg =~ ^-[evwu] ]]; then
      _container_deny "$arg" "combined short flags (${arg:1}) are not on the allowlist"
    elif [[ $arg =~ ^-[evwu] ]]; then
      c=${arg:1:1} rest=${arg:2}
      case $c in e) opt=--env ;; v) opt=--volume ;; w) opt=--workdir ;; u) opt=--user ;; esac
      [[ -z $rest ]] || { val=$rest have_val=1; }
    elif [[ $arg == -* ]]; then
      _container_deny "$arg" "not on the allowlist"
    else
      _container_deny "$arg" "unexpected argument before --"
    fi
    opt=${opt,,}
    case $opt in
      --init)
        ((!have_val)) || _container_deny "$arg" "--init takes no value"
        run_args+=(--init)
        continue ;;
      --env-out | --cpus | --cpuset-cpus | --memory | --network | --net | --security-opt | --env | --hostname | --user | --workdir | --volume | --mount) ;;
      *) _container_deny "${arg%%=*}" "not on the allowlist (allowed: --cpus --cpuset-cpus --memory --network --security-opt seccomp=FILE.json -e --hostname --init --user --workdir -v --mount)" ;;
    esac
    if ((!have_val)); then
      (($# >= 1)) || _container_deny "$opt" "needs a value"
      val=$1
      shift
    fi
    val=${val#"${val%%[![:space:]]*}"}
    val=${val%"${val##*[![:space:]]}"}
    case $opt in
      --env-out) env_out=$val ;;
      --cpus)
        [[ $val =~ ^[0-9]+([.][0-9]+)?$ && $val =~ [1-9] ]] || _container_deny "--cpus $val" "not a positive number of CPUs"
        has_limit=1; run_args+=(--cpus "$val") ;;
      --cpuset-cpus)
        [[ $val =~ ^[0-9]+([-,][0-9]+)*$ ]] || _container_deny "--cpuset-cpus $val" "not a CPU list"
        has_limit=1; run_args+=(--cpuset-cpus "$val") ;;
      --memory)
        [[ $val =~ ^[0-9]+[bBkKmMgG]?$ && $val =~ [1-9] ]] || _container_deny "--memory $val" "not a positive size"
        run_args+=(--memory "$val") ;;
      --network | --net)
        case ${val,,} in
          host | bridge | none) network=${val,,} ;;
          *) _container_deny "$opt $val" "only host, bridge or none" ;;
        esac
        run_args+=(--network "$network") ;;
      --security-opt)
        # Compared case-sensitively, the way docker reads it. Seccomp profiles come only from the
        # repo's containers/seccomp/ directory in the guest, by base name.
        if [[ $val =~ ^seccomp=([A-Za-z0-9._-]+\.json)$ ]]; then
          seccomp=${BASH_REMATCH[1]}
          run_args+=(--security-opt "seccomp=$(_guest_root)/examples/13-where-code-runs/containers/seccomp/$seccomp")
        elif [[ $val == no-new-privileges || $val == no-new-privileges=true ]]; then
          run_args+=(--security-opt no-new-privileges)
        else
          _container_deny "--security-opt $val" "only seccomp=NAME.json (from containers/seccomp/) and no-new-privileges"
        fi ;;
      --env)
        [[ $val =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || _container_deny "--env $val" "must be KEY=VALUE (the guest's environment is not passed through)"
        run_args+=(--env "$val") ;;
      --hostname)
        [[ $val =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || _container_deny "--hostname $val" "not a host name"
        host_set=1; run_args+=(--hostname "$val") ;;
      --user)
        [[ $val =~ ^[A-Za-z0-9_.:-]+$ ]] || _container_deny "--user $val" "not a user"
        run_args+=(--user "$val") ;;
      --workdir)
        [[ $val =~ ^/[^[:space:]]*$ && $val != *..* ]] || _container_deny "--workdir $val" "not an absolute path"
        run_args+=(--workdir "$val") ;;
      --volume)
        local vsrc vdst vopts
        IFS=: read -r vsrc vdst vopts <<<"$val"
        [[ -z $vopts || $vopts =~ ^(ro|rw|z|Z)(,(ro|rw|z|Z))*$ ]] || _container_deny "--volume $val" "unknown mount options"
        _container_mount_ok "$vsrc" "$vdst"
        run_args+=(--volume "$val") ;;
      --mount)
        local msrc='' mdst='' kv key mtype=''
        local -a kvs
        IFS=, read -ra kvs <<<"$val"
        for kv in "${kvs[@]}"; do
          key=${kv%%=*}
          case ${key,,} in
            type) mtype=${kv#*=} ;;
            src | source) msrc=${kv#*=} ;;
            dst | destination | target) mdst=${kv#*=} ;;
            readonly | ro) ;;
            *) _container_deny "--mount $val" "key '$key' is not allowed" ;;
          esac
        done
        [[ ${mtype,,} == bind ]] || _container_deny "--mount $val" "only type=bind"
        _container_mount_ok "$msrc" "$mdst"
        run_args+=(--mount "$val") ;;
    esac
  done
  (($# >= 1)) || die "container_run: no IMAGE after --"
  image=$1
  shift
  [[ $image != -* ]] || die "container_run: image '$image' starts with '-'"
  ((host_set)) || run_args+=(--hostname "$name")
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "container_run: bad container name '$name'"
  [[ -n $env_out ]] || die "container_run: --env-out FILE is required"
  [[ ${GUEST_PROFILE:-} =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
    die "container_run: set GUEST_PROFILE to snapshot/profile (like lab-ready-r04/stock-unpinned)"

  # The image: name:tag, optionally @sha256:digest; never untagged or :latest.
  local ref digest_arg='' last tag
  [[ $image =~ ^([^[:space:]@]+)(@sha256:[0-9a-f]{64})?$ ]] || die "container_run: image '$image' is not name:tag[@sha256:digest]"
  ref=${BASH_REMATCH[1]}
  digest_arg=${BASH_REMATCH[2]#@}
  last=${ref##*/}
  [[ $last == *:* ]] || die "container_run: image '$image' has no tag (name:tag[@sha256:digest])"
  tag=${last##*:}
  [[ $tag != latest ]] || die "container_run: image '$image' uses :latest; pin an exact tag"
  [[ $ref =~ ^([^[:space:]:@/]+:[0-9]+/)?[^[:space:]:@]+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
    die "container_run: image '$ref' is not a name:tag the report schema accepts"
  local lock=${LOWLAT_IMAGES_LOCK:-$LOWLAT_EXAMPLES/13-where-code-runs/containers/IMAGES.lock} lock_digest=''
  if [[ -f $lock ]]; then
    # Only field 1 (the image as container_run takes it) is matched.
    lock_digest=$(awk -v ref="$ref" -v dg="$digest_arg" '
      /^[[:space:]]*(#|$)/ { next }
      { n = split($1, a, "@"); if (a[1] == ref && (dg == "" || a[2] == dg)) { found = 1; print a[2]; exit } }
      END { exit !found }' "$lock") || die "container_run: $ref is not listed in $lock"
    [[ $lock_digest != *PENDING* ]] || die "container_run: $ref has a PENDING digest in $lock; build the images first (containers/build-images.sh in the guest)"
    [[ -z $lock_digest || $lock_digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "container_run: $ref has a malformed digest '$lock_digest' in $lock"
  else
    echo "container_run: warning: no IMAGES.lock at $lock; the image is not checked against a lock" >&2
  fi

  # A name already in use is not ours to remove: refuse before the trap can know it.
  if guest docker inspect --format '{{.Id}}' "$name" >/dev/null 2>&1; then
    die "container_run: a container named $name already exists in the guest"
  fi
  local tmp created=0 rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lowlat-container.XXXXXX")
  # shellcheck disable=SC2317,SC2329 # runs from the EXIT trap
  _container_cleanup() {
    # created is set before docker create, so a signal between the two still removes NAME.
    if ((created)); then guest docker rm -f "$name" >/dev/null 2>&1 || true; fi
    rm -rf "$tmp"
  }
  trap _container_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # create (pulls if needed), start, wait. Docker's stdout (the container ID) is discarded.
  created=1
  guest docker create --name "$name" --cgroupns=private --entrypoint sh "${run_args[@]}" "$image" \
    -c "$_CGROUP_WRAP" sh "$@" >/dev/null 2> >(_scrub_ids >&2) ||
    { echo "container_run: docker create failed for $name" >&2; return 3; }
  guest docker start "$name" >/dev/null 2> >(_scrub_ids >&2) || { echo "container_run: docker start failed for $name" >&2; return 3; }
  rc=$(guest docker wait "$name") || { echo "container_run: docker wait failed for $name" >&2; return 3; }
  [[ $rc =~ ^[0-9]+$ ]] || { echo "container_run: unreadable exit status '$rc'" >&2; return 3; }

  # Output: stdout minus the fenced cgroup block (which must be last), then stderr.
  : >"$tmp/stdout.txt"; : >"$tmp/block.txt"
  guest docker logs "$name" >"$tmp/out.txt" 2>"$tmp/err.txt" || true
  # Only the LAST BEGIN counts and the END must be the last line, with no other sentinel between
  # them. One empty line before BEGIN is the wrapper's own newline and is dropped; a partial last
  # workload line stays. Everything before BEGIN is the workload's stdout.
  local block_ok=1
  awk -v blk="$tmp/block.txt" -v rest="$tmp/stdout.txt" '
    { L[NR] = $0 }
    $0 == "@@LOWLAT_CGROUP_BEGIN" { b = NR }
    END {
      for (i = 1; i <= NR; i++) if (i != b - 1 || L[i] != "" || !b) if (!b || i < b) print L[i] > rest
      if (!b) exit 1
      if (L[NR] != "@@LOWLAT_CGROUP_END" || NR == b) exit 1
      for (i = b + 1; i < NR; i++) { if (L[i] ~ /^@@LOWLAT_CGROUP_/) exit 1; print L[i] > blk }
    }' "$tmp/out.txt" || block_ok=0
  _scrub_ids <"$tmp/stdout.txt" || true
  _scrub_ids <"$tmp/err.txt" >&2 || true

  local nr='' us='' cm='' cs=''
  if ((block_ok)); then
    # Every line is "key value" with a plain value; a key may appear once; the four we use must
    # have the exact shapes below.
    local key rest_of seen=' ' line
    while IFS= read -r line; do
      key=${line%% *}
      rest_of=${line#"$key"}
      rest_of=${rest_of# }
      if [[ $seen == *" $key "* ]]; then block_ok=0; break; fi
      seen+="$key "
      case $key in
        rc) [[ $rest_of == "$rc" ]] || block_ok=0 ;;
        nr_throttled) [[ $rest_of =~ ^[0-9]+$ ]] && nr=$rest_of || block_ok=0 ;;
        throttled_usec) [[ $rest_of =~ ^[0-9]+$ ]] && us=$rest_of || block_ok=0 ;;
        cpu.max) [[ $rest_of =~ ^(max|[0-9]+)\ [0-9]+$ ]] && cm=$rest_of || block_ok=0 ;;
        cpuset.cpus.effective) [[ -z $rest_of || $rest_of =~ ^[0-9]+([-,][0-9]+)*$ ]] && cs=$rest_of || block_ok=0 ;;
        *) [[ $line =~ ^[a-z_]+\ [0-9]+$ ]] || block_ok=0 ;;
      esac
      ((block_ok)) || break
    done <"$tmp/block.txt"
    [[ $seen == *" rc "* && $seen == *" nr_throttled "* && $seen == *" throttled_usec "* && $seen == *" cpu.max "* ]] || block_ok=0
  fi
  if ((!block_ok)); then
    nr='' us='' cm='' cs=''
    if ((has_limit)); then
      echo "container_run: no usable cgroup block in the output of $name; a --cpus/--cpuset-cpus lane needs it (does the image have sh and cat?)" >&2
      return 4
    fi
  fi

  # The facts, while the container still exists.
  local image_id
  guest docker inspect "$name" >"$tmp/inspect.json" || { echo "container_run: docker inspect failed for $name" >&2; return 3; }
  image_id=$(jq -er '.[0].Image' "$tmp/inspect.json") || die "container_run: inspect has no Image"
  guest docker image inspect "$image_id" >"$tmp/image.json" || die "container_run: docker image inspect failed"
  local digest=${digest_arg:-$lock_digest}
  if [[ -n $digest ]]; then
    jq -e --arg d "$digest" --arg i "$image_id" \
      '.[0] | (.Id == $i) and ((.Id == $d) or ((.RepoDigests // []) | any(endswith("@" + $d))))' \
      "$tmp/image.json" >/dev/null || die "container_run: the image the guest ran is not $digest (inspect says $image_id)"
  else
    digest=$image_id
  fi
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "container_run: no usable image digest ('$digest')"
  jq -n --slurpfile ins "$tmp/inspect.json" --arg gp "$GUEST_PROFILE" --arg image "$ref" --arg digest "$digest" \
    --arg seccomp "$seccomp" --arg net "$network" --arg cm "$cm" --arg cs "$cs" --arg nr "$nr" --arg us "$us" '
    ($ins[0][0].HostConfig) as $h
    | {runtime: {environment: {
        kind: "container",
        guest_profile: $gp,
        container: {
          runtime: "docker", image: $image, image_digest: $digest,
          network: $net,
          cpu_quota: (if ($h.NanoCpus // 0) == 0 then null else (($h.NanoCpus / 1e9) | tostring) end),
          cpuset: (if ($h.CpusetCpus // "") == "" then null else $h.CpusetCpus end),
          seccomp: $seccomp},
        cgroup: {
          cpu_max: ($cm | if . == "" then null else . end),
          cpuset_effective: ($cs | if . == "" then null else . end),
          nr_throttled: ($nr | if . == "" then null else tonumber end),
          throttled_usec: ($us | if . == "" then null else tonumber end)}}}}' >"$env_out.tmp" ||
    die "container_run: jq could not build the environment block"
  mv "$env_out.tmp" "$env_out"
  return "$rc"
)

# interleave_env N LANE...: run N alternations over named environment lanes (host, vm, container)
# in the order A B C A B C ... by calling the caller's `run_lane LANE ALT` for each (ALT counts
# alternations from 1). The order is interleave's, so lanes share the machine's drift. A failing
# run_lane stops the sequence and its status is returned.
#   run_lane() { lane_run "$1" "$2"; }
#   interleave_env 3 host vm container
interleave_env() {
  local n=${1:?interleave_env N LANE...} lane i=0 lanes
  shift
  (($#)) || die "interleave_env: no lanes"
  [[ $n =~ ^[1-9][0-9]*$ ]] || die "interleave_env: N must be a positive integer, got '$n'"
  for lane in "$@"; do
    [[ $lane =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "interleave_env: bad lane name '$lane'"
  done
  declare -F run_lane >/dev/null || die "interleave_env: define run_lane LANE ALT first"
  lanes=$#
  while IFS= read -r lane; do
    run_lane "$lane" $((i / lanes + 1)) || return $?
    i=$((i + 1))
  done < <(interleave "$n" "$@")
}

# strace_summary OUT -- CMD...: run CMD under `strace -f -c` (syscall counts and time, children
# followed; our own child, so no privilege) and write only the summary table to OUT, scrubbed
# through scripts/scrub-host-ids.py --filter. The raw strace file OUT.raw is removed on every
# path, a failure or a signal included. CMD's own output passes through.
# Returns CMD's status, except 77 (the automake "skipped" code, so a CMD that exits 3 is not taken
# for a skip) when strace is not installed or kernel.yama.ptrace_scope (read only) is 2 or more,
# with the reason on stderr; 1 when strace wrote no summary.
strace_summary() (
  out=${1:?strace_summary OUT -- CMD...}
  shift
  [[ ${1:-} == -- ]] || die "usage: strace_summary OUT -- CMD..."
  shift
  (($#)) || die "strace_summary: no command"
  command -v strace >/dev/null 2>&1 || { echo "strace_summary: skipped, strace is not installed" >&2; return 77; }
  scope=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 0)
  if [[ $scope =~ ^[0-9]+$ ]] && ((scope >= 2)); then
    echo "strace_summary: skipped, kernel.yama.ptrace_scope is $scope (tracing needs privilege)" >&2
    return 77
  fi
  raw=$out.raw
  trap 'rm -f "$raw"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  rc=0
  strace -f -c -o "$raw" "$@" || rc=$?
  if [[ -s $raw ]]; then
    sed -n '/^% time/,$p' "$raw" | _scrub_ids >"$out"
  else
    : >"$out"
  fi
  [[ -s $out ]] || { echo "strace_summary: strace wrote no summary for '$*'" >&2; return 1; }
  return "$rc"
)

# from_samples SAMPLES SIDECAR OUT: convert the raw little-endian int64 nanosecond file a
# free-threaded process wrote with array('q').tofile, plus its JSON sidecar (example, variant,
# count, dropped, build/runtime.python_build, gil_enabled false, ...), to a lowlat-report/1 JSON
# at OUT, through `lowlat-report from-samples`. The measured process never imports lowlat_measure
# (that re-enables the GIL); this runs in the ordinary GIL environment. Needs LOWLAT_PROFILE.
from_samples() {
  (($# == 3)) || die "usage: from_samples SAMPLES SIDECAR OUT"
  [[ -f $1 && -f $2 ]] || die "from_samples: missing $1 or $2"
  uvrun lowlat-report from-samples "$(realpath "$1")" "$(realpath "$2")" "$(realpath -m "$3")" >/dev/null || die "from_samples: conversion failed for $1"
}
