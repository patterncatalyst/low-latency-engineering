"""End to end: the real C++ simulator at 1 kHz for 2 s into the consumer."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

EXAMPLES = Path(__file__).resolve().parents[5]
SIM = EXAMPLES / "build/release/common/line-simulator/line-simulator"


@pytest.mark.skipif(
    not SIM.is_file(), reason=f"simulator not built: {SIM} (cmake --preset release)"
)
@pytest.mark.usefixtures("lowlat_profile")
def test_simulator_into_consumer(tmp_path, bound_port):
    report = tmp_path / "r.json"
    cmd = [
        sys.executable,
        "-m",
        "lowlat_consumer",
        "--bind",
        "127.0.0.1:0",
        "--expect",
        "2000",
        "--report",
        str(report),
    ]
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True) as consumer:
        try:
            banner = consumer.stdout.readline()
            assert banner.startswith("line-consumer-py: bound")  # socket is up
            port = bound_port(banner)
            subprocess.run(
                [
                    str(SIM),
                    "--rate",
                    "1000",
                    "--duration",
                    "2",
                    "--quiet",
                    "--dest",
                    f"127.0.0.1:{port}",
                ],
                check=True,
                timeout=30,
            )
            out, _ = consumer.communicate(timeout=30)
        finally:
            if consumer.poll() is None:
                consumer.kill()
    # exit 0 proves no negative latency (the consumer aborts with 2 otherwise)
    assert consumer.returncode == 0, out
    data = json.loads(report.read_text(encoding="utf-8"))
    assert data["count"] == 2000
    assert data["dropped"] == 0
    assert data["percentiles"]["p50"] > 0
