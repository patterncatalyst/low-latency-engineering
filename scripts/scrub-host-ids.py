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
    scripts/scrub-host-ids.py --self-test   check the container-ID and guest-home rules
    scripts/scrub-host-ids.py --filter      read stdin, write the scrubbed text to stdout
    scripts/scrub-host-ids.py --print-rules print `git filter-repo --replace-text` rules
                                            to stdout (they contain the account name:
                                            never commit that output)

Text files are rewritten as bytes, so only the matched strings change. `.gz` files are
decompressed, scrubbed and recompressed with no stored name or mtime (like `gzip -n`).
The account name is read at run time (HOME, else the passwd entry); it is never written
in this file. The same goes for the lab guest account ($GUEST_USER, else scripts/lab/lab.env,
else the cloud-init user). Container IDs (64-hex and 12-hex) are scrubbed only in container
contexts, so sha256 digests survive.
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

HOMES = "/ho" + "me"  # split only so the host-ids grep does not flag this line

GENERIC_CPU = "Intel 8-core/16-thread laptop CPU"

# ---------------------------------------------------------------------------
# The replacement table, applied top to bottom. It holds only generic patterns: the
# machine's own values (CPU model string, DMI product name, kernel release and build
# line, account name) are read at run time by host_rules() and user_rules(), so no
# identifying string is ever written in this file.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Rule:
    pattern: str  # literal text, or a regex when regex=True
    replacement: str
    regex: bool = False
    why: str = ""


CPU_PART = r"i[3579]-\d{4,5}[A-Z]{0,2}"

FIXED_RULES: list[Rule] = [
    # CPU model: the /proc/cpuinfo spelling first, then the shorter ones.
    Rule(
        rf"(?:\d+(?:st|nd|rd|th) Gen )?Intel\(R\) Core\(TM\) {CPU_PART}(?: (?:CPU )?@ [\d.]+GHz)?",
        GENERIC_CPU,
        regex=True,
        why="cpu model string",
    ),
    Rule(rf"Intel Core {CPU_PART}\b", GENERIC_CPU, regex=True, why="cpu model in prose"),
    Rule(rf"(?<![A-Za-z0-9+/=-]){CPU_PART}\b", GENERIC_CPU, regex=True, why="cpu part, bare"),
    # Laptop model: the value of the DMI product_name field.
    Rule(
        r'("product_name"\s*:\s*)"(?!redacted")[^"]*"',
        r'\1"redacted"',
        regex=True,
        why="dmi product_name value",
    ),
    # Host kernel: any stock Fedora release to major.minor (the lab guest's `.lowlatrt`
    # kernel never matches, and the `kernel-...` SRPM pin is kept).
    Rule(
        r"(?<!kernel-)\b(\d+\.\d+)\.\d+-\d+\.fc\d+\.x86_64\b(?!\.rpm)",
        r"\1",
        regex=True,
        why="stock Fedora kernel release, to major.minor",
    ),
    Rule(
        r"#\d+ SMP PREEMPT_DYNAMIC \w{3} \w{3} +\d{1,2} \d\d:\d\d:\d\d UTC \d{4}",
        "PREEMPT_DYNAMIC",
        regex=True,
        why="host kernel build line",
    ),
    # (The lab guest's home paths are guest_rules(), read from lab.env at run time.)
    # Container IDs (64-hex and 12-hex) only where the context says container: a hostname or
    # container key, a docker/podman/containerd cgroup or storage path, a `docker ps` row, the
    # HOSTNAME environment variable, and a line that is only 64 hex (`docker run -d` stdout).
    # Other bare hex runs are never touched, so `sha256:<64 hex>`
    # digests (image_digest, @sha256: in image references) survive.
    Rule(
        r'("(?:[Hh]ostname|container(?:[_-]?[Ii][Dd])?|ContainerId|Id)"\s*:\s*")[0-9a-f]{12}(?:[0-9a-f]{52})?(")',
        r"\1<container-id>\2",
        regex=True,
        why="container id in a hostname, container or Id key",
    ),
    Rule(
        r"\b(docker|libpod|crio|cri-containerd|containerd)-[0-9a-f]{64}\b",
        r"\1-<container-id>",
        regex=True,
        why="container cgroup scope",
    ),
    Rule(
        r"(/(?:docker|containers|libpod|kubepods[\w./-]*|libpod_parent[\w./-]*))/[0-9a-f]{64}\b",
        r"\1/<container-id>",
        regex=True,
        why="container id in a cgroup or storage path",
    ),
    Rule(
        r"(?m)^[0-9a-f]{12}(?:[0-9a-f]{52})?(?=\s{2,}\S+\s{2,}\"[^\"\n]*\"\s)",
        "<container-id>",
        regex=True,
        why="docker ps row (docker pads its columns with two or more spaces)",
    ),
    Rule(
        r"(?m)^[0-9a-f]{64}(?=\r?$)",
        "<container-id>",
        regex=True,
        why="a line of exactly 64 hex: `docker run -d` stdout",
    ),
    Rule(
        r"\b(HOSTNAME=)[0-9a-f]{12}(?:[0-9a-f]{52})?\b",
        r"\1<container-id>",
        regex=True,
        why="container hostname variable",
    ),
    Rule(
        r"(?i)\b(container[ _-]?id[=: ]+)[0-9a-f]{12}(?:[0-9a-f]{52})?\b",
        r"\1<container-id>",
        regex=True,
        why="container id in prose or key=value",
    ),
]


