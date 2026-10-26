"""vm/timerlat-summary.awk: `rtla timerlat hist` output reduced to a line per column.

The sample below follows the layout the rtla documentation shows (header, `Index IRQ-nnn
Thr-nnn`, non-empty bucket rows, the `over:`, `count:`, `min:`, `avg:` and `max:` rows). It is a
stand-in until the first guest run; the awk script finds columns by name, so a different column
order or an added `Usr-nnn` column is read the same way.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

AWK = Path(__file__).resolve().parents[1] / "vm" / "timerlat-summary.awk"

SAMPLE = """# RTLA timerlat histogram
# Time unit is microseconds (us)
# Duration:   0 00:02:00
Index   IRQ-003   Thr-003
0              0         0
1              5         0
2             90         0
3            800         2
4            100         7
5              4        40
10             1       900
48             0        49
over:          0         2
count:      1000      1000
min:           1         3
avg:           3         9
max:          10        48
"""


def summarise(text: str, tmp_path: Path) -> dict[str, dict[str, str]]:
    src = tmp_path / "rtla.out"
    src.write_text(text, encoding="utf-8")
    done = subprocess.run(
        ["awk", "-f", str(AWK), str(src)], capture_output=True, text=True, check=False
    )
    assert done.returncode == 0, done.stderr
    return {
        line.split()[0]: dict(f.split("=") for f in line.split()[1:])
        for line in done.stdout.splitlines()
    }


pytestmark = pytest.mark.skipif(shutil.which("awk") is None, reason="awk is not installed")


def test_irq_and_thread_columns(tmp_path: Path) -> None:
    got = summarise(SAMPLE, tmp_path)
    # IRQ: 1000 samples; rank 500 is in bucket 3 (cumulative 5+90+800), rank 990 in
    # bucket 4 (995), rank 999 in bucket 5 (999).
    assert got["irq"] == {
        "count": "1000",
        "over": "0",
        "min": "1",
        "max": "10",
        "p50": "3",
        "p99": "4",
        "p99_9": "5",
    }
    # Thread: rank 500 is in bucket 10 (cumulative 949), rank 990 in bucket 48 (998), rank 999
    # beyond the buckets (over holds 2).
    assert got["thread"]["p50"] == "10"
    assert got["thread"]["p99"] == "48"
    assert got["thread"]["p99_9"] == "over"
    assert got["thread"]["over"] == "2"


def test_no_average_is_printed(tmp_path: Path) -> None:
    src = tmp_path / "rtla.out"
    src.write_text(SAMPLE, encoding="utf-8")
    done = subprocess.run(
        ["awk", "-f", str(AWK), str(src)], capture_output=True, text=True, check=False
    )
    assert "avg" not in done.stdout and "mean" not in done.stdout


def test_user_column_is_named(tmp_path: Path) -> None:
    text = SAMPLE.replace("IRQ-003   Thr-003", "IRQ-003   Thr-003   Usr-003")
    text = "\n".join(
        line + "  0"
        if line[:1].isdigit() or line.startswith(("over:", "count:", "min:", "avg:", "max:"))
        else line
        for line in text.splitlines()
    )
    assert set(summarise(text, tmp_path)) == {"irq", "thread", "user"}


def test_input_without_a_histogram_fails(tmp_path: Path) -> None:
    src = tmp_path / "rtla.out"
    src.write_text("rtla: no such tracer\n", encoding="utf-8")
    done = subprocess.run(
        ["awk", "-f", str(AWK), str(src)], capture_output=True, text=True, check=False
    )
    assert done.returncode == 1
