#!/usr/bin/env bash
# guest-run.sh - Ch14, the guest side. It runs IN THE LAB GUEST (vm/run.sh starts it over vsock ssh); it is not meant to
# be run on the host.
#
# The host driver reverts the guest to a snapshot, pushes the binaries into ~/<repo>/lane-bin (lib.sh lane_revert, each
# checked by sha256), and then calls these steps in order. cyclictest is not among them: lib.sh cyclictest_run is a host
# helper (it runs rt-tests over lab_ssh and converts the result with lowlat-report on the host), so the driver starts it
# beside the `probe` step. Everything that needs only the guest lives here.
#
#   guest-run.sh begin LANE ALT     clean the output directory, take the guest profile, switch stock-full to full preemption
#                                   (read back), checksum the binaries, read steal ticks and the interrupt-thread census
#   guest-run.sh idle-wait [SEC]    wait until the guest has been under 1 percent busy over a 2 s window
#   guest-run.sh probe              cyclic-probe, FIFO 95 on CPU 2, the same period and duration as cyclictest on CPU 3
#   guest-run.sh line               the line: four simulators (10 kHz together), the C++ consumer at FIFO on CPU 2
#   guest-run.sh pi                 pi-demo plain-mutex, then pi-mutex, on CPU 3
#   guest-run.sh java               the Java lane on Temurin by path: hot thread FIFO through JNA, an allocating thread,
#                                   -Xlog:safepoint to a file, chrt -p of the hot thread
#   guest-run.sh end                steal ticks, the mechanism counters, environment labels on every report
#
#   DRY_RUN=1                       print every command a step would run, run nothing
#   SMOKE=1                         short durations (lanes.sh), a check of the scripts and not a measurement
#
# Every load and every FIFO program runs under `timeout -s KILL`, because a FIFO thread that spins can starve the shell.
# sudo appears only inside this script, which runs only in the guest. Output: ~/<repo>/lane-out/, which the driver fetches.
set -euo pipefail
# shellcheck source=../../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../../_lib/lib.sh"
# shellcheck source=../lanes.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../lanes.sh"

DRY_RUN=${DRY_RUN:-0}
SMOKE=${SMOKE:-0}

# This script writes under the checkout and starts FIFO threads: it belongs in the lab guest and nowhere else. Unless it is
# a dry run, it refuses to start on anything that is not a KVM guest carrying the lab's marker file.
if ((!DRY_RUN)); then
  [[ $(systemd-detect-virt 2>/dev/null || true) == kvm && -r /var/log/lab-ready ]] ||
    die "guest-run.sh runs only in the lab guest (systemd-detect-virt must say kvm and /var/log/lab-ready must exist); use DRY_RUN=1 to print what it would do"
fi

BIN=$LOWLAT_ROOT/lane-bin
OUT=$LOWLAT_ROOT/lane-out
JAR=$BIN/preempt-rt-java.jar
export LOWLAT_PROFILE=$OUT/profile.json

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

# The lane this directory was begun for, and its guest profile string (snapshot/profile).
lane_name() { if ((DRY_RUN)); then echo "${GUEST_LANE:-stock-lazy}"; else cat "$OUT/lane"; fi; }
guest_profile() { lane_guest_profile "$(lane_name)"; }

# run_logged LOG CMD...: run CMD with its output in LOG (and the tail of LOG on stderr if it fails), or print it under DRY_RUN=1.
run_logged() {
  local log=$1
  shift
  if ((DRY_RUN)); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf ' > %q\n' "$log"
  else
    "$@" >"$log" 2>&1 || { tail -n 20 "$log" >&2; die "$1 ${*:2:3} failed (log: $log)"; }
  fi
}

# own_out: give the files a sudo'd program wrote back to the guest user, so the next step and the fetch can read them.
own_out() { x sudo chown -R "$(id -un):$(id -gn)" "$OUT"; }

# tag_env FILE...: the lane's runtime.environment (kind vm and the guest profile) into reports whose program has no option for it.
tag_env() {
  local f gp
  gp=$(guest_profile)
  for f in "$@"; do
    [[ -f $f ]] || die "tag_env: $f was not produced"
    jq --arg gp "$gp" '.runtime = ((.runtime // {}) * {environment: {kind: "vm", guest_profile: $gp}})' "$f" >"$f.tmp" || die "tag_env: jq failed on $f"
    mv "$f.tmp" "$f"
  done
}

# preempt_mode: the scheduler's preemption-mode knob; the selected mode is the one in parentheses.
# debugfs prints the modes with a trailing space ('full (lazy) '); strip it before comparing.
preempt_mode() { sudo cat /sys/kernel/debug/sched/preempt | sed 's/[[:space:]]*$//'; }

