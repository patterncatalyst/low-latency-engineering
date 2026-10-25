#!/usr/bin/env bash
# guest-run.sh - Ch15, the guest side. It runs IN THE LAB GUEST (vm/run.sh starts each step over vsock ssh);
# it is not meant to be run on the host.
#
#   guest-run.sh prepare                      output directory, tool and Temurin checks, the guest profile, binary checksums
#   guest-run.sh facts                        facts.json: isolated, nohz_full, the latency cmdline, preempt model, tuned,
#                                             systemd CPUAffinity, PID 1's affinity, default_smp_affinity, tool versions
#   guest-run.sh steal                        print "steal_ticks total_ticks clk_tck" from /proc/stat
#   guest-run.sh probe CPU SECONDS NAME       placement-probe pinned to CPU for SECONDS: NAME (tick, decide switches)
#   guest-run.sh noise-sample SECONDS NAME    which CPU every stress-ng and hackbench thread last ran on, sampled
#   guest-run.sh line DIR                     the 10 kHz line: four simulators on CPUs 0-1, the epoll receiver on 2-3
#   guest-run.sh java MODE SECONDS NAME       taskset (whole JVM on 2-3) | hot-thread (JVM on 0-1, one thread on CPU 3)
#   guest-run.sh irq-affinity NAME            smp_affinity writes: one virtio-net IRQ, one managed virtio-blk IRQ (errno)
#   guest-run.sh disk-io CPUS SECONDS [defect]  stress-ng --hdd (O_DIRECT) under taskset on CPUS
#   guest-run.sh hold FLAG MAX                wait until FLAG exists (the host brackets /proc/interrupts around cyclictest)
#
#   DRY_RUN=1                                 print every command a step would run, run nothing
#
# Every load generator and every program that can hold a CPU runs under `timeout -s KILL`, so a hung one ends by itself
# and a revert to the lane snapshot undoes the rest. The only privileged commands are the guest's own sudo, inside this
# script: reading debugfs and writing /proc/irq/*/smp_affinity_list. Nothing runs on the host.
#
# Outputs land in examples/15-cpu-partitioning/vm-out/ (vm/run.sh fetches the directory). cyclictest and the interrupt
# brackets run from the host (lib.sh cyclictest_run, interrupts_delta), because the converter needs the host's tools.
set -euo pipefail
# shellcheck source=../../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../../_lib/lib.sh"
# shellcheck source=../lanes.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../lanes.sh"
# shellcheck source=../../../versions.env
# shellcheck source-path=SCRIPTDIR
. "$LOWLAT_ROOT/versions.env"

DRY_RUN=${DRY_RUN:-0}

# This script writes under the checkout and starts load: it belongs in the lab guest and nowhere else. Unless it is a dry
# run, it refuses to start on anything that is not a KVM guest carrying the lab's marker file.
if ((!DRY_RUN)); then
  [[ $(systemd-detect-virt 2>/dev/null || true) == kvm && -r /var/log/lab-ready ]] ||
    die "guest-run.sh runs only in the lab guest (systemd-detect-virt must say kvm and /var/log/lab-ready must exist); use DRY_RUN=1 to print what it would do"
fi

LOWLAT_GUEST_ROOT=$(cd "$LOWLAT_ROOT" && pwd -P)
VMOUT=$LOWLAT_GUEST_ROOT/$GUEST_OUT
BIN=$LOWLAT_GUEST_ROOT/lane-bin # lane_revert pushes the checksummed binaries here
JAVA=/opt/temurin-$TEMURIN_VERSION/bin/java # Temurin by path, never /usr/bin/java
export LOWLAT_PROFILE=$VMOUT/profile.json

