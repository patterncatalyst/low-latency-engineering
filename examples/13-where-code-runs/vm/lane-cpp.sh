#!/bin/sh
# lane-cpp.sh - one C++ lane run: the same script on the host, in the guest and inside a container.
#
#   lane-cpp.sh --bin DIR --out DIR [--mode full|consumer|sims] [--consumer-cpu N] [--pool] [--pool-workers N]
#               [--rate HZ] [--seconds S] [--base-port P] [--dest HOST] [--decide-ns N] [--hold-ms N]
#
# It runs only POSIX sh, coreutils and the four binaries in --bin (line-simulator, io-receive,
# place-probe, busy-pool), because it runs in a ubi-minimal image that has no jq, no taskset and no
# Python. The caller sets LOWLAT_PROFILE (the reports embed it).
#
#   full      the probe, the optional busy pool, the Ch12 epoll consumer and four simulator instances
#             (one per tunnel camera, --rate Hz each) in this environment: the clock-domain rule puts the
#             simulator and the consumer in the same one
#   consumer  the probe and the consumer only; the simulators run elsewhere (the bridge lane: the
#             simulators run in the guest and the datagram crosses the veth)
#   sims      the simulators only, sending to --dest
#
# Writes into --out: probe-cpp.json, binaries-MODE.txt (the four checksums), consumer.json, lateness.json (camera 0's simulator),
# pool.json (with --pool), and one .log per process. Exit status is non-zero if any process failed.
set -eu

BIN='' OUT='' MODE=full CPU='' POOL=0 POOL_WORKERS='' RATE=2500 SECS=20 BASE=47340 DEST=127.0.0.1 DECIDE_NS=3000 HOLD_MS=500
CAMERAS=4

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case $1 in
    --bin) BIN=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --mode) MODE=${2:?}; shift 2 ;;
    --consumer-cpu) CPU=${2:?}; shift 2 ;;
    --pool) POOL=1; shift ;;
    --pool-workers) POOL_WORKERS=${2:?}; shift 2 ;;
    --rate) RATE=${2:?}; shift 2 ;;
    --seconds) SECS=${2:?}; shift 2 ;;
    --base-port) BASE=${2:?}; shift 2 ;;
    --dest) DEST=${2:?}; shift 2 ;;
    --decide-ns) DECIDE_NS=${2:?}; shift 2 ;;
    --hold-ms) HOLD_MS=${2:?}; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$BIN" ] && [ -n "$OUT" ] || usage
case $MODE in full | consumer | sims) ;; *) echo "lane-cpp: --mode full|consumer|sims" >&2; exit 2 ;; esac
for n in "$RATE" "$SECS" "$BASE" "$DECIDE_NS" "$HOLD_MS"; do
  case $n in '' | *[!0-9]*) echo "lane-cpp: '$n' is not a number" >&2; exit 2 ;; esac
done
[ "$MODE" = sims ] || [ -n "${LOWLAT_PROFILE:-}" ] || { echo "lane-cpp: LOWLAT_PROFILE is not set" >&2; exit 2; }
for b in line-simulator io-receive place-probe busy-pool; do
  [ -x "$BIN/$b" ] || { echo "lane-cpp: $BIN/$b is not an executable" >&2; exit 2; }
done
mkdir -p "$OUT"

