#!/usr/bin/env bash
# profile.sh - capture the machine/VM profile that must accompany every latency number.
#
# Usage: scripts/profile.sh [--text] [--pid PID] [--out FILE] [-h|--help]
#   (default)    print one JSON object (schema lowlat-profile/1) to stdout
#   --text       print an aligned human-readable block instead
#   --pid PID    report CPU affinity / sched policy of PID (default: this script)
#   --out FILE   write JSON to FILE; nothing on stdout
#
# No root needed. Every probe degrades to null/"unknown" when a file or tool is
# missing or unreadable, so it runs on the Fedora host and inside a KVM guest.
set -euo pipefail

SYS=/sys/devices/system/cpu
MODE=json
OUT=""
PID=$$

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Print file contents (first line unless "all"), empty on any failure.
read_file() {
  local f=$1
  [[ -r $f ]] || return 0
  if [[ ${2:-} == all ]]; then cat "$f" 2>/dev/null || true
  else head -n1 "$f" 2>/dev/null || true; fi
}

# JSON string from $1, or null when empty.
jstr() { jq -nc --arg v "$1" 'if $v == "" then null else $v end'; }
# JSON number from $1, or null when not numeric.
jnum() { jq -nc --arg v "$1" 'try ($v | tonumber) catch null'; }
# Run a command quietly; print stdout, never fail.
try() { "$@" 2>/dev/null || true; }
have() { command -v "$1" >/dev/null 2>&1; }

# Collapse "name value" lines on stdin: one distinct value -> string, else map.
collapse() {
  jq -Rn '[inputs | select(length > 0) | split(" ") | {key: .[0], value: .[1]}]
          | if length == 0 then null
            elif (map(.value) | unique | length) == 1 then .[0].value
            else from_entries end'
}

per_cpu() { # per_cpu <relative file under cpuN/>
  local d
  for d in "$SYS"/cpu[0-9]*; do
    if [[ -r $d/$1 ]]; then
      echo "${d##*/} $(read_file "$d/$1")"
    fi
  done
}

# Value of key=value (or bare key) from the kernel cmdline, null if absent.
cmdline_param() {
  local cmd=$1 key=$2 tok toks
  read -ra toks <<<"$cmd"
  for tok in "${toks[@]}"; do
    case $tok in
      "$key"=*) jstr "${tok#*=}"; return ;;
      "$key") jstr "(set)"; return ;;
    esac
  done
  echo null
}

g_cpu() {
  local model lscpu_json="{}"
  model=$(try grep -m1 '^model name' /proc/cpuinfo | sed 's/^[^:]*: *//')
  have lscpu && lscpu_json=$(try lscpu -J || echo '{}')
  [[ -n $lscpu_json ]] || lscpu_json="{}"
  local smt; smt=$(read_file "$SYS/smt/active")
  jq -nc --argjson l "$lscpu_json" --argjson model "$(jstr "$model")" \
     --arg smt "$smt" --argjson online "$(jstr "$(read_file "$SYS/online")")" '
    def f($k): [$l.lscpu[]? | select(.field == $k) | .data][0] | try tonumber catch null;
    { model: $model,
      sockets: f("Socket(s):"),
      cores_per_socket: f("Core(s) per socket:"),
      threads_per_core: f("Thread(s) per core:"),
      logical_cpus: f("CPU(s):"),
      smt_active: (if $smt == "1" then true elif $smt == "0" then false else null end),
      online: $online }'
}

g_power() {
  local gov epp nt boost
  gov=$(per_cpu cpufreq/scaling_governor | collapse)
  epp=$(per_cpu cpufreq/energy_performance_preference | collapse)
  nt=$(read_file "$SYS/intel_pstate/no_turbo")
  boost=$(read_file "$SYS/cpufreq/boost")
  jq -nc --argjson drv "$(jstr "$(read_file "$SYS/cpu0/cpufreq/scaling_driver")")" \
     --argjson gov "${gov:-null}" --argjson epp "${epp:-null}" \
     --arg nt "$nt" --arg boost "$boost" \
     --argjson fmin "$(jnum "$(read_file "$SYS/cpu0/cpufreq/scaling_min_freq")")" \
     --argjson fmax "$(jnum "$(read_file "$SYS/cpu0/cpufreq/scaling_max_freq")")" '
    { scaling_driver: $drv, governor: $gov, energy_performance_preference: $epp,
      intel_pstate_no_turbo: (if $nt == "" then null else $nt == "1" end),
      cpufreq_boost: (if $boost == "" then null else $boost == "1" end),
      cpu0_min_khz: $fmin, cpu0_max_khz: $fmax }'
}

g_tuned() {
  local p=""
  if have tuned-adm; then
    p=$(try tuned-adm active | sed -n 's/^Current active profile: *//p')
  fi
  [[ -n $p ]] || p=$(read_file /etc/tuned/active_profile)
  jstr "$p"
}

