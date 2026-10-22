"""Smoke tests; the measurement itself is verify.sh's job."""

from lowlat_co import experiment
from lowlat_co.cli import build_parser


def test_defaults():
    a = build_parser().parse_args(["run", "--out", "x"])
    assert (a.stall_ms, a.stall_seq, a.expect) == (200, 5000, 10_000)


def test_control_run():
    a = build_parser().parse_args(["run", "--stall-ms", "0", "--suffix=-control", "--out", "x"])
    assert a.stall_ms == 0 and a.suffix == "-control"


def test_correction_backfills_the_stall():
    rec = experiment.Recorders()
    experiment.closed_loop(rec, 300, stall_ms=50, stall_seq=100)
    assert rec.closed_loop_naive.histogram.get_total_count() == 300
    assert rec.closed_loop_corrected.histogram.get_total_count() > 300 + 40


def test_clock_probe_records_every_call():
    probes = experiment.clock_probe(1000)
    assert set(probes) == {"clock-read", "clock-read-perf_counter_ns"}
    assert all(r.histogram.get_total_count() == 1000 for r in probes.values())
