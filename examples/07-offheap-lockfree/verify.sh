#!/usr/bin/env bash
# Ch7 verify (host part): move the hand-off, the audit journal and the manifest off the
# blocking, per-event and on-heap paths, and measure what each one costs.
#   1. decide-thread voluntary context switches: agrona-spsc and disruptor <= 1 % of the parcels,
#      blocking-queue >= 25 %.
#   2. hand-off p99 (steady window): agrona-spsc and disruptor <= 1/5 of blocking-queue.
#   3. JMH -prof gc: Disruptor and Agrona publish <= 1 B/op, linked-queue >= 16 B/op.
#   4. the journal tailer reads back exactly N events in sequence order; the chronicle-journal
#      decide thread makes no write system calls (<= 1 % of N) where write-per-parcel makes one per
#      event (exact); the decide-thread minor faults show the first touch of the mapped file's pages
#      (chronicle >= journal bytes / (4096 x 16) and >= 5x write-per-parcel). Append p50/p99/p99.9
#      are observed, not asserted.
#   5. old generation after a full GC: chronicle-map-manifest <= 1/4 of on-heap-manifest.
#   6. every run: count = N, dropped = 0, every divert command arrived, every report passes check.
# Java runs 10 variants and the C++ lane 2, each at 10 kHz x 20 s (N = 200,000). Ports: data
# 47270, commands 47271, C++ 47274. See README.md.
#   VM=1          the affinity part (lab VM), vm/run.sh: unpinned vs pinned-isolated, see README.md
#   RECHECK=DIR   evaluate the criteria on the reports already in DIR (no build, no run)
set -euo pipefail
# shellcheck source=../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../_lib/lib.sh"

EXAMPLE=07-offheap-lockfree
DIR=$(example_dir)
PORT=47270
CPP_PORT=47274
RATE=10000
SECONDS_RUN=20
COUNT=$((RATE * SECONDS_RUN))
WINDOW=20000
HOLD_MS=1500 # how long the decide thread stays alive after the last parcel, for the ctx sample

JAVA_VARIANTS=(blocking-queue linked-queue agrona-spsc agrona-spsc-backoff disruptor disruptor-blocking-wait
  chronicle-journal write-per-parcel chronicle-map-manifest on-heap-manifest)
CPP_VARIANTS=(atomic-spsc atomic-wait)
# The host part has the scheduler's choice only; the VM part (vm/run.sh, VM=1) runs the
# unpinned/pinned-isolated pair alternately in the lab guest.
PLACEMENTS=(unpinned)

if [[ ${VM:-0} == 1 ]]; then
  exec "$DIR/vm/run.sh"
fi

# RECHECK=DIR: evaluate the criteria on the reports already in DIR (no build, no run).
if [[ -n ${RECHECK:-} ]]; then
  OUT=$(cd "$RECHECK" && pwd)
  export LOWLAT_PROFILE=$OUT/profile.json
else
  require_quiet_host
  OUT=$(results_dir)
  capture_profile "$OUT"
  # Journal files live under the results directory, which git ignores (results/**/queue/).
  # Each run removes its own; the trap catches an aborted one.
  QUEUE_DIR=$OUT/queue
  trap '_bg_cleanup; rm -rf "$QUEUE_DIR"' EXIT

  build_cpp offheap-handoff line-simulator offheap-lockfree-test
  BUILD_JAVA_TESTS=1 build_java "$DIR/java" # benchmarks.jar; the unit tests run on the way
  step "unit tests: the SPSC ring"
  "$(cpp_bin offheap-lockfree-test)" --gtest_brief=1
  py_sync
fi

JAR=$DIR/java/target/benchmarks.jar
# Chronicle's --add-opens/--add-exports list, read from the pom property it is defined in, so
# the two cannot drift. (A shaded jar's manifest cannot carry them.)
mapfile -t CHRONICLE_ARGS < <(sed -n '/<chronicle.jvmArgs>/,/<\/chronicle.jvmArgs>/p' "$DIR/java/pom.xml" |
  grep -oE -- '--[a-z-]+=[^[:space:]<]+')