steal_ticks() { awk '/^cpu / {print $9, $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9}' /proc/stat; }
busy_ticks() { awk '/^cpu / {print $2 + $3 + $4 + $7 + $8, $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9}' /proc/stat; }

# ---- begin ----------------------------------------------------------------------------------------------------------------
begin() {
  local lane=$1 alt=$2 want mode
  [[ $alt =~ ^[1-9][0-9]*$ ]] || die "ALT must be a positive integer"
  lane_snapshot "$lane" >/dev/null # refuses an unknown lane
  step "guest: begin $lane alternation $alt"
  x rm -rf "$OUT"
  x install -d -m 0755 "$OUT" "$OUT/line" "$OUT/pi" "$OUT/java"
  if ((!DRY_RUN)); then
    echo "$lane" >"$OUT/lane"
    echo "$alt" >"$OUT/alt"
  fi
  x "$LOWLAT_ROOT/scripts/profile.sh" --out "$OUT/profile.json"
  if ((!DRY_RUN)); then
    [[ $(jq -r .virt.type "$OUT/profile.json") == kvm ]] || die "the guest profile does not say virt.type kvm"
  fi
  if [[ $lane == stock-full ]]; then
    # The runtime switch (S1): same kernel, same snapshot, full preemption instead of lazy. Read back before the lane starts.
    x sudo sh -c 'echo full > /sys/kernel/debug/sched/preempt'
    if ((!DRY_RUN)); then
      mode=$(preempt_mode)
      want=$(lane_preempt_mode stock-full)
      [[ $mode == "$want" ]] || die "stock-full: /sys/kernel/debug/sched/preempt reads '$mode' after writing full (expected '$want')"
      ok "stock-full: preempt mode is '$mode'"
    fi
  elif ((!DRY_RUN)); then
    mode=$(preempt_mode)
    want=$(lane_preempt_mode "$lane")
    [[ $mode == "$want" ]] || die "$lane: /sys/kernel/debug/sched/preempt reads '$mode' (expected '$want'); is the snapshot right?"
    ok "$lane: preempt mode is '$mode'"
  fi
  if ((DRY_RUN)); then
    x sh -c "cd $BIN && sha256sum cyclic-probe pi-demo line-simulator io-receive preempt-rt-java.jar > $OUT/binaries.txt"
  else
    (cd "$BIN" && sha256sum cyclic-probe pi-demo line-simulator io-receive preempt-rt-java.jar) >"$OUT/binaries.txt"
    steal_ticks >"$OUT/steal0"
  fi
}

# ---- idle-wait ------------------------------------------------------------------------------------------------------------
idle_wait() {
  local max_wait=${1:-120} i b0 t0 b1 t1
  if ((DRY_RUN)); then
    printf '[dry-run] wait until the guest is under 1 percent busy (up to %s s)\n' "$max_wait"
    return 0
  fi
  for ((i = 0; i < max_wait; i += 2)); do
    read -r b0 t0 < <(busy_ticks)
    sleep 2
    read -r b1 t1 < <(busy_ticks)
    ((t1 > t0)) || die "idle-wait: /proc/stat did not advance"
    if ((100 * (b1 - b0) <= (t1 - t0))); then return 0; fi # under 1 percent busy
  done
  die "the guest was still busy after $max_wait s"
}

# ---- probe ----------------------------------------------------------------------------------------------------------------
probe() {
  step "guest: cyclic-probe, FIFO 95 on CPU $PROBE_CPU, ${CT_SECONDS} s at ${INTERVAL_US} us"
  run_logged "$OUT/probe.log" sudo env LOWLAT_PROFILE="$LOWLAT_PROFILE" timeout -s KILL $((CT_SECONDS + 60)) "$BIN/cyclic-probe" \
    --cpu "$PROBE_CPU" --interval-us "$INTERVAL_US" --duration-ms $((CT_SECONDS * 1000)) --priority 95 --mlockall \
    --example "$EXAMPLE" --variant cyclic-probe --env vm --guest-profile "$(guest_profile)" --report "$OUT/probe.json"
  own_out
}

