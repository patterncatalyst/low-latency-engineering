#!/usr/bin/env bash
# Ch8 verify: zero-copy flat data removes the decode allocation Ch5 measured.
#
# Criteria (each prints a check mark or a cross; any cross fails the run, after all have been evaluated):
#   1  golden bytes: the C++ header, the Java FFM reader and the Python reader decode
#      contracts/flat/parcel-v1/golden-seed{1,42,2026}.bin to the same fields, equal to the committed JSON
#   2  JMH decode: flat-ffm <= 1 B/op, protobuf-decode >= 100 B/op, protobuf p50 >= 3x flat p50 (one run)
#   3  line 10 kHz x 10 s: flat-ffm end-to-end allocated bytes per parcel <= 5 % of protobuf-decode
#   4  JMH sweep of 1,000,000 in-flight parcels: flat-table p50 <= 1/2 of object-table p50 (same run)
#   5  FFM downcall clock_gettime(CLOCK_MONOTONIC) agrees with System.nanoTime() within 1 ms
#      (standard and critical; their per-call cost is observed, not asserted)
#   6  every report: count, dropped = 0 on the line, lowlat-report check, Java build.flags present
#   4  also: the two table benchmarks report gc.count 0, so a collection cannot undo the object-table scatter
# Observed, not asserted: compact object headers (JOL), the C++ decode variants and table layouts,
# the Python lane (unpack_from vs ParseFromString, allocations per parcel).
#
#   ./verify.sh                 build, run, assert
#   RECHECK=results/<run-id>    re-evaluate the committed reports without building or running anything
#   ALLOW_BUSY=1 ./verify.sh    measure while a lab VM or other load is running (noisy)
#   SKIP_BUILD=1 ./verify.sh    reuse existing builds
#   RESULTS_DIR=DIR             where reports go (default results/latest)
#   LOWLAT_BUILD=DIR            private C++ build directory
#
# UDP ports 47281 (protobuf-decode) and 47282 (flat-ffm) on 127.0.0.1. Never changes the host.
# The jq programs handed to `holds` are single-quoted: $a, $f are jq variables, not shell ones.
# shellcheck disable=SC2016
set -euo pipefail
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

EXAMPLE=08-zero-copy-flat
HERE=$(example_dir)
CONTRACT=$LOWLAT_ROOT/contracts/flat/parcel-v1
JAR=$HERE/java/target/benchmarks.jar
RATE=10000
SECONDS_RUN=10
COUNT=$((RATE * SECONDS_RUN))
PORT_PROTOBUF=47281
PORT_FLAT=47282
# FFM downcalls are restricted methods: grant them on the command line, as production would.
NATIVE=(--enable-native-access=ALL-UNNAMED)

if [[ -n ${RECHECK:-} ]]; then
  OUT=$(cd "$RECHECK" && pwd)
  export LOWLAT_PROFILE=$OUT/profile.json
  RUN=0
else
  RUN=1
  require_quiet_host
  OUT=$(results_dir)
  # Remove only the three directories this script writes, and only under a real results path.
  [[ $OUT == /*/*/* ]] || die "refusing to clear subdirectories of $OUT"
  rm -rf "${OUT:?}"/{jmh,cpp,python}
  mkdir -p "$OUT/jmh" "$OUT/cpp" "$OUT/python"
  capture_profile "$OUT"
fi

# holds EXPR MESSAGE: EXPR is a jq boolean over --argjson inputs given as the remaining arguments.
holds() {
  local expr=$1 message=$2
  shift 2
  if jq -en "$@" "$expr" >/dev/null; then ok "$message"; else bad "$message"; fi
}

# ---- build ---------------------------------------------------------------------------------
if ((RUN)); then
  build_cpp line-simulator flat-dump flat-bench zero-copy-flat-test
  BUILD_JAVA_TESTS=1 build_java "$HERE/java" # the Java tests (layout, golden, allocation, downcall) run on the way
  py_sync
  [[ -f $JAR ]] || die "missing $JAR (build_java first)"

  step "unit tests: C++ (GoogleTest) and Python (pytest); Java ran during the package step"
  "$(cpp_bin zero-copy-flat-test)" --gtest_brief=1
  uvrun --package lowlat-flat pytest -q "$HERE/flat-py/tests"
  ok "C++, Java and Python unit tests pass"
