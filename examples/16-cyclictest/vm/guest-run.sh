#!/usr/bin/env bash
# guest-run.sh - Ch16, the guest side. It runs IN THE LAB GUEST (vm/run.sh starts it over vsock ssh after
# lane_revert pushed it, with cyclic-probe, profile.sh and timerlat-summary.awk, into one directory); it is not
# meant to be run on the host. It needs only bash, coreutils, jq, awk, util-linux (chrt, taskset), cyclictest and
# rtla; it sources nothing from the repository, so the guest needs no checkout.
#
#   guest-run.sh preflight                  tools present, cyclictest and rtla versions, the probe runs
#   guest-run.sh idle-wait [SEC]            wait until the guest has been under 1 percent busy over a 2 s window
#   guest-run.sh idle-driver                print the cpuidle driver (/sys/devices/system/cpu/cpuidle/current_driver)
#   guest-run.sh haltpoll-arm               add cpuidle_haltpoll.force=1 to the RT boot entry with grubby and reboot
#   guest-run.sh lane LANE ALT              one lane, one alternation: naive | method | timerlat | haltpoll-forced |
#                                           idle-default
#
# Environment (vm/run.sh passes all of it; lanes.sh holds the values): LANE_OUT (output root), GUEST_PROFILE,
#   SNAPSHOT, MEASURE_CPU, PROBE_CPU, INTERVAL_US, HIST_US, PRIORITY, NAIVE_S, METHOD_S, TIMERLAT_S, IDLE_S,
#   TIMERLAT_THRESHOLD_US, TIMERLAT_BUCKET_US, TIMERLAT_ENTRIES.
#   DRY_RUN=1   print what a lane would run, run nothing
#
# Every program the lane starts runs as `sudo timeout -s KILL N ...`, so a hung cyclictest, probe or rtla is killed.
# Results land in LANE_OUT/LANE/altN/:
#   cyclictest-run.json   cyclictest --json without nodename and without the per-thread average
#   cyclictest.hist.gz    the --histfile, gzipped, without the average trailer
#   sched.json            policy, priority and affinity of every task of the measured process, read with chrt -p
#                         and taskset -pc while it ran
#   cpuidle.json          the idle driver, governor and per-state usage before and after
#   steal.json            steal ticks over the lane (all CPUs and the measurement CPU)
#   profile.json          the guest's profile (scripts/profile.sh)
#   cpp/cyclic-probe.json, cpp/sched.json   (method) the probe's report and its scheduling
#   timerlat.json, timerlat.txt             (timerlat) the IRQ and thread latency summary; no raw trace
#   lane.json             what ran: tool versions, command line, durations
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DRY_RUN=${DRY_RUN:-0}
EXAMPLE=16-cyclictest

die() { printf 'guest-run: %s\n' "$*" >&2; exit 1; }
step() { printf '== guest: %s\n' "$*"; }

# The lab guest, and nowhere else: this script reboots, edits boot entries and starts real-time threads.
if ((!DRY_RUN)); then
  [[ $(systemd-detect-virt 2>/dev/null || true) == kvm && -r /var/log/lab-ready ]] ||
    die "runs only in the lab guest (systemd-detect-virt must say kvm and /var/log/lab-ready must exist); use DRY_RUN=1 to print what it would do"
fi

need() { local v; for v in "$@"; do [[ -n ${!v:-} ]] || die "$v is not set (vm/run.sh passes it)"; done; }

# ---- small readers ------------------------------------------------------------------------------------------------------
busy_ticks() { awk '/^cpu / {print $2 + $3 + $4 + $7 + $8 + $9, $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9}' /proc/stat; }

# steal_read CPU: aggregate and per-CPU steal ticks, as "ALL_STEAL CPU_STEAL TOTAL" (USER_HZ ticks).
steal_read() {
  awk -v c="cpu$1" '/^cpu / {s = $9; t = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9} $1 == c {cs = $9} END {print s, cs, t}' /proc/stat
}

