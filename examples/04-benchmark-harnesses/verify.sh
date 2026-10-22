#!/usr/bin/env bash
# Ch4 verify: three benchmark harnesses on one SSCC-18 check digit.
#
# Observable effects asserted (exit non-zero when one is absent):
#   C++    Google Benchmark: the optimizer-eliminated variant reports >= 10x lower
#          median time than the DoNotOptimize-guarded one
#   Java   JMH SampleTime: the dead-code-eliminated variant is >= 10x faster at the median,
#          and the output carries p0.99 and p0.999
#   Python pyperf: >= 20 values across >= 3 worker processes; median and percentiles shown
# Raw harness JSON and one lowlat report per benchmark land in the results directory.
#
# Never touches the host: pyperf's "system is not tuned" warning is expected and kept
# (tuning is taught in Part 5, inside the lab VM).
#   ALLOW_BUSY=1  measure while other work runs (numbers are noisy)
#   SKIP_BUILD=1  reuse existing builds
set -euo pipefail
# shellcheck source=../_lib/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

HERE=$(example_dir)
PY_PACKAGE=lowlat-bench-harnesses
# An eliminated loop can time as 0.000 ns; floor the divisor so the ratio is finite.
FLOOR_NS=0.01

# pyrun ARGS...: run inside the uv workspace with this example's package installed.
pyrun() { (cd "$LOWLAT_EXAMPLES" && uv run -q --package "$PY_PACKAGE" "$@"); }

require_quiet_host
OUT=$(results_dir)
capture_profile "$OUT"

# ---- build and unit-test parity --------------------------------------------------------
build_cpp check-digit-bench check-digit-test
BUILD_JAVA_TESTS=1 build_java "$HERE/java" # benchmarks.jar; the parity test runs on the way
step "unit tests: check digit parity on known-good SSCCs"
"$(cpp_bin check-digit-test)" --gtest_brief=1
pyrun pytest -q "$HERE/benchmarks-py/tests"
ok "C++ (GoogleTest), Java (JUnit, ran during package) and Python (pytest) agree on the check digit"

# ---- C++: Google Benchmark -------------------------------------------------------------
step "C++ Google Benchmark: 30 repetitions per benchmark"
"$(cpp_bin check-digit-bench)" --benchmark_out="$OUT/gbench.json" \
  --benchmark_out_format=json >"$OUT/gbench.console.txt" 2>&1
redact_host "$OUT/gbench.json"
echo "Google Benchmark aggregates (default output also prints a mean; read median and p99):"
jq -r '.benchmarks[] | select(.aggregate_name == "median" or .aggregate_name == "p99")
       | "  \(.run_name | split("/")[0])  \(.aggregate_name)  \(.real_time * 1000 | round / 1000) \(.time_unit)"' \
  "$OUT/gbench.json"
gb_median() {
  jq -er --arg n "$1" '.benchmarks[] | select(.run_name | startswith($n))
                       | select(.aggregate_name == "median") | .real_time' "$OUT/gbench.json"
}
gb_guarded=$(gb_median BM_CheckDigit_Guarded)
gb_elim=$(gb_median BM_CheckDigit_Eliminated)
gb_ratio=$(jq -n --argjson g "$gb_guarded" --argjson e "$gb_elim" --argjson f "$FLOOR_NS" \
  '$g / ([$e, $f] | max) | floor')
echo "  median guarded = $gb_guarded ns, eliminated = $gb_elim ns (divisor floored at $FLOOR_NS ns)"
assert_ge "$gb_ratio" 10 "C++: eliminated median is >= 10x lower than guarded"

# ---- Java: JMH SampleTime --------------------------------------------------------------
step "Java JMH SampleTime: 3 forks x (3 warm-up + 5 measured) iterations"
java -jar "$HERE/java/target/benchmarks.jar" -rf json -rff "$OUT/jmh.json" >"$OUT/jmh.console.txt" 2>&1
echo "JMH percentile view (percent, ns per check digit):"
jq -r '.[] | "  \(.benchmark | split(".") | last)\n" +
       ([.primaryMetric.scorePercentiles | to_entries[]
         | "    p\(.key)  \(.value * 1000 | round / 1000)"] | join("\n"))' "$OUT/jmh.json"
