"""A synthetic results tree for verify.sh: what vm/run.sh would leave behind, built on the host.

No guest is involved. The cyclictest numbers are random but real inputs: histfiles and JSON go
through the converter (``lowlat-report`` library code), so ``verify.sh``'s checks of the reports
and of the recomputation run on genuine converter output. Anything a test wants to break is
changed after ``build_run``.
"""

from __future__ import annotations

import copy
import gzip
import json
import random
from pathlib import Path

from lowlat_measure.cyclictest import reports_from_cyclictest

HERE = Path(__file__).resolve().parent
FIXTURE_PROFILE = HERE.parents[1] / "common" / "measure-fixtures" / "profile.json"
SNAPSHOT = "lab-ready-r05-iso"
PROFILE = f"{SNAPSHOT}/isolated"
LANES = ["naive", "method", "timerlat", "haltpoll-forced", "idle-default"]
SECONDS = {"naive": 10, "method": 300, "timerlat": 120, "haltpoll-forced": 120, "idle-default": 120}
BINARIES = [
    {"name": "cyclic-probe", "sha256": "a" * 64},
    {"name": "guest-run.sh", "sha256": "b" * 64},
    {"name": "profile.sh", "sha256": "c" * 64},
    {"name": "timerlat-summary.awk", "sha256": "d" * 64},
]
CMDLINE = {
    "naive": "cyclictest -D 10 -h 20000 -q",
    "method": "cyclictest -m -p95 --policy=fifo -a3 -i 1000 -D 300 -h 20000 --clock=monotonic -q",
    "haltpoll-forced": (
        "cyclictest -m -p95 --policy=fifo -a3 -i 1000 -D 120 -h 20000 --clock=monotonic"
        " --default-system -q"
    ),
}
CMDLINE["idle-default"] = CMDLINE["haltpoll-forced"]


