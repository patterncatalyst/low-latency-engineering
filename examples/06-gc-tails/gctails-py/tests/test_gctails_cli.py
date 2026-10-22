import pytest
from lowlat_gctails.cli import VARIANTS, build_parser


def test_defaults_name_the_example_and_port():
    args = build_parser().parse_args([])
    assert args.example == "06-gc-tails"
    assert args.bind == ("127.0.0.1", 47261)
    assert args.variant == "cyclic-garbage"


def test_variants_are_the_two_python_lanes():
    assert VARIANTS == ("cyclic-garbage", "frozen")
    with pytest.raises(SystemExit):
        build_parser().parse_args(["--variant", "zgc"])


@pytest.mark.parametrize("flag", ["--live-entries", "--samples", "--rate", "--warmup"])
def test_sizes_must_be_positive(flag, capsys):
    with pytest.raises(SystemExit) as exc:
        build_parser().parse_args([flag, "0"])
    assert exc.value.code == 2
    assert "must be > 0" in capsys.readouterr().err
