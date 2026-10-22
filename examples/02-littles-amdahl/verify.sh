#!/usr/bin/env bash
#
# examples/02-littles-amdahl/verify.sh - prove the two laws of Ch2 on the parcel line.
#
#   ./verify.sh                 # build, run, assert, write reports to results/latest
#   ALLOW_BUSY=1 ./verify.sh    # measure although a lab VM is running (numbers are noisy)
#   SKIP_BUILD=1 ./verify.sh    # reuse existing builds
#   RESULTS_DIR=DIR ./verify.sh # write reports elsewhere
#
# A. Little's Law (C++ and Java): at 1 kHz for 10 s, with a variable service time, the sampled
#    number of parcels in the system L is within 5 % of lambda * W-bar.
# B. Amdahl's Law: speedup at N=4 is within +-15 % of 1 / (s + (1 - s) / N) with the measured
#    serial fraction s (C++ and Java); Python threads < 1.3x (the GIL), processes > 2x.
#
# Exit 0 only when every criterion holds. All criteria are evaluated and printed; a failed one
# does not hide the others. Never changes the host: no sudo, no sysctl.
set -euo pipefail
# shellcheck source=../_lib/lib.sh
. "$(dirname "$0")/../_lib/lib.sh"

EXAMPLE=02-littles-amdahl
HERE=$(example_dir)
PORT_CPP=47220
PORT_JAVA=47221
RATE=1000
DURATION=10
REPS=${REPS:-30}
failures=0

require_quiet_host
RESULTS=$(results_dir)
capture_profile "$RESULTS"
jq -n --arg load "$(cut -d' ' -f1-3 /proc/loadavg)" '{loadavg: $load}' >"$RESULTS/loadavg.json"
ok "loadavg at start: $(jq -r .loadavg "$RESULTS/loadavg.json") ($(nproc) CPUs)"

# check LABEL PASS(0/1) DETAIL: print one criterion outcome; count failures.
check() {
  if (($2)); then ok "PASS $1: $3"; else
    say_bad "FAIL $1: $3" >&2
    failures=$((failures + 1))
  fi
}

# within ABS_VALUE LIMIT: 1 when |ABS_VALUE| <= LIMIT (floats), else 0.
within() { jq -n --argjson v "$1" --argjson l "$2" 'if ($v | fabs) <= $l then 1 else 0 end'; }

# pct VALUE: VALUE x 100 with a sign and DECIMALS places (default 2), e.g. 0.0123 -> +1.23
pct() { printf "%+.${2:-2}f" "$(jq -n --argjson v "$1" '$v * 100')"; }

# lt A B / gt A B: 1 when the float A is below / above B, else 0.
lt() { jq -n --argjson a "$1" --argjson b "$2" 'if $a < $b then 1 else 0 end'; }
gt() { jq -n --argjson a "$1" --argjson b "$2" 'if $a > $b then 1 else 0 end'; }

# ---------------------------------------------------------------------------- build
BIN_JAR="$HERE/java/target/littles-amdahl-java.jar"
if [[ ${SKIP_BUILD:-0} != 1 ]]; then
  build_cpp littles-consumer amdahl-cpp ch02-model-test line-simulator
  build_java "$HERE/java"
  step "unit tests"
  "$(cpp_bin ch02-model-test)" --gtest_brief=1
  mvn -B -q -f "$LOWLAT_EXAMPLES/pom.xml" -pl 02-littles-amdahl/java -am test
  (cd "$LOWLAT_EXAMPLES" && uv run -q --package lowlat-amdahl pytest -q "$HERE/amdahl-py")
fi
[[ -f $BIN_JAR ]] || die "missing $BIN_JAR (run without SKIP_BUILD)"
PY_BIN="$LOWLAT_EXAMPLES/.venv/bin/amdahl-py"
[[ -x $PY_BIN ]] || (cd "$LOWLAT_EXAMPLES" && uv run -q --package lowlat-amdahl true)
[[ -x $PY_BIN ]] || die "amdahl-py is not installed in the uv workspace"

# ---------------------------------------------------------------------------- A: Little
# littles LANG PORT CMD...: start the consumer, wait until it listens, run the simulator.
littles() {
  local lang=$1 port=$2
  shift 2
  step "Little's Law, $lang: lambda=$RATE/s for ${DURATION}s into UDP $port"
  "$@" >"$RESULTS/$lang-littles.log" 2>&1 &
  local pid=$!
  bg_track "$pid"
  wait_udp_bound "$port" "$pid" "$RESULTS/$lang-littles.log" 200
  simulate --rate "$RATE" --duration "$DURATION" --dest "127.0.0.1:$port" --quiet >/dev/null
  wait "$pid" || { cat "$RESULTS/$lang-littles.log" >&2; die "$lang consumer failed"; }
  bg_forget "$pid"
  grep -E '^(model|warehouse):' "$RESULTS/$lang-littles.log"
}

littles cpp "$PORT_CPP" "$(cpp_bin littles-consumer)" --port "$PORT_CPP" --rate "$RATE" \
  --duration "$DURATION" --report "$RESULTS/cpp-littles.json"
littles java "$PORT_JAVA" java -cp "$BIN_JAR" io.patterncatalyst.lowlat.ch02.LittlesConsumer \
  --port "$PORT_JAVA" --rate "$RATE" --duration "$DURATION" --report "$RESULTS/java-littles.json"