# x CMD...: run CMD, or print it under DRY_RUN=1.
x() {
  if ((DRY_RUN)); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
# to FILE CMD...: run CMD with its standard output in FILE, or print it under DRY_RUN=1.
to() {
  local file=$1
  shift
  if ((DRY_RUN)); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf ' > %s\n' "$file"
  else
    "$@" >"$file"
  fi
}

# ---- prepare, facts, steal ----------------------------------------------------------------------------------------------
prepare() {
  step "guest: prepare $VMOUT"
  x install -d -m 0755 "$VMOUT"
  local t
  for t in timeout taskset cyclictest stress-ng hackbench jq python3; do
    if ((DRY_RUN)); then printf '[dry-run] command -v %s\n' "$t"; else command -v "$t" >/dev/null || die "the guest has no $t"; fi
  done
  if ((DRY_RUN)); then
    printf '[dry-run] test -x %s\n' "$JAVA"
  else
    [[ -x $JAVA ]] || die "no Temurin at $JAVA"
    [[ $("$JAVA" -version 2>&1 | awk 'NR <= 2' | tr '\n' ' ') == *"Temurin-$TEMURIN_VERSION+"* ]] || die "$JAVA is not Temurin $TEMURIN_VERSION"
  fi
  x "$LOWLAT_ROOT/scripts/profile.sh" --out "$VMOUT/profile.json"
  if ((!DRY_RUN)); then
    [[ $(jq -r .virt.type "$VMOUT/profile.json") == kvm ]] || die "the guest profile does not say virt.type kvm"
    (cd "$BIN" && sha256sum "${LANE_BINARIES[@]}") >"$VMOUT/binaries.txt"
  else
    printf '[dry-run] (cd %s && sha256sum %s) > %s/binaries.txt\n' "$BIN" "${LANE_BINARIES[*]}" "$VMOUT"
  fi
}

# kernel_list FILE: the CPU list in a sysfs file as the kernel prints it; "" for an empty file or the "(null)" older kernels print.
kernel_list() {
  local v
  v=$(<"$1")
  [[ $v != "(null)" ]] || v=''
  printf '%s' "$v"
}

facts() {
  step "guest: facts"
  if ((DRY_RUN)); then
    printf '[dry-run] read /sys/devices/system/cpu/{isolated,nohz_full}, /proc/cmdline (latency options only), debugfs sched/preempt (sudo), tuned-adm active,\n'
    printf '[dry-run]   systemd CPUAffinity, taskset -cp 1, /proc/irq/default_smp_affinity, findmnt /var/tmp, tool versions > %s/facts.json\n' "$VMOUT"
    return 0
  fi
  local isolated nohz cmdline preempt tuned affinity pid1 default_smp tmp_fstype ct stress
  isolated=$(kernel_list /sys/devices/system/cpu/isolated)
  nohz=$(kernel_list /sys/devices/system/cpu/nohz_full)
  # Only the latency-relevant options: the full command line also holds the root device and the boot image.
  cmdline=$(tr ' ' '\n' </proc/cmdline | grep -E '^(isolcpus|nohz|nohz_full|rcu_nocbs|rcutree\..*|rcupdate\..*|irqaffinity|skew_tick|tsc|tuned\..*|nosoftlockup|threadirqs|preempt)(=.*)?$' | paste -sd' ' || true)
  preempt=$(sudo cat /sys/kernel/debug/sched/preempt 2>/dev/null || echo unreadable)
  tuned=$(tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: //p' | head -n1 || true)
  [[ -n $tuned ]] || tuned=$(cat /etc/tuned/active_profile 2>/dev/null || true)
  affinity=$(grep -rhE '^[[:space:]]*CPUAffinity=' /etc/systemd/system.conf /etc/systemd/system.conf.d 2>/dev/null | tail -n1 | sed 's/^[[:space:]]*//' || true)
  pid1=$(taskset -cp 1 | sed 's/.*: //')
  default_smp=$(</proc/irq/default_smp_affinity)
  tmp_fstype=$(findmnt -no FSTYPE /var/tmp || echo unknown)
  # awk 'NR == 1' reads all of the input, so the tool never gets SIGPIPE under pipefail (head exits after one line).
  ct=$(cyclictest -V 2>&1 | awk 'NR == 1' || true)
  stress=$(stress-ng --version 2>&1 | awk 'NR == 1' || true)
  jq -n --arg ex "$EXAMPLE" --arg isolated "$isolated" --arg nohz "$nohz" --arg cmdline "$cmdline" --arg preempt "$preempt" \
    --arg tuned "${tuned:-none}" --arg affinity "${affinity:-none}" --arg pid1 "$pid1" --arg smp "$default_smp" --arg tmp "$tmp_fstype" \
    --arg kernel "$(uname -r)" --arg ct "$ct" --arg stress "$stress" --arg java "$("$JAVA" -version 2>&1 | awk 'NR == 1')" \
    '{schema: "lowlat-lane-facts/1", example: $ex, kernel_release: $kernel, preempt: $preempt, isolated: $isolated, nohz_full: $nohz,
      cmdline: $cmdline, tuned_profile: $tuned, systemd_cpu_affinity: $affinity, pid1_affinity: $pid1, default_smp_affinity: $smp,
      var_tmp_fstype: $tmp, tools: {cyclictest: $ct, stress_ng: $stress, java: $java}}' >"$VMOUT/facts.json"
}

# steal: the guest's own steal ticks (time the hypervisor ran something else while a vCPU wanted to run) and all ticks.
steal() {
  awk '/^cpu / {print $9, $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9}' /proc/stat | tr '\n' ' '
  getconf CLK_TCK
}

# ---- probes ---------------------------------------------------------------------------------------------------------------
probe() {
  local cpu=$1 secs=$2 name=$3
  step "guest: placement-probe on CPU $cpu for ${secs} s -> $name"
  to "$VMOUT/$name" timeout -s KILL $((secs + 30)) "$BIN/placement-probe" --cpu "$cpu" --busy-ms $((secs * 1000))
}

# noise_sample SECONDS NAME: the last-run CPU of every stress-ng and hackbench thread, read from /proc/PID/task/TID/stat
# (field 39, counted after the last ")" as lib.sh thread_cpus does), every 100 ms. Done here in one pass over all the
# noise threads: thread_cpus samples one PID at a time and a hackbench group is dozens of processes. A thread counts as
# seen on the isolated set when any sample put it there.
noise_sample() {
  local secs=$1 name=$2 n i tmp cpus_json
  step "guest: noise-sample ${secs} s -> $name"
  if ((DRY_RUN)); then
    printf '[dry-run] %s x awk over /proc/[0-9]*/task/[0-9]*/stat (comm stress-ng*, hackbench*), 100 ms apart > %s\n' "$((secs * 10))" "$name"
    return 0
  fi
  n=$((secs * 10))
  tmp=$(mktemp)
  for ((i = 0; i < n; i++)); do
    awk '{ if (match($0, /\(.*\)/) == 0) next
           comm = substr($0, RSTART + 1, RLENGTH - 2)
           m = split(substr($0, RSTART + RLENGTH + 1), f, " ")
           if (m >= 37 && comm ~ /^(stress-ng|hackbench)/) print $1, f[37] }' /proc/[0-9]*/task/[0-9]*/stat 2>/dev/null >>"$tmp" || true
    sleep 0.1
  done
  cpus_json=$(_cpu_expand "$ISOLATED_SET" | jq -Rn '[inputs | tonumber]')
  jq -Rn --arg ex "$EXAMPLE" --arg iso "$ISOLATED_SET" --argjson isoc "$cpus_json" --argjson n "$n" '
    [inputs | split(" ") | {t: .[0], c: (.[1] | tonumber)}] as $o
    | {schema: "lowlat-noise-cpus/1", example: $ex, isolated: $iso, samples: $n, interval_s: 0.1,
       observations: ($o | length),
       threads: ($o | map(.t) | unique | length),
       threads_on_isolated: ($o | map(select(.c as $c | $isoc | index($c))) | map(.t) | unique | length),
       cpus: ($o | group_by(.c) | map({key: (.[0].c | tostring), value: length}) | from_entries)}' <"$tmp" >"$VMOUT/$name"
  rm -f "$tmp"
  [[ $(jq .observations "$VMOUT/$name") -gt 0 ]] || die "noise-sample: no stress-ng or hackbench thread was running"
}