# cpuidle_json: the driver, the governor and, per CPU and state, usage and time in us.
cpuidle_json() {
  local base=/sys/devices/system/cpu/cpuidle drv gov rows s cpu
  drv=$(cat "$base/current_driver" 2>/dev/null || echo unknown)
  gov=$(cat "$base/current_governor" 2>/dev/null || cat "$base/current_governor_ro" 2>/dev/null || echo unknown)
  rows=$(
    for s in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[0-9]*; do
      [[ -r $s/name ]] || continue
      cpu=${s#/sys/devices/system/cpu/cpu}
      cpu=${cpu%%/*}
      printf '%s\t%s\t%s\t%s\n' "$cpu" "$(<"$s/name")" "$(<"$s/usage")" "$(<"$s/time")"
    done
  )
  jq -Rn --arg drv "$drv" --arg gov "$gov" '
    [inputs | select(length > 0) | split("\t")] as $r
    | {driver: $drv, governor: $gov,
       states: (reduce $r[] as $x ({}; .[$x[0]][$x[1]] = {usage: ($x[2] | tonumber), time_us: ($x[3] | tonumber)})) }' <<<"$rows"
}

# sched_tasks PID: a JSON array with the policy, priority and affinity of every task (thread) of PID.
sched_tasks() {
  local pid=$1 t tid comm out pol prio aff
  for t in /proc/"$pid"/task/*; do
    tid=${t##*/}
    comm=$(<"$t/comm") || continue
    out=$(chrt -p "$tid" 2>/dev/null) || continue
    pol=$(sed -n 's/.*scheduling policy: //p' <<<"$out")
    prio=$(sed -n 's/.*scheduling priority: //p' <<<"$out")
    aff=$(taskset -pc "$tid" 2>/dev/null | sed 's/.*: //')
    jq -nc --argjson tid "$tid" --arg comm "$comm" --arg pol "$pol" --argjson prio "${prio:-0}" --arg aff "$aff" \
      '{tid: $tid, comm: $comm, policy: $pol, priority: $prio, affinity: $aff}'
  done | jq -s .
}

# find_pid COMM: the pid of the one process called COMM, waiting up to 10 s for it to start.
find_pid() {
  local i pid
  for ((i = 0; i < 100; i++)); do
    pid=$(pgrep -x "$1" | head -n1 || true)
    [[ -z $pid ]] || { echo "$pid"; return 0; }
    sleep 0.1
  done
  return 1
}

# ---- sub-commands -------------------------------------------------------------------------------------------------------
preflight() {
  local t
  for t in cyclictest rtla chrt taskset jq awk pgrep timeout gzip grubby; do
    command -v "$t" >/dev/null || die "the guest has no $t"
  done
  timeout -s KILL 10 "$HERE/cyclic-probe" --interval-us 1000 --duration-ms 30 >/dev/null || die "cyclic-probe does not run in the guest (a library the host build used?)"
  # awk 'NR == 1', not head -n1: it reads all of the input, so the tool never gets SIGPIPE under pipefail.
  printf 'cyclictest %s\n' "$(cyclictest --version 2>&1 | awk 'NR == 1')"
  printf 'rtla %s\n' "$(rtla --version 2>&1 | awk 'NR == 1')"
}

idle_wait() {
  local max=${1:-120} i b0 t0 b1 t1
  for ((i = 0; i < max; i += 2)); do
    read -r b0 t0 < <(busy_ticks)
    sleep 2
    read -r b1 t1 < <(busy_ticks)
    ((t1 > t0)) || die "idle-wait: /proc/stat did not advance"
    ((100 * (b1 - b0) <= t1 - t0)) && return 0
  done
  die "the guest was still busy after $max s"
}

haltpoll_arm() {
  local idx args default
  # The RT entry by its grubby index: on Fedora Cloud's btrfs /boot, grubby rejects kernel paths.
  # awk reads all of grubby's output (no early exit), so grubby never gets SIGPIPE under pipefail.
  idx=$(sudo grubby --info=ALL | awk -F'[="]' '/^index=/ { i = $2 } /^kernel=.*lowlatrt/ && !found { print i; found = 1 }')
  [[ $idx =~ ^[0-9]+$ ]] || die "no PREEMPT_RT boot entry found"
  default=$(sudo grubby --default-index)
  [[ $default == "$idx" ]] || die "the RT entry ($idx) is not the default boot entry ($default); the reboot would not use it"
  sudo grubby --update-kernel="$idx" --args=cpuidle_haltpoll.force=1
  args=$(sudo grubby --info="$idx" | sed -n 's/^args="\(.*\)"$/\1/p')
  [[ " $args " == *" cpuidle_haltpoll.force=1 "* ]] || die "grubby did not persist cpuidle_haltpoll.force=1"
  sync
  # Reboot after this command returns, so the ssh session ends cleanly and the driver sees the new boot id.
  nohup bash -c 'sleep 2; sudo systemctl reboot' </dev/null >/dev/null 2>&1 &
  echo "rebooting with cpuidle_haltpoll.force=1 on boot entry $idx"
}

# ---- one lane ------------------------------------------------------------------------------------------------------------
# ct_args LANE: sets CT_DUR and the CT_ARGS array (cyclictest's own options; --json and --histfile are added by run_ct).
ct_args() {
  case $1 in
    naive)
      # cyclictest's defaults: SCHED_OTHER, priority 0, no -m, no -a, 1 ms interval, PM-QoS written, and the clock it picks
      # when none is named (CLOCK_REALTIME at rt-tests v2.11). Only the duration and the histogram range are ours.
      CT_DUR=$NAIVE_S
      CT_ARGS=(-D "$CT_DUR" -h "$HIST_US" -q)
      ;;
    method)
      CT_DUR=$METHOD_S
      CT_ARGS=(-m "-p$PRIORITY" --policy=fifo "-a$MEASURE_CPU" -i "$INTERVAL_US" -D "$CT_DUR" -h "$HIST_US" --clock=monotonic -q)
      ;;
    haltpoll-forced | idle-default)
      # --default-system: no write to /dev/cpu_dma_latency, so the idle driver is not masked by cyclictest's PM-QoS request.
      CT_DUR=$IDLE_S
      CT_ARGS=(-m "-p$PRIORITY" --policy=fifo "-a$MEASURE_CPU" -i "$INTERVAL_US" -D "$CT_DUR" -h "$HIST_US" --clock=monotonic --default-system -q)
      ;;
    *) die "not a cyclictest lane: $1" ;;
  esac
}