((${#CHRONICLE_ARGS[@]} > 0)) || die "no chronicle.jvmArgs found in $DIR/java/pom.xml"
# A fixed, pre-touched heap on the default collector (G1): no resize, no first-touch page faults.
# Chronicle Core posts usage analytics unless told not to; a measurement run makes no network
# call, so the property switches it off.
JVM_FLAGS=(-Xms1g -Xmx1g -XX:+AlwaysPreTouch -XX:+UseG1GC -Dchronicle.analytics.disable=true)

# run_variant LANG VARIANT: one 10 kHz x 20 s run. Reports land in $OUT as LANG-VARIANT*.json.
# The decide thread prints "decide-thread pid=P tid=T"; this script reads that thread's context
# switches from /proc before the simulator starts and again at the "window-end" line, and adds
# the difference to the end-to-end report as runtime.ctx_switches.
run_variant() {
  local lang=$1 variant=$2 report log pid port tid_line dpid tid vol0 inv0 vol1 inv1 wr0 pf0 wr1 pf1 f
  local -a cmd flags=()
  report=$OUT/$lang-$variant.json
  log=$OUT/$lang-$variant.log
  step "$lang / $variant"
  case $lang in
    java)
      port=$PORT
      java_flags "$variant"
      # The JFR sampler is a thread of its own and the hot path is what is measured: keep the
      # GC and safepoint log, drop the recording.
      for f in "${JAVA_RUN_FLAGS[@]}"; do
        [[ $f == -XX:StartFlightRecording* ]] || flags+=("$f")
      done
      cmd=(java "${flags[@]}" "${JVM_FLAGS[@]}" "${CHRONICLE_ARGS[@]}" -cp "$JAR"
        io.patterncatalyst.lowlat.offheap.Handoff --variant "$variant" --bind "127.0.0.1:$port"
        --journal-dir "$QUEUE_DIR" --placement "${PLACEMENTS[0]}")
      ;;
    cpp)
      port=$CPP_PORT
      cmd=("$(cpp_bin offheap-handoff)" --variant "$variant" --bind "127.0.0.1:$port")
      ;;
  esac
  cmd+=(--expect "$COUNT" --window "$WINDOW" --idle-timeout-ms 5000 --sample-hold-ms "$HOLD_MS"
    --example "$EXAMPLE" --report "$report")
  printf 'command:' >"$log"
  printf ' %q' "${cmd[@]}" >>"$log"
  printf '\n' >>"$log"
  "${cmd[@]}" >>"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait_udp_bound "$port" "$pid" "$log" 1800 # a manifest load takes seconds
  tid_line=$(wait_log_line '^decide-thread pid=[0-9]+ tid=[0-9]+$' "$log" "$pid")
  [[ $tid_line =~ pid=([0-9]+)\ tid=([0-9]+) ]] || die "unparseable decide-thread line: $tid_line"
  dpid=${BASH_REMATCH[1]}
  tid=${BASH_REMATCH[2]}
  [[ $dpid == "$pid" ]] || die "decide thread reports pid $dpid, launched $pid"
  read -r vol0 inv0 < <(task_ctx_switches "$pid" "$tid")
  read -r wr0 pf0 < <(task_io_faults "$pid" "$tid")
  simulate --rate "$RATE" --duration "$SECONDS_RUN" --dest "127.0.0.1:$port" --quiet >>"$log"
  wait_log_line '^window-end handled=' "$log" "$pid" >/dev/null
  read -r vol1 inv1 < <(task_ctx_switches "$pid" "$tid")
  read -r wr1 pf1 < <(task_io_faults "$pid" "$tid")
  wait "$pid" || { cat "$log" >&2; die "$lang/$variant failed"; }
  bg_forget "$pid"
  jq --argjson v $((vol1 - vol0)) --argjson i $((inv1 - inv0)) \
    --arg n "; decide_write_syscalls=$((wr1 - wr0)); decide_minor_faults=$((pf1 - pf0))" \
    '.runtime.ctx_switches = {voluntary: $v, involuntary: $i} | .notes += $n' "$report" >"$report.tmp" && mv "$report.tmp" "$report"
  [[ ! -d ${QUEUE_DIR:-/nonexistent} ]] || rmdir --ignore-fail-on-non-empty "$QUEUE_DIR"
}

# note_of FILE KEY: the integer or word after "KEY=" in a report's notes.
note_of() { jget "$1" ".notes | capture(\"$2=(?<v>[^;]+)\").v"; }

# check_run LANG VARIANT: the per-run criterion 6 (and the journal and manifest counts of 4 and 5).
check_run() {
  local lang=$1 variant=$2 r h
  r=$OUT/$lang-$variant.json
  h=$OUT/$lang-$variant-handoff.json
  [[ $(jget "$r" .count) -eq $COUNT ]] || die "$lang/$variant: count != $COUNT"
  [[ $(jget "$r" .dropped) -eq 0 ]] || die "$lang/$variant: parcels were dropped"
  [[ $(jget "$h" .count) -eq $COUNT ]] || die "$lang/$variant: hand-off count != $COUNT"
  [[ $(note_of "$r" overflow) -eq 0 ]] || die "$lang/$variant: the hand-off overflowed"
  [[ $(jget "$OUT/$lang-$variant-handoff-steady.json" .count) -eq $((COUNT - WINDOW)) ]] ||
    die "$lang/$variant: steady window != $((COUNT - WINDOW))"
  if [[ $lang == java ]]; then
    [[ $(note_of "$r" divert_received) -eq $COUNT ]] || die "$variant: not every divert command arrived on the command socket"
    if jq -e '.notes | test("journal_readback_count")' "$r" >/dev/null; then
      [[ $(note_of "$r" journal_readback_count) -eq $COUNT ]] || die "$variant: the tailer did not read back $COUNT events"
      [[ $(note_of "$r" journal_in_order) == true ]] || die "$variant: the journal is not in sequence order"
      [[ $(jget "$OUT/java-$variant-journal-append.json" .count) -eq $COUNT ]] || die "$variant: journal append count != $COUNT"
    fi
    if jq -e '.notes | test("manifest_hits")' "$r" >/dev/null; then
      [[ $(note_of "$r" manifest_hits) -eq $COUNT ]] || die "$variant: manifest lookups missed"
    fi
  fi
}

if [[ -z ${RECHECK:-} ]]; then
  for variant in "${JAVA_VARIANTS[@]}"; do
    run_variant java "$variant"
  done
  for variant in "${CPP_VARIANTS[@]}"; do
    run_variant cpp "$variant"
  done

  step "JMH -prof gc: bytes allocated per publish"
  jmh_lock_wait 30 "$OUT/jmh.console.txt" \
    java --enable-native-access=ALL-UNNAMED -jar "$JAR" PublishBenchmark -prof gc -rf json -rff "$OUT/jmh.json" ||
    die "JMH failed"
fi

step "checking reports"
mapfile -t reports < <(find "$OUT" -maxdepth 1 -name '*.json' ! -name profile.json ! -name 'jmh*.json' | sort)
report_check "${reports[@]}"
for variant in "${JAVA_VARIANTS[@]}"; do
  check_run java "$variant"
done
for variant in "${CPP_VARIANTS[@]}"; do
  check_run cpp "$variant"
done
ok "every run: count $COUNT, dropped 0, no overflow, every divert command received"

FAILURES=0
bad() {
  say_bad "$*"
  FAILURES=$((FAILURES + 1))
}
# expect_ge A B MESSAGE / expect_lt A B MESSAGE: like assert_ge and assert_lt, but a miss is
# counted and the run goes on, so one run shows every criterion's measured value against its bound.
expect_ge() { if (($1 >= $2)); then ok "$3 ($1 >= $2)"; else bad "$3 (got $1, need >= $2)"; fi; }
expect_lt() { if (($1 < $2)); then ok "$3 ($1 < $2)"; else bad "$3 (got $1, need < $2)"; fi; }

# p99_of FILE: the p99 in ns.
p99_of() { jget "$1" .percentiles.p99; }
vol_of() { jget "$OUT/java-$1.json" .runtime.ctx_switches.voluntary; }
hand_p99() { p99_of "$OUT/java-$1-handoff-steady.json"; }

step "criteria 1: decide-thread context switches"
block_vol=$(vol_of blocking-queue)
echo "  voluntary / involuntary per run (N = $COUNT):"
for v in "${JAVA_VARIANTS[@]}"; do
  echo "    $v: $(vol_of "$v") / $(jget "$OUT/java-$v.json" .runtime.ctx_switches.involuntary)"
done
for v in agrona-spsc disruptor; do
  expect_lt "$(vol_of "$v")" $((COUNT / 100 + 1)) "1: $v voluntary ctx switches <= 1 % of parcels (<= $((COUNT / 100)))"
done
expect_ge "$block_vol" $((COUNT / 4)) "1: blocking-queue voluntary ctx switches >= 25 % of parcels (>= $((COUNT / 4)))"

step "criteria 2: hand-off p99, steady window (parcels >= $WINDOW)"
block_p99=$(hand_p99 blocking-queue)
echo "  hand-off p50 / p99 / p99.9 in ns:"
for v in "${JAVA_VARIANTS[@]}"; do
  echo "    $v: $(jget "$OUT/java-$v-handoff-steady.json" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9)"')"
done
for v in agrona-spsc disruptor; do
  expect_ge "$block_p99" $((5 * $(hand_p99 "$v"))) "2: $v hand-off p99 ($(hand_p99 "$v") ns) <= 1/5 of blocking-queue ($block_p99 ns)"
done

step "criteria 3: JMH gc.alloc.rate.norm (bytes per publish)"
bop_milli() { jq -er --arg s "$1" '.[] | select(.params.structure == $s) | .secondaryMetrics["gc.alloc.rate.norm"].score * 1000 | floor' "$OUT/jmh.json"; }
for s in blocking-queue linked-queue agrona-spsc disruptor; do
  echo "  $s: $(jq -er --arg s "$s" '.[] | select(.params.structure == $s) | .secondaryMetrics["gc.alloc.rate.norm"].score * 1000 | round / 1000' "$OUT/jmh.json") B/op"
done
for s in disruptor agrona-spsc; do
  expect_lt "$(bop_milli "$s")" 1001 "3: $s publish <= 1 B/op (milli-B/op shown)"
done
expect_ge "$(bop_milli linked-queue)" 16000 "3: linked-queue publish >= 16 B/op (milli-B/op shown)"

step "criteria 4: the audit journal"
for v in chronicle-journal write-per-parcel; do
  echo "  $v: tailer/readback $(note_of "$OUT/java-$v.json" journal_readback_count) events, in order $(note_of "$OUT/java-$v.json" journal_in_order);" \
    "append p50 / p99 / p99.9, steady window = $(jget "$OUT/java-$v-journal-append-steady.json" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9)"') ns;" \
    "whole run p99 = $(p99_of "$OUT/java-$v-journal-append.json") ns"
done
# The append latency ratio is not asserted: it is the product of two costs that depend on the file
# system under the journal (journal_fs in the notes). A write() to tmpfs is far cheaper than one to
# btrfs, and the mapped append pays a minor fault on the first touch of each new page, which the
# kernel's fault-around spreads over several pages on btrfs and ext4 but not on tmpfs. The mechanism
# does not depend on the file system: no system call per event, and a page fault per new page.
for v in chronicle-journal write-per-parcel; do
  echo "  $v: decide-thread write syscalls $(note_of "$OUT/java-$v.json" decide_write_syscalls)," \
    "minor faults $(note_of "$OUT/java-$v.json" decide_minor_faults)," \
    "journal $(note_of "$OUT/java-$v.json" journal_bytes) B on $(note_of "$OUT/java-$v.json" journal_fs)"
done
echo "  chronicle-journal: block size $(note_of "$OUT/java-chronicle-journal.json" journal_block_size) B," \
  "roll cycle $(note_of "$OUT/java-chronicle-journal.json" journal_roll_cycle)"
expect_lt "$(note_of "$OUT/java-chronicle-journal.json" decide_write_syscalls)" $((COUNT / 100 + 1)) \
  "4: chronicle-journal appends without a write system call (<= 1 % of events)"
expect_ge "$(note_of "$OUT/java-write-per-parcel.json" decide_write_syscalls)" "$COUNT" \
  "4: write-per-parcel makes at least one write system call per event (exact)"

# The first touch of a mapped page is a minor fault. The kernel maps at most fault_around_bytes
# (64 KiB, 16 pages) per file-backed read fault, so the journal's pages cannot cost fewer than
# bytes / (4096 x 16) faults; on tmpfs there is no fault-around and it is one per page. The bound is
# that floor, and the write-per-parcel journal (a write() copies into the page cache and touches no
# mapped page) sits near zero.
chron_faults=$(note_of "$OUT/java-chronicle-journal.json" decide_minor_faults)
file_faults=$(note_of "$OUT/java-write-per-parcel.json" decide_minor_faults)
journal_pages=$(($(note_of "$OUT/java-chronicle-journal.json" journal_bytes) / 4096))
expect_ge "$chron_faults" $((journal_pages / 16)) \
  "4: chronicle-journal decide-thread minor faults >= first touch of its $journal_pages pages / 16 (fault-around)"
expect_ge "$chron_faults" $((5 * (file_faults + 1))) \
  "4: chronicle-journal decide-thread minor faults >= 5x write-per-parcel's ($file_faults)"
echo "  chronicle-journal faults per journal page: $((chron_faults * 100 / journal_pages)) %"

step "criteria 5: old generation after a full GC, 1,000,000-entry manifest"
cmap_old=$(jget "$OUT/java-chronicle-map-manifest.json" .runtime.gc.old_gen_used_bytes)
heap_old=$(jget "$OUT/java-on-heap-manifest.json" .runtime.gc.old_gen_used_bytes)
echo "  baseline (no manifest, before the run): $(note_of "$OUT/java-on-heap-manifest.json" old_gen_baseline_bytes) B"
echo "  manifest lookup p50 / p99 in ns: chronicle-map $(jget "$OUT/java-chronicle-map-manifest-manifest-lookup.json" '"\(.percentiles.p50) / \(.percentiles.p99)"')," \
  "on-heap $(jget "$OUT/java-on-heap-manifest-manifest-lookup.json" '"\(.percentiles.p50) / \(.percentiles.p99)"')"
expect_ge "$heap_old" $((4 * cmap_old)) "5: chronicle-map-manifest old gen ($cmap_old B) <= 1/4 of on-heap-manifest ($heap_old B)"

step "observed: the C++ lane (atomic-spsc spins, atomic-wait parks)"
for v in "${CPP_VARIANTS[@]}"; do
  echo "  $v: hand-off p50 / p99 / p99.9 = $(jget "$OUT/cpp-$v-handoff-steady.json" '"\(.percentiles.p50) / \(.percentiles.p99) / \(.percentiles.p99_9)"') ns;" \
    "decide-thread ctx switches voluntary $(jget "$OUT/cpp-$v.json" .runtime.ctx_switches.voluntary) involuntary $(jget "$OUT/cpp-$v.json" .runtime.ctx_switches.involuntary)"
done

((FAILURES == 0)) || die "$FAILURES criteria not met; results in $OUT"
ok "07-offheap-lockfree (host): the hand-off, journal and manifest criteria hold; results in $OUT"
jq -r '"profile: \(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release) load1=\(.load.load1)"' "$LOWLAT_PROFILE"