# ---- the line --------------------------------------------------------------------------------------------------------------
line() {
  local d=$VMOUT/$1 i expect cons_pid sim_pids='' p rc=0
  expect=$((LINE_RATE * LINE_SECONDS))
  step "guest: the line, $CAMERAS cameras x ${LINE_RATE} Hz x ${LINE_SECONDS} s; simulators on CPUs $HOUSEKEEPING_SET, receive/decide on CPUs $ISOLATED_SET"
  x install -d -m 0755 "$d"
  if ((DRY_RUN)); then
    printf '[dry-run] taskset -c %s timeout -s KILL %s io-receive --variant epoll --base-port %s --expect %s --hold-ms %s --decide-ns %s --report consumer.json\n' \
      "$ISOLATED_SET" "$((LINE_SECONDS + 90))" "$UDP_BASE" "$expect" "$HOLD_MS" "$DECIDE_NS"
    printf '[dry-run] %s x taskset -c %s timeout -s KILL %s line-simulator --rate %s --duration %s --dest 127.0.0.1:PORT --wire flat --quiet\n' \
      "$CAMERAS" "$HOUSEKEEPING_SET" "$((LINE_SECONDS + 30))" "$LINE_RATE" "$LINE_SECONDS"
    return 0
  fi
  taskset -c "$ISOLATED_SET" timeout -s KILL $((LINE_SECONDS + 90)) "$BIN/io-receive" --variant epoll --base-port "$UDP_BASE" \
    --expect "$expect" --hold-ms "$HOLD_MS" --decide-ns "$DECIDE_NS" --report "$d/consumer.json" >"$d/consumer.log" 2>&1 &
  cons_pid=$!
  bg_track "$cons_pid"
  # The receiver binds before the start hold ends and prints "released" when its threads go: only then do the simulators start.
  wait_log_line '^released$' "$d/consumer.log" "$cons_pid" 600 >/dev/null
  for ((i = 0; i < CAMERAS; i++)); do
    local -a report=()
    ((i != 0)) || report=(--report "$d/lateness.json") # camera 0's emit lateness
    taskset -c "$HOUSEKEEPING_SET" timeout -s KILL $((LINE_SECONDS + 30)) "$BIN/line-simulator" --rate "$LINE_RATE" --duration "$LINE_SECONDS" \
      --dest "127.0.0.1:$((UDP_BASE + i))" --wire flat --quiet "${report[@]}" >"$d/sim$i.log" 2>&1 &
    sim_pids+=" $!"
    bg_track "$!"
  done
  for p in $sim_pids; do
    wait "$p" || { echo "a simulator instance failed" >&2; rc=1; }
    bg_forget "$p"
  done
  wait "$cons_pid" || { tail -n 20 "$d/consumer.log" >&2; echo "the receiver failed" >&2; rc=1; }
  bg_forget "$cons_pid"
  ((rc == 0)) || die "the line failed"
  # The Ch12 receiver writes its own example id; in this chapter's results the report belongs to this example.
  jq --arg e "$EXAMPLE" '.example = $e' "$d/consumer.json" >"$d/consumer.json.tmp" || die "jq failed on consumer.json"
  mv "$d/consumer.json.tmp" "$d/consumer.json"
  [[ $(jq .count "$d/consumer.json") -gt 0 ]] || die "the receiver recorded no parcels"
}