jmh_p() {
  jq -er --arg b "$1" --arg p "$2" '.[] | select(.benchmark | endswith($b))
                                    | .primaryMetric.scorePercentiles[$p]' "$OUT/jmh.json"
}
for p in 99.0 99.9; do
  jq -e --arg p "$p" 'all(.[]; .primaryMetric.scorePercentiles | has($p))' "$OUT/jmh.json" >/dev/null \
    || die "JMH JSON has no p$p"
done
if ! grep -q 'p0.99 ' "$OUT/jmh.console.txt" || ! grep -q 'p0.999 ' "$OUT/jmh.console.txt"; then
  die "JMH console output lacks p0.99 / p0.999"
fi
ok "JMH SampleTime output includes p0.99 and p0.999"
jmh_guarded=$(jmh_p .guarded 50.0)
jmh_elim=$(jmh_p .eliminated 50.0)
jmh_ratio=$(jq -n --argjson g "$jmh_guarded" --argjson e "$jmh_elim" --argjson f "$FLOOR_NS" \
  '$g / ([$e, $f] | max) | floor')
echo "  p50 guarded = $jmh_guarded ns, eliminated = $jmh_elim ns (divisor floored at $FLOOR_NS ns)"
assert_ge "$jmh_ratio" 10 "Java: eliminated p50 is >= 10x lower than guarded"

# ---- Python: pyperf --------------------------------------------------------------------
step "Python pyperf: 6 worker processes x 4 values, 3 warm-ups each"
rm -f "$OUT/pyperf.json"
pyrun python "$HERE/benchmarks-py/src/lowlat_bench/bench_check_digit.py" \
  -o "$OUT/pyperf.json" --processes 6 --values 4 --warmups 3 >"$OUT/pyperf.console.txt" 2>&1
redact_host "$OUT/pyperf.json"
grep -E 'WARNING|not tuned|system tune' "$OUT/pyperf.console.txt" || true
pyrun python -m pyperf stats "$OUT/pyperf.json" | tee "$OUT/pyperf.stats.txt"
pyrun python -m pyperf system show >"$OUT/pyperf.system-show.txt" 2>&1 || true
echo "host tuning state (pyperf system show, read-only; untuned by design):"
grep -E 'governor|Turbo' "$OUT/pyperf.system-show.txt" | sed 's/^/  /' || true
py_values=$(jq '[.benchmarks[0].runs[] | .values // empty | length] | add' "$OUT/pyperf.json")
py_procs=$(jq '[.benchmarks[0].runs[] | select(.values)] | length' "$OUT/pyperf.json")
assert_ge "$py_values" 20 "pyperf recorded values"
assert_ge "$py_procs" 3 "pyperf worker processes with values"
py_warm=$(jq -r '[.benchmarks[0].runs[0].warmups[0][1], ([.benchmarks[0].runs[] | .values // empty | .[]] | sort | .[length / 2 | floor])]
                 | map(. * 1e9 * 10 | round / 10) | "first warm-up \(.[0]) ns, median measured \(.[1]) ns"' "$OUT/pyperf.json")
echo "  warm-up vs warmed (calibration run, cold interpreter): $py_warm"

# ---- convert every harness's samples to lowlat reports and check them ------------------
step "converting harness samples to lowlat reports"
mapfile -t reports < <(
  pyrun bench-to-report gbench "$OUT/gbench.json" "$OUT"
  pyrun bench-to-report jmh "$OUT/jmh.json" "$OUT"
  pyrun bench-to-report pyperf "$OUT/pyperf.json" "$OUT")
((${#reports[@]} == 6)) || die "expected 6 reports, got ${#reports[@]}"
pyrun lowlat-report check "${reports[@]}" >/dev/null
echo "report percentiles in ns (lowlat-report show prints microseconds, too coarse here):"
for r in "${reports[@]}"; do
  jq -r '"  \(.language) \(.variant): n=\(.count) p50=\(.percentiles.p50) p90=\(.percentiles.p90) p99=\(.percentiles.p99) p99.9=\(.percentiles.p99_9) max=\(.percentiles.max)"' "$r"
done
ok "6 lowlat reports validate (profile embedded: $(jq -r '.profile.host_label' "${reports[0]}"))"

ok "04-benchmark-harnesses: C++ ${gb_ratio}x, Java ${jmh_ratio}x, pyperf ${py_values} values / ${py_procs} processes; results in $OUT"