# start_ct DIR: cyclictest under sudo timeout -s KILL, in the background (CT_BG).
start_ct() {
  local raw
  step "cyclictest ${CT_ARGS[*]} for $CT_DUR s"
  if ((DRY_RUN)); then
    printf '[dry-run] sudo timeout -s KILL %s cyclictest %s --json=<tmp>/ct.json --histfile=<tmp>/ct.hist\n' "$((CT_DUR + 30))" "${CT_ARGS[*]}"
    return 0
  fi
  # The raw files go to a /tmp directory of their own: cyclictest records its command line in the JSON, and that
  # must not carry a path under the guest user's home.
  raw=$(mktemp -d /tmp/lowlat-ct.XXXXXX)
  RAW=$raw
  # shellcheck disable=SC2024 # the redirects are meant to be opened by this user, in its own directory
  sudo timeout -s KILL "$((CT_DUR + 30))" cyclictest "${CT_ARGS[@]}" --json="$raw/ct.json" --histfile="$raw/ct.hist" >"$raw/ct.out" 2>"$raw/ct.err" &
  CT_BG=$!
}

# start_probe DIR: the C++ probe on PROBE_CPU with the method lane's parameters, for METHOD_S, in the background (PROBE_BG).
start_probe() {
  local d=$1
  step "cyclic-probe on cpu $PROBE_CPU for $METHOD_S s"
  if ((DRY_RUN)); then
    printf '[dry-run] sudo env LOWLAT_PROFILE=%s/profile.json timeout -s KILL %s cyclic-probe --cpu %s --interval-us %s --duration-ms %s --priority %s --mlockall --example %s --variant probe --env vm --guest-profile %s --report %s/cpp/cyclic-probe.json\n' \
      "$d" "$((METHOD_S + 30))" "$PROBE_CPU" "$INTERVAL_US" "$((METHOD_S * 1000))" "$PRIORITY" "$EXAMPLE" "$GUEST_PROFILE" "$d"
    return 0
  fi
  mkdir -p "$d/cpp"
  # shellcheck disable=SC2024 # the redirect is meant to be opened by this user
  sudo env LOWLAT_PROFILE="$d/profile.json" timeout -s KILL "$((METHOD_S + 30))" "$HERE/cyclic-probe" --cpu "$PROBE_CPU" \
    --interval-us "$INTERVAL_US" --duration-ms "$((METHOD_S * 1000))" --priority "$PRIORITY" --mlockall --example "$EXAMPLE" \
    --variant probe --env vm --guest-profile "$GUEST_PROFILE" --report "$d/cpp/cyclic-probe.json" >"$d/cpp/probe.out" 2>&1 &
  PROBE_BG=$!
}

