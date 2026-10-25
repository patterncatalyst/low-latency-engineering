# shellcheck shell=bash
# lanes.sh - what verify.sh, vm/run.sh and vm/guest-run.sh agree on: the lanes, the workload, the ports,
# the images and the helpers that put a lane's environment into its reports. Source it after
# examples/_lib/lib.sh.
#
# A lane is where the code runs:
#   host                bare metal (the laptop), with the lab VM booted and idle
#   vm                  native in the lab guest
#   container-host-net  Docker in the guest, --network host
#   container-bridge    Docker in the guest, the default bridge: the simulators run in the guest and
#                       the datagrams cross the veth to the consumer in the container
#   container-cpu-quota Docker in the guest, --cpus=2, with a busy pool of 4 beside the consumer
#   container-cpuset    Docker in the guest, --cpuset-cpus=2,3, with the same pool
# Every comparison is inside one run (D9): the lanes alternate H V N B Q S, three times.

EXAMPLE=13-where-code-runs
LANES=(host vm container-host-net container-bridge container-cpu-quota container-cpuset)
CONTAINER_LANES=(container-host-net container-bridge container-cpu-quota container-cpuset)
ROUNDS=3

# Workload: four simulator instances (tunnel cameras) at LINE_RATE Hz each = 10 kHz, LINE_SECONDS long.
CAMERAS=4
LINE_RATE=${LINE_RATE:-2500}
LINE_SECONDS=${LINE_SECONDS:-20}
DECIDE_NS=${DECIDE_NS:-3000}
HOLD_MS=${HOLD_MS:-500}
line_count() { echo $((LINE_RATE * LINE_SECONDS * CAMERAS)); }

# Ports on 127.0.0.1 (or the container's address in the bridge lane): UDP 47340-47343, TCP 47344. Examples 00-12
# use 47000-47336, so nothing here collides with them; a run never overlaps another example's.
UDP_BASE=47340
Q_PORT=47344

# The guest: 4 vCPUs. The consumer is pinned to guest CPU 3 in every guest lane (it is in --cpuset-cpus=2,3).
GUEST_VCPUS=4
GUEST_CPU=3
GUEST_PROFILE_NAME=${GUEST_PROFILE:-lab-ready-r04/stock-unpinned}
LIMIT_CPUS=2         # container-cpu-quota: --cpus=2 (cpu.max "200000 100000")
LIMIT_CPUSET=2,3     # container-cpuset: --cpuset-cpus=2,3

# The Quarkus service lanes (container-cpu-quota and container-cpuset): the Ch12 service, virtual-thread variant,
# driven by the Ch12 open-loop client in the guest. 3 kHz x 2 ms = 6 requests in flight.
Q_RATE=${Q_RATE:-3000}
Q_SECONDS=${Q_SECONDS:-5}
Q_WARMUP_SECONDS=${Q_WARMUP_SECONDS:-3}
Q_POOL=8
Q_SERVICE_MS=2
SERVER_JVM=(-Xms512m -Xmx512m -XX:+AlwaysPreTouch)

IMAGE_CPP=lowlat/place-cpp:r04
IMAGE_JAVA=lowlat/place-java:r04
IMAGE_PY=lowlat/place-py:r04
CPP_BINARIES=(line-simulator io-receive place-probe busy-pool)
CPUPROBE_CLASS=io.patterncatalyst.lowlat.ch13.CpuProbe
CLIENT_MAIN=io.patterncatalyst.lowlat.ch12.Main

# SMOKE=1 is a check of the scripts: 2 s lanes, nothing enforced.
if [[ ${SMOKE:-0} == 1 ]]; then
  LINE_SECONDS=2
  Q_SECONDS=2
  Q_WARMUP_SECONDS=1
  HOLD_MS=100
fi

# set_lane_args: the lane-cpp.sh workload options, from the values above (call it after they are final).
set_lane_args() {
  LANE_ARGS=(--rate "$LINE_RATE" --seconds "$LINE_SECONDS" --base-port "$UDP_BASE" --decide-ns "$DECIDE_NS" --hold-ms "$HOLD_MS")
}

# lane_kind LANE: the runtime.environment.kind a lane's reports carry.
lane_kind() {
  case $1 in
    host) echo host ;;
    vm) echo vm ;;
    container-*) echo container ;;
    *) die "unknown lane '$1'" ;;
  esac
}
# lane_has_pool LANE: the two limit lanes run the busy pool of 4 (hardware_concurrency) beside the consumer.
lane_has_pool() { [[ $1 == container-cpu-quota || $1 == container-cpuset ]]; }

