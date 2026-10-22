#!/usr/bin/env bash
#
# examples/03-coordinated-omission/verify.sh
#
# Proves the observable effect of coordinated omission, in C++, Java and Python:
# the line simulator (1 kHz x 10 s) feeds a consumer that stalls once for 200 ms, and
# the SAME run is recorded three ways plus a closed-loop client. Then a control run
# without the stall, and a clock-read probe.
#
#   ./verify.sh                 build, run, assert (fails if the effect is absent)
#   ALLOW_BUSY=1 ./verify.sh    measure while a lab VM or other load is running (noisy)
#   SKIP_BUILD=1 ./verify.sh    reuse existing builds
#   LOWLAT_BUILD=DIR ./verify.sh  private C++ build directory
#
# Reports (lowlat-report/1) and profile.json land in $RESULTS_DIR
# (default results/latest). UDP ports 47230-47235 on 127.0.0.1.
set -euo pipefail
# shellcheck source=../_lib/lib.sh
. "$(dirname "$0")/../_lib/lib.sh"

EX="$(example_dir)"
RATE=1000
DURATION=10
EXPECT=$((RATE * DURATION))
STALL_MS=200
STALL_SEQ=5000

require_quiet_host
OUT="$(results_dir)"
rm -f "$OUT"/*.json "$OUT"/*.log
capture_profile "$OUT"

build_cpp co-experiment line-simulator
build_java "$EX/java"
py_sync

CPP_BIN="$(cpp_bin co-experiment)"
JAR="$EX/java/target/co-experiment-java.jar"
[[ -f $JAR ]] || die "missing $JAR (build_java first)"

# consumer LANG ARGS...: run one language's experiment binary.
consumer() {
  local lang=$1
  shift
  case $lang in
    cpp) "$CPP_BIN" "$@" ;;
    java) java -jar "$JAR" "$@" ;;
    python) uvrun --package lowlat-co co-experiment-py "$@" ;;
  esac
}

# run_pair LANG PORT STALL_MS SUFFIX: start the consumer, feed it 10 s of parcels.
run_pair() {
  local lang=$1 port=$2 stall=$3 suffix=$4 log suffix_arg
  # argparse reads a value that starts with '-' as an option unless it is joined with '='.
  if [[ $lang == python ]]; then suffix_arg=(--suffix="$suffix"); else suffix_arg=(--suffix "$suffix"); fi
  log="$OUT/$lang${suffix:-}.log"
  step "$lang: stall ${stall} ms at parcel $STALL_SEQ, port $port${suffix:+ ($suffix)}"
  : >"$log"
  consumer "$lang" run --bind "127.0.0.1:$port" --expect "$EXPECT" --stall-ms "$stall" \
    --stall-seq "$STALL_SEQ" "${suffix_arg[@]}" --out "$OUT" >"$log" 2>&1 &
  local consumer_pid=$!
  bg_track "$consumer_pid"
  wait_udp_bound "$port" "$consumer_pid" "$log"
  simulate --rate "$RATE" --duration "$DURATION" --dest "127.0.0.1:$port" --quiet >/dev/null
  wait "$consumer_pid" || { cat "$log" >&2; die "$lang consumer failed"; }
  bg_forget "$consumer_pid"
}

# p99 LANG VARIANT: the p99 in ns from a report.
p99() { jget "$OUT/$1-$2.json" '.percentiles.p99'; }

port=47230
for lang in cpp java python; do
  run_pair "$lang" "$port" "$STALL_MS" ''
  port=$((port + 1))
  run_pair "$lang" "$port" 0 '-control'
  port=$((port + 1))
  step "$lang: clock-read probe (1e6 calls)"
  consumer "$lang" probe --out "$OUT" >"$OUT/$lang-probe.log" 2>&1 || {
    cat "$OUT/$lang-probe.log" >&2
    die "$lang probe failed"
  }
done

failures=0
bad() { printf '%s✗ %s%s\n' "$_c_bad" "$*" "$_c_off"; failures=$((failures + 1)); }
# expect_ge A B MESSAGE / expect_lt A B MESSAGE / expect_within_2x A B MESSAGE: record, do not stop,
# so one run reports every criterion.
expect_ge() { if (($1 >= $2)); then ok "$3 ($1 >= $2)"; else bad "$3 (got $1, need >= $2)"; fi; }
expect_lt() { if (($1 < $2)); then ok "$3 ($1 < $2)"; else bad "$3 (got $1, need < $2)"; fi; }
expect_within_2x() {
  if (($1 <= 2 * $2 && $2 <= 2 * $1)); then ok "$3 ($1 and $2)"; else bad "$3 (got $1 and $2)"; fi
}

step "criteria (p99 in ns)"
for lang in cpp java python; do
  receipt=$(p99 "$lang" receipt-time)
  intended=$(p99 "$lang" intended-time)
  corrected=$(p99 "$lang" closed-loop-corrected)
  naive=$(p99 "$lang" closed-loop-naive)
  printf '%s: receipt=%s intended=%s closed-corrected=%s closed-naive=%s\n' \
    "$lang" "$receipt" "$intended" "$corrected" "$naive"
  expect_ge "$intended" 50000000 "$lang intended-time p99 shows the stall (>= 50 ms)"
  expect_lt "$receipt" 1000000 "$lang receipt-time p99 hides it (< 1 ms)"
  expect_within_2x "$corrected" "$intended" "$lang closed-loop-corrected p99 within 2x of intended-time p99"
  expect_lt "$naive" 1000000 "$lang closed-loop-naive p99 hides it (< 1 ms)"

  c_intended=$(p99 "$lang" intended-time-control)
  c_corrected=$(p99 "$lang" closed-loop-corrected-control)
  c_naive=$(p99 "$lang" closed-loop-naive-control)
  printf '%s control: intended=%s closed-corrected=%s closed-naive=%s\n' \
    "$lang" "$c_intended" "$c_corrected" "$c_naive"
  # intended-time still carries the simulator's send lateness and the loopback hop (~100-200 us).
  expect_lt "$c_intended" 1000000 "$lang control intended-time p99 has no stall tail (< 1 ms)"
  expect_within_2x "$c_corrected" "$c_naive" "$lang control closed-loop-corrected within 2x of closed-loop-naive"
done

step "reports (schema, histogram decode, percentile recompute)"
# Reports only: profile.json sits in the same directory.
report_check "$OUT"/{cpp,java,python}-*.json || bad "lowlat-report check failed"
printf 'host clocksource: %s (available: %s)\n' \
  "$(jget "$LOWLAT_PROFILE" '.clock.current_clocksource')" \
  "$(jget "$LOWLAT_PROFILE" '.clock.available_clocksource | join(" ")')"

((failures == 0)) || die "$failures criteria failed: the effect was not (fully) observed"
ok "coordinated omission observed in C++, Java and Python"
