"""``python -m lowlat_place [--out FILE]``: print or write the CPU-count probe as JSON."""

import argparse
import json
from pathlib import Path

from lowlat_place import probe


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="lowlat_place", description=__doc__)
    parser.add_argument("--out", type=Path, help="write the JSON here instead of printing it")
    args = parser.parse_args(argv)
    text = json.dumps(probe(), indent=2) + "\n"
    if args.out is None:
        print(text, end="")
    else:
        args.out.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
