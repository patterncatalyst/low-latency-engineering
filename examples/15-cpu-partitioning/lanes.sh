# shellcheck shell=bash
# Sourced by verify.sh, vm/run.sh and vm/guest-run.sh, which use these names.
# shellcheck disable=SC2034
# lanes.sh - what verify.sh, vm/run.sh and vm/guest-run.sh agree on: the lanes, the snapshots, the CPU sets, the
# workload sizes and the ports. Source it after examples/_lib/lib.sh.
#
# A lane is a clean snapshot plus a workload (D4: revert before every lane):
#   shared             lab-ready-r05-rt   RT kernel, no isolation; noise on CPUs 0-3
#   isolated           lab-ready-r05-iso  tuned cpu-partitioning (isolated_cores=2-3) + isolcpus=domain,managed_irq,2-3
#                                         irqaffinity=0-1; noise on CPUs 0-1; also the two Java placements and the
#                                         smp_affinity write demo
#   irq-steered        lab-ready-r05-iso  disk I/O submitted from CPUs 0-1, so its completions interrupt CPUs 0-1
#   irq-on-measure-cpu lab-ready-r05-iso  a thread on CPU 3 does the disk I/O, so its completions interrupt CPU 3
#   cache-noise        lab-ready-r05-iso  stress-ng --stream and --cache on CPUs 0-1 (observed)
# Every comparison is inside one run: the lanes alternate, three times (interleave_env).

EXAMPLE=15-cpu-partitioning
LANES=(shared isolated irq-steered irq-on-measure-cpu cache-noise)
ROUNDS=3

# The guest has 4 vCPUs: housekeeping 0-1, isolated 2-3. The decide thread is on CPU 2, cyclictest on CPU 3.
HOUSEKEEPING_SET=0-1
ISOLATED_SET=2-3
DECIDE_CPU=2
MEASURE_CPU=3

SNAPSHOT_SHARED=lab-ready-r05-rt
SNAPSHOT_ISOLATED=lab-ready-r05-iso
PROFILE_SHARED=rt-shared
PROFILE_ISOLATED=isolate-cpu23

# snapshot_of LANE / profile_of LANE / lane_isolated LANE: which snapshot a lane starts from, the profile name its reports
# record, and whether the guest boots with CPUs 2-3 isolated.
snapshot_of() {
  case $1 in
    shared) echo "$SNAPSHOT_SHARED" ;;
    isolated | irq-steered | irq-on-measure-cpu | cache-noise) echo "$SNAPSHOT_ISOLATED" ;;
    *) die "unknown lane '$1'" ;;
  esac
}
profile_of() {
  case $1 in
    shared) echo "$PROFILE_SHARED" ;;
    isolated | irq-steered | irq-on-measure-cpu | cache-noise) echo "$PROFILE_ISOLATED" ;;
    *) die "unknown lane '$1'" ;;
  esac
}
lane_isolated() { [[ $1 != shared ]]; }

# Durations, in seconds. The defaults are the plan's (D13): cyclictest 300 s at 1 ms, the line at 10 kHz x 20 s.
CT_SECONDS=${CT_SECONDS:-300}          # cyclictest, shared / isolated / cache-noise
IRQ_SECONDS=${IRQ_SECONDS:-60}         # cyclictest beside the disk I/O, the IRQ pair (observed latency, exact counts)
TICK_SECONDS=${TICK_SECONDS:-10}       # one busy task on CPU 2, no other load: the LOC count
DECIDE_SECONDS=${DECIDE_SECONDS:-20}   # the busy decide thread on CPU 2 beside the noise: involuntary switches
JAVA_SECONDS=${JAVA_SECONDS:-10}       # each of the two Java placements
NOISE_SAMPLE_SECONDS=${NOISE_SAMPLE_SECONDS:-5}
CT_INTERVAL_US=1000
CT_HIST_US=20000                       # cyclictest -h: the histogram range; a sample beyond it fails the conversion

# The line: four simulator instances (tunnel cameras) at LINE_RATE Hz each = 10 kHz, LINE_SECONDS long; the consumer is the
# Ch12 epoll receiver, restricted to the isolated set. UDP 47410-47413 (r05 owns 47400-47429; 00-13 use 47000-47344).
CAMERAS=4
LINE_RATE=${LINE_RATE:-2500}
LINE_SECONDS=${LINE_SECONDS:-20}
DECIDE_NS=${DECIDE_NS:-3000}
HOLD_MS=${HOLD_MS:-500}
UDP_BASE=47410
line_count() { echo $((LINE_RATE * LINE_SECONDS * CAMERAS)); }

# virtio-blk request-queue IRQs by interrupts_delta's row name (IRQ number, a dash, the last column), e.g. 29-virtio1-req.3.
BLK_IRQ_REGEX='-virtio[0-9]+-req\.[0-9]+$'

GUEST_OUT=examples/$EXAMPLE/vm-out # relative to the repository in the guest, where the guest writes
LANE_BINARIES=(io-receive line-simulator placement-probe cpu-partitioning-java.jar)

# SMOKE=1 is a check of the scripts: short lanes, one alternation, nothing enforced.
if [[ ${SMOKE:-0} == 1 ]]; then
  ROUNDS=1
  CT_SECONDS=10
  IRQ_SECONDS=10
  TICK_SECONDS=3
  DECIDE_SECONDS=3
  JAVA_SECONDS=3
  NOISE_SAMPLE_SECONDS=2
  LINE_SECONDS=2
  HOLD_MS=100
fi

EXAMPLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
