"""Convert cyclictest output to ``lowlat-report/1`` reports, one per measurement thread.

Input is the pair a run writes with ``--json=FILE --histfile=FILE`` (rt-tests v2.11). The
histogram file is the source of every number: ``print_hist`` writes a ``# Histogram`` header,
one row per non-empty bucket (``%06d`` bucket index, then the per-thread counts separated by a
tab, plus a sum column with ``--histofall``) and the trailer lines ``# Min Latencies:``,
``# Avg Latencies:``, ``# Max Latencies:`` and ``# Histogram Overflows:`` with one value per
thread. A bucket is one unit wide: 1 us, or 1 ns with ``-N``. The counts are loaded into the
lowlat recorder (value = bucket x unit, in ns), so percentiles come from HdrHistogram like every
other report (five significant digits, so 1 us buckets stay distinct to about 134 ms).

What is deliberately left out:

* cyclictest's average. The ``avg`` of the JSON and the ``# Avg Latencies:`` trailer are never
  read, and nothing average-like is written.
* ``sysinfo.nodename`` (the guest hostname) and the raw command line. ``sysinfo.realtime`` is
  ignored too: it reads 0 on a PREEMPT_RT kernel, so the kernel check uses the profile.

Samples beyond the histogram's range (``-h US``) are counted, not binned, so their values are
unknown beyond the thread's maximum. An overflow fails the conversion unless ``allow_overflow``
is set; then each overflowed sample is recorded at that maximum (the tail percentiles become
upper bounds, the max stays exact) and the overflow is in ``runtime.counters.overflows`` and the
notes. A run whose JSON and histfile disagree (cycles, the JSON's own histogram, ``return_code``)
is refused.

The clock comes from the ``cmdline:`` value of the JSON. rt-tests v2.11 uses CLOCK_REALTIME when
``-c`` is absent (its help text says monotonic), so absent means ``realtime``.
"""

import getopt
import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from lowlat_measure.recorder import Recorder
from lowlat_measure.runtime import environment, runtime_block

# getopt_long() arguments of cyclictest v2.11 (process_options). Python's getopt has no optional
# arguments, so "a::A::t::" are listed as flags here and _normalise() removes their values.
_SHORT = "b:c:d:D:F:h:H:i:l:MNo:p:mqrRsSuvxaAt"
_SHORT_OPTIONAL = frozenset("aAt")
_SHORT_WITH_ARG = frozenset("bcdDFhHilop")
_LONG_NO_ARG = (
    "default-system laptop mlockall refresh_on_max nsecs quiet priospread relative resolution "
    "system smi smp tracemark unbuffered verbose dbg_cyclictest help posix_timers"
).split()
_LONG_WITH_ARG = (
    "breaktrace clock distance duration latency fifo histogram histofall histfile interval json "
    "loops mainaffinity oscope priority policy spike spike-nodes deepest-idle-state"
).split()
_LONG_OPTIONAL = ("affinity", "aligned", "secaligned", "threads")
_LONG_ALL = (*_LONG_NO_ARG, *_LONG_WITH_ARG, *_LONG_OPTIONAL)
_CLOCKS = {"0": "monotonic", "monotonic": "monotonic", "1": "realtime", "realtime": "realtime"}
# cyclictest takes a --policy value starting with one of these names; any other means "other".
_POLICIES = ("other", "batch", "idle", "fifo", "rr")
LANGUAGE = "cpp"  # cyclictest is C; the schema's language enum has no "c"
# 1 us buckets stay distinct in HdrHistogram up to about 134 ms with five significant digits
# (three, the kit default, merge neighbouring buckets from about 1 ms).
SIGNIFICANT_DIGITS = 5
_HIST_ROW = re.compile(r"^\d+(\s|$)")


@dataclass(frozen=True)
class CmdLine:
    """What a report needs from the cyclictest command line, after cyclictest's own rules."""

    clock: str  # "monotonic", "realtime" or "aux<N>"
    policy: str  # of the highest-priority thread
    priority: int  # of thread 0; each later thread is one lower with ``priospread``
    nsecs: bool
    priospread: bool


@dataclass(frozen=True)
class Histogram:
    """Per-thread bucket counts and trailer values of a ``--histfile``."""

    buckets: list[dict[int, int]]  # per thread: bucket index -> count
    maxima: list[int]
    overflows: list[int]


def _normalise(tokens: list[str]) -> list[str]:
    """Drop the attached value of an optional-argument option (Python's getopt has none).

    ``-a2,3``, ``-t4`` and ``--affinity=2`` become ``-a``, ``-t`` and ``--affinity``; the rest of
    a short cluster before the optional letter is kept (``-mt4`` is ``-m -t``).
    """
    out = []
    for token in tokens:
        if token.startswith("--"):
            name, eq, _ = token[2:].partition("=")
            matches = [n for n in _LONG_ALL if n == name] or [
                n for n in _LONG_ALL if n.startswith(name)
            ]
            if eq and len(matches) == 1 and matches[0] in _LONG_OPTIONAL:
                token = f"--{name}"
        elif token.startswith("-") and len(token) > 2:
            for pos, letter in enumerate(token[1:], start=1):
                if letter in _SHORT_WITH_ARG:
                    break
                if letter in _SHORT_OPTIONAL:
                    token = token[: pos + 1]
                    break
        out.append(token)
    return out


