#!/usr/bin/env python3
"""validate.py - static checks for the Jekyll site, the figures and the scripts.

Standard library plus PyYAML. Run from anywhere:

    python3 scripts/validate.py
    uv run --project examples --with pyyaml python scripts/validate.py   # no system PyYAML

Checks (exit 1 on any failure, each failure printed as "FAIL <check>: <detail>"):
  front-matter   _docs/_parts/_plans/_example_pages front matter parses; a
                 description holding ": " is quoted
  parts          every chapter's `part:` equals a _parts `part_name`
  liquid         no stray {{ or {% in _docs outside include tags, {{ ... | relative_url }}
                 and {% raw %} blocks
  figures        every excalidraw include has assets/diagrams/X.svg (well-formed XML)
                 and X.excalidraw (valid JSON); alt and caption equal _data/diagrams.yml
  diagrams-yml   every _data/diagrams.yml name has both files; chapters 0-4 have >= 2 entries
  codetabs       `langs` count equals the number of fenced blocks that follow the tag
  shell-syntax   `bash -n` on every *.sh under scripts/ and examples/ (not .venv/build/target)
  means          "mean latency"/"average latency" fail (unless the sentence negates it);
                 every other use of mean/average in _docs is printed for review
"""
import json
import re
import subprocess
import sys
import xml.dom.minidom
import xml.parsers.expat
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: python3 -m pip install pyyaml, or "
             "uv run --project examples --with pyyaml python scripts/validate.py")

ROOT = Path(__file__).resolve().parent.parent
DIAGRAMS_DIR = ROOT / "assets" / "diagrams"
COLLECTIONS = ["_docs", "_parts", "_plans", "_example_pages"]
failures: list[str] = []

type Pages = dict[str, dict[Path, tuple[dict, str]]]


def fail(check: str, detail: str) -> None:
    failures.append(f"FAIL {check}: {detail}")


def rel(p: Path) -> str:
    return str(p.relative_to(ROOT))


def split_front_matter(text: str) -> tuple[str | None, str]:
    """Return (front matter text, body); front matter is None when absent."""
    if not text.startswith("---"):
        return None, text
    parts = text.split("\n---", 1)
    if len(parts) < 2:
        return None, text
    head = parts[0][3:]
    body = parts[1].split("\n", 1)[1] if "\n" in parts[1] else ""
    return head, body


def load_front_matter(path: Path) -> tuple[dict, str, str]:
    text = path.read_text(encoding="utf-8")
    head, body = split_front_matter(text)
    if head is None:
        fail("front-matter", f"{rel(path)}: no front matter")
        return {}, "", text
    try:
        data = yaml.safe_load(head) or {}
    except yaml.YAMLError as exc:
        fail("front-matter", f"{rel(path)}: {str(exc).splitlines()[0]}")
        return {}, head, body
    if not isinstance(data, dict):
        fail("front-matter", f"{rel(path)}: front matter is not a mapping")
        return {}, head, body
    for line in head.splitlines():
        m = re.match(r"(description|title):\s*(.+)$", line)
        if m and ": " in m.group(2) and m.group(2)[0] not in "\"'":
            fail("front-matter", f"{rel(path)}: unquoted {m.group(1)} contains a colon")
    return data, head, body


def check_figure_files(name: str, where: str) -> None:
    svg, exc = DIAGRAMS_DIR / f"{name}.svg", DIAGRAMS_DIR / f"{name}.excalidraw"
    if not svg.is_file():
        fail("figures", f"{where}: missing {rel(svg)}")
    else:
        try:
            xml.dom.minidom.parse(str(svg))
        except (xml.parsers.expat.ExpatError, OSError) as e:
            fail("figures", f"{rel(svg)}: not well-formed XML ({e})")
    if not exc.is_file():
        fail("figures", f"{where}: missing {rel(exc)}")
    else:
        try:
            json.loads(exc.read_text(encoding="utf-8"))
        except ValueError as e:
            fail("figures", f"{rel(exc)}: invalid JSON ({e})")


# ---------------------------------------------------------------- front matter, parts
def check_front_matter() -> Pages:
    pages: Pages = {}
    for coll in COLLECTIONS:
        pages[coll] = {}
        for path in sorted((ROOT / coll).glob("*.md")):
            data, _head, body = load_front_matter(path)
            pages[coll][path] = (data, body)
    print(
        f"front matter: {sum(len(v) for v in pages.values())} files in {', '.join(COLLECTIONS)}"
    )

    part_names = {d.get("part_name") for d, _ in pages["_parts"].values()}
    for path, (data, _body) in pages["_docs"].items():
        part = data.get("part")
        if part is None:
            fail("parts", f"{rel(path)}: no part:")
        elif part not in part_names:
            fail("parts", f"{rel(path)}: part {part!r} matches no _parts part_name")
    for path, (data, _body) in pages["_example_pages"].items():
        for key in ("card_eyebrow", "card_title", "card_blurb", "order", "permalink"):
            if key not in data:
                fail("front-matter", f"{rel(path)}: missing {key}")
    return pages


# ---------------------------------------------------------------- liquid hygiene
RAW = re.compile(r"\{%-?\s*raw\s*-?%\}.*?\{%-?\s*endraw\s*-?%\}", re.S)
INCLUDE = re.compile(r"\{%-?\s*include\s+.*?%\}", re.S)
REL_URL = re.compile(r"\{\{\s*'[^']*'\s*\|\s*relative_url\s*\}\}")