pids=''
cleanup() {
  for p in $pids; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# has_line FILE TEXT: true when a line of FILE is exactly TEXT (builtins only).
has_line() {
  [ -f "$1" ] || return 1
  while IFS= read -r l; do
    [ "$l" = "$2" ] && return 0
  done <"$1"
  return 1
}
# wait_line FILE TEXT PID TRIES: poll every 50 ms for the line; false if PID exits or the tries run out.
wait_line() {
  n=0
  while [ "$n" -lt "$4" ]; do
    has_line "$1" "$2" && return 0
    kill -0 "$3" 2>/dev/null || { has_line "$1" "$2"; return; }
    sleep 0.05
    n=$((n + 1))
  done
  return 1
}

# The binaries that ran, by checksum: the host, the guest and the container must all show the same four.
(cd "$BIN" && sha256sum line-simulator io-receive place-probe busy-pool) >"$OUT/binaries-$MODE.txt"
[ "$MODE" = sims ] || "$BIN/place-probe" --out "$OUT/probe-cpp.json"

rc=0
pool_pid=''
if [ "$POOL" = 1 ] && [ "$MODE" != sims ]; then
  if [ -n "$POOL_WORKERS" ]; then
    "$BIN/busy-pool" --workers "$POOL_WORKERS" --out "$OUT/pool.json" >"$OUT/pool.log" 2>&1 &
  else
    "$BIN/busy-pool" --out "$OUT/pool.json" >"$OUT/pool.log" 2>&1 &
  fi
  pool_pid=$!
  pids="$pids $pool_pid"
  # Its first line, "N workers started", is printed once every worker thread exists and is spinning at the gate.
  n=0
  until [ -s "$OUT/pool.log" ] || [ "$n" -ge 200 ]; do sleep 0.05; n=$((n + 1)); done
  [ -s "$OUT/pool.log" ] || { echo "lane-cpp: the busy pool did not start" >&2; exit 1; }
fi

cons_pid=''
if [ "$MODE" != sims ]; then
  cpu_arg=''
  [ -z "$CPU" ] || cpu_arg=$CPU
  if [ -n "$cpu_arg" ]; then
    timeout "$((SECS + 90))" "$BIN/io-receive" --variant epoll --base-port "$BASE" --expect "$((RATE * SECS))" --cpus "$cpu_arg" \
      --hold-ms "$HOLD_MS" --decide-ns "$DECIDE_NS" --report "$OUT/consumer.json" >"$OUT/consumer.log" 2>&1 &
  else
    timeout "$((SECS + 90))" "$BIN/io-receive" --variant epoll --base-port "$BASE" --expect "$((RATE * SECS))" \
      --hold-ms "$HOLD_MS" --decide-ns "$DECIDE_NS" --report "$OUT/consumer.json" >"$OUT/consumer.log" 2>&1 &
  fi
  cons_pid=$!
  pids="$pids $cons_pid"
  # The receiver binds before the start hold ends, and prints "released" when the threads go: only then do the simulators start.
  wait_line "$OUT/consumer.log" released "$cons_pid" 400 || { cat "$OUT/consumer.log" >&2; echo "lane-cpp: the consumer never reached 'released'" >&2; exit 1; }
fi

if [ "$MODE" != consumer ]; then
  sim_pids=''
  i=0
  while [ "$i" -lt "$CAMERAS" ]; do
    if [ "$i" -eq 0 ]; then
      "$BIN/line-simulator" --rate "$RATE" --duration "$SECS" --dest "$DEST:$((BASE + i))" --wire flat --quiet \
        --report "$OUT/lateness.json" >"$OUT/sim$i.log" 2>&1 &
    else
      "$BIN/line-simulator" --rate "$RATE" --duration "$SECS" --dest "$DEST:$((BASE + i))" --wire flat --quiet \
        >"$OUT/sim$i.log" 2>&1 &
    fi
    sim_pids="$sim_pids $!"
    pids="$pids $!"
    i=$((i + 1))
  done
  for p in $sim_pids; do
    wait "$p" || { echo "lane-cpp: a simulator instance failed" >&2; rc=1; }
  done
fi

if [ -n "$cons_pid" ]; then
  wait "$cons_pid" || { echo "lane-cpp: the consumer failed" >&2; tail -n 20 "$OUT/consumer.log" >&2; rc=1; }
fi
if [ -n "$pool_pid" ]; then
  kill -TERM "$pool_pid" 2>/dev/null || true
  wait "$pool_pid" || { echo "lane-cpp: the busy pool failed" >&2; rc=1; }
fi
pids=''
[ "$rc" -eq 0 ] && echo "lane-cpp: $MODE done" || echo "lane-cpp: $MODE FAILED" >&2
exit "$rc"
