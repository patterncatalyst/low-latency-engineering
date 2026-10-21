# examples/_lib/lib.sh - shared helpers for every examples/NN-*/verify.sh.
#
# Source it from a verify.sh:
#   . "$(dirname "$0")/../_lib/lib.sh"
#
# A verify.sh builds what it needs, captures the machine profile once, runs the
# example, writes reports into $RESULTS_DIR, checks them with lowlat-report and
# asserts the example's observable effect. It never changes the host: no sudo,
# no sysctl, no tuning. Exit 0 only when the effect was observed.
#
# Environment:
#   RESULTS_DIR   where reports go (default: <example>/results/latest)
#   ALLOW_BUSY=1  measure even if a lowlat-* VM is running (the numbers are then
#                 labelled by the profile's lab.running_domains, but are noisy)
#   SKIP_BUILD=1  reuse existing builds
#   LOWLAT_BUILD  C++ binary dir (default examples/build/release); set a private
#                 one when several builds run at once

set -euo pipefail

LOWLAT_EXAMPLES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOWLAT_ROOT="$(cd "$LOWLAT_EXAMPLES/.." && pwd)"
LOWLAT_BUILD="${LOWLAT_BUILD:-$LOWLAT_EXAMPLES/build/release}"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  _c_ok=$'\e[32m'; _c_bad=$'\e[31m'; _c_step=$'\e[36m'; _c_off=$'\e[0m'
else
  _c_ok=''; _c_bad=''; _c_step=''; _c_off=''
fi
step() { printf '%s━━ %s%s\n' "$_c_step" "$*" "$_c_off"; }
ok()   { printf '%s✓ %s%s\n' "$_c_ok" "$*" "$_c_off"; }
die()  { printf '%s✗ %s%s\n' "$_c_bad" "$*" "$_c_off" >&2; exit 1; }

# example_dir: absolute path of the calling example (the dir holding verify.sh).
example_dir() { cd "$(dirname "${BASH_SOURCE[-1]}")" && pwd; }

# Refuse to take host measurements while a lab VM competes for the CPUs.
require_quiet_host() {
  [[ ${ALLOW_BUSY:-0} == 1 ]] && return 0
  local running
  running=$(timeout 5 virsh -c qemu:///system list --name 2>/dev/null | grep '^lowlat-' || true)
  [[ -z $running ]] || die "lab VM running ($running): stop it (scripts/lab/lab-down.sh) or set ALLOW_BUSY=1"
}

# results_dir: create and print $RESULTS_DIR (default <example>/results/latest).
results_dir() {
  local dir=${RESULTS_DIR:-$(example_dir)/results/latest}
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# capture_profile DIR: write DIR/profile.json and export LOWLAT_PROFILE.
capture_profile() {
  "$LOWLAT_ROOT/scripts/profile.sh" --out "$1/profile.json"
  export LOWLAT_PROFILE="$1/profile.json"
  ok "profile: $(jq -r '"\(.host_label) virt=\(.virt.type) governor=\(.power.governor) tuned=\(.tuned) kernel=\(.kernel.release)"' "$LOWLAT_PROFILE")"
}

# build_cpp [TARGET...]: configure (once) and build the release preset.
build_cpp() {
  [[ ${SKIP_BUILD:-0} == 1 ]] && return 0
  step "building C++ (release preset) ${*:-all}"
  (cd "$LOWLAT_EXAMPLES" && cmake --preset release -B "$LOWLAT_BUILD" >/dev/null)
  if (($#)); then
    cmake --build "$LOWLAT_BUILD" --target "$@"
  else
    cmake --build "$LOWLAT_BUILD"
  fi
}

# cpp_bin NAME: absolute path of a built executable under the release build.
cpp_bin() {
  local bin
  bin=$(find "$LOWLAT_BUILD" -type f -name "$1" -perm -u+x -print -quit)
  [[ -n $bin ]] || die "C++ executable '$1' not found under $LOWLAT_BUILD (build_cpp first)"
  printf '%s' "$bin"
}

# build_java MODULE_DIR: package one Maven module (its parent is examples/pom.xml).
build_java() {
  [[ ${SKIP_BUILD:-0} == 1 ]] && return 0
  step "building Java module $1"
  mvn -B -q -f "$1/pom.xml" -DskipTests package
}

# py_sync: make sure the uv workspace is installed.
py_sync() {
  [[ ${SKIP_BUILD:-0} == 1 ]] && return 0
  step "syncing the Python workspace"
  (cd "$LOWLAT_EXAMPLES" && uv sync -q)
}

# uvrun ARGS...: run inside the examples uv workspace.
uvrun() { (cd "$LOWLAT_EXAMPLES" && uv run -q "$@"); }

# report_check FILE...: schema-validate and recompute every report.
report_check() { uvrun lowlat-report check "$@"; uvrun lowlat-report show "$@"; }

# jget FILE JQ: read one value from a report.
jget() { jq -er "$2" "$1"; }

# assert_ge A B MESSAGE: integer A >= B, else fail with MESSAGE.
assert_ge() {
  (($1 >= $2)) || die "$3 (got $1, need >= $2)"
  ok "$3 ($1 >= $2)"
}

# assert_lt A B MESSAGE: integer A < B.
assert_lt() {
  (($1 < $2)) || die "$3 (got $1, need < $2)"
  ok "$3 ($1 < $2)"
}

# simulate ARGS...: run the reference line simulator (C++).
simulate() { "$(cpp_bin line-simulator)" "$@"; }