# Keep only latency-relevant cmdline parameters; drop root=UUID, BOOT_IMAGE and
# anything else that identifies the machine, since profiles are published.
latency_cmdline() {
  local tok keep=() toks
  read -ra toks <<<"$1"
  for tok in "${toks[@]}"; do
    case ${tok%%=*} in
      isolcpus|nohz|nohz_full|rcu_nocbs|rcu_nocb_poll|irqaffinity|threadirqs|preempt|\
      mitigations|nosmt|idle|intel_idle.max_cstate|processor.max_cstate|intel_pstate|\
      clocksource|tsc|skew_tick|nosoftlockup|nowatchdog|nmi_watchdog|audit|selinux|\
      hugepages|hugepagesz|default_hugepagesz|transparent_hugepage|numa_balancing|\
      kthread_cpus|housekeeping|isolcpus.*|workqueue.*)
        keep+=("$tok") ;;
    esac
  done
  printf '%s' "${keep[*]}"
}

g_kernel() {
  local rel ver cmd preempt rt_file rt=false
  rel=$(uname -r); ver=$(uname -v); cmd=$(latency_cmdline "$(read_file /proc/cmdline)")
  case $ver in
    *PREEMPT_RT*) preempt=PREEMPT_RT ;;
    *PREEMPT_DYNAMIC*) preempt=PREEMPT_DYNAMIC ;;
    *PREEMPT*) preempt=PREEMPT ;;
    *) preempt=none ;;
  esac
  rt_file=$(read_file /sys/kernel/realtime)
  if [[ $rt_file == 1 || $preempt == PREEMPT_RT ]]; then rt=true; fi
  jq -nc --arg rel "$rel" --arg ver "$ver" --arg pre "$preempt" --argjson rt "$rt" \
     --argjson rtf "$(jstr "$rt_file")" --argjson cmd "$(jstr "$cmd")" \
     --argjson iso "$(cmdline_param "$cmd" isolcpus)" \
     --argjson nohz "$(cmdline_param "$cmd" nohz_full)" \
     --argjson rcu "$(cmdline_param "$cmd" rcu_nocbs)" \
     --argjson irq "$(cmdline_param "$cmd" irqaffinity)" \
     --argjson sysiso "$(jstr "$(read_file "$SYS/isolated")")" \
     --argjson sysnohz "$(jstr "$(read_file "$SYS/nohz_full")")" '
    { release: $rel, version: $ver, preempt_model: $pre, realtime: $rt,
      sys_kernel_realtime: $rtf, cmdline: $cmd,
      isolcpus: $iso, nohz_full: $nohz, rcu_nocbs: $rcu, irqaffinity: $irq,
      sys_isolated: $sysiso, sys_nohz_full: $sysnohz }'
}

g_clock() {
  local d=/sys/devices/system/clocksource/clocksource0
  jq -nc --argjson cur "$(jstr "$(read_file $d/current_clocksource)")" \
     --arg av "$(read_file $d/available_clocksource)" \
     '{current_clocksource: $cur, available_clocksource: ($av | split(" ") | map(select(length > 0)))}'
}

g_process() {
  local aff pol
  aff=$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "/proc/$PID/status" 2>/dev/null || true)
  if [[ -z $aff ]] && have taskset; then
    aff=$(try taskset -cp "$PID" | sed 's/.*: *//')
  fi
  pol=""
  if have chrt; then
    pol=$(try chrt -p "$PID" | sed -n 's/.*scheduling policy: *//p')
  fi
  jq -nc --argjson pid "$PID" --argjson aff "$(jstr "$aff")" --argjson pol "$(jstr "$pol")" \
     '{pid: $pid, cpu_affinity: $aff, sched_policy: $pol}'
}

g_virt() {
  local v=""
  if have systemd-detect-virt; then v=$(systemd-detect-virt 2>/dev/null || true); fi
  jq -nc --arg v "${v:-unknown}" \
     --argjson prod "$(jstr "$(read_file /sys/class/dmi/id/product_name)")" \
     '{type: $v, product_name: $prod}'
}

