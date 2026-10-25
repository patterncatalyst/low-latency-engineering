#!/usr/bin/env bash
# guest-run.sh - Ch13, the guest side. It runs IN THE LAB GUEST (vm/run.sh starts it over vsock ssh);
# it is not meant to be run on the host.
#
#   guest-run.sh prepare            make the output directory, take the guest profile, copy the four C++
#                                   binaries out of the place-cpp image (through container_run) and the
#                                   lane scripts beside them
#   guest-run.sh lane LANE ALT      one lane, one alternation: vm | container-host-net | container-bridge |
#                                   container-cpu-quota | container-cpuset
#   guest-run.sh proc-stat          print "busy_ticks total_ticks" from /proc/stat (the host driver reads it
#                                   twice around the host lane to show the guest was idle)
#   guest-run.sh idle-wait [SEC]    wait until the guest has been under 1 percent busy over a 2 s window
#
#   DRY_RUN=1                       print every command a lane would run, run nothing
#   SMOKE=1                         2 s lanes, a check of the scripts and not a measurement
#
# Every container goes through container_run (examples/_lib/lib.sh): its allowlisted options only
# (--network host|bridge, --cpus 2, --cpuset-cpus 2,3, default seccomp, -v only under CONTAINER_OUT_DIR),
# which also records the image digest and the container's own cgroup counters (nr_throttled and
# throttled_usec, read by the wrapper from the container's cpu.stat at the end of the run). Inside the
# guest container_run's `guest docker ...` calls run locally: LAB_SSH is vm/local-shell.sh.
#
# Reports land in $CONTAINER_OUT_DIR/LANE/altN/{cpp,python,java,quarkus}/ and steal.json; vm/run.sh fetches them.
set -euo pipefail
# shellcheck source=../../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../../_lib/lib.sh"
# shellcheck source=../lanes.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../lanes.sh"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DRY_RUN=${DRY_RUN:-0}
SMOKE=${SMOKE:-0}

# This script starts containers, writes under the checkout and deletes files: it belongs in the lab guest and nowhere
# else. Unless it is a dry run, it refuses to start on anything that is not a KVM guest carrying the lab's marker file.
if ((!DRY_RUN)); then
  [[ $(systemd-detect-virt 2>/dev/null || true) == kvm && -r /var/log/lab-ready ]] ||
    die "guest-run.sh runs only in the lab guest (systemd-detect-virt must say kvm and /var/log/lab-ready must exist); use DRY_RUN=1 to print what it would do"
fi