def _read(path: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def host_rules() -> list[Rule]:
    """Literal rules for this machine's own identifying values, read at run time."""
    rules = []
    for line in _read("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            model = line.split(":", 1)[1].strip()
            if model:
                rules.append(Rule(model, GENERIC_CPU, why="this host's cpu model"))
            break
    product = _read("/sys/class/dmi/id/product_name")
    if len(product) >= 4:
        rules.append(Rule(product, "redacted", why="this host's laptop model"))
    for args, repl in ((["uname", "-v"], "PREEMPT_DYNAMIC"), (["uname", "-r"], None)):
        try:
            out = subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()
        except OSError, subprocess.CalledProcessError:
            continue
        if not out or "lowlatrt" in out or "PREEMPT_RT" in out:
            continue
        if repl is None:
            m = re.match(r"(\d+\.\d+)", out)
            repl = m.group(1) if m else "redacted"
        rules.append(Rule(out, repl, why="this host's kernel"))
    return rules


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


def guest_user() -> str:
    """The lab guest account, read at run time: $GUEST_USER, lab.env or the cloud-init user."""
    env = os.environ.get("GUEST_USER", "").strip()
    if env:
        return env
    sources = [
        (ROOT / "scripts/lab/lab.env", r"GUEST_USER:=([A-Za-z_][\w.-]*)\}"),
        (
            ROOT / "scripts/lab/cloud-init/user-data.tmpl",
            r"^users:\s*\n\s*-\s*name:\s*([A-Za-z_][\w.-]*)",
        ),
    ]
    for path, pat in sources:
        m = re.search(pat, _read(str(path)), re.MULTILINE)
        if m:
            return m.group(1)
    return ""


def guest_rules(user: str) -> list[Rule]:
    """Home paths of the guest account (checkout first), like user_rules for the host account."""
    if not user or user == "user":
        return []
    q = re.escape(user)
    return [
        Rule(
            rf"{HOMES}/{q}/(?:Dev/)?low-latency-engineering",
            "<repo>",
            regex=True,
            why="guest checkout",
        ),
        Rule(rf"{HOMES}/{q}(?![A-Za-z0-9_])", "~", regex=True, why="guest home directory"),
    ]


def all_rules(user: str | None = None) -> list[Rule]:
    return (
        host_rules()
        + FIXED_RULES
        + guest_rules(guest_user())
        + user_rules(account_name() if user is None else user)
    )


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


# ----------------------------------------------------------------- self-test
SELF_TEST_CASES: list[tuple[str, str, str]] = [
    # (name, input, expected output)
    (
        "container id in hostname key",
        '{"hostname": "0123456789ab"}',
        '{"hostname": "<container-id>"}',
    ),
    ("64-hex container key", '"container": "' + "ab" * 32 + '"', '"container": "<container-id>"'),
    ("docker inspect Id", '"Id": "' + "cd" * 32 + '"', '"Id": "<container-id>"'),
    (
        "cgroup scope",
        "/system.slice/docker-" + "ef" * 32 + ".scope",
        "/system.slice/docker-<container-id>.scope",
    ),
    ("cgroup path", "0::/docker/" + "12" * 32 + "\n", "0::/docker/<container-id>\n"),
    (
        "docker ps row",
        '0123456789ab   img:1.0   "/bin/sh"   2 min ago   Up',
        '<container-id>   img:1.0   "/bin/sh"   2 min ago   Up',
    ),
    (
        "docker ps --no-trunc row",
        "ab" * 32 + '   img:1.0   "/bin/sh"   2 min ago   Up',
        '<container-id>   img:1.0   "/bin/sh"   2 min ago   Up',
    ),
    (
        "git log --abbrev=12 survives",
        '0123456789ab  fix "quoted" thing in the parser',
        '0123456789ab  fix "quoted" thing in the parser',
    ),
    ("git log --oneline survives", '0123456789ab feat: x "y" z', '0123456789ab feat: x "y" z'),
    ("HOSTNAME variable", "HOSTNAME=0123456789ab", "HOSTNAME=<container-id>"),
    ("HOSTNAME 64-hex", "HOSTNAME=" + "ab" * 32, "HOSTNAME=<container-id>"),
    ("docker run -d stdout", "ab" * 32 + "\n", "<container-id>\n"),
    ("bare 64-hex mid-line survives", "key " + "ab" * 32 + " end", "key " + "ab" * 32 + " end"),
    ("sha256 on its own line survives", "sha256:" + "ab" * 32 + "\n", "sha256:" + "ab" * 32 + "\n"),
    (
        "sha256 digest survives",
        "image_digest: sha256:" + "ab" * 32,
        "image_digest: sha256:" + "ab" * 32,
    ),
    ("pinned reference survives", "img:1.0@sha256:" + "01" * 32, "img:1.0@sha256:" + "01" * 32),
    (
        "image Id digest survives",
        '"Id": "sha256:' + "ab" * 32 + '"',
        '"Id": "sha256:' + "ab" * 32 + '"',
    ),
    ("bare hex survives", "commit 0123456789ab fixed it", "commit 0123456789ab fixed it"),
]


def self_test() -> int:
    """Check the container-ID and guest-home rules, with a made-up guest account."""
    bad = 0
    compiled = compile_rules(FIXED_RULES + guest_rules("guestacct"))
    cases = SELF_TEST_CASES + [
        ("guest home", HOMES + "/guestacct/notes.txt", "~/notes.txt"),
        ("guest checkout", HOMES + "/guestacct/low-latency-engineering/x", "<repo>/x"),
        ("other home survives", HOMES + "/otheracct/x", HOMES + "/otheracct/x"),
    ]
    for name, text, want in cases:
        got = scrub_text(text, compiled)
        ok = got == want and scrub_text(got, compiled) == got  # expected output, idempotent
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        bad += not ok
    print(f"scrub-host-ids self-test: {len(cases) - bad}/{len(cases)} cases behave")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", help="files or directories (default: tracked files)")
    ap.add_argument(
        "--check", action="store_true", help="change nothing; exit 1 if a file would change"
    )
    ap.add_argument("--filter", action="store_true", help="scrub stdin to stdout")
    ap.add_argument("--self-test", action="store_true", help="check the container and guest rules")
    ap.add_argument(
        "--print-rules", action="store_true", help="print git filter-repo --replace-text rules"
    )
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.print_rules:
        print_rules()
        return 0
    if args.filter:
        sys.stdout.write(scrub_text(sys.stdin.read(), compile_rules(all_rules())))
        return 0
    return run(args.paths, args.check)


if __name__ == "__main__":
    sys.exit(main())
