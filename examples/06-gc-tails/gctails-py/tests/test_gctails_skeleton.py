"""Wiring proof: the package imports, its entry point runs and the workspace kits resolve."""

import lowlat_consumer  # noqa: F401  (workspace dependency resolves)
import lowlat_measure  # noqa: F401
from lowlat_gctails import cli


def test_entry_point_runs(capsys):
    assert cli.main() == 0
    assert "gc-tails-py" in capsys.readouterr().out