def write(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")


def histogram(rng: random.Random, n: int, mu: float, sigma: float) -> dict[int, int]:
    counts: dict[int, int] = {}
    for _ in range(n):
        bucket = min(int(rng.lognormvariate(mu, sigma)), 19_999)
        counts[bucket] = counts.get(bucket, 0) + 1
    for bucket in (301, 777, 1500, 5000, 12345):
        counts[bucket] = counts.get(bucket, 0) + 3
    return counts


def hist_text(counts: dict[int, int]) -> str:
    top = max(counts)
    rows = "".join(f"{b:06d} {counts.get(b, 0):06d}\n" for b in range(20_001))
    return (
        f"# Histogram\n{rows}# Min Latencies: {min(counts):05d}\n# Max Latencies: {top:05d}\n"
        "# Histogram Overflows: 00000\n# Histogram Overflow at cycle number:\n# Thread 0: \n"
    )


def tasks(lane: str) -> list[dict]:
    other = {"policy": "SCHED_OTHER", "priority": 0}
    if lane == "naive":
        return [
            {"tid": 10, "comm": "cyclictest", "affinity": "0-3", **other},
            {"tid": 11, "comm": "cyclictest", "affinity": "0-3", **other},
        ]
    fifo = {"policy": "SCHED_FIFO", "priority": 95}
    return [
        {"tid": 10, "comm": "cyclictest", "affinity": "0-3", **other},
        {"tid": 11, "comm": "cyclictest", "affinity": "3", **fifo},
    ]


def build_run(root: Path, alts: int = 3, seed: int = 7, probe_mu: float = 1.8) -> Path:
    """Write a complete results directory under ``root`` and return it."""
    import os

    rng = random.Random(seed)
    profile = json.loads(FIXTURE_PROFILE.read_text(encoding="utf-8"))
    profile["virt"]["type"] = "kvm"
    profile["kernel"].update(
        {"version": "#1 SMP PREEMPT_RT", "sys_isolated": "2-3", "release": "7.2.11-rt"}
    )
    write(root / "profile.json", profile)
    os.environ["LOWLAT_PROFILE"] = str(root / "profile.json")
    write(
        root / "run-start.json",
        {
            "example": "16-cyclictest",
            "mode": "vm",
            "snapshot": SNAPSHOT,
            "guest_profile": PROFILE,
            "reverted": True,
            "rounds": alts,
            "smoke": False,
            "seconds": SECONDS,
            "interval_us": 1000,
            "hist_us": 20000,
            "priority": 95,
            "timerlat_threshold_us": 1000,
        },
    )
    (root / "vm").mkdir(exist_ok=True)
    (root / "vm" / "LABEL").write_text("vm\n", encoding="utf-8")
    (root / "SHA256SUMS").write_text(
        "".join(f"{b['sha256']}  {b['name']}\n" for b in BINARIES), encoding="utf-8"
    )
    for lane in LANES:
        for alt in range(1, alts + 1):
            lane_dir(root / "vm" / lane / f"alt{alt}", lane, alt, rng, profile, probe_mu)
    return root


def lane_dir(
    d: Path, lane: str, alt: int, rng: random.Random, profile: dict, probe_mu: float
) -> None:
    write(d / "profile.json", profile)
    write(d / "lane.json", {"lane": lane, "alt": alt, "snapshot": SNAPSHOT, "binaries": BINARIES})
    driver = "haltpoll" if lane == "haltpoll-forced" else "none"
    states = {"3": {"haltpoll": {"usage": 5, "time_us": 9}}} if driver == "haltpoll" else {}
    after = {"3": {"haltpoll": {"usage": 905, "time_us": 99}}} if driver == "haltpoll" else {}
    write(
        d / "cpuidle.json",
        {
            "before": {"driver": driver, "governor": "menu", "states": states},
            "after": {"driver": driver, "governor": "menu", "states": after},
        },
    )
    write(d / "steal.json", {"steal_ticks": 1, "measure_cpu": 3, "measure_cpu_steal_ticks": 0})
    write(
        d / "vcpupin.json",
        [{"vcpu": 0, "cpus": "0-15"}, {"vcpu": 1, "cpus": "0-15"}]
        + [{"vcpu": 2, "cpus": "12"}, {"vcpu": 3, "cpus": "13"}],
    )
    write(d / "interrupts.json", {"LOC": {"2": 40, "3": 41}})
    write(d / "host-quiet.json", {"host_load1": 0.4})
    if lane == "timerlat":
        write(d / "sched.json", tasks("method"))
        col = {"count": 119_000, "over": 0, "min": 1, "max": 40, "p50": 3, "p99": 9, "p99_9": 27}
        write(
            d / "timerlat.json",
            {
                "irq": col,
                "thread": {**col, "p99": 21, "p99_9": 44, "max": 63},
                "stopped_at_threshold": False,
                "tracefs_fallback_lines": 1,
                "threshold_us": 1000,
            },
        )
        (d / "timerlat.txt").write_text("# RTLA timerlat histogram\n", encoding="utf-8")
        return
    write(d / "sched.json", tasks(lane))
    n = 9_990 if lane == "naive" else (299_940 if lane == "method" else 119_970)
    sigma = 0.6 if lane == "naive" else 0.35
    counts = histogram(rng, n, 1.8, sigma)
    cycles = sum(counts.values())
    text = hist_text(counts)
    meta = {
        "file_version": 1,
        "cmdline:": CMDLINE[lane],
        "rt_test_version:": "2.11",
        "return_code": 0,
        "num_threads": 1,
        "resolution_in_ns": 0,
        "thread": {
            "0": {
                "cycles": cycles,
                "cpu": 1 if lane == "naive" else 3,
                "node": 0,
                "histogram": {str(b): c for b, c in counts.items()},
            }
        },
    }
    write(d / "cyclictest-run.json", meta)
    with gzip.open(d / "cyclictest.hist.gz", "wt", encoding="utf-8") as fh:
        fh.write(text)
    ((_, report),) = reports_from_cyclictest(
        meta, text, example="16-cyclictest", variant="cyclictest", guest_profile=PROFILE
    )
    pins = json.loads((d / "vcpupin.json").read_text(encoding="utf-8"))
    report["runtime"]["environment"]["guest_profile"] = {
        "snapshot": SNAPSHOT,
        "profile": "isolated",
        "vcpupin": pins,
    }
    report["runtime"]["counters"]["interrupts"] = {"LOC": {"2": 40, "3": 41}}
    write(d / "cyclictest.json", report)
    if lane == "method":
        pcounts = histogram(rng, n, probe_mu, sigma)
        pmeta = {**meta, "thread": {"0": {**meta["thread"]["0"], "cycles": sum(pcounts.values())}}}
        pmeta["thread"]["0"]["histogram"] = {str(b): c for b, c in pcounts.items()}
        ((_, probe),) = reports_from_cyclictest(
            pmeta, hist_text(pcounts), example="16-cyclictest", variant="probe"
        )
        probe["runtime"]["counters"] = {"samples": sum(pcounts.values()), "missed_periods": 5}
        probe["runtime"]["environment"] = copy.deepcopy(report["runtime"]["environment"])
        write(d / "cpp" / "cyclic-probe.json", probe)
        probe_task = {"tid": 20, "comm": "cyclic-probe", "policy": "SCHED_FIFO", "priority": 95}
        write(d / "cpp" / "sched.json", [{**probe_task, "affinity": "2"}])