# The guest checkout, resolved, and the one directory containers may mount (lib.sh's rule).
LOWLAT_GUEST_ROOT=$(cd "$LOWLAT_ROOT" && pwd -P)
export LOWLAT_GUEST_ROOT
# GUEST_REPO is relative to the guest user's home (`guest` does `cd` to it).
case $LOWLAT_GUEST_ROOT in
  "$HOME"/*) GUEST_REPO=${LOWLAT_GUEST_ROOT#"$HOME"/} ;;
  *) GUEST_REPO=low-latency-engineering ;;
esac
export GUEST_REPO
VMOUT=$LOWLAT_GUEST_ROOT/examples/$EXAMPLE/vm-out
export CONTAINER_OUT_DIR=$VMOUT
export LAB_SSH=$HERE/local-shell.sh
export TARGET_VM=${TARGET_VM:-lowlat-target}
export GUEST_PROFILE=$GUEST_PROFILE_NAME
export LOWLAT_PROFILE=$VMOUT/profile.json
BIN=$VMOUT/bin
JARS=$VMOUT/jars
PY_VERSION=$(<"$LOWLAT_ROOT/examples/.python-version")

# x CMD...: run CMD, or print it under DRY_RUN=1.
x() {
  if ((DRY_RUN)); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
if ((DRY_RUN)); then
  # Print the container a lane would start, and succeed.
  container_run() {
    printf '[dry-run] container_run'
    printf ' %q' "$@"
    printf '\n'
  }
fi

NAMES=()
cleanup_containers() {
  local n
  # Containers this run started and that are still there (container_run removes its own on every exit path; this is for a
  # background container_run that was killed while it waited). Never under DRY_RUN: nothing was started.
  ((DRY_RUN)) && return 0
  for n in "${NAMES[@]}"; do docker rm -f "$n" >/dev/null 2>&1 || true; done
}
trap 'cleanup_containers; _bg_cleanup' EXIT

# lane_dir LANE ALT: create (world-writable: the containers run as uid 10001) and print the lane's output directory.
lane_dir() {
  local d=$VMOUT/$1/alt$2 sub
  for sub in cpp python java quarkus; do
    x install -d -m 0777 "$d/$sub" >&2
  done
  x chmod 0777 "$VMOUT/$1" "$d" >&2
  printf '%s' "$d"
}

set_lane_args

# probes_native DIR: the Python and Java views in the guest itself (the vm lane).
probes_native() {
  local d=$1
  # The interpreter every other lane uses: uv-managed CPython from examples/.python-version (installed by `prepare`).
  x env PYTHONPATH="$LOWLAT_ROOT/examples/$EXAMPLE/place-py/src" uv run --no-project --no-config --python "$PY_VERSION" \
    python -m lowlat_place --out "$d/python/probe-python.json"
  x java -cp "$JARS/where-code-runs-java.jar" "$CPUPROBE_CLASS" --out "$d/java/probe-java.json"
}

steal_json() {
  local d=$1 s0=$2 t0=$3 s1 t1
  ((DRY_RUN)) && return 0
  read -r s1 t1 < <(steal_ticks)
  jq -n --argjson s $((s1 - s0)) --argjson t $((t1 - t0)) --argjson hz "$(getconf CLK_TCK)" --arg ex "$EXAMPLE" \
    '{schema: "lowlat-steal/1", example: $ex, steal_ticks: $s, total_ticks: $t, clk_tck: $hz}' >"$d/steal.json"
}

# ---- the vm lane: native in the guest ------------------------------------------------------------------------------------
lane_vm() {
  local d=$1 envf=$1/vm-env.json
  step "guest: vm lane (native), alternation $2"
  x "$VMOUT/lane-cpp.sh" --bin "$BIN" --out "$d/cpp" --mode full --consumer-cpu "$GUEST_CPU" "${LANE_ARGS[@]}"
  probes_native "$d"
  ((DRY_RUN)) && return 0
  env_json_vm "$envf"
  relabel_example "$d/cpp/consumer.json"
  tag_env "$envf" "$d/cpp/consumer.json" "$d/cpp/lateness.json" "$d/cpp/probe-cpp.json" "$d/python/probe-python.json" "$d/java/probe-java.json"
}

# ---- the container lanes -------------------------------------------------------------------------------------------------

# container_probes LANE ALT DIR LIMIT_OPTION...: the Python and Java views from inside the same limits.
container_probes() {
  local lane=$1 alt=$2 d=$3 name
  shift 3
  local rel=$lane/alt$alt
  name=lowlat-c13-$lane-a$alt-py
  NAMES+=("$name")
  container_run "$name" --env-out "$d/py-env.json" "$@" -v "$VMOUT:/out" -- "$IMAGE_PY" python -m lowlat_place --out "/out/$rel/python/probe-python.json"
  name=lowlat-c13-$lane-a$alt-jvm
  NAMES+=("$name")
  container_run "$name" --env-out "$d/jvm-env.json" "$@" -v "$VMOUT:/out" -- "$IMAGE_JAVA" \
    java -cp /app/cpuprobe/where-code-runs-java.jar "$CPUPROBE_CLASS" --out "/out/$rel/java/probe-java.json"
  ((DRY_RUN)) && return 0
  tag_env "$d/py-env.json" "$d/python/probe-python.json"
  tag_env "$d/jvm-env.json" "$d/java/probe-java.json"
}

# container_cpp LANE ALT DIR LIMIT_OPTION...: the C++ lane inside one container (simulators and consumer together).
container_cpp() {
  local lane=$1 alt=$2 d=$3 name
  shift 3
  local rel=$lane/alt$alt
  local -a pool=()
  lane_has_pool "$lane" && pool=(--pool)
  name=lowlat-c13-$lane-a$alt-cpp
  NAMES+=("$name")
  step "guest: $lane, alternation $alt: simulators and consumer in $name"
  container_run "$name" --env-out "$d/cpp-env.json" "$@" -v "$VMOUT:/out" -e LOWLAT_PROFILE=/out/profile.json -- "$IMAGE_CPP" \
    sh /out/lane-cpp.sh --bin /usr/local/bin --out "/out/$rel/cpp" --mode full --consumer-cpu "$GUEST_CPU" "${LANE_ARGS[@]}" "${pool[@]}"
  ((DRY_RUN)) && return 0
  local -a files=("$d/cpp/consumer.json" "$d/cpp/lateness.json" "$d/cpp/probe-cpp.json")
  [[ ${#pool[@]} -eq 0 ]] || files+=("$d/cpp/pool.json")
  relabel_example "$d/cpp/consumer.json"
  tag_env "$d/cpp-env.json" "${files[@]}"
}

# container_bridge ALT DIR: the consumer in a container on the default bridge; the four simulators here in the guest, sending to the
# container's address on the bridge. container_run blocks until the container exits, so it runs in the background.
container_bridge() {
  local alt=$1 d=$2 name=lowlat-c13-container-bridge-a$1-cpp cpid ip tries
  local rel=container-bridge/alt$alt
  NAMES+=("$name")
  step "guest: container-bridge, alternation $alt: consumer in $name, simulators in the guest"
  if ((DRY_RUN)); then
    container_run "$name" --env-out "$d/cpp-env.json" --network bridge -v "$VMOUT:/out" -e LOWLAT_PROFILE=/out/profile.json -- "$IMAGE_CPP" \
      sh /out/lane-cpp.sh --bin /usr/local/bin --out "/out/$rel/cpp" --mode consumer --bind 0.0.0.0 --consumer-cpu "$GUEST_CPU" "${LANE_ARGS[@]}"
    x docker inspect --format '{{.NetworkSettings.Networks.bridge.IPAddress}}' "$name"
    x "$VMOUT/lane-cpp.sh" --bin "$BIN" --out "$d/cpp" --mode sims --dest "<container address on the bridge>" "${LANE_ARGS[@]}"
    return 0
  fi
  container_run "$name" --env-out "$d/cpp-env.json" --network bridge -v "$VMOUT:/out" -e LOWLAT_PROFILE=/out/profile.json -- "$IMAGE_CPP" \
    sh /out/lane-cpp.sh --bin /usr/local/bin --out "/out/$rel/cpp" --mode consumer --bind 0.0.0.0 --consumer-cpu "$GUEST_CPU" "${LANE_ARGS[@]}" &
  cpid=$!
  bg_track "$cpid"
  # The consumer's log is in the bind mount: "released" means it is bound and the start gate has opened.
  for ((tries = 0; tries < 1200; tries++)); do
    grep -qx released "$d/cpp/consumer.log" 2>/dev/null && break
    kill -0 "$cpid" 2>/dev/null || { wait "$cpid" || true; die "the bridge consumer container exited before it was released"; }
    sleep 0.1
  done
  ((tries < 1200)) || die "the bridge consumer was not released within 120 s"
  # Its address on the bridge, read once and used only on the command line: it is never written to a result.
  ip=$(docker inspect --format '{{.NetworkSettings.Networks.bridge.IPAddress}}' "$name")
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no bridge address for $name"
  "$VMOUT/lane-cpp.sh" --bin "$BIN" --out "$d/cpp" --mode sims --dest "$ip" "${LANE_ARGS[@]}" || die "the simulators failed"
  wait "$cpid" || die "the bridge consumer container failed"
  bg_forget "$cpid"
  local envf=$d/vm-env.json
  env_json_vm "$envf"
  relabel_example "$d/cpp/consumer.json"
  tag_env "$d/cpp-env.json" "$d/cpp/consumer.json" "$d/cpp/probe-cpp.json"
  tag_env "$envf" "$d/cpp/lateness.json" # the simulator ran in the guest, outside the container
}

# container_quarkus LANE ALT DIR LIMIT_OPTION...: the Ch12 Quarkus service in the Java container under the same limit, the Ch12 open-loop
# client in the guest. Host network, so the client reaches 127.0.0.1 without publishing a port.
container_quarkus() {
  local lane=$1 alt=$2 d=$3 name svc tries
  shift 3
  local rel=$lane/alt$alt
  name=lowlat-c13-$lane-a$alt-svc
  NAMES+=("$name")
  step "guest: $lane, alternation $alt: Quarkus service in $name at $Q_RATE Hz, client in the guest"
  x rm -f "${d:?}/quarkus/stop"
  if ((DRY_RUN)); then
    container_run "$name" --env-out "$d/svc-env.json" "$@" --network host -v "$VMOUT:/out" -- "$IMAGE_JAVA" \
      sh /out/service-lane.sh "/out/$rel/quarkus/stop" "/out/$rel/quarkus/service.json" "${SERVER_JVM[@]}" "-Dquarkus.http.port=$Q_PORT"
    x taskset -c 0,1 java -cp "$JARS/io-engines-java.jar" "$CLIENT_MAIN" client --variant virtual-thread --base-url "http://127.0.0.1:$Q_PORT" \
      --rate "$Q_RATE" --seconds "$Q_SECONDS" --warmup-seconds "$Q_WARMUP_SECONDS" --pool "$Q_POOL" --service-time-ms "$Q_SERVICE_MS" --report "$d/quarkus/client.json"
    return 0
  fi
  container_run "$name" --env-out "$d/svc-env.json" "$@" --network host -v "$VMOUT:/out" -- "$IMAGE_JAVA" \
    sh /out/service-lane.sh "/out/$rel/quarkus/stop" "/out/$rel/quarkus/service.json" "${SERVER_JVM[@]}" "-Dquarkus.http.port=$Q_PORT" &
  svc=$!
  bg_track "$svc"
  for ((tries = 0; tries < 600; tries++)); do
    curl -sf -m 2 "http://127.0.0.1:$Q_PORT/stats" >/dev/null 2>&1 && break
    kill -0 "$svc" 2>/dev/null || { wait "$svc" || true; die "the Quarkus container exited before it was ready"; }
    sleep 0.1
  done
  ((tries < 600)) || die "the Quarkus service did not answer on $Q_PORT within 60 s"
  # The client sends from guest CPUs 0 and 1, away from the cpuset 2,3 the container may be confined to; the same in both limit lanes.
  if ! taskset -c 0,1 java -Xms256m -Xmx1g -XX:+ExitOnOutOfMemoryError -cp "$JARS/io-engines-java.jar" "$CLIENT_MAIN" client --variant virtual-thread \
    --base-url "http://127.0.0.1:$Q_PORT" --rate "$Q_RATE" --seconds "$Q_SECONDS" --warmup-seconds "$Q_WARMUP_SECONDS" --pool "$Q_POOL" \
    --service-time-ms "$Q_SERVICE_MS" --report "$d/quarkus/client.json" >"$d/quarkus/client.log" 2>&1; then
    tail -n 20 "$d/quarkus/client.log" >&2
    touch "$d/quarkus/stop"
    chmod a+r "$d/quarkus/stop"
    wait "$svc" || true
    die "the open-loop client failed"
  fi
  touch "$d/quarkus/stop"
  chmod a+r "$d/quarkus/stop"
  wait "$svc" || die "the Quarkus container failed"
  bg_forget "$svc"
  relabel_example "$d/quarkus/client.json"
  tag_env "$d/svc-env.json" "$d/quarkus/client.json" "$d/quarkus/service.json"
}

lane_container() {
  local lane=$1 alt=$2 d=$3
  local -a limit=()
  case $lane in
    container-host-net) limit=(--network host) ;;
    container-bridge) limit=(--network bridge) ;;
    container-cpu-quota) limit=(--cpus "$LIMIT_CPUS") ;;
    container-cpuset) limit=(--cpuset-cpus "$LIMIT_CPUSET") ;;
    *) die "not a container lane: $lane" ;;
  esac
  if [[ $lane == container-bridge ]]; then
    container_bridge "$alt" "$d"
  else
    container_cpp "$lane" "$alt" "$d" "${limit[@]}"
  fi
  container_probes "$lane" "$alt" "$d" "${limit[@]}"
  if lane_has_pool "$lane"; then container_quarkus "$lane" "$alt" "$d" "${limit[@]}"; fi
}

# ---- sub-commands ----------------------------------------------------------------------------------------------------------
prepare() {
  step "guest: prepare $VMOUT"
  x install -d -m 0777 "$VMOUT" "$BIN" "$JARS"
  x install -m 0755 "$HERE/lane-cpp.sh" "$HERE/service-lane.sh" "$VMOUT/"
  x "$LOWLAT_ROOT/scripts/profile.sh" --out "$VMOUT/profile.json"
  x chmod a+r "$VMOUT/profile.json"
  # The vm lane's Python: the same uv-managed CPython the host lane and the python image run. uv downloads it once per
  # prepared guest (python-build-standalone); a uv too old to list this release fails here, not in the middle of a lane.
  x uv python install "$PY_VERSION"
  local -a paths=()
  local b
  for b in "${CPP_BINARIES[@]}"; do paths+=("/usr/local/bin/$b"); done
  # The same four binaries the host and the guest lanes run: copied out of the image through container_run.
  container_run lowlat-c13-extract --env-out "$VMOUT/extract-env.json" -v "$VMOUT:/out" -- "$IMAGE_CPP" cp "${paths[@]}" /out/bin/
  if ((!DRY_RUN)); then
    [[ $(jq -r .virt.type "$VMOUT/profile.json") == kvm ]] || die "the guest profile does not say virt.type kvm"
    (cd "$BIN" && sha256sum "${CPP_BINARIES[@]}")
  fi
}

case ${1:-} in
  prepare) prepare ;;
  lane)
    lane=${2:?lane LANE ALT} alt=${3:?lane LANE ALT}
    [[ $alt =~ ^[1-9][0-9]*$ ]] || die "ALT must be a positive integer"
    d=$(lane_dir "$lane" "$alt")
    read -r s0 t0 < <(steal_ticks)
    case $lane in
      vm) lane_vm "$d" "$alt" ;;
      container-*) lane_container "$lane" "$alt" "$d" ;;
      *) die "unknown guest lane '$lane' (the host lane runs on the host)" ;;
    esac
    steal_json "$d" "$s0" "$t0"
    if ((!DRY_RUN)); then
      env_json_vm "$d/steal-env.json"
      tag_env "$d/steal-env.json" "$d/steal.json"
      # The environment blocks were merged into the reports; they are not results of their own.
      find "${d:?}" -maxdepth 1 -name '*-env.json' -delete
      scrub_results "$VMOUT/$lane"
    fi
    ;;
  proc-stat) busy_ticks ;;
  idle-wait)
    max_wait=${2:-120}
    for ((i = 0; i < max_wait; i += 2)); do
      read -r b0 t0 < <(busy_ticks)
      sleep 2
      read -r b1 t1 < <(busy_ticks)
      ((t1 > t0)) || die "idle-wait: /proc/stat did not advance"
      # under 1 percent busy
      if ((100 * (b1 - b0) <= (t1 - t0))); then exit 0; fi
    done
    die "the guest was still busy after $max_wait s"
    ;;
  *) die "usage: guest-run.sh prepare | lane LANE ALT | proc-stat | idle-wait [SEC]" ;;
esac