def check_liquid(pages: Pages) -> None:
    for path, (_data, body) in pages["_docs"].items():
        cleaned = RAW.sub("", body)
        cleaned = INCLUDE.sub("", cleaned)
        cleaned = REL_URL.sub("", cleaned)
        for lineno, line in enumerate(cleaned.splitlines(), 1):
            if "{{" in line or "{%" in line:
                fail(
                    "liquid",
                    f"{rel(path)}: stray Liquid near cleaned line {lineno}: {line.strip()[:80]}",
                )


# ---------------------------------------------------------------- figures
EXCALIDRAW_INCLUDE = re.compile(r"\{%-?\s*include\s+excalidraw\.html\s+(.*?)-?%\}", re.S)
ATTR = re.compile(r'(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"')


def check_figures(pages: Pages) -> None:
    yml_path = ROOT / "_data" / "diagrams.yml"
    entries = yaml.safe_load(yml_path.read_text(encoding="utf-8")) or []
    by_name = {e["name"]: e for e in entries}
    if len(by_name) != len(entries):
        fail("diagrams-yml", "duplicate name in _data/diagrams.yml")

    for path, (_data, body) in pages["_docs"].items():
        for m in EXCALIDRAW_INCLUDE.finditer(RAW.sub("", body)):
            attrs = dict(ATTR.findall(m.group(1)))
            name = attrs.get("file")
            if not name:
                fail("figures", f"{rel(path)}: excalidraw include without file=")
                continue
            check_figure_files(name, rel(path))
            entry = by_name.get(name)
            if entry is None:
                fail("figures", f"{rel(path)}: {name} is not in _data/diagrams.yml")
                continue
            for key in ("alt", "caption"):
                if attrs.get(key) != entry.get(key):
                    fail(
                        "figures",
                        f"{rel(path)}: {name} {key} differs from _data/diagrams.yml\n"
                        f"    chapter: {attrs.get(key)!r}\n    yaml:    {entry.get(key)!r}",
                    )

    for name in by_name:
        check_figure_files(name, "_data/diagrams.yml")
    for n in range(5):
        count = sum(1 for name in by_name if name.startswith(f"{n:02d}-"))
        if count < 2:
            fail(
                "diagrams-yml",
                f"chapter {n} has {count} entries in _data/diagrams.yml, need >= 2",
            )
    print(f"figures: {len(by_name)} entries in _data/diagrams.yml")


# ---------------------------------------------------------------- codetabs
CODETABS = re.compile(r'\{%-?\s*include\s+codetabs\.html\s+langs="([^"]*)"\s*-?%\}')
FENCE = re.compile(r"^(\s*)(```+|~~~+)")


def check_codetabs(pages: Pages) -> None:
    ntabs = 0
    for path, (_data, body) in pages["_docs"].items():
        lines = body.splitlines()
        for i, line in enumerate(lines):
            m = CODETABS.search(line)
            if not m:
                continue
            ntabs += 1
            want = len(m.group(1).split("|"))
            got, j = 0, i + 1
            while j < len(lines):
                if not lines[j].strip():
                    j += 1
                    continue
                fence = FENCE.match(lines[j])
                if not fence:
                    break
                got += 1
                marker = fence.group(2)
                j += 1
                while j < len(lines) and not lines[j].lstrip().startswith(marker):
                    j += 1
                j += 1
            if got != want:
                fail(
                    "codetabs",
                    f"{rel(path)}:{i + 1}: langs lists {want}, {got} fenced block(s) follow",
                )
    print(f"codetabs: {ntabs} groups")


# ---------------------------------------------------------------- shell syntax
SKIP_DIRS = {".venv", "build", "target", "node_modules", ".git", "__pycache__"}


def check_shell_syntax() -> None:
    sh_files = [
        p
        for top in ("scripts", "examples")
        for p in sorted((ROOT / top).rglob("*.sh"))
        if not SKIP_DIRS & set(p.relative_to(ROOT).parts)
    ]
    for p in sh_files:
        res = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
        if res.returncode:
            detail = res.stderr.strip().splitlines()[0] if res.stderr else "bash -n failed"
            fail("shell-syntax", f"{rel(p)}: {detail}")
    print(f"shell-syntax: {len(sh_files)} scripts")


# ---------------------------------------------------------------- no mean latency
BAD_MEAN = re.compile(r"\b(mean|average|avg)\s+(latenc(?:y|ies)|response\s+time)", re.I)
# "never quotes a mean latency"
NEGATED = re.compile(r"\b(never|not|no|nor|without|n't|none)\b", re.I)
MEAN = re.compile(r"\b(mean|means|average|averages|avg)\b", re.I)


def check_means(pages: Pages) -> None:
    review: list[str] = []
    for path, (_data, body) in pages["_docs"].items():
        for lineno, line in enumerate(body.splitlines(), 1):
            bad = BAD_MEAN.search(line)
            if bad and not NEGATED.search(line[: bad.start()].rsplit(". ", 1)[-1]):
                fail("means", f"{rel(path)}:{lineno}: {line.strip()[:100]}")
            elif m := MEAN.search(line):
                review.append(f"{rel(path)}: {m.group(0)!r} {line.strip()[:110]}")
    if review:
        print(
            f"means: {len(review)} line(s) use mean/average; "
            "review each is a labelled model input or not a latency:"
        )
        for r in review:
            print(f"  {r}")


# ---------------------------------------------------------------- result
def main() -> int:
    pages = check_front_matter()
    check_liquid(pages)
    check_figures(pages)
    check_codetabs(pages)
    check_shell_syntax()
    check_means(pages)
    if failures:
        print()
        print("\n".join(failures))
        print(f"\n{len(failures)} check(s) failed")
        return 1
    print("\nvalidate: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