# sample_sched COMM OUT: read the policy, priority and affinity of the running process COMM into OUT while it measures.
sample_sched() {
  local pid
  pid=$(find_pid "$1") || die "$1 is not running (it exited early?)"
  sched_tasks "$pid" >"$2"
}

# finish_ct DIR: wait for cyclictest, then keep its JSON (no hostname, no average) and its histogram (gzipped, no average).
finish_ct() {
  local d=$1 raw=$RAW rc=0
  wait "$CT_BG" || rc=$?
  CT_BG=''
  ((rc != 124 && rc != 137)) || die "cyclictest was killed by timeout -s KILL after $((CT_DUR + 30)) s"
  ((rc == 0)) || { cat "$raw/ct.err" >&2 || true; die "cyclictest failed (status $rc)"; }
  sudo chown -R "$(id -u):$(id -g)" "$raw"
  [[ -s $raw/ct.json && -s $raw/ct.hist ]] || die "cyclictest wrote no --json/--histfile output"
  # No hostname, no average and no file paths in what is kept.
  jq 'del(.sysinfo.nodename) | del(.thread[]?.avg) | ."cmdline:" |= gsub(" --(json|histfile)=[^ ]*"; "")' "$raw/ct.json" >"$d/cyclictest-run.json"
  grep -v '^# Avg Latencies' "$raw/ct.hist" | gzip -9 -n >"$d/cyclictest.hist.gz"
  sudo rm -rf "$raw"
}

finish_probe() {
  local d=$1 rc=0
  wait "$PROBE_BG" || rc=$?
  PROBE_BG=''
  ((rc != 124 && rc != 137)) || die "cyclic-probe was killed by timeout -s KILL"
  ((rc == 0)) || die "cyclic-probe failed (status $rc): $(tail -n 3 "$d/cpp/probe.out" 2>/dev/null)"
  sudo chown -R "$(id -u):$(id -g)" "$d/cpp"
  rm -f "$d/cpp/probe.out" # the console summary; the report is the result
}

