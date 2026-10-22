import pytest
from lowlat_latdist.cli import build_parser


def test_slow_us_default():
    assert build_parser().parse_args([]).slow_us == 2000


@pytest.mark.parametrize("value", ["0", "-1"])
def test_slow_us_rejects_non_positive(value, capsys):
    with pytest.raises(SystemExit) as exc:
        build_parser().parse_args(["--slow-us", value])
    assert exc.value.code == 2
    assert "must be > 0" in capsys.readouterr().err
