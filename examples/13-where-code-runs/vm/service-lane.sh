#!/bin/sh
# service-lane.sh - the Ch12 Quarkus service inside the Java container, for the quota-against-cpuset lanes.
#
#   service-lane.sh STOP_FILE OUT_FILE JAVA_ARG...
#
# Starts `java JAVA_ARG... -jar /app/quarkus-app/quarkus-run.jar`, waits until STOP_FILE exists (the
# open-loop client in the guest touches it when it is done), then counts the JVM's threads by name from
# /proc and writes OUT_FILE: how many Vert.x event loops, Quarkus worker ("executor-thread") and
# virtual-thread carrier threads the JVM sized itself to under this container's limit. Kernel thread names are cut to
# 15 characters, hence the prefixes. Carriers are the workers of the virtual-thread scheduler's ForkJoinPool
# ("ForkJoinPool-N-worker-M"), whose comm is cut to "ForkJoinPool-N-"; the common pool ("ForkJoinPool.commonPool-worker-M",
# comm "ForkJoinPool.co") has a dot where the digit is and is not counted. The pool's number is not assumed to be 1. Stops the JVM and exits 0.
# Runs under POSIX sh and coreutils only (ubi-minimal has no jq).
set -eu
stop=${1:?STOP_FILE}
out=${2:?OUT_FILE}
shift 2

java "$@" -jar /app/quarkus-app/quarkus-run.jar &
jpid=$!
trap 'kill "$jpid" 2>/dev/null || true' EXIT

waited=0
while [ ! -e "$stop" ]; do
  kill -0 "$jpid" 2>/dev/null || { echo "service-lane: the JVM exited before the client finished" >&2; exit 1; }
  [ "$waited" -lt 6000 ] || { echo "service-lane: no stop file after 10 minutes" >&2; exit 1; }
  sleep 0.1
  waited=$((waited + 1))
done

loops=0 workers=0 carriers=0
for t in /proc/"$jpid"/task/*; do
  [ -r "$t/comm" ] || continue
  read -r name <"$t/comm" || continue
  case $name in
    vert.x-eventloo*) loops=$((loops + 1)) ;;
    executor-thread*) workers=$((workers + 1)) ;;
    ForkJoinPool-[0-9]*) carriers=$((carriers + 1)) ;;
  esac
done
printf '{\n  "schema": "lowlat-place-probe/1",\n  "example": "13-where-code-runs",\n  "language": "java-service",\n  "service": {\n    "event_loop_threads": %s,\n    "executor_threads": %s,\n    "carrier_threads": %s\n  }\n}\n' \
  "$loops" "$workers" "$carriers" >"$out"

kill -TERM "$jpid" 2>/dev/null || true
wait "$jpid" 2>/dev/null || true
trap - EXIT
exit 0
