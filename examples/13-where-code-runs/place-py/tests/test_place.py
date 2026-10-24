import json
import os
from pathlib import Path

import pytest
from lowlat_place import __main__ as cli
from lowlat_place import cpu_counts, probe


def test_usable_cpus_do_not_exceed_system_cpus() -> None:
    counts = cpu_counts()
    assert counts["cpu_count"] is not None
    assert counts["process_cpu_count"] is not None
    assert 1 <= counts["process_cpu_count"] <= counts["cpu_count"]


def test_process_cpu_count_follows_the_affinity_mask() -> None:
    counts = cpu_counts()
    assert counts["affinity_count"] == len(os.sched_getaffinity(0))
    assert counts["process_cpu_count"] == counts["affinity_count"]


def test_a_narrowed_mask_shows_in_process_cpu_count_but_not_in_cpu_count() -> None:
    before = os.sched_getaffinity(0)
    one = {min(before)}
    os.sched_setaffinity(0, one)
    try:
        counts = cpu_counts()
        assert counts["process_cpu_count"] == 1
        assert counts["affinity_count"] == 1
        assert counts["cpu_count"] == os.cpu_count()
    finally:
        os.sched_setaffinity(0, before)


def test_probe_names_the_build_and_the_schema() -> None:
    doc = probe()
    assert doc["schema"] == "lowlat-place-probe/1"
    assert doc["language"] == "python"
    py = doc["python"]
    assert isinstance(py, dict)
    assert isinstance(py["gil_enabled"], bool)
    assert isinstance(py["free_threaded_build"], bool)


def test_the_cli_writes_the_probe_to_the_file_named_by_out(tmp_path: Path) -> None:
    out = tmp_path / "python.json"
    assert cli.main(["--out", str(out)]) == 0
    doc = json.loads(out.read_text(encoding="utf-8"))
    assert doc["python"]["affinity_count"] == len(os.sched_getaffinity(0))


def test_the_cli_prints_when_out_is_absent(capsys: pytest.CaptureFixture[str]) -> None:
    assert cli.main([]) == 0
    assert json.loads(capsys.readouterr().out)["language"] == "python"