def parse_cmdline(cmdline: str, threads: int) -> CmdLine:
    """Clock, policy, priority and ``-N`` from the ``cmdline:`` string, as cyclictest sees them.

    Options are read with ``getopt.gnu_getopt`` and cyclictest v2.11's option tables, so long
    options may be abbreviated. Later options win. Then v2.11's rules apply (``process_options``):
    ``-p`` makes the policy FIFO unless it is FIFO or RR already, and any non-zero priority forces
    FIFO afterwards (``-p95 --policy=other`` runs FIFO 95); a FIFO or RR policy with priority 0
    (no ``-p``, or ``-p 0``) runs at ``threads + 1``, and so does ``--priospread`` with priority 0.
    An unrecognised policy name means ``other``. ``threads`` is the run's thread count (``-S``
    makes it the CPU count, which only the JSON knows).
    """
    longs = [f"{n}=" if n in _LONG_WITH_ARG else n for n in _LONG_ALL]
    try:
        options, _ = getopt.gnu_getopt(_normalise(cmdline.split()[1:]), _SHORT, longs)
    except getopt.GetoptError as exc:
        raise ValueError(f"cmdline: {exc}") from exc
    clock, policy, priority, nsecs, spread = "realtime", "other", 0, False, False
    for opt, value in options:
        name = {"-c": "--clock", "-p": "--priority"}.get(opt, opt)
        if name in ("-N", "--nsecs"):
            nsecs = True
        elif name == "--priospread":
            spread = True
        elif name == "--clock":
            if value in _CLOCKS:
                clock = _CLOCKS[value]
            elif re.fullmatch(r"aux[0-7]", value):
                clock = value
            else:
                raise ValueError(f"cmdline: unknown clock {value!r}")
        elif name == "--priority":
            priority = int(value)
            if policy not in ("fifo", "rr"):
                policy = "fifo"
        elif name == "--policy":
            policy = next((p for p in _POLICIES if value.lower().startswith(p)), "other")
    if not 0 <= priority <= 99:
        raise ValueError(f"cmdline: priority {priority} is outside 0-99")
    if spread and priority == 0:
        priority = threads + 1
    if priority and policy not in ("fifo", "rr"):
        policy = "fifo"
    if policy in ("fifo", "rr") and priority == 0:
        priority = threads + 1
    return CmdLine(clock, policy, priority, nsecs, spread)


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

    Raises ``ValueError`` on a failed run (``return_code``), on an overflow (unless
    ``allow_overflow``), on an empty thread and on input that contradicts itself (units, thread
    count, sample counts, the JSON's own histogram, the maximum).

    An overflowed sample has no bucket; it is recorded at the thread's ``# Max Latencies:``
    value, so the report's count equals the cycles and its max is exact. The tail percentiles
    then read as upper bounds, and the notes say so.
    """
    if result.get("return_code", 0) != 0:
        raise ValueError(f"json: cyclictest return_code {result['return_code']}")
    threads = sorted(result["thread"].items(), key=lambda item: int(item[0]))
    cmd = parse_cmdline(str(result.get("cmdline:", "")), len(threads))
    if "resolution_in_ns" in result and bool(result["resolution_in_ns"]) != cmd.nsecs:
        raise ValueError("json: resolution_in_ns disagrees with -N in cmdline:")
    unit = 1 if cmd.nsecs else 1000  # ns per bucket
    unit_name = "ns" if cmd.nsecs else "us"
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
        if (
            "histogram" in thread
            and {int(k): int(v) for k, v in thread["histogram"].items()} != bins
        ):
            raise ValueError(f"thread {thread_id}: json histogram differs from the histfile")
        binned, overflows, cycles = sum(bins.values()), hist.overflows[slot], int(thread["cycles"])
        if binned + overflows != cycles:
            raise ValueError(
                f"thread {thread_id}: histfile holds {binned} binned + {overflows} overflowed "
                f"samples, json says {cycles} cycles"
            )
        top, peak = max(bins), hist.maxima[slot]
        if overflows and peak <= top:
            raise ValueError(
                f"thread {thread_id}: overflowed, but max {peak} is within the buckets"
            )
        if not overflows and peak != top:
            raise ValueError(f"thread {thread_id}: max {peak} but top bucket {top}")
        recorder = Recorder(example, f"{variant}-t{thread_id}", SIGNIFICANT_DIGITS)
        for bucket, count in sorted(bins.items()):
            recorder.record(bucket * unit, count)
        if overflows:
            recorder.record(peak * unit, overflows)
        priority = cmd.priority - slot if cmd.priospread else cmd.priority
        notes = (
            f"cyclictest{f' {version}' if version else ''}, thread {thread_id} on cpu "
            f"{thread['cpu']}; clock {cmd.clock}; policy {cmd.policy if priority else 'other'}, "
            f"priority {priority}; histogram buckets of 1 {unit_name}, reported as the bucket's "
            f"lower edge in ns (cyclictest truncates to whole {unit_name}, so a latency is up "
            f"to 1 {unit_name} above its value; HdrHistogram with {SIGNIFICANT_DIGITS} digits "
            "adds under 0.002% above 131 us)"
        )
        if overflows:
            notes += (
                f"; HISTOGRAM OVERFLOW: {overflows} of {cycles} samples were beyond the -h "
                f"range and are recorded at the maximum, {peak} {unit_name}, so the tail "
                "percentiles are upper bounds; max is exact"
            )
        else:
            notes += f"; max is the worst of {cycles} samples"
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
