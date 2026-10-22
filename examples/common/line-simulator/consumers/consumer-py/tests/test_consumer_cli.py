import argparse

import pytest
from lowlat_consumer.cli import build_parser, positive_int


@pytest.mark.parametrize("text, value", [("1", 1), ("4194304", 4194304)])
def test_positive_int_accepts(text, value):
    assert positive_int(text) == value


@pytest.mark.parametrize("text", ["0", "-5", "abc", "1.5", ""])
def test_positive_int_rejects(text):
    with pytest.raises(argparse.ArgumentTypeError):
        positive_int(text)


@pytest.mark.parametrize("flag", ["--rcvbuf", "--expect", "--idle-timeout-ms"])
def test_parser_rejects_non_positive(flag, capsys):
    with pytest.raises(SystemExit) as exc:
        build_parser().parse_args([flag, "0"])
    assert exc.value.code == 2
    assert "must be > 0" in capsys.readouterr().err