g_load() {
  local a b c run rest
  read -r a b c run rest < <(read_file /proc/loadavg) || true
  jq -nc --argjson a "$(jnum "${a:-}")" --argjson b "$(jnum "${b:-}")" \
     --argjson c "$(jnum "${c:-}")" --argjson run "$(jnum "${run%%/*}")" \
     '{load1: $a, load5: $b, load15: $c, running: $run}'
}

g_memory() {
  local mi=/proc/meminfo thp
  # shellcheck disable=SC2016  # awk program, not shell
  mem() { jnum "$(try awk -v k="$1:" '$1 == k {print $2}' "$mi")"; }
  # bracketed (active) word of a THP knob such as "always [madvise] never"
  thp_mode() { read_file "/sys/kernel/mm/transparent_hugepage/$1" | sed -n 's/.*\[\(.*\)\].*/\1/p'; }
  thp=$(thp_mode enabled)
  jq -nc --argjson t "$(mem MemTotal)" --argjson ht "$(mem HugePages_Total)" \
     --argjson hf "$(mem HugePages_Free)" --argjson hs "$(mem Hugepagesize)" \
     --argjson thp "$(jstr "$thp")" --argjson defrag "$(jstr "$(thp_mode defrag)")" \
     --argjson shmem "$(jstr "$(thp_mode shmem_enabled)")" \
     '{mem_total_kb: $t, hugepages_total: $ht, hugepages_free: $hf,
       hugepagesize_kb: $hs, transparent_hugepage: $thp,
       thp_enabled: $thp, thp_defrag: $defrag,
       thp_shmem_enabled: $shmem}'
}

g_lab() {
  local out=""
  if have virsh; then
    out=$(try timeout 5 virsh -c qemu:///system list --name)
  fi
  jq -nc --arg o "$out" '{running_domains: ($o | split("\n") | map(select(length > 0)))}'
}

g_tools() {
  local gcc clang java javafull py cmake paranoid memlock
  gcc=$(have gcc && try gcc --version | head -n1 || true)
  clang=$(have clang && try clang --version | head -n1 || true)
  java=$(have java && { java -version 2>&1 | head -n1; } || true)
  # Runtime + VM lines carry vendor and build, e.g. "Temurin-25.0.5+8 (build 25.0.5+8-LTS)".
  javafull=$(have java && { java -version 2>&1 | sed -n '2,3p' | paste -sd'|' | sed 's/|/ | /'; } || true)
  py=$(have python3 && try python3 --version || true)
  cmake=$(have cmake && try cmake --version | head -n1 || true)
  paranoid=$(read_file /proc/sys/kernel/perf_event_paranoid)
  memlock=$(ulimit -l 2>/dev/null || true) # KiB, or "unlimited"
  jq -nc --argjson gcc "$(jstr "$gcc")" --argjson clang "$(jstr "$clang")" \
     --argjson java "$(jstr "$java")" --argjson jfull "$(jstr "$javafull")" \
     --argjson py "$(jstr "$py")" --argjson cmake "$(jstr "$cmake")" \
     --argjson para "$(jnum "$paranoid")" --argjson ml "$(jstr "$memlock")" \
     '{gcc: $gcc, clang: $clang, java: $java, java_full: $jfull, python3: $py, cmake: $cmake,
       perf_event_paranoid: $para, memlock_kb: $ml}'
}

# Publishable label instead of the real hostname: the lab VM's name inside a
# lowlat-* guest, otherwise "bare-metal-host"; LOWLAT_HOST_LABEL overrides.
host_label() {
  local h
  h=$(hostname 2>/dev/null || true)
  if [[ -n ${LOWLAT_HOST_LABEL:-} ]]; then printf '%s' "$LOWLAT_HOST_LABEL"
  elif [[ $h == lowlat-* ]]; then printf '%s' "$h"
  else printf 'bare-metal-host'
  fi
}

build_json() {
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(host_label)" \
    --argjson cpu "$(g_cpu)" --argjson power "$(g_power)" --argjson tuned "$(g_tuned)" \
    --argjson kernel "$(g_kernel)" --argjson clock "$(g_clock)" --argjson process "$(g_process)" \
    --argjson virt "$(g_virt)" --argjson load "$(g_load)" --argjson memory "$(g_memory)" \
    --argjson lab "$(g_lab)" --argjson tools "$(g_tools)" \
    '{schema: "lowlat-profile/1", captured_at: $at, host_label: $host,
      cpu: $cpu, power: $power, tuned: $tuned, kernel: $kernel, clock: $clock,
      process: $process, virt: $virt, load: $load, memory: $memory, lab: $lab, tools: $tools}'
}

# Flatten JSON to aligned "path  value" lines.
render_text() {
  jq -r '[paths(type != "object" and type != "array") as $p | {k: ($p | map(tostring) | join(".")), v: getpath($p)}]
         | (map(.k | length) | max) as $w
         | .[] | "\(.k + (" " * ($w - (.k | length))))  \(.v | tostring)"' <<<"$1"
}

while (($#)); do
  case $1 in
    --text) MODE=text ;;
    --pid) PID=${2:?--pid needs a PID}; shift ;;
    --out) OUT=${2:?--out needs a file}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[[ $PID =~ ^[0-9]+$ ]] || { echo "invalid PID: $PID" >&2; exit 2; }

json=$(build_json)
if [[ -n $OUT ]]; then
  printf '%s\n' "$json" >"$OUT"
elif [[ $MODE == text ]]; then
  render_text "$json"
else
  printf '%s\n' "$json"
fi