fi

# ---- 1. golden bytes: C++ writer, Java FFM reader and Python reader agree -------------------
step "1. golden bytes: three readers, three seeds"
dump_cpp() { "$(cpp_bin flat-dump)" "$1"; }
dump_java() { java "${NATIVE[@]}" -cp "$JAR" io.patterncatalyst.lowlat.flat.Main dump "$1"; }
dump_python() { uvrun --package lowlat-flat flat-py dump "$1"; }
if ((RUN)); then
  : >"$OUT/golden-agreement.txt"
  for seed in 1 42 2026; do
    bin=$CONTRACT/golden-seed$seed.bin
    want=$(jq -S .records "$CONTRACT/golden-seed$seed.json")
    records=$(jq 'length' <<<"$want")
    for reader in cpp java python; do
      got=$("dump_$reader" "$bin" | jq -S .records)
      if [[ $got == "$want" ]]; then
        printf 'seed %s: %s decodes %s records identical to golden-seed%s.json\n' "$seed" "$reader" "$records" "$seed" \
          >>"$OUT/golden-agreement.txt"
      else
        printf 'seed %s: %s DIFFERS from golden-seed%s.json\n' "$seed" "$reader" "$seed" >>"$OUT/golden-agreement.txt"
      fi
    done
  done
fi
cat "$OUT/golden-agreement.txt"
if [[ $(grep -c 'identical to' "$OUT/golden-agreement.txt") -eq 9 ]] && ! grep -q DIFFERS "$OUT/golden-agreement.txt"; then
  ok "1 C++, Java and Python agree on every field of 3 seeds x 8 records"
else
  bad "1 the readers disagree (see above)"
fi

# ---- 2 and 4. JMH: decode and table sweep (one run), plus the clock benchmarks ---------------
step "JMH SampleTime with the gc profiler: DecodeBenchmark, TableBenchmark, ClockBenchmark (about 3 minutes)"
if ((RUN)); then
  jmh_lock_wait 30 "$OUT/jmh.console.txt" java -jar "$JAR" -rf json -rff "$OUT/jmh.json" -prof gc || die "JMH failed"
  uvrun --package lowlat-flat flat-py jmh-to-report "$OUT/jmh.json" "$OUT/jmh" >/dev/null
fi
jmh_p50() { jget "$OUT/jmh/java-$1.json" .percentiles.p50; }
jmh_alloc() { jget "$OUT/jmh/java-$1.json" '.runtime.alloc_bytes_per_parcel'; }

step "2. decode: flat-ffm vs protobuf-decode (same JMH run)"
flat_alloc=$(jmh_alloc flat-ffm)
proto_alloc=$(jmh_alloc protobuf-decode)
flat_p50=$(jmh_p50 flat-ffm)
proto_p50=$(jmh_p50 protobuf-decode)
printf '  flat-ffm        %s B/op, p50 %s ns\n  protobuf-decode %s B/op, p50 %s ns\n' \
  "$flat_alloc" "$flat_p50" "$proto_alloc" "$proto_p50"
holds '$a <= 1' "2 flat-ffm allocates <= 1 B/op ($flat_alloc)" --argjson a "$flat_alloc"
holds '$a >= 100' "2 protobuf-decode allocates >= 100 B/op ($proto_alloc)" --argjson a "$proto_alloc"
holds '$p >= 3 * $f' "2 protobuf p50 ($proto_p50 ns) >= 3x flat p50 ($flat_p50 ns)" \
  --argjson p "$proto_p50" --argjson f "$flat_p50"

step "4. in-flight table sweep of 1,000,000 parcels: flat-table vs object-table (same JMH run)"
flat_table=$(jmh_p50 flat-table)
object_table=$(jmh_p50 object-table)
printf '  flat-table   p50 %s ns\n  object-table p50 %s ns\n' "$flat_table" "$object_table"
holds '2 * $f <= $o' "4 flat-table p50 ($flat_table ns) <= 1/2 of object-table p50 ($object_table ns)" \
  --argjson f "$flat_table" --argjson o "$object_table"
