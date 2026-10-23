#!/usr/bin/env bash
# Ch7 verify, VM part (VM=1 ../verify.sh): does a pinned, isolated CPU keep the decide thread
# of the spin hand-off off the scheduler and out of the tail?
#
# In the lab guest (lowlat-target, snapshot lab-ready-iso: PREEMPT_RT kernel booted with
# isolcpus=3 nohz_full=3 rcu_nocbs=3, vCPU 3 pinned to host CPU 13), with `stress-ng --cpu 3`
# pinned to guest CPUs 0-2 as the noise, run the agrona-spsc variant at 10 kHz x 20 s with the
# decide thread
#   unpinned          where the guest scheduler puts it, among the noise, and
#   pinned-isolated   OpenHFT Affinity lock on guest CPU 3,
# alternated three times inside one boot (u p u p u p), and compare:
#   1. decide-thread involuntary context switches per run: pinned <= 10, unpinned >= 100.
#   2. hand-off p99.9 (steady window): pinned <= 1/2 of unpinned (median of the REPS runs of each, three by default).
#   3. every run: count = N, dropped = 0, no overflow, every divert command arrived, the pinned
#      decide thread's allowed CPUs are exactly {3}, every report passes lowlat-report check.
# Results: $RESULTS_DIR/vm/ (default results/latest/vm/), labelled `vm`, with the guest's own
# profile.json. A VM number is never compared with a host number.
#
# The guest must be running and freshly reverted:
#   scripts/lab/revert-vm.sh lowlat-target lab-ready-iso && scripts/lab/lab-up.sh
# and is shut down afterwards by scripts/lab/lab-down.sh (this script leaves it running so a
# failed run can be inspected). Nothing on the host changes: the guest takes the privileged work.
#   REPS=3        alternations
#   SKIP_BUILD=1  reuse the host build of benchmarks.jar and line-simulator
set -euo pipefail
# shellcheck source=../../_lib/lib.sh
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../../_lib/lib.sh"
# shellcheck source=../../../versions.env
# shellcheck source-path=SCRIPTDIR
. "$LOWLAT_ROOT/versions.env"

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET=${TARGET_VM:-lowlat-target}
LAB=$LOWLAT_ROOT/scripts/lab
export LIBVIRT_DEFAULT_URI=${LIBVIRT_DEFAULT_URI:-qemu:///system}
PORT=47270
RATE=10000
SECONDS_RUN=20
COUNT=$((RATE * SECONDS_RUN))
WINDOW=20000
HOLD_MS=1500
REPS=${REPS:-3}
PLACEMENTS=(unpinned pinned-isolated)
GUEST_REPO=low-latency-engineering # relative to the guest user's home
GUEST_OUT=lowlat-vm-run

lab_ssh() { "$LAB/lab-ssh.sh" "$TARGET" "$@"; }
# guest CMD...: run CMD in the guest, each word quoted for the guest shell, from the repo root.
guest() { lab_ssh "cd $GUEST_REPO && $(printf '%q ' "$@")"; }

cleanup() {
  # A killed or failed run must not leave noise or a spinning JVM in the guest.
  timeout 30 "$LAB/lab-ssh.sh" "$TARGET" "pkill -f '^stress-ng'; pkill -f '[i]o.patterncatalyst.lowlat.offheap.Handoff'; true" >/dev/null 2>&1 || true
  _bg_cleanup
}
trap cleanup EXIT

RESULTS=$(results_dir)
VMDIR=$RESULTS/vm
rm -rf "$VMDIR"
mkdir -p "$VMDIR"

step "host build: benchmarks.jar and line-simulator"
build_cpp line-simulator
build_java "$DIR/java"
JAR=$DIR/java/target/benchmarks.jar
SIM=$(cpp_bin line-simulator)
[[ -f $JAR ]] || die "no $JAR"

step "guest prerequisites"
"$LOWLAT_ROOT/scripts/check-prereqs.sh" --vm | tee "$VMDIR/check-prereqs.txt"
lab_ssh 'java -version 2>&1' >"$VMDIR/guest-java.txt"
java_line=$(head -n2 "$VMDIR/guest-java.txt" | tr '\n' ' ')
[[ $java_line == *"Temurin-$TEMURIN_VERSION+"* ]] || die "guest java is not Temurin $TEMURIN_VERSION: $java_line"
ok "guest runs Temurin $TEMURIN_VERSION"
cmdline=$(lab_ssh cat /proc/cmdline)
[[ " $cmdline " == *" isolcpus=3 "* && " $cmdline " == *" nohz_full=3 "* && " $cmdline " == *" rcu_nocbs=3 "* ]] ||
  die "guest cmdline has no isolcpus=3 nohz_full=3 rcu_nocbs=3: revert to lab-ready-iso (scripts/lab/revert-vm.sh $TARGET lab-ready-iso)"
ok "guest cmdline isolates CPU 3 (isolcpus, nohz_full, rcu_nocbs)"
virsh vcpupin "$TARGET" >"$VMDIR/vcpupin.txt"
echo "libvirt vcpupin (a pin, not a host isolation):" && cat "$VMDIR/vcpupin.txt"

# shellcheck disable=SC2016 # $HOME expands in the guest
GUEST_HOME=$(lab_ssh 'echo $HOME')
GUEST_RUN=$GUEST_HOME/$GUEST_OUT
step "deploy"
"$LAB/deploy-to-vm.sh" "$TARGET"
lab_ssh "mkdir -p $GUEST_REPO/examples/07-offheap-lockfree/java/target $GUEST_REPO/examples/build/release && rm -rf $GUEST_OUT && mkdir -p $GUEST_OUT"
lab_ssh "cat >$GUEST_REPO/examples/07-offheap-lockfree/java/target/benchmarks.jar" <"$JAR"
lab_ssh "cat >$GUEST_REPO/examples/build/release/line-simulator && chmod +x $GUEST_REPO/examples/build/release/line-simulator" <"$SIM"
guest examples/build/release/line-simulator --help >/dev/null || die "the host-built line-simulator does not run in the guest"
# The guest's own profile (virt.type, kernel, cmdline-derived isolation) is the one the guest reports carry.
guest scripts/profile.sh --out "$GUEST_RUN/profile.json"
lab_ssh "cat $GUEST_OUT/profile.json" >"$VMDIR/profile.json"
[[ $(jget "$VMDIR/profile.json" .virt.type) == kvm ]] || die "the guest profile does not say virt.type kvm"
printf 'vm\n' >"$VMDIR/LABEL"

step "noise: stress-ng --cpu 3 on guest CPUs 0-2"
lab_ssh 'setsid nohup taskset -c 0-2 stress-ng --cpu 3 --timeout 7200 >/dev/null 2>&1 </dev/null & sleep 1; true'
sleep 2
# shellcheck disable=SC2016 # expands in the guest
noise=$(lab_ssh 'for p in $(pgrep -f "^stress-ng"); do awk "/^Cpus_allowed_list:/ {print \$2}" /proc/$p/status; done | sort | uniq -c')
echo "stress-ng processes by allowed CPUs: $noise"
[[ -n $noise && $(wc -l <<<"$noise") -eq 1 && $noise == *" 0-2" ]] || die "stress-ng is not confined to guest CPUs 0-2: $noise"
[[ $(lab_ssh "pgrep -fc '^stress-ng-cpu'") -eq 3 ]] || die "stress-ng is not running"
ok "stress-ng --cpu 3 running on guest CPUs 0-2 (guest CPU 3 is isolated and idle of it)"

# One run: guest-run.sh in the guest, then fetch its directory.
JVM=(-Xms1g -Xmx1g -XX:+AlwaysPreTouch -XX:+UseG1GC --enable-native-access=ALL-UNNAMED -Dchronicle.analytics.disable=true)
mapfile -t CHRONICLE_ARGS < <(sed -n '/<chronicle.jvmArgs>/,/<\/chronicle.jvmArgs>/p' "$DIR/java/pom.xml" |
  grep -oE -- '--[a-z-]+=[^[:space:]<]+')
((${#CHRONICLE_ARGS[@]} > 0)) || die "no chronicle.jvmArgs found in $DIR/java/pom.xml"
for ((rep = 1; rep <= REPS; rep++)); do
  for placement in "${PLACEMENTS[@]}"; do
    run=r$rep-$placement
    step "run $run (of $REPS alternations, one boot)"
    guest env LOWLAT_PROFILE="$GUEST_RUN/profile.json" examples/07-offheap-lockfree/vm/guest-run.sh \
      "$placement" "$GUEST_RUN/$run" "$RATE" "$SECONDS_RUN" "$WINDOW" "$HOLD_MS" "$PORT" -- "${JVM[@]}" "${CHRONICLE_ARGS[@]}" |
      tee "$VMDIR/$run.console.txt"
    mkdir -p "$VMDIR/$run"
    lab_ssh "tar -C $GUEST_OUT/$run -cf - ." | tar -C "$VMDIR/$run" -xf -
  done
done
lab_ssh "pkill -f '^stress-ng'; true"

step "checking reports (on the host)"
mapfile -t reports < <(find "$VMDIR" -mindepth 2 -name 'java-*.json' | sort)
report_check "${reports[@]}"

step "criteria 3: every run"
for ((rep = 1; rep <= REPS; rep++)); do
  for placement in "${PLACEMENTS[@]}"; do
    r=$VMDIR/r$rep-$placement/java-agrona-spsc.json
    h=$VMDIR/r$rep-$placement/java-agrona-spsc-handoff.json
    [[ $(jget "$r" .count) -eq $COUNT ]] || die "$placement r$rep: count != $COUNT"
    [[ $(jget "$r" .dropped) -eq 0 ]] || die "$placement r$rep: parcels were dropped"
    [[ $(jget "$h" .count) -eq $COUNT ]] || die "$placement r$rep: hand-off count != $COUNT"
    [[ $(note_of "$r" overflow) -eq 0 ]] || die "$placement r$rep: the hand-off overflowed"
    [[ $(note_of "$r" divert_received) -eq $COUNT ]] || die "$placement r$rep: not every divert command arrived"
    [[ $(note_of "$r" placement) == "$placement" ]] || die "$placement r$rep: the report says placement $(note_of "$r" placement)"
    if [[ $placement == pinned-isolated ]]; then
      [[ $(note_of "$r" decide_cpus_allowed) == 3 && $(note_of "$r" decide_cpu_start) -eq 3 && $(note_of "$r" decide_cpu_end) -eq 3 ]] ||
        die "pinned r$rep: the decide thread is not confined to guest CPU 3 ($(note_of "$r" decide_cpus_allowed))"
    fi
  done
done
ok "every run: count $COUNT, dropped 0, no overflow, every divert command received, pinned thread confined to CPU 3"

inv_of() { jget "$VMDIR/r$1-$2/java-agrona-spsc.json" .runtime.ctx_switches.involuntary; }
vol_of() { jget "$VMDIR/r$1-$2/java-agrona-spsc.json" .runtime.ctx_switches.voluntary; }
p999_of() { jget "$VMDIR/r$1-$2/java-agrona-spsc-handoff-steady.json" .percentiles.p99_9; }
p99_of() { jget "$VMDIR/r$1-$2/java-agrona-spsc-handoff-steady.json" .percentiles.p99; }
p50_of() { jget "$VMDIR/r$1-$2/java-agrona-spsc-handoff-steady.json" .percentiles.p50; }

echo "  per run (guest, label vm): decide-thread involuntary / voluntary ctx switches; hand-off p50 / p99 / p99.9 ns, steady window"
for ((rep = 1; rep <= REPS; rep++)); do
  for placement in "${PLACEMENTS[@]}"; do
    echo "    r$rep $placement: $(inv_of "$rep" "$placement") / $(vol_of "$rep" "$placement");" \
      "$(p50_of "$rep" "$placement") / $(p99_of "$rep" "$placement") / $(p999_of "$rep" "$placement")"
  done
done

step "criteria 1: decide-thread involuntary context switches per run"
for ((rep = 1; rep <= REPS; rep++)); do
  expect_le "$(inv_of "$rep" pinned-isolated)" 10 "1: r$rep pinned-isolated involuntary ctx switches <= 10"
  expect_ge "$(inv_of "$rep" unpinned)" 100 "1: r$rep unpinned involuntary ctx switches >= 100"
done

step "criteria 2: hand-off p99.9, steady window (median of $REPS alternations, same boot)"
unp=() pin=()
for ((rep = 1; rep <= REPS; rep++)); do
  unp+=("$(p999_of "$rep" unpinned)")
  pin+=("$(p999_of "$rep" pinned-isolated)")
done
unp_med=$(median_ns "${unp[@]}")
pin_med=$(median_ns "${pin[@]}")
expect_ge "$unp_med" $((2 * pin_med)) "2: pinned-isolated hand-off p99.9 ($pin_med ns) <= 1/2 of unpinned ($unp_med ns)"

((FAILURES == 0)) || die "$FAILURES criteria not met; results in $VMDIR"
ok "07-offheap-lockfree (VM): pinning to the isolated CPU holds the decide thread's tail; results in $VMDIR, label vm (never compare with host numbers)"
jq -r '"profile: \(.host_label) virt=\(.virt.type) kernel=\(.kernel.release) tuned=\(.tuned)"' "$VMDIR/profile.json"