# env_json_host / env_json_vm: the runtime.environment block of a host or vm lane, as a file lib.sh's merge reads
# (container_run writes the same shape for a container).
env_json_host() { jq -n '{runtime: {environment: {kind: "host"}}}' >"$1"; }
env_json_vm() { jq -n --arg gp "$GUEST_PROFILE_NAME" '{runtime: {environment: {kind: "vm", guest_profile: $gp}}}' >"$1"; }

# tag_env ENV_JSON FILE...: merge the environment block of ENV_JSON into each file's `runtime`. A missing file is an error:
# a lane that did not produce what it was to produce must not be tagged as if it had.
tag_env() {
  local env=$1 f
  shift
  for f in "$@"; do
    [[ -f $f ]] || die "tag_env: $f was not produced"
    jq --slurpfile e "$env" '.runtime = ((.runtime // {}) * $e[0].runtime)' "$f" >"$f.tmp" || die "tag_env: jq failed on $f"
    mv "$f.tmp" "$f"
  done
}

# relabel_example FILE...: the Ch12 consumer and the Ch12 open-loop client write example "12-io-engines"; in this chapter's
# results they belong to this example. Only that field changes; the variant stays what the program ran.
relabel_example() {
  local f
  for f in "$@"; do
    [[ -f $f ]] || die "relabel_example: $f was not produced"
    jq --arg e "$EXAMPLE" '.example = $e' "$f" >"$f.tmp" || die "relabel_example: jq failed on $f"
    mv "$f.tmp" "$f"
  done
}

# steal_ticks: the aggregate "cpu" line of /proc/stat as "steal_ticks total_ticks" (the guest's own time, in USER_HZ ticks;
# steal is time the hypervisor ran something else while a vCPU wanted to run; guest and guest_nice are inside user).
steal_ticks() { awk '/^cpu / {print $9, $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9}' /proc/stat; }
# busy_ticks: "busy_ticks total_ticks" of the same line (everything but idle and iowait), for the idle check around the host lane.
busy_ticks() { awk '/^cpu / {print $2 + $3 + $4 + $7 + $8, $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9}' /proc/stat; }

# run_bg LOG CMD...: run CMD in the background, wait for it, and print its output afterwards. A bash trap runs only
# after a foreground command ends, so a TERM or INT to the driver would otherwise wait out a 20 s lane; a `wait` returns
# at once, the trap exits, and the EXIT handler stops the whole tree (_bg_cleanup). CMD is reachable by $!.
run_bg() {
  local log=$1 pid rc=0
  shift
  "$@" >"$log" 2>&1 &
  pid=$!
  bg_track "$pid"
  wait "$pid" || rc=$?
  bg_forget "$pid"
  cat "$log"
  return "$rc"
}

EXAMPLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# host_lane_run ALT: the host lane, one alternation, into $OUT/host/altN. Needs OUT (the results directory), HOST_BIN (the four C++
# binaries), HOST_CPU (the consumer's CPU), CPUPROBE_JAR, LOWLAT_PROFILE (the host profile) and LOWLAT_SCRATCH.
host_lane_run() {
  local alt=$1 d=$OUT/host/alt$1 envf
  mkdir -p "$d/cpp" "$d/python" "$d/java"
  envf=$LOWLAT_SCRATCH/host-env.json
  env_json_host "$envf"
  set_lane_args
  step "host lane, alternation $alt: simulators and consumer on the host (consumer on CPU $HOST_CPU)"
  "$EXAMPLE_DIR/vm/lane-cpp.sh" --bin "$HOST_BIN" --out "$d/cpp" --mode full --consumer-cpu "$HOST_CPU" "${LANE_ARGS[@]}" ||
    die "the host lane failed (alternation $alt)"
  uvrun python -m lowlat_place --out "$d/python/probe-python.json"
  java -cp "$CPUPROBE_JAR" "$CPUPROBE_CLASS" --out "$d/java/probe-java.json"
  relabel_example "$d/cpp/consumer.json"
  tag_env "$envf" "$d/cpp/consumer.json" "$d/cpp/lateness.json" "$d/cpp/probe-cpp.json" "$d/python/probe-python.json" "$d/java/probe-java.json"
}
