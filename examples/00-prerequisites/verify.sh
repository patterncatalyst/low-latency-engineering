#!/usr/bin/env bash
# verify.sh - Ch0 lab smoke test.
#
# Proves the toolchain works end to end: each language's line consumer receives
# 5,000 datagrams from the C++ line simulator at 1 kHz for 5 s, loses none, and
# writes a schema-valid report with the machine profile attached.
#
#   ./verify.sh              # host smoke test
#   VM=1 ./verify.sh         # additionally run the lab-guest smoke test
#
# Environment: RESULTS_DIR, ALLOW_BUSY=1, SKIP_BUILD=1, LOWLAT_BUILD, PORT_BASE
# (first of three UDP ports, default 47200), VM=1. Never changes the host.
set -euo pipefail

# shellcheck source=../_lib/lib.sh
. "$(dirname "$0")/../_lib/lib.sh"

EXAMPLE=00-prerequisites
EXPECT=5000
RATE=1000
DURATION=5
PORT_BASE=${PORT_BASE:-47200}
JAVA_MODULE=$LOWLAT_EXAMPLES/common/line-simulator/consumers/java
JAVA_JAR=$JAVA_MODULE/target/line-consumer-java.jar

step "host prerequisites"
"$LOWLAT_ROOT/scripts/check-prereqs.sh"
ok "check-prereqs.sh exited 0"

require_quiet_host
RESULTS=$(results_dir)
capture_profile "$RESULTS"

build_cpp line-simulator line-consumer
build_java "$JAVA_MODULE"
py_sync

CPP_CONSUMER=$(cpp_bin line-consumer)
[[ -f $JAVA_JAR ]] || die "Java consumer jar not found: $JAVA_JAR"

# run_one LANG PORT CMD...: start the consumer, wait until its UDP socket is bound, drive the
# simulator into it, wait for the consumer to exit and require exit 0.
run_one() {
  local lang=$1 port=$2; shift 2
  local out=$RESULTS/$lang.out
  step "$lang consumer on 127.0.0.1:$port"
  : >"$out"
  "$@" --bind "127.0.0.1:$port" --expect "$EXPECT" --example "$EXAMPLE" \
       --variant baseline --report "$RESULTS/$lang.json" >"$out" 2>&1 &
  local consumer_pid=$!
  bg_track "$consumer_pid"
  wait_udp_bound "$port" "$consumer_pid" "$out"
  simulate --rate "$RATE" --duration "$DURATION" --dest "127.0.0.1:$port" --quiet \
    >"$RESULTS/sim-$lang.out" 2>&1 || die "simulator failed for $lang (see $RESULTS/sim-$lang.out)"
  local rc=0
  wait "$consumer_pid" || rc=$?
  bg_forget "$consumer_pid"
  cat "$out"
  ((rc == 0)) || die "$lang consumer exited $rc"
  ok "$lang consumer exited 0"
}

run_one cpp    "$PORT_BASE"       "$CPP_CONSUMER"
run_one python "$((PORT_BASE+1))" uv run --project "$LOWLAT_EXAMPLES" -q line-consumer-py
run_one java   "$((PORT_BASE+2))" java -jar "$JAVA_JAR"

step "checking the three reports"
report_check "$RESULTS/cpp.json" "$RESULTS/python.json" "$RESULTS/java.json"
for lang in cpp python java; do
  f=$RESULTS/$lang.json
  [[ $(jget "$f" .count) -eq $EXPECT ]] || die "$lang: count $(jget "$f" .count), expected $EXPECT"
  [[ $(jget "$f" .dropped) -eq 0 ]]     || die "$lang: dropped $(jget "$f" .dropped), expected 0"
  jget "$f" .profile >/dev/null         || die "$lang: report carries no profile"
  ok "$lang: count=$EXPECT dropped=0 p99=$(jget "$f" .percentiles.p99) ns"
done

# --- VM=1: lab-guest smoke test (needs the guest running: ALLOW_BUSY=1) -----
if [[ ${VM:-0} == 1 ]]; then
  step "lab guest smoke test (VM=1)"
  VMDIR=$RESULTS/vm
  mkdir -p "$VMDIR"
  TARGET=${TARGET_VM:-lowlat-target}
  "$LOWLAT_ROOT/scripts/check-prereqs.sh" --vm | tee "$VMDIR/check-prereqs.txt"
  "$LOWLAT_ROOT/scripts/lab/deploy-to-vm.sh" "$TARGET"
  lab_ssh() { "$LOWLAT_ROOT/scripts/lab/lab-ssh.sh" "$TARGET" "$@"; }
  # cyclictest needs root: the guest has passwordless sudo, the host is untouched.
  lab_ssh sudo cyclictest -m -p95 -D60 -q | tee "$VMDIR/cyclictest.txt"
  grep -q 'Max' "$VMDIR/cyclictest.txt" || die "cyclictest printed no Max latency line"
  # shellcheck disable=SC2016 # $HOME must expand in the guest, not here
  lab_ssh 'exec "$HOME/low-latency-engineering/scripts/profile.sh"' >"$VMDIR/profile.json"
  jq -e '.virt.type != "none"' "$VMDIR/profile.json" >/dev/null || die "guest profile does not report a virtual machine"
  printf 'vm\n' >"$VMDIR/LABEL"
  ok "guest results labelled vm in $VMDIR (never compare with bare-metal numbers)"
fi

ok "00-prerequisites: all three languages received $EXPECT/$EXPECT with 0 dropped"
echo "profile: $(jq -r '"\(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned)"' "$LOWLAT_PROFILE")"