# A collection during a table run would move the object table's scatter; both must report gc.count 0.
for method in flatTable objectTable; do
  collections=$(jq -er --arg m ".$method" '.[] | select(.benchmark | endswith($m)) | .secondaryMetrics["gc.count"].score' "$OUT/jmh.json")
  holds '$c == 0' "4 $method ran without a garbage collection (gc.count $collections)" --argjson c "$collections"
done

step "5. FFM clock_gettime downcall vs System.nanoTime()"
printf '  per call, p50: nano-time %s ns, downcall-standard %s ns, downcall-critical %s ns (observed)\n' \
  "$(jmh_p50 nano-time)" "$(jmh_p50 downcall-standard)" "$(jmh_p50 downcall-critical)"
if ((RUN)); then
  java "${NATIVE[@]}" -cp "$JAR" io.patterncatalyst.lowlat.flat.Main clock-check >"$OUT/clock-check.json"
fi
for linkage in standard critical; do
  skew=$(jget "$OUT/clock-check.json" ".$linkage.max_skew_ns")
  holds '$s < 1000000' "5 $linkage downcall within 1 ms of System.nanoTime() (largest skew outside the nanoTime bracket: $skew ns)" \
    --argjson s "$skew"
done

# ---- 3. the line: protobuf-decode vs flat-ffm at 10 kHz x 10 s --------------------------------
# run_line VARIANT PORT WIRE: one consumer, one simulator run; report in $OUT/java-VARIANT.json.
run_line() {
  local variant=$1 port=$2 wire=$3 report="$OUT/java-$1.json" log="$OUT/java-$1.log" pid
  step "line: $variant ($wire wire), ${RATE} Hz x ${SECONDS_RUN} s, UDP $port"
  java "${NATIVE[@]}" -cp "$JAR" io.patterncatalyst.lowlat.flat.Main consume --variant "$variant" \
    --bind "127.0.0.1:$port" --expect "$COUNT" --example "$EXAMPLE" --report "$report" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_udp_bound "$port" "$pid" "$log"
  simulate --rate "$RATE" --duration "$SECONDS_RUN" --dest "127.0.0.1:$port" --wire "$wire" --quiet >>"$log"
  wait "$pid" || { cat "$log" >&2; die "$variant consumer failed"; }
  bg_forget "$pid"
}
if ((RUN)); then
  run_line protobuf-decode "$PORT_PROTOBUF" protobuf
  run_line flat-ffm "$PORT_FLAT" flat
fi

step "3. line end-to-end allocation per parcel (receive thread: channel, decode, handler)"
line_proto=$(jget "$OUT/java-protobuf-decode.json" .runtime.alloc_bytes_per_parcel)
line_flat=$(jget "$OUT/java-flat-ffm.json" .runtime.alloc_bytes_per_parcel)
printf '  protobuf-decode %s B/parcel, flat-ffm %s B/parcel\n' "$line_proto" "$line_flat"
holds '100 * $f <= 5 * $p' "3 flat-ffm allocates <= 5 % of protobuf-decode per parcel ($line_flat vs $line_proto B)" \
  --argjson f "$line_flat" --argjson p "$line_proto"
for variant in protobuf-decode flat-ffm; do
  printf '  %s p50 %s ns, p99 %s ns, p99.9 %s ns, max %s ns\n' "$variant" \
    "$(jget "$OUT/java-$variant.json" .percentiles.p50)" "$(jget "$OUT/java-$variant.json" .percentiles.p99)" \
    "$(jget "$OUT/java-$variant.json" .percentiles.p99_9)" "$(jget "$OUT/java-$variant.json" .percentiles.max)"
done

# ---- observed: compact object headers ---------------------------------------------------------
step "compact-headers (observed): JOL footprint with and without -XX:+UseCompactObjectHeaders"
# JOL reads field offsets with sun.misc.Unsafe (a JDK 25 warning, kept in the .err file; a record class
# needs -Djol.magicFieldOffset) and wants -Djdk.attach.allowAttachSelf for object-graph sizes.
JOL=(-Djol.magicFieldOffset=true -Djdk.attach.allowAttachSelf=true)
if ((RUN)); then
  java "${NATIVE[@]}" "${JOL[@]}" -cp "$JAR" io.patterncatalyst.lowlat.flat.Main footprint \
    2>"$OUT/footprint-standard.err" >"$OUT/footprint-standard.json"
  java "${NATIVE[@]}" "${JOL[@]}" -XX:+UseCompactObjectHeaders -cp "$JAR" io.patterncatalyst.lowlat.flat.Main footprint \
    2>"$OUT/footprint-compact-headers.err" >"$OUT/footprint-compact-headers.json"
