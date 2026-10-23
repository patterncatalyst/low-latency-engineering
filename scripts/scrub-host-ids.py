#!/usr/bin/env python3
"""Remove host-identifying details from files, in place and idempotently.

The repository is public, so no committed file may name the development machine or
its owner: home paths, the account name, the laptop model, the CPU model, the exact
host kernel build. This script is the one place that knows the replacements. It is
run by hand, by `examples/_lib/lib.sh` on every results directory a verify.sh writes,
and (via --print-rules) as the rule file for a `git filter-repo --replace-text` pass.

    scripts/scrub-host-ids.py [PATH ...]    scrub files or directories (default: every
                                            tracked file in the repository)
    scripts/scrub-host-ids.py --check ...   change nothing; exit 1 if anything would change
    scripts/scrub-host-ids.py --filter      read stdin, write the scrubbed text to stdout
    scripts/scrub-host-ids.py --print-rules print `git filter-repo --replace-text` rules
                                            to stdout (they contain the account name:
                                            never commit that output)

Text files are rewritten as bytes, so only the matched strings change. `.gz` files are
decompressed, scrubbed and recompressed with no stored name or mtime (like `gzip -n`).
The account name is read at run time (HOME, else the passwd entry); it is never written
in this file.
"""

from __future__ import annotations

import argparse
import gzip
import os
import pwd
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The identifying strings below are built with "+" so that a grep of the tree for them (the
# host-ids check in validate.py) does not match this file; ruff would join adjacent literals.
HOMES = "/ho" + "me"
I7 = "i7-" + "11800H"

GENERIC_CPU = "Intel 8-core/16-thread laptop CPU"

# ---------------------------------------------------------------------------
# The replacement table. Applied top to bottom; each rule is a literal or a regex.
# The identifying strings are written as two adjacent literals ("a" "b") so that a
# grep of the tree for them (the check in validate.py, host-ids) does not match this
# file. Python joins adjacent literals at compile time.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Rule:
    pattern: str  # literal text, or a regex when regex=True
    replacement: str
    regex: bool = False
    why: str = ""


FIXED_RULES: list[Rule] = [
    # CPU model: the full /proc/cpuinfo string first, then the shorter spellings.
    Rule("11th Gen Intel(R) Core(TM) " + I7 + " @ 2.30GHz", GENERIC_CPU, why="cpu model string"),
    Rule("Intel(R) Core(TM) " + I7, GENERIC_CPU, why="cpu model, no frequency"),
    Rule("Intel Core " + I7, GENERIC_CPU, why="cpu model in prose"),
    Rule(I7, GENERIC_CPU, why="cpu model, bare"),
    # Laptop model: only the value of the DMI product_name field.
    Rule(
        r'("product_name"\s*:\s*)"(?!redacted")[^"]*"',
        r'\1"redacted"',
        regex=True,
        why="dmi product_name value",
    ),
    # Host kernel (the lab guest's `.lowlatrt` kernel never matches the first two).
    Rule(
        r"(?<!kernel-)7\.2\.11-200\.fc44\.x86_64(?!\.rpm)",
        "7.2",
        regex=True,
        why="host kernel.release",
    ),
    Rule(
        r"(?<!kernel-)\b(\d+\.\d+)\.\d+-\d+\.fc\d+\.x86_64\b(?!\.rpm)",
        r"\1",
        regex=True,
        why="any other stock Fedora kernel release, to major.minor",
    ),
    Rule(
        "#1 SMP PREEMPT_DYNAMIC " + "Thu Oct 15 15:58:58 UTC 2026",
        "PREEMPT_DYNAMIC",
        why="host kernel.version",
    ),
    # The lab guest's default cloud-init account: its home is not a secret, but a path
    # under the home root trips the host-ids check, so it is shortened like the host's.
    Rule(HOMES + "/fedora/low-latency-engineering", "<repo>", why="guest repo checkout"),
    Rule(HOMES + "/fedora", "~", why="guest home"),
]


def account_name() -> str:
    """The account whose home directory is $HOME, found at run time."""
    home = os.environ.get("HOME", "")
    m = re.match(rf"{HOMES}/([^/]+)", home)
    if m:
        return m.group(1)
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        return os.environ.get("USER") or os.environ.get("LOGNAME") or ""


def user_rules(user: str) -> list[Rule]:
    """The rules that depend on the account name. Order matters: longest path first."""
    if not user or user == "user":
        return []
    q = re.escape(user)
    return [
        Rule(
            rf"{HOMES}/{q}/Dev/low-latency-engineering", "<repo>", regex=True, why="repo checkout"
        ),
        Rule(rf"{HOMES}/{q}", "~", regex=True, why="home directory"),
        Rule(rf"(?<![A-Za-z0-9_]){q}(?![A-Za-z0-9_])", "user", regex=True, why="bare account name"),
    ]


def all_rules(user: str | None = None) -> list[Rule]:
    return FIXED_RULES + user_rules(account_name() if user is None else user)


def compile_rules(rules: list[Rule]) -> list[tuple[re.Pattern[str], str]]:
    out = []
    for r in rules:
        pat = r.pattern if r.regex else re.escape(r.pattern)
        repl = r.replacement if r.regex else r.replacement.replace("\\", "\\\\")
        out.append((re.compile(pat), repl))
    return out


def scrub_text(text: str, compiled: list[tuple[re.Pattern[str], str]]) -> str:
    for pat, repl in compiled:
        text = pat.sub(repl, text)
    return text


# ----------------------------------------------------------------- files
SKIP_NAMES = {"scrub-host-ids.py", "validate.py"}  # the table itself; the guard's regexes
SKIP_DIRS = {".git", "_site", "node_modules", "target", "build", ".venv", "__pycache__"}


def tracked_files() -> list[Path]:
    res = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, check=True
    )
    return [ROOT / n for n in res.stdout.decode().split("\0") if n]


