"""Convert cyclictest output to ``lowlat-report/1`` reports, one per measurement thread.

Input is the pair a run writes with ``--json=FILE --histfile=FILE`` (rt-tests v2.11). The
histogram file is the source of every number: ``print_hist`` writes a ``# Histogram`` header,
one row per non-empty bucket (``%06d`` bucket index, then the per-thread counts separated by a
tab, plus a sum column with ``--histofall``) and the trailer lines ``# Min Latencies:``,
``# Avg Latencies:``, ``# Max Latencies:`` and ``# Histogram Overflows:`` with one value per
thread. A bucket is one unit wide: 1 us, or 1 ns with ``-N``. The counts are loaded into the
lowlat recorder (value = bucket x unit, in ns), so percentiles come from HdrHistogram like every
other report.

What is deliberately left out:

* cyclictest's average. The ``avg`` of the JSON and the ``# Avg Latencies:`` trailer are never
  read, and nothing average-like is written.
* ``sysinfo.nodename`` (the guest hostname) and the raw command line. ``sysinfo.realtime`` is
  ignored too: it reads 0 on a PREEMPT_RT kernel, so the kernel check uses the profile.

Samples beyond the histogram's range (``-h US``) are counted, not binned. They make the
percentiles cover only the binned samples, so an overflow fails the conversion unless
``allow_overflow`` is set, in which case it is recorded in ``runtime.counters.overflows`` and
the notes.

The clock comes from the ``cmdline:`` value of the JSON. rt-tests v2.11 uses CLOCK_REALTIME when
``-c`` is absent (its help text says monotonic), so absent means ``realtime``.
"""

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from lowlat_measure.recorder import Recorder
from lowlat_measure.runtime import environment, runtime_block

# Short options that take an argument (getopt string "a::A::b:c:d:D:F:h:H:i:l:MNo:p:mqrRsSt::uvx").
_SHORT_WITH_ARG = frozenset("bcdDFhHilop")
_SHORT_OPTIONAL_ARG = frozenset("aAt")
# Long options with a required argument (long_options in cyclictest.c).
_LONG_WITH_ARG = frozenset(
    "breaktrace clock distance duration latency fifo histogram histofall histfile interval json "
    "loops mainaffinity oscope priority policy".split()
)
_CLOCKS = {"0": "monotonic", "monotonic": "monotonic", "1": "realtime", "realtime": "realtime"}
_POLICIES = (
    ("other", "other"),
    ("batch", "batch"),
    ("idle", "idle"),
    ("fifo", "fifo"),
    ("rr", "rr"),
)
LANGUAGE = "cpp"  # cyclictest is C; the schema's language enum has no "c"
_HIST_ROW = re.compile(r"^\d+(\s|$)")


@dataclass(frozen=True)
class CmdLine:
    """What a report needs from the cyclictest command line."""

    clock: str  # "monotonic", "realtime" or "aux<N>"
    policy: str
    priority: int
    nsecs: bool


@dataclass(frozen=True)
class Histogram:
    """Per-thread bucket counts and trailer values of a ``--histfile``."""

    buckets: list[dict[int, int]]  # per thread: bucket index -> count
    maxima: list[int]
    overflows: list[int]


def parse_cmdline(cmdline: str) -> CmdLine:
    """Clock, policy, priority and ``-N`` from the ``cmdline:`` string, as getopt would see it.

    Later options win, as in cyclictest. ``-p`` makes the policy FIFO unless it is already FIFO
    or RR; ``--policy`` after it overrides. An unrecognised policy name means ``other``.
    """
    tokens = cmdline.split()[1:]  # drop argv[0]
    clock, policy, priority, nsecs = "realtime", "other", 0, False
    i = 0
    while i < len(tokens):
        token = tokens[i]
        i += 1
        name: str | None = None
        value: str | None = None
        if token.startswith("--") and len(token) > 2:
            name, _, inline = token[2:].partition("=")
            value = inline if "=" in token else None
            if name in _LONG_WITH_ARG and value is None and i < len(tokens):
                value = tokens[i]
                i += 1
            if name == "nsecs":
                nsecs = True
        elif token.startswith("-") and len(token) > 1:
            for pos, letter in enumerate(token[1:], start=1):
                if letter == "N":
                    nsecs = True
                if letter in _SHORT_WITH_ARG:
                    rest = token[pos + 1 :]
                    if rest:
                        value = rest
                    elif i < len(tokens):
                        value = tokens[i]
                        i += 1
                    name = {"c": "clock", "p": "priority"}.get(letter, letter)
                    break
                if letter in _SHORT_OPTIONAL_ARG:
                    break  # an optional argument is only ever attached; the rest is its value
        if name == "clock" and value is not None:
            if value in _CLOCKS:
                clock = _CLOCKS[value]
            elif re.fullmatch(r"aux[0-7]", value):
                clock = value
            else:
                raise ValueError(f"cmdline: unknown clock {value!r}")
        elif name == "priority" and value is not None:
            priority = int(value)
            if policy not in ("fifo", "rr"):
                policy = "fifo"
        elif name == "policy" and value is not None:
            policy = next(
                (p for prefix, p in _POLICIES if value.lower().startswith(prefix)), "other"
            )
    return CmdLine(clock, policy, priority, nsecs)