# ---- line -----------------------------------------------------------------------------------------------------------------
# The Ch12 epoll consumer at SCHED_FIFO on CPU 2 (chrt: io-receive has no policy option, and one thread does the work),
# four simulator instances on the housekeeping CPUs 0-1, loopback. The simulator starts only when the consumer has printed
# "released" (it is bound and its start hold is over).
line() {
  local expect=$((LINE_RATE * LINE_SECONDS * CAMERAS)) i cons tries
  local -a sims=()
  step "guest: the line, $((LINE_RATE * CAMERAS)) Hz x ${LINE_SECONDS} s = $expect parcels, consumer FIFO 90 on CPU $LINE_CPU"
  if ((DRY_RUN)); then
    x sudo env LOWLAT_PROFILE="$LOWLAT_PROFILE" timeout -s KILL $((LINE_SECONDS + 90)) chrt -f 90 "$BIN/io-receive" --variant epoll \
      --base-port "$UDP_BASE" --expect "$expect" --hold-ms "$HOLD_MS" --decide-ns "$DECIDE_NS" --cpus "$LINE_CPU" --report "$OUT/line/consumer.json"
    for ((i = 0; i < CAMERAS; i++)); do
      x taskset -c "$HOUSEKEEPING_CPUS" timeout -s KILL $((LINE_SECONDS + 30)) "$BIN/line-simulator" --rate "$LINE_RATE" \
        --duration "$LINE_SECONDS" --dest "127.0.0.1:$((UDP_BASE + i))" --wire flat --quiet
    done
    return 0
  fi
  # shellcheck disable=SC2024 # the log is the guest user's; only the consumer runs as root
  sudo env LOWLAT_PROFILE="$LOWLAT_PROFILE" timeout -s KILL $((LINE_SECONDS + 90)) chrt -f 90 "$BIN/io-receive" --variant epoll \
    --base-port "$UDP_BASE" --expect "$expect" --hold-ms "$HOLD_MS" --decide-ns "$DECIDE_NS" --cpus "$LINE_CPU" \
    --report "$OUT/line/consumer.json" >"$OUT/line/consumer.log" 2>&1 &
  cons=$!
  bg_track "$cons"
  for ((tries = 0; tries < 400; tries++)); do
    grep -qx released "$OUT/line/consumer.log" 2>/dev/null && break
    kill -0 "$cons" 2>/dev/null || { wait "$cons" || true; tail -n 20 "$OUT/line/consumer.log" >&2; die "the consumer exited before it was released"; }
    sleep 0.05
  done
  ((tries < 400)) || die "the consumer never reached 'released' within 20 s"
  for ((i = 0; i < CAMERAS; i++)); do
    if ((i == 0)); then
      taskset -c "$HOUSEKEEPING_CPUS" timeout -s KILL $((LINE_SECONDS + 30)) "$BIN/line-simulator" --rate "$LINE_RATE" --duration "$LINE_SECONDS" \
        --dest "127.0.0.1:$((UDP_BASE + i))" --wire flat --quiet --report "$OUT/line/lateness.json" >"$OUT/line/sim$i.log" 2>&1 &
    else
      taskset -c "$HOUSEKEEPING_CPUS" timeout -s KILL $((LINE_SECONDS + 30)) "$BIN/line-simulator" --rate "$LINE_RATE" --duration "$LINE_SECONDS" \
        --dest "127.0.0.1:$((UDP_BASE + i))" --wire flat --quiet >"$OUT/line/sim$i.log" 2>&1 &
    fi
    sims+=($!)
    bg_track "$!"
  done
  for i in "${sims[@]}"; do
    wait "$i" || die "a line simulator failed"
    bg_forget "$i"
  done
  wait "$cons" || { tail -n 20 "$OUT/line/consumer.log" >&2; die "the line consumer failed"; }
  bg_forget "$cons"
  own_out
  jq --arg e "$EXAMPLE" '.example = $e' "$OUT/line/consumer.json" >"$OUT/line/consumer.json.tmp" && mv "$OUT/line/consumer.json.tmp" "$OUT/line/consumer.json"
  tag_env "$OUT/line/consumer.json" "$OUT/line/lateness.json"
}

# ---- pi -------------------------------------------------------------------------------------------------------------------
pi() {
  local variant
  step "guest: priority inversion on CPU $PI_CPU, $PI_ROUNDS rounds, plain-mutex then pi-mutex"
  for variant in plain-mutex pi-mutex; do
    run_logged "$OUT/pi/$variant.log" sudo env LOWLAT_PROFILE="$LOWLAT_PROFILE" timeout -s KILL 90 "$BIN/pi-demo" --variant "$variant" \
      --cpu "$PI_CPU" --rounds "$PI_ROUNDS" --report "$OUT/pi/$variant.json"
  done
  own_out
  if ((!DRY_RUN)); then tag_env "$OUT/pi/plain-mutex.json" "$OUT/pi/pi-mutex.json"; fi
}