# ---- Java ------------------------------------------------------------------------------------------------------------------
java_lane() {
  local mode=$1 secs=$2 name=$3 mask
  local -a jvm=(-Xms256m -Xmx256m --enable-native-access=ALL-UNNAMED)
  local -a cmd=("$JAVA" "${jvm[@]}" -cp "$BIN/cpu-partitioning-java.jar" io.patterncatalyst.lowlat.ch15.JvmPlacement --seconds "$secs" --isolated "$ISOLATED_SET" --out "$VMOUT/$name")
  case $mode in
    taskset) mask=$ISOLATED_SET cmd+=(--mode taskset) ;;                              # the whole JVM on the isolated pair
    hot-thread) mask=$HOUSEKEEPING_SET cmd+=(--mode hot-thread --cpu "$MEASURE_CPU") ;; # the JVM on 0-1, one thread moved to CPU 3
    *) die "java: MODE is taskset or hot-thread" ;;
  esac
  step "guest: Temurin $TEMURIN_VERSION, $mode: JVM on CPUs $mask for ${secs} s -> $name"
  if ((DRY_RUN)); then
    printf '[dry-run] taskset -c %s timeout -s KILL %s' "$mask" "$((secs + 60))"
    printf ' %q' "${cmd[@]}"
    printf '\n'
    return 0
  fi
  taskset -c "$mask" timeout -s KILL $((secs + 60)) "${cmd[@]}" >"$VMOUT/$name.log" 2>&1 || { tail -n 20 "$VMOUT/$name.log" >&2; die "the JVM placement ($mode) failed"; }
}

# ---- IRQ affinity ----------------------------------------------------------------------------------------------------------
# The smp_affinity write, with the errno Python's OSError carries: one virtio-net IRQ (not managed: the write is accepted
# and the effective affinity moves) and one virtio-blk request-queue IRQ (managed by the kernel: the write is refused).
# The affinity is put back afterwards. Runs under the guest's sudo; reads and writes /proc/irq only.
# shellcheck disable=SC2016
IRQ_PY='
import errno, json, re, sys

def irqs(pattern):
    out = []
    for line in open("/proc/interrupts"):
        f = line.split()
        if f and re.fullmatch(r"\d+:", f[0]) and re.search(pattern, f[-1]):
            out.append((int(f[0][:-1]), f[-1]))
    return out

def read(path):
    try:
        return open(path).read().strip()
    except OSError as e:
        return "errno %d" % e.errno

def attempt(irq, name, value):
    base = "/proc/irq/%d/" % irq
    r = {"irq": irq, "name": name, "wrote": value,
         "before": read(base + "smp_affinity_list"), "effective_before": read(base + "effective_affinity_list")}
    try:
        with open(base + "smp_affinity_list", "w") as f:
            f.write(value)
        r["errno"], r["errno_name"] = 0, "accepted"
    except OSError as e:
        r["errno"], r["errno_name"] = e.errno, errno.errorcode.get(e.errno, "E%d" % e.errno)
    r["after"] = read(base + "smp_affinity_list")
    r["effective_after"] = read(base + "effective_affinity_list")
    if r["errno"] == 0:
        try:
            with open(base + "smp_affinity_list", "w") as f:
                f.write(r["before"])
        except OSError:
            r["restore_failed"] = True
    return r

