#!/usr/bin/env bash
# Ch7 VM part, guest side: one 10 kHz x 20 s run of the agrona-spsc hand-off with the decide
# thread placed by PLACEMENT, and the decide thread's context switches read from /proc.
# vm/run.sh starts this in the lab guest over ssh; it is not meant to be run on the host.
#
#   guest-run.sh PLACEMENT OUTDIR RATE SECONDS WINDOW HOLD_MS PORT -- JVM_ARG...
#
# Needs LOWLAT_PROFILE (the guest's profile.json), the benchmarks.jar and the line-simulator that
# run.sh copied in, and prints the same lines as the host run. Reports land in OUTDIR as
# java-agrona-spsc*.json.
set -euo pipefail
# shellcheck source=../../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../../_lib/lib.sh"

(($# >= 8)) && [[ $8 == -- ]] || die "usage: guest-run.sh PLACEMENT OUTDIR RATE SECONDS WINDOW HOLD_MS PORT -- JVM_ARG..."
PLACEMENT=$1
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
RATE=$3
SECONDS_RUN=$4
WINDOW=$5
HOLD_MS=$6
PORT=$7
shift 8
COUNT=$((RATE * SECONDS_RUN))
VARIANT=agrona-spsc
EXAMPLE=07-offheap-lockfree
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
JAR=$DIR/java/target/benchmarks.jar
[[ -f $JAR && -n ${LOWLAT_PROFILE:-} ]] || die "no $JAR or no LOWLAT_PROFILE"

report=$OUT/java-$VARIANT.json
log=$OUT/java-$VARIANT.log
java_flags "$VARIANT"
flags=()
for f in "${JAVA_RUN_FLAGS[@]}"; do
  [[ $f == -XX:StartFlightRecording* ]] || flags+=("$f") # a JFR sampler thread is not hot-path company
done
cmd=(java "${flags[@]}" "$@" -cp "$JAR" io.patterncatalyst.lowlat.offheap.Handoff --variant "$VARIANT"
  --bind "127.0.0.1:$PORT" --journal-dir "$OUT/queue" --placement "$PLACEMENT"
  --expect "$COUNT" --window "$WINDOW" --idle-timeout-ms 5000 --sample-hold-ms "$HOLD_MS"
  --example "$EXAMPLE" --report "$report")
printf 'command:' >"$log"
printf ' %q' "${cmd[@]}" >>"$log"
printf '\n' >>"$log"
step "guest: $VARIANT, placement $PLACEMENT"
"${cmd[@]}" >>"$log" 2>&1 &
pid=$!
bg_track "$pid"
wait_udp_bound "$PORT" "$pid" "$log" 600
line=$(wait_log_line '^(decide-thread pid=[0-9]+ tid=[0-9]+|placement failed: .*)$' "$log" "$pid" 1500)
[[ $line != placement\ failed:* ]] || die "$line"
[[ $line =~ pid=([0-9]+)\ tid=([0-9]+) ]] || die "unparseable decide-thread line: $line"
[[ ${BASH_REMATCH[1]} == "$pid" ]] || die "decide thread reports pid ${BASH_REMATCH[1]}, launched $pid"
tid=${BASH_REMATCH[2]}

# Where the decide thread may run, and where it runs, read from the kernel (not from the program).
allowed=$(awk '/^Cpus_allowed_list:/ {print $2}' "/proc/$pid/task/$tid/status")
cpu_start=$(awk '{print $39}' "/proc/$pid/task/$tid/stat")
read -r vol0 inv0 < <(task_ctx_switches "$pid" "$tid")
simulate --rate "$RATE" --duration "$SECONDS_RUN" --dest "127.0.0.1:$PORT" --quiet >>"$log"
wait_log_line '^window-end handled=' "$log" "$pid" >/dev/null
read -r vol1 inv1 < <(task_ctx_switches "$pid" "$tid")
cpu_end=$(awk '{print $39}' "/proc/$pid/task/$tid/stat")
wait "$pid" || { cat "$log" >&2; die "$VARIANT failed"; }
bg_forget "$pid"
jq --argjson v $((vol1 - vol0)) --argjson i $((inv1 - inv0)) \
  --arg n "; decide_cpus_allowed=$allowed; decide_cpu_start=$cpu_start; decide_cpu_end=$cpu_end" \
  '.runtime.ctx_switches = {voluntary: $v, involuntary: $i} | .notes += $n' "$report" >"$report.tmp" && mv "$report.tmp" "$report"
rm -rf "$OUT/queue"
ok "placement $PLACEMENT: involuntary $((inv1 - inv0)), voluntary $((vol1 - vol0)), decide thread allowed on CPUs $allowed, ran on CPU $cpu_start..$cpu_end"
