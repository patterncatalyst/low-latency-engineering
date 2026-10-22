#!/usr/bin/env bash
# Ch1 verify: latency is a distribution, and design choices move its shape.
#   A. per-parcel vs batch-32: equal throughput (<1 % apart), batch p50 >= 10x per-parcel p50.
#   B. bimodal-1pct: p99 >= 20x p50 while p50 stays in the fast mode (< 1/4 of the slow path).
# Runs C++, Python and Java at 1 kHz x 10 s on UDP port 47210. See README.md.
# RECHECK=results/<run-id> re-evaluates committed reports without running anything.
set -euo pipefail
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

EXAMPLE=01-latency-distribution
DIR=$(example_dir)
PORT=47210
RATE=1000
SECONDS_RUN=10
COUNT=$((RATE * SECONDS_RUN))

# RECHECK=DIR: evaluate the criteria on the reports already in DIR (no build, no run).
if [[ -n ${RECHECK:-} ]]; then
  out=$(cd "$RECHECK" && pwd)
  export LOWLAT_PROFILE=$out/profile.json
else
  require_quiet_host
  out=$(results_dir)
  capture_profile "$out"

  build_cpp latdist-consumer line-simulator
  build_java "$DIR/java"
  py_sync
fi

# consumer_cmd LANG: print the consumer command line (one word per line).
consumer_cmd() {
  case $1 in
    cpp) cpp_bin latdist-consumer ;;
    python) printf '%s\n' uv run -q --package lowlat-latdist latdist-py ;;
    java) printf '%s\n' java -jar "$DIR/java/target/latdist-java.jar" ;;
  esac
}

# run_variant LANG VARIANT: one 1 kHz x 10 s run; report in $out/LANG-VARIANT.json.
run_variant() {
  local lang=$1 variant=$2 report log cmd=() pid
  report="$out/$lang-$variant.json"
  log="$out/$lang-$variant.log"
  mapfile -t cmd < <(consumer_cmd "$lang")
  step "$lang / $variant"
  (cd "$LOWLAT_EXAMPLES" && exec "${cmd[@]}" --variant "$variant" --bind "127.0.0.1:$PORT" \
    --expect "$COUNT" --example "$EXAMPLE" --report "$report") >"$log" 2>&1 &
  pid=$!
  # The consumer prints its "variant" line once it is bound (after calibration).
  for _ in $(seq 1 300); do
    grep -q 'variant' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; die "$lang/$variant consumer exited early"; }
    sleep 0.1
  done
  simulate --rate "$RATE" --duration "$SECONDS_RUN" --dest "127.0.0.1:$PORT" --quiet >>"$log"
  wait "$pid" || { cat "$log" >&2; die "$lang/$variant consumer failed"; }
  [[ $(jget "$report" .count) -eq $COUNT ]] || die "$lang/$variant: count != $COUNT"
  [[ $(jget "$report" .dropped) -eq 0 ]] || die "$lang/$variant: parcels were dropped"
}

# throughput_mhz FILE: processed throughput in milli-Hz, from the report's notes.
throughput_mhz() { jget "$1" '.notes | capture("throughput_mhz=(?<v>[0-9]+)").v'; }

reports=()
for lang in cpp python java; do
  for variant in per-parcel batch-32 bimodal-1pct; do
    [[ -n ${RECHECK:-} ]] || run_variant "$lang" "$variant"
    reports+=("$out/$lang-$variant.json")
  done
done

step "checking reports"
report_check "${reports[@]}"

for lang in cpp python java; do
  step "criteria: $lang"
  pp="$out/$lang-per-parcel.json"
  b32="$out/$lang-batch-32.json"
  bim="$out/$lang-bimodal-1pct.json"

  # A. Same offered rate, so the same processed throughput (relative difference < 1 %).
  t_pp=$(throughput_mhz "$pp")
  t_b32=$(throughput_mhz "$b32")
  diff=$((t_pp > t_b32 ? t_pp - t_b32 : t_b32 - t_pp))
  assert_lt $((diff * 100)) "$t_pp" "$lang A: throughput per-parcel=$t_pp mHz vs batch-32=$t_b32 mHz differs < 1 %"
  # A. ...but each parcel waits for its batch to fill.
  pp_p50=$(jget "$pp" .percentiles.p50)
  assert_ge "$(jget "$b32" .percentiles.p50)" $((10 * pp_p50)) "$lang A: batch-32 p50 >= 10x per-parcel p50 ($pp_p50 ns)"

  # B. One parcel in a hundred is slow: the tail explodes, the median does not move.
  bim_p50=$(jget "$bim" .percentiles.p50)
  assert_ge "$(jget "$bim" .percentiles.p99)" $((20 * bim_p50)) "$lang B: bimodal p99 >= 20x its own p50 ($bim_p50 ns)"
  # Within the same run: every slow parcel takes at least slow_path_us, so a median
  # under a quarter of it lies in the fast mode. (Comparing with the per-parcel run's
  # p50 instead fails on an untuned host, where the median shifts from run to run.)
  slow_ns=$(jget "$bim" '.notes | capture("slow_path_us=(?<v>[0-9]+)").v | tonumber * 1000')
  assert_lt "$bim_p50" $((slow_ns / 4)) "$lang B: bimodal p50 stays under 1/4 of its slow path ($slow_ns ns)"
done

ok "01-latency-distribution: the distribution, not one number, is the result"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