fi
for run in standard compact-headers; do
  jq -r --arg run "$run" '"  \($run): ParcelState \(.parcel_state_instance_bytes) B, protobuf ParcelEvent \(.protobuf_parcel_event_instance_bytes) B, object table of \(.parcels) = \(.object_table_bytes) B, flat table = \(.flat_table_bytes) B"' \
    "$OUT/footprint-$run.json"
done
[[ $(jq -r .compact_object_headers "$OUT/footprint-standard.json") == false ]] || bad "the standard footprint run had compact headers on"
[[ $(jq -r .compact_object_headers "$OUT/footprint-compact-headers.json") == true ]] || bad "the compact-headers run did not enable the flag"

# ---- observed: C++ lane -----------------------------------------------------------------------
step "C++ lane (observed): decode variants over std::span<const std::byte>, flat vs pointer table"
if ((RUN)); then
  "$(cpp_bin flat-bench)" --benchmark_out="$OUT/cpp/gbench.json" --benchmark_out_format=json \
    >"$OUT/cpp/gbench.console.txt" 2>&1
  redact_host "$OUT/cpp/gbench.json"
  uvrun --package lowlat-flat flat-py gbench-to-report "$OUT/cpp/gbench.json" "$OUT/cpp" >/dev/null
fi
for variant in decode-memcpy decode-bit-cast decode-start-lifetime-as; do
  printf '  %-26s p50 %s ns per 1024 records\n' "$variant" "$(jget "$OUT/cpp/cpp-$variant.json" .percentiles.p50)"
done
for variant in flat-table pointer-table; do
  printf '  %-26s p50 %s ns per sweep of 1,000,000\n' "$variant" "$(jget "$OUT/cpp/cpp-$variant.json" .percentiles.p50)"
done

# ---- observed: Python lane --------------------------------------------------------------------
step "Python lane (observed): struct.unpack_from over a memoryview vs ParseFromString"
if ((RUN)); then
  uvrun --package lowlat-flat flat-py decode --out "$OUT/python" | tee "$OUT/python/console.txt"
else
  cat "$OUT/python/console.txt"
fi

# ---- 6. reports ------------------------------------------------------------------------------
step "6. reports: schema, histogram decode, percentile recompute; counts, drops, JVM flags"
mapfile -t reports < <(find "$OUT/jmh" "$OUT/cpp" "$OUT/python" "$OUT" -maxdepth 1 -name '*.json' \
  -exec grep -lE '"schema" ?: ?"lowlat-report/1"' {} + | sort -u)
if report_check "${reports[@]}" >/dev/null; then
  ok "6 ${#reports[@]} reports validate (profile embedded: $(jget "${reports[0]}" .profile.host_label))"
else
  bad "6 lowlat-report check failed"
fi
line_ok=1
for variant in protobuf-decode flat-ffm; do
  [[ $(jget "$OUT/java-$variant.json" .count) -eq $COUNT ]] || { bad "6 $variant: count != $COUNT"; line_ok=0; }
  [[ $(jget "$OUT/java-$variant.json" .dropped) -eq 0 ]] || { bad "6 $variant: parcels were dropped"; line_ok=0; }
done
if ((line_ok)); then ok "6 line runs: count = $COUNT and dropped = 0 for both variants"; fi
flags_ok=1
for r in "$OUT"/jmh/java-*.json "$OUT"/java-*.json; do
  jq -e '.build.flags | length > 0' "$r" >/dev/null || { bad "6 $(basename "$r"): build.flags missing"; flags_ok=0; }
done
if ((flags_ok)); then ok "6 every Java report carries build.flags"; fi

((FAILURES == 0)) || die "$FAILURES criteria failed: the effect was not (fully) observed"
ok "08-zero-copy-flat: flat records removed the decode allocation; results in $OUT"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