# ---- java -----------------------------------------------------------------------------------------------------------------
java_lane() {
  local jpid tries tid
  step "guest: Java on Temurin (by path), hot thread FIFO 95 through JNA on CPU $JAVA_CPU, ${JAVA_SECONDS} s"
  if ((DRY_RUN)); then
    x sudo env LOWLAT_PROFILE="$LOWLAT_PROFILE" timeout -s KILL $((JAVA_SECONDS + 90)) "$GUEST_JAVA" -Xms256m -Xmx256m \
      --enable-native-access=ALL-UNNAMED "-Xlog:safepoint:file=$OUT/java/safepoint.log:uptime,level,tags" -cp "$JAR" io.patterncatalyst.lowlat.ch14.Main \
      --cpu "$JAVA_CPU" --alloc-cpu 1 --seconds "$JAVA_SECONDS" --period-us "$INTERVAL_US" --priority 95 --env vm --guest-profile "$(guest_profile)" --report "$OUT/java/java-wake.json"
    x sh -c "chrt -p <tid of hot-wake> > $OUT/java/chrt-hot.txt"
    return 0
  fi
  [[ -x $GUEST_JAVA ]] || die "$GUEST_JAVA is not in the guest (the r05 snapshots carry Temurin 25.0.5 there; /usr/bin/java is not used)"
  # shellcheck disable=SC2024 # the log is the guest user's; only the JVM runs as root
  sudo env LOWLAT_PROFILE="$LOWLAT_PROFILE" timeout -s KILL $((JAVA_SECONDS + 90)) "$GUEST_JAVA" -Xms256m -Xmx256m \
    --enable-native-access=ALL-UNNAMED "-Xlog:safepoint:file=$OUT/java/safepoint.log:uptime,level,tags" -cp "$JAR" io.patterncatalyst.lowlat.ch14.Main \
    --cpu "$JAVA_CPU" --alloc-cpu 1 --seconds "$JAVA_SECONDS" --period-us "$INTERVAL_US" --priority 95 --env vm --guest-profile "$(guest_profile)" \
    --report "$OUT/java/java-wake.json" >"$OUT/java/java.log" 2>&1 &
  jpid=$!
  bg_track "$jpid"
  tid=''
  for ((tries = 0; tries < 600; tries++)); do
    tid=$(sed -n 's/^hot-thread tid=\([0-9][0-9]*\) .*/\1/p' "$OUT/java/java.log" 2>/dev/null | head -n1)
    [[ -n $tid ]] && break
    kill -0 "$jpid" 2>/dev/null || { wait "$jpid" || true; tail -n 20 "$OUT/java/java.log" >&2; die "the Java lane exited before its hot thread was FIFO"; }
    sleep 0.1
  done
  [[ -n $tid ]] || die "the hot thread did not report its tid within 60 s"
  # The evidence the plan asks for: the policy of the hot thread as the kernel sees it, and which threads are not SCHED_OTHER.
  chrt -p "$tid" >"$OUT/java/chrt-hot.txt" 2>&1 || die "chrt -p $tid failed"
  ps -eLo tid=,cls=,rtprio=,comm= | awk '$4 == "hot-wake" || $4 == "allocator"' >"$OUT/java/threads.txt"
  grep -q 'SCHED_FIFO' "$OUT/java/chrt-hot.txt" || { cat "$OUT/java/chrt-hot.txt" >&2; die "the Java hot thread $tid is not SCHED_FIFO"; }
  wait "$jpid" || { tail -n 20 "$OUT/java/java.log" >&2; die "the Java lane failed"; }
  bg_forget "$jpid"
  own_out
  # Safepoints: the log has one line per safepoint ("Safepoint "Reason", ... Total: N ns").
  local n total
  n=$(grep -c 'Safepoint "' "$OUT/java/safepoint.log" || true)
  total=$(sed -n 's/.*Total: \([0-9][0-9]*\) ns.*/\1/p' "$OUT/java/safepoint.log" | awk '{s += $1} END {print s + 0}')
  jq --argjson n "$n" --argjson t "$total" '.runtime.counters.safepoints = $n | .runtime.counters.safepoint_total_ns = $t' \
    "$OUT/java/java-wake.json" >"$OUT/java/java-wake.json.tmp" && mv "$OUT/java/java-wake.json.tmp" "$OUT/java/java-wake.json"
}

