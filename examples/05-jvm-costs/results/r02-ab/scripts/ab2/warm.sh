#!/usr/bin/env bash
# usage: warm.sh TREE OUTDIR  -- verbatim run_java warmed from the tree's own verify.sh
set -euo pipefail
T=$1; OUT=$2; mkdir -p "$OUT"
cd "$T/examples/05-jvm-costs"
. ../_lib/lib.sh
DIR=$T/examples/05-jvm-costs; PORT=47250; RATE=1000; DURATION=20; COUNT=$((RATE*DURATION)); WINDOW=2000; WARM_UP=20000
JAR=$DIR/java/target/benchmarks.jar
MAIN=io.patterncatalyst.lowlat.jvmcosts.Costs
JIT_TOOL=io.patterncatalyst.lowlat.jvmcosts.JitWindows
JVM_ARGS=(-XX:+UseG1GC -Xms256m -Xmx256m)
capture_profile "$OUT" >/dev/null
window_time() { sed -nE "s/^window-times:.* $1=([^ ]+).*/\1/p" "$2"; }
variant=warmed
report=$OUT/java-$variant.json; log=$OUT/java-$variant.log
java_flags "$variant"
OBS=()
for flag in "${JAVA_RUN_FLAGS[@]}"; do
  [[ $flag == -XX:StartFlightRecording:* ]] && flag+=',jdk.Compilation#threshold=0ms,jdk.Deoptimization#enabled=true'
  OBS+=("$flag")
done
java "${OBS[@]}" "${JVM_ARGS[@]}" -cp "$JAR" "$MAIN" --variant $variant --bind "127.0.0.1:$PORT" --expect "$COUNT" --window "$WINDOW" --report "$report" --warm-up "$WARM_UP" >"$log" 2>&1 &
pid=$!
bg_track "$pid"
wait_udp_bound "$PORT" "$pid" "$log" 900
simulate --rate "$RATE" --duration "$DURATION" --dest "127.0.0.1:$PORT" --quiet >>"$log"
wait "$pid" || { cat "$log" >&2; exit 1; }
bg_forget "$pid"
java -cp "$JAR" "$JIT_TOOL" --jfr "$JFR_FILE" --window "$WINDOW" \
  --first "$(window_time first "$log")" --boundary "$(window_time boundary "$log")" --end "$(window_time end "$log")" \
  "$report" "$OUT/java-$variant-first-$WINDOW.json" "$OUT/java-$variant-steady.json" >>"$log"