for lang in cpp java; do
  f=$RESULTS/$lang-littles.json
  count=$(jget "$f" .count)
  dropped=$(jget "$f" .dropped)
  l=$(jget "$f" .model.L_sampled_time_average)
  pred=$(jget "$f" .model.predicted_L)
  err=$(jget "$f" .model.relative_error)
  check "A $lang no loss" "$((count == RATE * DURATION && dropped == 0))" "count=$count dropped=$dropped"
  check "A $lang Little's Law" "$(within "$err" 0.05)" \
    "L(sampled)=$l vs lambda*W-bar=$pred, error $(pct "$err") % (need within 5 %)"
done
echo "warehouse framing: $(jq -r --arg rate "$RATE" '.model.warehouse | "\(.scan_to_divert_budget_ms) ms scan-to-divert at \(.belt_mps) m/s = \(.belt_metres_in_budget) m of belt; at \($rate) parcels/s that is lambda*W = \(.in_flight_parcels) parcels in flight"' "$RESULTS/cpp-littles.json")"

# ---------------------------------------------------------------------------- B: Amdahl
# effective_ghz FILE: user cycles over task-clock from a perf-stat CSV; "unavailable (...)" if none.
paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)
effective_ghz() {
  local cycles clock
  cycles=$(awk -F, '$3 ~ /^cycles/ && $1 ~ /^[0-9]+$/ {print $1}' "$1" 2>/dev/null || true)
  clock=$(awk -F, '$3 ~ /^task-clock/ && $1 ~ /^[0-9.]+$/ {print $1}' "$1" 2>/dev/null || true)
  if [[ -n $cycles && -n $clock ]]; then
    printf '%.2f' "$(jq -n --argjson c "$cycles" --argjson t "$clock" '$c / ($t * 1e6)')"
  else
    echo "unavailable (perf_event_paranoid=$paranoid)"
  fi
}

# amdahl LANG CMD...: run under perf stat (user-space events, own process, no root) when it works.
amdahl() {
  local lang=$1
  shift
  step "Amdahl's Law, $lang: N=1,2,4, $REPS repetitions each"
  local perf_out=$RESULTS/$lang-perf.csv
  if perf stat -x, -e cycles:u,task-clock -o "$perf_out" -- true 2>/dev/null; then
    perf stat -x, -e cycles:u,task-clock -o "$perf_out" -- "$@"
  else
    rm -f "$perf_out"
    "$@"
  fi
  local ghz
  ghz=$(effective_ghz "$perf_out")
  echo "effective GHz ($lang, user cycles / task-clock): $ghz"
  # Record it beside the model (a modelling input / run condition, not a latency).
  local f
  for f in "$RESULTS/$lang"-amdahl-*.json; do
    jq --arg ghz "$ghz" '.model.effective_ghz = (try ($ghz | tonumber) catch $ghz)' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  done
}

amdahl cpp "$(cpp_bin amdahl-cpp)" --reps "$REPS" --report-dir "$RESULTS"
amdahl java java -cp "$BIN_JAR" io.patterncatalyst.lowlat.ch02.Amdahl --reps "$REPS" --report-dir "$RESULTS"
amdahl python "$PY_BIN" --reps "$REPS" --report-dir "$RESULTS"

for lang in cpp java; do
  f=$RESULTS/$lang-amdahl-n4.json
  s=$(jget "$f" .model.serial_fraction_modelling_input)
  pred=$(jget "$f" .model.predicted_speedup)
  meas=$(jget "$f" .model.measured_speedup_p50)
  err=$(jget "$f" .model.relative_error)
  check "B $lang Amdahl N=4" "$(within "$err" 0.15)" \
    "s=$s, predicted $(printf %.2f "$pred")x, measured $(printf %.2f "$meas")x, error $(pct "$err" 1) % (need within 15 %)"
done
t4=$(jget "$RESULTS/python-amdahl-threads-n4.json" .model.measured_speedup_p50)
p4=$(jget "$RESULTS/python-amdahl-processes-n4.json" .model.measured_speedup_p50)
gil=$(jget "$RESULTS/python-amdahl-threads-n4.json" .build.gil_enabled)
check "B python threads (GIL=$gil)" "$(lt "$t4" 1.3)" "N=4 speedup $(printf %.2f "$t4")x (need < 1.3x)"
check "B python processes" "$(gt "$p4" 2.0)" "N=4 speedup $(printf %.2f "$p4")x (need > 2x)"

# Observation, not a criterion: the same work without the barriers. A lock section then overlaps
# the other workers' parallel work, so the run beats the strict-serial formula.
step "observation: --sync free (no barriers), C++ and Java, 10 repetitions"
"$(cpp_bin amdahl-cpp)" --sync free --reps 10 --report-dir "$RESULTS" | grep -E 'serial fraction|N=[0-9]:'
java -cp "$BIN_JAR" io.patterncatalyst.lowlat.ch02.Amdahl --sync free --reps 10 --report-dir "$RESULTS" |
  grep -E 'serial fraction|N=[0-9]:'

# ---------------------------------------------------------------------------- reports
step "validating reports"
mapfile -t reports < <(find "$RESULTS" -maxdepth 1 -name '*.json' ! -name profile.json ! -name loadavg.json | sort)
report_check "${reports[@]}"
jq -r '.profile | "profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release)"' "${reports[0]}"

if ((failures)); then
  die "$EXAMPLE: $failures criterion/criteria failed (reports in $RESULTS)"
fi
ok "$EXAMPLE verified: every criterion holds (reports in $RESULTS)"