# ---- end ------------------------------------------------------------------------------------------------------------------
# thread_census PATTERN: "count policies" for the kernel threads whose name starts with PATTERN, policies as
# class:rtprio pairs (TS = SCHED_OTHER, FF = SCHED_FIFO), sorted and unique.
thread_census() {
  ps -eo cls=,rtprio=,comm= | awk -v pat="$1" 'index($3, pat) == 1 {n++; p[$1 ":" $2] = 1}
    END {out = ""; for (k in p) out = out (out == "" ? "" : ",") k; print n + 0, out}' | sed 's/ $/ -/'
}

end() {
  local s0 t0 s1 t1 lane irq ktim ksoft rcuc cmdline cfg_rt
  step "guest: end, steal ticks and the mechanism counters"
  if ((DRY_RUN)); then
    printf '[dry-run] write %s/steal.json and %s/mechanism.json (steal ticks, kernel, preempt mode, irq/ ktimers ksoftirqd rcuc census)\n' "$OUT" "$OUT"
    return 0
  fi
  lane=$(lane_name)
  read -r s0 t0 <"$OUT/steal0"
  read -r s1 t1 < <(steal_ticks)
  jq -n --argjson s $((s1 - s0)) --argjson t $((t1 - t0)) --argjson hz "$(getconf CLK_TCK)" --arg ex "$EXAMPLE" --arg gp "$(guest_profile)" \
    '{schema: "lowlat-steal/1", example: $ex, steal_ticks: $s, total_ticks: $t, clk_tck: $hz, runtime: {environment: {kind: "vm", guest_profile: $gp}}}' >"$OUT/steal.json"
  rm -f "$OUT/steal0"
  read -r irq irq_pol < <(thread_census 'irq/')
  read -r ktim ktim_pol < <(thread_census 'ktimers/')
  read -r ksoft ksoft_pol < <(thread_census 'ksoftirqd/')
  read -r rcuc rcuc_pol < <(thread_census 'rcuc/')
  # The command line, without what identifies a machine: the boot image, the root device and the resume device.
  cmdline=$(tr ' ' '\n' </proc/cmdline | grep -vE '^(BOOT_IMAGE|root|resume|rd\.[a-z.]*)=' | paste -sd' ')
  cfg_rt=$(grep -c '^CONFIG_PREEMPT_RT=y' "/boot/config-$(uname -r)" 2>/dev/null || true)
  jq -n --arg lane "$lane" --arg snap "$(lane_snapshot "$lane")" --arg ex "$EXAMPLE" --arg gp "$(guest_profile)" \
    --arg r "$(uname -r)" --arg v "$(uname -v)" --arg cmd "$cmdline" --arg mode "$(preempt_mode)" \
    --argjson cfg_rt "${cfg_rt:-0}" --argjson rt_runtime "$(cat /proc/sys/kernel/sched_rt_runtime_us)" \
    --argjson irq "$irq" --arg irq_pol "$irq_pol" --argjson ktim "$ktim" --arg ktim_pol "$ktim_pol" \
    --argjson ksoft "$ksoft" --arg ksoft_pol "$ksoft_pol" --argjson rcuc "$rcuc" --arg rcuc_pol "$rcuc_pol" \
    '{schema: "lowlat-mechanism/1", example: $ex, lane: $lane, snapshot: $snap, guest_profile: $gp,
      kernel: {release: $r, version: $v, cmdline: $cmd, preempt_mode: $mode, config_preempt_rt: ($cfg_rt > 0), sched_rt_runtime_us: $rt_runtime},
      threads: {irq: {count: $irq, policies: $irq_pol}, ktimers: {count: $ktim, policies: $ktim_pol},
                ksoftirqd: {count: $ksoft, policies: $ksoft_pol}, rcuc: {count: $rcuc, policies: $rcuc_pol}},
      runtime: {environment: {kind: "vm", guest_profile: $gp}}}' >"$OUT/mechanism.json"
  own_out
  ok "$lane: $(jq -r '"\(.kernel.release), preempt \(.kernel.preempt_mode), irq/ \(.threads.irq.count), ktimers \(.threads.ktimers.count)"' "$OUT/mechanism.json")"
}

# ---- sub-commands ---------------------------------------------------------------------------------------------------------
case ${1:-} in
  begin)
    GUEST_LANE=${2:?begin LANE ALT}
    begin "$GUEST_LANE" "${3:?begin LANE ALT}"
    ;;
  idle-wait) idle_wait "${2:-120}" ;;
  probe) probe ;;
  line) line ;;
  pi) pi ;;
  java) java_lane ;;
  end) end ;;
  *) die "usage: guest-run.sh begin LANE ALT | idle-wait [SEC] | probe | line | pi | java | end" ;;
esac