def parse_histfile(text: str, threads: int) -> Histogram:
    """Bucket counts and the ``# Max Latencies:`` / ``# Histogram Overflows:`` trailers.

    With ``--histofall`` each row and those two trailers carry one extra column for the sum over
    all threads; it is dropped. The ``# Avg Latencies:`` trailer is skipped unread.
    """
    buckets: list[dict[int, int]] = [{} for _ in range(threads)]
    maxima: list[int] | None = None
    overflows: list[int] | None = None
    for line in text.splitlines():
        if line.startswith("#"):
            label, _, values = line[1:].partition(":")
            label = label.strip()
            if label in ("Max Latencies", "Histogram Overflows"):
                numbers = [int(v) for v in values.split()]
                if len(numbers) < threads:
                    raise ValueError(f"histfile: {label} has {len(numbers)} values, not {threads}")
                if label == "Max Latencies":
                    maxima = numbers[:threads]
                else:
                    overflows = numbers[:threads]
        elif _HIST_ROW.match(line):
            index, *counts = line.split()
            if len(counts) < threads:
                raise ValueError(f"histfile: row {index} has {len(counts)} counts, not {threads}")
            for thread, count in enumerate(counts[:threads]):
                if int(count):
                    buckets[thread][int(index)] = int(count)
    if maxima is None or overflows is None:
        raise ValueError("histfile: no '# Max Latencies:' or '# Histogram Overflows:' trailer")
    return Histogram(buckets, maxima, overflows)


def reports_from_cyclictest(
    result: Mapping[str, Any],
    histfile_text: str,
    *,
    example: str,
    variant: str = "cyclictest",
    allow_overflow: bool = False,
    guest_profile: str | None = None,
) -> list[tuple[str, dict[str, Any]]]:
    """``(variant, report)`` per thread: ``<variant>-t<N>``.

    Raises ``ValueError`` on an overflow (unless ``allow_overflow``), on an empty thread and on
    input that contradicts itself (units, thread count, maximum).
    """
    cmd = parse_cmdline(str(result.get("cmdline:", "")))
    if "resolution_in_ns" in result and bool(result["resolution_in_ns"]) != cmd.nsecs:
        raise ValueError("json: resolution_in_ns disagrees with -N in cmdline:")
    unit = 1 if cmd.nsecs else 1000  # ns per bucket
    unit_name = "ns" if cmd.nsecs else "us"
    threads = sorted(result["thread"].items(), key=lambda item: int(item[0]))
    hist = parse_histfile(histfile_text, len(threads))
    if not allow_overflow and any(hist.overflows):
        spots = ", ".join(f"thread {t}: {n}" for t, n in enumerate(hist.overflows) if n)
        raise ValueError(
            f"histogram overflow ({spots}): samples beyond the -h range are not in the "
            "percentiles; rerun with a larger -h, or pass --allow-overflow"
        )
    version = str(result.get("rt_test_version:", "")).strip()
    reports = []
    for slot, (thread_id, thread) in enumerate(threads):
        bins = hist.buckets[slot]
        if not bins:
            raise ValueError(f"thread {thread_id}: the histogram holds no samples")
        recorder = Recorder(example, f"{variant}-t{thread_id}")
        for bucket, count in sorted(bins.items()):
            recorder.record(bucket * unit, count)
        binned, overflows = sum(bins.values()), hist.overflows[slot]
        top = max(bins)
        if not overflows and hist.maxima[slot] != top:
            raise ValueError(f"thread {thread_id}: max {hist.maxima[slot]} but top bucket {top}")
        cycles = int(thread["cycles"])
        notes = (
            f"cyclictest{f' {version}' if version else ''}, thread {thread_id} on cpu "
            f"{thread['cpu']}; clock {cmd.clock}; policy {cmd.policy}, priority {cmd.priority}; "
            f"histogram buckets of 1 {unit_name}, so percentiles resolve to 1 {unit_name}; "
            f"max is the worst of {cycles} samples"
        )
        if overflows:
            notes += (
                f"; HISTOGRAM OVERFLOW: {overflows} samples beyond the -h range (max "
                f"{hist.maxima[slot]} {unit_name}) are not binned, so the percentiles cover "
                f"{binned} of {cycles} samples and max is the top bucket"
            )
        elif binned != cycles:
            notes += f"; {binned} binned against {cycles} cycles"
        env = environment("vm", guest_profile=guest_profile) if guest_profile else None
        report = recorder.build_report(
            notes,
            language=LANGUAGE,
            build={
                "compiler": f"cyclictest (rt-tests {version})" if version else "cyclictest",
                "gil_enabled": None,
            },
            runtime=runtime_block(
                event_counts={"samples": cycles, "overflows": overflows}, env=env
            ),
        )
        reports.append((recorder.variant, report))
    return reports


def convert(
    json_path: Path, histfile: Path, out_dir: Path, *, example: str, **options: Any
) -> list[tuple[Path, dict[str, Any]]]:
    """Read the pair and return ``(path, report)`` per thread; nothing is written."""
    result = json.loads(json_path.read_text(encoding="utf-8"))
    pairs = reports_from_cyclictest(
        result, histfile.read_text(encoding="utf-8"), example=example, **options
    )
    return [(out_dir / f"{variant}.json", report) for variant, report in pairs]