# run_timerlat DIR: rtla timerlat hist on MEASURE_CPU. Collection is BPF first and tracefs when that fails (the RT build
# has no BTF). It writes a trace file only with -t, which is not passed; the work directory is removed regardless.
run_timerlat() {
  local d=$1 work bgpid rc=0 t0 t1 fallback
  step "rtla timerlat hist on cpu $MEASURE_CPU for $TIMERLAT_S s, stop above $TIMERLAT_THRESHOLD_US us"
  if ((DRY_RUN)); then
    printf '[dry-run] sudo timeout -s KILL %s rtla timerlat hist -c %s -d %ss -P f:%s -p %s -T %s -b %s -E %s\n' \
      "$((TIMERLAT_S + 30))" "$MEASURE_CPU" "$TIMERLAT_S" "$PRIORITY" "$INTERVAL_US" "$TIMERLAT_THRESHOLD_US" "$TIMERLAT_BUCKET_US" "$TIMERLAT_ENTRIES"
    return 0
  fi
  work=$(mktemp -d /tmp/lowlat-rtla.XXXXXX)
  t0=$(date +%s)
  # shellcheck disable=SC2024 # the redirects are meant to be opened by this user
  (cd "$work" && sudo timeout -s KILL "$((TIMERLAT_S + 30))" rtla timerlat hist -c "$MEASURE_CPU" -d "${TIMERLAT_S}s" -P "f:$PRIORITY" \
    -p "$INTERVAL_US" -T "$TIMERLAT_THRESHOLD_US" -b "$TIMERLAT_BUCKET_US" -E "$TIMERLAT_ENTRIES" >"$work/rtla.out" 2>"$work/rtla.err") &
  bgpid=$!
  sleep 3
  sample_sched rtla "$d/sched.json"
  wait "$bgpid" || rc=$?
  t1=$(date +%s)
  ((rc != 124 && rc != 137)) || die "rtla was killed by timeout -s KILL after $((TIMERLAT_S + 30)) s"
  [[ -s $work/rtla.out ]] || { cat "$work/rtla.err" >&2 || true; die "rtla timerlat wrote no output (status $rc)"; }
  # The summary is a line per column. A threshold stop is recorded, not an error: rtla prints its auto-analysis and exits.
  awk -f "$HERE/timerlat-summary.awk" "$work/rtla.out" >"$work/summary.txt" || die "no histogram in rtla's output"
  # What is kept of rtla's text: its header, the trailer rows and any auto-analysis, but not the bucket rows and not the
  # average row. Capped, so a long analysis cannot bloat the results.
  grep -v -e '^[0-9]\+[[:space:]]' -e '^avg:' "$work/rtla.out" | head -n 200 >"$d/timerlat.txt" || true
  head -n 5 "$work/rtla.err" >>"$d/timerlat.txt"
  fallback=$(grep -c -e 'BTF' -e 'tracefs' "$work/rtla.err" || true)
  jq -Rn --argjson cpu "$MEASURE_CPU" --argjson thr "$TIMERLAT_THRESHOLD_US" --argjson want "$TIMERLAT_S" --argjson got "$((t1 - t0))" \
    --argjson bucket "$TIMERLAT_BUCKET_US" --argjson entries "$TIMERLAT_ENTRIES" --argjson rc "$rc" --argjson period "$INTERVAL_US" \
    --argjson fb "${fallback:-0}" --arg ex "$EXAMPLE" --slurpfile sched "$d/sched.json" '
    def val: if . == "null" then null elif . == "over" then "over" else tonumber end;
    [inputs | select(length > 0) | split(" ") | {k: .[0], v: (.[1:] | map(split("=") | {key: .[0], value: (.[1] | val)}) | from_entries)}]
    | {schema: "lowlat-timerlat/1", example: $ex, cpu: $cpu, unit: "us", period_us: $period, bucket_us: $bucket, entries: $entries,
       threshold_us: $thr, duration_requested_s: $want, elapsed_s: $got, stopped_at_threshold: ($got + 2 < $want),
       rtla_status: $rc, tracefs_fallback_lines: $fb, tasks: $sched[0]}
      + (reduce .[] as $c ({}; .[$c.k] = $c.v))' "$work/summary.txt" >"$d/timerlat.json"
  rm -rf "$work"
}