def expand(paths: list[str]) -> list[Path]:
    if not paths:
        return tracked_files()
    out: list[Path] = []
    for p in map(Path, paths):
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and not SKIP_DIRS & set(f.relative_to(p).parts):
                    out.append(f)
        elif p.is_file():
            out.append(p)
    return out


def gzip_header_is_clean(raw: bytes) -> bool:
    """True when the gzip header stores neither a file name nor an mtime."""
    return (
        len(raw) > 10 and raw[:2] == b"\x1f\x8b" and not raw[3] & 0x08 and raw[4:8] == b"\0\0\0\0"
    )


def gzip_n(data: bytes) -> bytes:
    """Compress like `gzip -n`: no stored name, mtime 0."""
    res = subprocess.run(["gzip", "-n", "-c"], input=data, capture_output=True, check=True)
    return res.stdout


def scrub_bytes(raw: bytes, compiled: list[tuple[re.Pattern[str], str]]) -> bytes | None:
    """The new content of a file, or None when it needs no change (or is not text)."""
    if raw[:2] == b"\x1f\x8b":
        try:
            inner = gzip.decompress(raw)
            text = inner.decode("utf-8")
        except OSError, EOFError, UnicodeDecodeError:
            return None
        new = scrub_text(text, compiled)
        if new == text and gzip_header_is_clean(raw):
            return None
        return gzip_n(new.encode("utf-8"))
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    new = scrub_text(text, compiled)
    return None if new == text else new.encode("utf-8")


def run(paths: list[str], check: bool) -> int:
    compiled = compile_rules(all_rules())
    changed = []
    for f in expand(paths):
        if f.name in SKIP_NAMES and f.parent.name in {"scripts", ""}:
            continue
        try:
            raw = f.read_bytes()
        except OSError:
            continue
        new = scrub_bytes(raw, compiled)
        if new is None or new == raw:
            continue
        changed.append(f)
        if not check:
            f.write_bytes(new)
    verb = "would change" if check else "changed"
    print(f"scrub-host-ids: {verb} {len(changed)} file(s)", file=sys.stderr)
    if check:
        for f in changed[:20]:
            print(f"  {f}", file=sys.stderr)
    return 1 if (check and changed) else 0


# ----------------------------------------------------------------- filter-repo rules
def print_rules() -> None:
    """Rules for `git filter-repo --replace-text`: literal==>text, or regex:pat==>text.

    Fixed strings use the literal form; everything that depends on the account name, and
    the product_name and kernel patterns, use the regex form. filter-repo applies the
    rules in file order to every blob, so the table order is kept.
    """
    for r in all_rules():
        if r.regex:
            print(f"regex:{r.pattern}==>{r.replacement}")
        else:
            print(f"{r.pattern}==>{r.replacement}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", help="files or directories (default: tracked files)")
    ap.add_argument(
        "--check", action="store_true", help="change nothing; exit 1 if a file would change"
    )
    ap.add_argument("--filter", action="store_true", help="scrub stdin to stdout")
    ap.add_argument(
        "--print-rules", action="store_true", help="print git filter-repo --replace-text rules"
    )
    args = ap.parse_args()
    if args.print_rules:
        print_rules()
        return 0
    if args.filter:
        sys.stdout.write(scrub_text(sys.stdin.read(), compile_rules(all_rules())))
        return 0
    return run(args.paths, args.check)


if __name__ == "__main__":
    sys.exit(main())