net = irqs(r"^virtio\d+-(input|output)\.\d+$")
blk = irqs(r"^virtio\d+-req\.\d+$")
if not net or not blk:
    sys.exit("no virtio-net (%d) or virtio-blk (%d) queue IRQ in /proc/interrupts" % (len(net), len(blk)))
print(json.dumps({"schema": "lowlat-irq-affinity/1", "example": sys.argv[1], "target_list": sys.argv[2],
                  "virtio_net": attempt(net[0][0], net[0][1], sys.argv[2]),
                  "virtio_blk": attempt(blk[0][0], blk[0][1], sys.argv[2])}, indent=2))
'
irq_affinity() {
  local name=$1
  step "guest: smp_affinity write on a virtio-net IRQ and a managed virtio-blk IRQ -> $name"
  if ((DRY_RUN)); then
    printf '[dry-run] sudo python3 -c <irq script> %s %s > %s\n' "$EXAMPLE" "$HOUSEKEEPING_SET" "$name"
    return 0
  fi
  # The redirect is meant to be the unprivileged user's: only the /proc/irq writes need root, and the output file is ours.
  # shellcheck disable=SC2024
  sudo python3 -c "$IRQ_PY" "$EXAMPLE" "$HOUSEKEEPING_SET" >"$VMOUT/$name"
}

# ---- disk I/O and the interrupt bracket ------------------------------------------------------------------------------------
# disk_io CPUS SECONDS [defect]: stress-ng --hdd, one worker per listed CPU, under taskset, O_DIRECT in 4 KiB writes under
# /var/tmp (a disk filesystem; /tmp may be tmpfs), so the submitting thread is the one that gets the completion interrupt.
# CPUS inside the isolated set is the defect lane's point and needs the third argument.
disk_io() {
  local cpulist=$1 secs=$2 defect=${3:-} c n
  local -A iso=()
  for c in $(_cpu_expand "$ISOLATED_SET"); do iso[$c]=1; done
  for c in $(_cpu_expand "$cpulist"); do
    [[ -z ${iso[$c]:-} || $defect == defect ]] || die "disk-io: CPU $c is in the isolated set ($ISOLATED_SET); only the irq-on-measure-cpu lane does that, on purpose"
  done
  n=$(_cpu_expand "$cpulist" | wc -l)
  step "guest: stress-ng --hdd $n (direct) on CPUs $cpulist for ${secs} s"
  x timeout -s KILL $((secs + 5)) taskset -c "$cpulist" stress-ng --hdd "$n" --hdd-opts direct --hdd-write-size 4k --hdd-bytes 256m \
    --temp-path /var/tmp --timeout "${secs}s" --quiet
}

hold() {
  local flag=$1 max=$2 i
  if ((DRY_RUN)); then
    printf '[dry-run] wait up to %s s for %s\n' "$max" "$flag"
    return 0
  fi
  for ((i = 0; i < max * 5; i++)); do
    [[ -e $flag ]] && { rm -f "$flag"; return 0; }
    sleep 0.2
  done
  die "hold: $flag did not appear within ${max} s"
}

case ${1:-} in
  prepare) prepare ;;
  facts) facts ;;
  steal) steal ;;
  probe) probe "${2:?probe CPU SECONDS NAME}" "${3:?probe CPU SECONDS NAME}" "${4:?probe CPU SECONDS NAME}" ;;
  noise-sample) noise_sample "${2:?noise-sample SECONDS NAME}" "${3:?noise-sample SECONDS NAME}" ;;
  line) line "${2:?line DIR}" ;;
  java) java_lane "${2:?java MODE SECONDS NAME}" "${3:?java MODE SECONDS NAME}" "${4:?java MODE SECONDS NAME}" ;;
  irq-affinity) irq_affinity "${2:?irq-affinity NAME}" ;;
  disk-io) disk_io "${2:?disk-io CPUS SECONDS [defect]}" "${3:?disk-io CPUS SECONDS [defect]}" "${4:-}" ;;
  hold) hold "${2:?hold FLAG MAX}" "${3:?hold FLAG MAX}" ;;
  *) die "usage: guest-run.sh prepare | facts | steal | probe CPU SECONDS NAME | noise-sample SECONDS NAME | line DIR | java MODE SECONDS NAME | irq-affinity NAME | disk-io CPUS SECONDS [defect] | hold FLAG MAX" ;;
esac
