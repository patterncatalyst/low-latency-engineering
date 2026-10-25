"""`tasks-py measure`: run one Ch11 workload; write raw samples and a sidecar.

Works in any build and imports no lowlat_measure.
"""

import argparse
import sys
from pathlib import Path

from lowlat_tasks import gil_enabled, python_build, sidecar, workloads
from lowlat_tasks.placement import free_threaded_build, parse_cpus


def _require_gil_off(when: str) -> None:
    """A free-threaded measurement is void if the GIL is on: stop instead of writing it."""
    if free_threaded_build() and sys._is_gil_enabled():
        raise SystemExit(f"tasks-py: the free-threaded interpreter has the GIL on {when}")


def _measure(args: argparse.Namespace) -> int:
    _require_gil_off("after its imports")  # the check the free-threaded lane depends on
    gil_at_start = gil_enabled()
    cpus = parse_cpus(args.cpus) if args.cpus else []
    variant = args.variant
    asyncio_variant = variant == "asyncio-tasks"
    if args.workload == "parked":
        run = (
            workloads.parked_asyncio(
                args.tasks, args.wait_ms, cpu=cpus[0] if cpus else -1, hold_ms=args.hold_ms
            )
            if asyncio_variant
            else workloads.parked_threads(args.tasks, args.wait_ms, hold_ms=args.hold_ms)
        )
    elif args.workload == "pingpong":
        if asyncio_variant:
            run = workloads.pingpong_asyncio(
                args.rounds, args.batch, cpu=cpus[0] if cpus else -1, hold_ms=args.hold_ms
            )
        else:
            if cpus and len(cpus) < 2:
                args.parser.error("--cpus needs 2 CPUs for threads")
            run = workloads.pingpong_threads(
                args.rounds, args.batch, cpus=cpus[:2] or None, hold_ms=args.hold_ms
            )
    else:  # neighbours
        if not asyncio_variant:
            args.parser.error("neighbours is measured for asyncio-tasks only")
        run = workloads.neighbours_asyncio(
            args.tasks,
            args.iterations,
            args.period_us,
            blocking=args.blocking_sleep_in_coroutine,
            debug=args.debug,
            cpu=cpus[0] if cpus else -1,
            hold_ms=args.hold_ms,
        )
    _require_gil_off("at the end of the run")
    samples_path, sidecar_path = sidecar.write(
        Path(args.out), run, variant, gil_at_start=gil_at_start
    )
    print(
        f"{args.workload} {variant} [{python_build()}]: {len(run.samples)} samples, "
        f"GIL at start {gil_at_start}, at end {gil_enabled()}"
    )
    for key, value in sorted(run.counters.items()):
        print(f"counter {key}={value}")
    print(f"samples: {samples_path}\nsidecar: {sidecar_path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tasks-py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    m = sub.add_parser("measure", help="run a workload; write raw samples and a sidecar")
    m.add_argument("workload", choices=["parked", "pingpong", "neighbours"])
    m.add_argument("--variant", choices=workloads.VARIANTS, required=True)
    m.add_argument("--tasks", type=int, default=10_000)
    m.add_argument("--wait-ms", type=int, default=1000)
    m.add_argument("--rounds", type=int, default=1_000_000)
    m.add_argument("--batch", type=int, default=1000)
    m.add_argument("--iterations", type=int, default=500)
    m.add_argument("--period-us", type=int, default=2000)
    m.add_argument(
        "--blocking-sleep-in-coroutine",
        action="store_true",
        help="neighbours: task 0 calls time.sleep(2 ms) in its coroutine every tenth iteration",
    )
    m.add_argument(
        "--debug",
        action="store_true",
        help="neighbours: asyncio debug mode, count slow-callback warnings",
    )
    m.add_argument(
        "--cpus", default="", help="CPUs to pin the measured threads to (distinct cores)"
    )
    m.add_argument(
        "--hold-ms", type=int, default=0, help="hold after placement-ready, for a script's check"
    )
    m.add_argument("--out", required=True, help="directory for samples.bin and sidecar.json")
    m.set_defaults(func=_measure, parser=m)
    args = parser.parse_args(argv)
    return args.func(args)