lane() {
  local lane=$1 alt=$2 d s0 c0 t0 s1 c1 t1 cpu_idle0='{}' started
  need LANE_OUT GUEST_PROFILE SNAPSHOT MEASURE_CPU PROBE_CPU INTERVAL_US HIST_US PRIORITY NAIVE_S METHOD_S TIMERLAT_S IDLE_S \
    TIMERLAT_THRESHOLD_US TIMERLAT_BUCKET_US TIMERLAT_ENTRIES
  [[ $alt =~ ^[1-9][0-9]*$ ]] || die "ALT must be a positive integer"
  d=$LANE_OUT/$lane/alt$alt
  ((DRY_RUN)) || d=$(realpath -m "$d")
  CT_BG='' PROBE_BG='' RAW=''
  if ((DRY_RUN)); then
    step "lane $lane, alternation $alt -> $d"
  else
    mkdir -p "$d"
    "$HERE/profile.sh" --out "$d/profile.json" >/dev/null
    [[ $(jq -r .virt.type "$d/profile.json") == kvm ]] || die "the guest profile does not say virt.type kvm"
    # A lane that fails leaves nothing running that could skew the next one.
    trap 'sudo pkill -KILL -x cyclictest 2>/dev/null || true; sudo pkill -KILL -x cyclic-probe 2>/dev/null || true; sudo pkill -KILL -x rtla 2>/dev/null || true' EXIT
    cpu_idle0=$(cpuidle_json)
    read -r s0 c0 t0 < <(steal_read "$MEASURE_CPU")
  fi
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  case $lane in
    naive | haltpoll-forced | idle-default)
      ct_args "$lane"
      start_ct "$d"
      if ((!DRY_RUN)); then
        sleep 3
        sample_sched cyclictest "$d/sched.json"
        finish_ct "$d"
      fi
      ;;
    method)
      ct_args method
      start_probe "$d"
      start_ct "$d"
      if ((!DRY_RUN)); then
        sleep 3
        sample_sched cyclictest "$d/sched.json"
        sample_sched cyclic-probe "$d/cpp/sched.json"
        finish_ct "$d"
        finish_probe "$d"
      fi
      ;;
    timerlat) run_timerlat "$d" ;;
    *) die "unknown lane '$lane'" ;;
  esac
  ((DRY_RUN)) && return 0
  read -r s1 c1 t1 < <(steal_read "$MEASURE_CPU")
  jq -n --argjson before "$cpu_idle0" --argjson after "$(cpuidle_json)" '{before: $before, after: $after}' >"$d/cpuidle.json"
  jq -n --argjson s $((s1 - s0)) --argjson c $((c1 - c0)) --argjson t $((t1 - t0)) --argjson hz "$(getconf CLK_TCK)" --argjson cpu "$MEASURE_CPU" \
    --arg ex "$EXAMPLE" '{schema: "lowlat-steal/1", example: $ex, steal_ticks: $s, measure_cpu: $cpu, measure_cpu_steal_ticks: $c, total_ticks: $t, clk_tck: $hz}' >"$d/steal.json"
  jq -n --arg lane "$lane" --argjson alt "$alt" --arg snap "$SNAPSHOT" --arg prof "$GUEST_PROFILE" --arg started "$started" \
    --arg ct "$(cyclictest --version 2>&1 | awk 'NR == 1')" --arg rtla "$(rtla --version 2>&1 | awk 'NR == 1')" \
    --arg args "${CT_ARGS[*]:-}" --argjson dur "${CT_DUR:-0}" \
    --argjson sums "$(cd "$HERE" && sha256sum cyclic-probe guest-run.sh profile.sh timerlat-summary.awk | jq -Rn '[inputs | split("  ") | {name: .[1], sha256: .[0]}]')" \
    '{schema: "lowlat-lane/1", lane: $lane, alt: $alt, snapshot: $snap, profile: $prof, started: $started, cyclictest_version: $ct,
      rtla_version: $rtla, cyclictest_options: $args, cyclictest_seconds: $dur, binaries: $sums}' >"$d/lane.json"
  sudo chown -R "$(id -u):$(id -g)" "$d" 2>/dev/null || true
}

case ${1:-} in
  preflight) preflight ;;
  idle-wait) idle_wait "${2:-120}" ;;
  idle-driver) cat /sys/devices/system/cpu/cpuidle/current_driver ;;
  haltpoll-arm) haltpoll_arm ;;
  lane) lane "${2:?lane LANE ALT}" "${3:?lane LANE ALT}" ;;
  *) die "usage: guest-run.sh preflight | idle-wait [SEC] | idle-driver | haltpoll-arm | lane LANE ALT" ;;
esac
