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
  diagrams-yml   every _data/diagrams.yml name has both files; every chapter with a
                 _docs/NN-*.md has >= 2 entries
  codetabs       `langs` count equals the number of fenced blocks that follow the tag, and
                 each fence's language matches its label (C++ cpp, Python python, Java java)
  shell-syntax   `bash -n` on every *.sh under scripts/ and examples/ (not .venv/build/target)
  chronicle      a pom.xml depending on net.openhft chronicle-* passes
                 -Dchronicle.analytics.disable=true to surefire (argLine) and to exec;
                 a Java source naming net.openhft.chronicle disables analytics itself
  means          "mean latency"/"average latency" fail (unless the sentence negates it);
                 every other use of mean/average in _docs is printed for review
  no-jfr         no *.jfr file is tracked by git (the JFR evidence is the text summaries)
  java-flags     every Java run report of chapters 5-8 under results/r02-* has a non-empty
                 build.flags (the -gc-pause reports derived from a JFR are exempt)
  vm-runs        every results/*vm-run*/ has vm/LABEL = vm, and every report and profile in
                 it records profile.virt.type = kvm
  prerelease     no EA/prerelease version in a pom.xml (dependency, plugin, parent, *.version
                 property), pyproject.toml, uv.lock, versions.env or CMake pin
  variant-names  a variant, option or slug is named for its defect (--naive, --unwarmed),
                 never honest/lie/lies/lying/cheat: verify.sh arrays, "--option" strings in
                 sources, result file names, report `variant` fields

    python3 scripts/validate.py --self-test   plants a bad case for each new check
                                              in a temporary tree and requires it to fail
"""

import json
import re
import subprocess
import sys
import tempfile
import tomllib
import xml.dom.minidom
import xml.parsers.expat
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit(
        "PyYAML is required: python3 -m pip install pyyaml, or "
        "uv run --project examples --with pyyaml python scripts/validate.py"
    )

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
    print(f"front matter: {sum(len(v) for v in pages.values())} files in {', '.join(COLLECTIONS)}")

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
    chapters = sorted({int(p.name[:2]) for p in (ROOT / "_docs").glob("[0-9][0-9]-*.md")})
    check_diagram_counts(chapters, list(by_name))
    print(f"figures: {len(by_name)} entries in _data/diagrams.yml")


def check_diagram_counts(chapters: list[int], names: list[str]) -> None:
    """Every chapter that has a page needs >= 2 diagrams (names start with the chapter number)."""
    for n in chapters:
        count = sum(1 for name in names if name.startswith(f"{n:02d}-"))
        if count < 2:
            fail(
                "diagrams-yml",
                f"chapter {n} has {count} entries in _data/diagrams.yml, need >= 2",
            )


# ---------------------------------------------------------------- codetabs
CODETABS = re.compile(r'\{%-?\s*include\s+codetabs\.html\s+langs="([^"]*)"\s*-?%\}')
FENCE = re.compile(r"^(\s*)(```+|~~~+)\s*([^\s`]*)")
TAB_LANG = {"C++": {"cpp", "c++"}, "Python": {"python", "py"}, "Java": {"java"}}


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
            labels = m.group(1).split("|")
            got, j = 0, i + 1
            while j < len(lines):
                if not lines[j].strip():
                    j += 1
                    continue
                fence = FENCE.match(lines[j])
                if not fence:
                    break
                got += 1
                if got <= len(labels):
                    label, lang = labels[got - 1], fence.group(3).lower()
                    if lang not in TAB_LANG.get(label, {label.lower()}):
                        fail(
                            "codetabs",
                            f"{rel(path)}:{j + 1}: tab {got} is labelled {label!r} "
                            f"but its fence is ```{lang}",
                        )
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
SKIP_DIRS = {".claude", "_site", ".venv", "build", "target", "node_modules", ".git", "__pycache__"}


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


# ---------------------------------------------------------------- chronicle analytics
# Chronicle Queue and Map post usage analytics (Google Analytics 4) unless the system
# property chronicle.analytics.disable is "true" when the first queue or map is built.
ANALYTICS_FLAG = "-Dchronicle.analytics.disable=true"
XML_COMMENT = re.compile(r"<!--.*?-->", re.S)
JAVA_COMMENT = re.compile(r"/\*.*?\*/|(?<![:\"])//[^\n]*", re.S)
DEP_MGMT = re.compile(r"<dependencyManagement>.*?</dependencyManagement>", re.S)
CHRONICLE_DEP = re.compile(r"<artifactId>\s*chronicle-[a-z-]+\s*</artifactId>")
ARG_LINE = re.compile(r"<argLine>[^<]*" + re.escape(ANALYTICS_FLAG))
EXEC_ARG = re.compile(r"<argument>\s*" + re.escape(ANALYTICS_FLAG) + r"\s*</argument>")
JAVA_GUARD = ("ChronicleAnalytics.disable(", "chronicle.analytics.disable")


def check_chronicle() -> None:
    poms = javas = 0
    for p in sorted(ROOT.rglob("pom.xml")):
        if SKIP_DIRS & set(p.relative_to(ROOT).parts):
            continue
        text = XML_COMMENT.sub("", p.read_text(encoding="utf-8"))
        if not CHRONICLE_DEP.search(DEP_MGMT.sub("", text)):
            continue
        poms += 1
        if not ARG_LINE.search(text):
            fail("chronicle", f"{rel(p)}: surefire <argLine> lacks {ANALYTICS_FLAG}")
        if "exec-maven-plugin" in text and not EXEC_ARG.search(text):
            fail("chronicle", f"{rel(p)}: exec <argument> lacks {ANALYTICS_FLAG}")
    for p in sorted(ROOT.rglob("*.java")):
        if SKIP_DIRS & set(p.relative_to(ROOT).parts):
            continue
        raw = p.read_text(encoding="utf-8")
        if "net.openhft.chronicle" not in JAVA_COMMENT.sub("", raw):
            continue
        javas += 1
        if not any(g in raw for g in JAVA_GUARD):
            fail(
                "chronicle",
                f"{rel(p)}: names net.openhft.chronicle but never calls "
                "ChronicleAnalytics.disable() or sets chronicle.analytics.disable",
            )
    print(f"chronicle: {poms} pom(s), {javas} source file(s) checked")


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


# ---------------------------------------------------------------- r02 repository checks
# These take the tree root so --self-test can run them on a temporary tree.
def relto(root: Path, p: Path) -> str:
    return str(p.relative_to(root))


def tracked_files(root: Path) -> list[str]:
    """Paths git tracks under root; without a repository, every file below it."""
    res = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True)
    if res.returncode == 0:
        return res.stdout.splitlines()
    return [relto(root, p) for p in root.rglob("*") if p.is_file()]


def walk(root: Path, pattern: str):
    """rglob that skips build, venv and VCS directories."""
    for p in sorted(root.rglob(pattern)):
        if p.is_file() and not SKIP_DIRS & set(p.relative_to(root).parts):
            yield p


def load_report(path: Path) -> dict | None:
    """The parsed JSON when path is a lowlat-report (schema lowlat-report/N), else None."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError, OSError:
        return None
    if isinstance(data, dict) and str(data.get("schema", "")).startswith("lowlat-report/"):
        return data
    return None


def check_no_jfr(root: Path) -> None:
    jfr = [f for f in tracked_files(root) if f.endswith(".jfr")]
    for f in jfr:
        fail("no-jfr", f"{f}: a JFR recording is tracked; commit its jfr summary text instead")
    print(f"no-jfr: {len(jfr)} tracked *.jfr")


FLAGS_FROM_CHAPTER = 5  # chapters 1-4 predate build.flags


def check_java_flags(root: Path) -> None:
    n = 0
    for path in walk(root / "examples", "*.json"):
        parts = path.relative_to(root / "examples").parts
        if len(parts) < 4 or parts[1] != "results" or not parts[2].startswith("r02-"):
            continue
        if not (parts[0][:2].isdigit() and int(parts[0][:2]) >= FLAGS_FROM_CHAPTER):
            continue
        report = load_report(path)
        if report is None or report.get("language") != "java":
            continue
        if str(report.get("variant", "")).endswith("-gc-pause"):
            continue  # pauses derived from the run's JFR; the run report has the flags
        n += 1
        if not str((report.get("build") or {}).get("flags") or "").strip():
            fail("java-flags", f"{relto(root, path)}: Java report has no build.flags")
    print(f"java-flags: {n} Java report(s) in chapters {FLAGS_FROM_CHAPTER}-8")


def check_vm_runs(root: Path) -> None:
    runs = 0
    for run in sorted((root / "examples").glob("*/results/*vm-run*")):
        if not run.is_dir():
            continue
        runs += 1
        label = run / "vm" / "LABEL"
        if not label.is_file():
            fail("vm-runs", f"{relto(root, run)}: no vm/LABEL")
        elif label.read_text(encoding="utf-8").strip() != "vm":
            fail("vm-runs", f"{relto(root, label)}: LABEL is not 'vm'")
        for path in walk(run, "*.json"):
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except ValueError:
                continue
            prof = data.get("profile", data) if isinstance(data, dict) else None
            if not isinstance(prof, dict) or str(prof.get("schema", "")) != "lowlat-profile/1":
                continue
            virt = (prof.get("virt") or {}).get("type")
            if virt != "kvm":
                fail("vm-runs", f"{relto(root, path)}: profile.virt.type is {virt!r}, need 'kvm'")
    print(f"vm-runs: {runs} vm-run director(ies)")


# A version is a prerelease when a separator or digit is followed by one of these words.
PRERELEASE = re.compile(
    r"(?i)(?:^|[-._+]|(?<=\d))(?:ea|snapshot|alpha|beta|rc|preview|early-access|milestone|dev|"
    r"jep\d+(?:ea)?|m)(?:\d*)(?=$|[-._+])|\d(?:a|b|rc)\d+(?:$|[-._+])|-ea\b"
)


def is_prerelease(version: str) -> bool:
    return bool(PRERELEASE.search(version.strip()))


def pom_versions(text: str) -> list[tuple[str, str]]:
    """(where, version) for every dependency, plugin, parent and *.version property."""
    out: list[tuple[str, str]] = []
    doc = xml.dom.minidom.parseString(text)

    def child_text(node, tag: str) -> str | None:
        for c in node.childNodes:
            if c.nodeType == c.ELEMENT_NODE and c.tagName == tag:
                return "".join(t.data for t in c.childNodes if t.nodeType == t.TEXT_NODE).strip()
        return None

    for tag in ("dependency", "plugin", "parent", "extension"):
        for node in doc.getElementsByTagName(tag):
            v = child_text(node, "version")
            if tag == "parent" and child_text(node, "groupId") == "io.patterncatalyst.lowlat":
                continue  # the book's own aggregator, versioned 1.0.0-SNAPSHOT
            if v and not v.startswith("${"):
                out.append((f"{child_text(node, 'artifactId') or tag}", v))
    for props in doc.getElementsByTagName("properties"):
        for c in props.childNodes:
            if c.nodeType == c.ELEMENT_NODE and c.tagName.endswith("version"):
                v = "".join(t.data for t in c.childNodes if t.nodeType == t.TEXT_NODE).strip()
                if v:
                    out.append((c.tagName, v))
    return out


def check_prerelease(root: Path) -> None:
    n = 0

    def bad(path: Path, where: str, version: str) -> None:
        fail(
            "prerelease", f"{relto(root, path)}: {where} = {version!r} is an EA/prerelease version"
        )

    for path in walk(root, "pom.xml"):
        n += 1
        try:
            versions = pom_versions(path.read_text(encoding="utf-8"))
        except xml.parsers.expat.ExpatError as e:
            fail("prerelease", f"{relto(root, path)}: not well-formed XML ({e})")
            continue
        for where, v in versions:
            if is_prerelease(v):
                bad(path, where, v)
    for path in walk(root, "pyproject.toml"):
        n += 1
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as e:
            fail("prerelease", f"{relto(root, path)}: invalid TOML ({e})")
            continue
        specs = list(data.get("project", {}).get("dependencies", []))
        for group in data.get("dependency-groups", {}).values():
            specs += [g for g in group if isinstance(g, str)]
        for spec in specs:
            for v in re.findall(r"(?:==|>=|<=|~=|===|!=|<|>)\s*([^\s,;]+)", spec):
                if is_prerelease(v):
                    bad(path, spec, v)
    for path in walk(root, "uv.lock"):
        n += 1
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as e:
            fail("prerelease", f"{relto(root, path)}: invalid TOML ({e})")
            continue
        for pkg in data.get("package", []):
            v = pkg.get("version", "")
            if v and is_prerelease(v):
                bad(path, pkg.get("name", "?"), v)
    for path in walk(root, "versions.env"):
        n += 1
        for line in path.read_text(encoding="utf-8").splitlines():
            m = re.match(r'\s*([A-Z0-9_]+_(?:VERSION|TAG|BUILD))="?([^"\s#]*)', line)
            if m and is_prerelease(m.group(2)):
                bad(path, m.group(1), m.group(2))
    for path in [*walk(root, "CMakeLists.txt"), *walk(root, "*.cmake")]:
        n += 1
        text = re.sub(r"(?m)#.*$", "", path.read_text(encoding="utf-8"))
        pins = re.findall(r"\bGIT_TAG\s+([^\s)]+)", text)
        pins += re.findall(r"\bURL\s+\S*?/(?:tags|download)/([^/\s)]+)", text)
        pins += re.findall(r"\bfind_package\(\s*\w+\s+(\d[\w.]*)", text)
        pins += re.findall(r"(?i)\bset\(\w*_VERSION\s+\"?([^\s\")]+)", text)
        for v in pins:
            if "$" not in v and is_prerelease(v):
                bad(path, "pin", v)
    print(f"prerelease: {n} version file(s)")


BANNED_WORD = {"honest", "honestly", "lie", "lies", "lying", "cheat", "cheats", "cheating"}


def banned_name(name: str) -> str | None:
    """The banned word when a hyphen/underscore/dot-separated name contains one."""
    for part in re.split(r"[-_.\s]+", name.lower()):
        if part in BANNED_WORD:
            return part
    return None


SRC_SUFFIXES = {".java", ".py", ".cpp", ".hpp", ".cc", ".h", ".sh"}
OPTION = re.compile(r"""["'](--[A-Za-z0-9][\w-]*)""")
SH_OPTION = re.compile(r"(?<![\w-])(--[A-Za-z0-9][\w-]*)")
VARIANT_ARRAY = re.compile(r"^\s*[A-Z_]*VARIANTS=\(([^)]*)\)", re.M)


def check_variant_names(root: Path) -> None:
    n = 0

    def bad(where: str, name: str, word: str) -> None:
        fail(
            "variant-names",
            f"{where}: {name!r} uses {word!r}; name a variant for its defect "
            "(--naive, --unwarmed), not for a moral",
        )

    for path in walk(root / "examples", "*"):
        rp = relto(root, path)
        if path.suffix == ".json" and "results" in path.parts:
            n += 1
            if w := banned_name(path.stem):
                bad(rp, path.name, w)
            report = load_report(path)
            if report and (w := banned_name(str(report.get("variant", "")))):
                bad(rp, f"variant {report['variant']}", w)
        elif path.suffix in SRC_SUFFIXES:
            n += 1
            text = path.read_text(encoding="utf-8", errors="replace")
            opts = set(OPTION.findall(text))
            if path.suffix == ".sh":
                opts |= set(SH_OPTION.findall(text))
                for arr in VARIANT_ARRAY.findall(text):
                    for name in arr.split():
                        if w := banned_name(name.strip("\"'")):
                            bad(rp, name, w)
            for o in sorted(opts):
                if w := banned_name(o):
                    bad(rp, o, w)
    print(f"variant-names: {n} source and report file(s)")


# ---------------------------------------------------------------- self-test
GOOD_REPORT = {
    "schema": "lowlat-report/1",
    "example": "05-jvm-costs",
    "language": "java",
    "variant": "naive",
    "build": {"compiler": "OpenJDK 25.0.5", "flags": "-Xmx1g"},
    "profile": {"schema": "lowlat-profile/1", "virt": {"type": "none"}},
}


def put(root: Path, rel_path: str, content: str | dict) -> None:
    p = root / rel_path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content if isinstance(content, str) else json.dumps(content), encoding="utf-8")


def planted(tree: dict[str, str | dict], check, git: bool = False) -> list[str]:
    """Run `check` on a temporary tree holding `tree`; return the failures it raised."""
    global failures
    saved, failures = failures, []
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, content in tree.items():
                put(root, name, content)
            if git:
                subprocess.run(["git", "-C", tmp, "init", "-q"], check=True)
                subprocess.run(["git", "-C", tmp, "add", "-A"], check=True)
            check(root)
        return failures
    finally:
        failures = saved


def self_test() -> int:
    global failures
    r = "examples/05-jvm-costs/results/r02-run1/java-naive.json"
    vm = "examples/07-offheap-lockfree/results/r02-vm-run1"
    vm_report = {**GOOD_REPORT, "profile": {"schema": "lowlat-profile/1", "virt": {"type": "kvm"}}}
    pom = (
        "<project><dependencies><dependency><artifactId>x</artifactId><version>{}</version>"
        "</dependency></dependencies></project>"
    )
    cases: list[tuple[str, dict, object, bool, str]] = [
        # (name, tree, check, git, substring the failure must contain; "" = must pass)
        (
            "no-jfr bad",
            {"examples/05-jvm-costs/results/r02-run1/a.jfr": "x"},
            check_no_jfr,
            True,
            "a.jfr",
        ),
        ("no-jfr good", {"examples/a.txt": "x"}, check_no_jfr, True, ""),
        (
            "java-flags bad",
            {r: {**GOOD_REPORT, "build": {"compiler": "c", "flags": ""}}},
            check_java_flags,
            False,
            "no build.flags",
        ),
        (
            "java-flags missing",
            {r: {**GOOD_REPORT, "build": {"compiler": "c"}}},
            check_java_flags,
            False,
            "no build.flags",
        ),
        ("java-flags good", {r: GOOD_REPORT}, check_java_flags, False, ""),
        (
            "vm-runs no LABEL",
            {f"{vm}/vm/profile.json": vm_report["profile"]},
            check_vm_runs,
            False,
            "no vm/LABEL",
        ),
        ("vm-runs wrong LABEL", {f"{vm}/vm/LABEL": "lab\n"}, check_vm_runs, False, "LABEL is not"),
        (
            "vm-runs not kvm",
            {f"{vm}/vm/LABEL": "vm\n", f"{vm}/vm/r1/j.json": GOOD_REPORT},
            check_vm_runs,
            False,
            "need 'kvm'",
        ),
        (
            "vm-runs good",
            {f"{vm}/vm/LABEL": "vm\n", f"{vm}/vm/r1/j.json": vm_report},
            check_vm_runs,
            False,
            "",
        ),
        (
            "prerelease pom ea",
            {"examples/pom.xml": pom.format("26-ea+3")},
            check_prerelease,
            False,
            "prerelease version",
        ),
        (
            "prerelease pom snapshot dep",
            {"examples/pom.xml": pom.format("1.2.0-SNAPSHOT")},
            check_prerelease,
            False,
            "SNAPSHOT",
        ),
        (
            "prerelease pom rc property",
            {
                "examples/pom.xml": (
                    "<project><properties><x.version>3.0.0-RC1</x.version></properties></project>"
                )
            },
            check_prerelease,
            False,
            "RC1",
        ),
        (
            "prerelease pom good",
            {
                "examples/pom.xml": pom.format("2.7.0").replace(
                    "<project>", "<project><version>1.0.0-SNAPSHOT</version>"
                )
            },
            check_prerelease,
            False,
            "",
        ),
        (
            "prerelease pyproject",
            {"examples/pyproject.toml": '[project]\nname="x"\ndependencies=["foo==2.0.0rc1"]\n'},
            check_prerelease,
            False,
            "2.0.0rc1",
        ),
        (
            "prerelease uv.lock",
            {"examples/uv.lock": '[[package]]\nname = "foo"\nversion = "1.0.0b2"\n'},
            check_prerelease,
            False,
            "1.0.0b2",
        ),
        (
            "prerelease versions.env",
            {"versions.env": 'JEP_VERSION="26-jep401ea"\n'},
            check_prerelease,
            False,
            "jep401ea",
        ),
        (
            "prerelease cmake",
            {"examples/CMakeLists.txt": "FetchContent_Declare(x\n  GIT_TAG v1.0-beta2)\n"},
            check_prerelease,
            False,
            "beta2",
        ),
        (
            "prerelease good",
            {
                "versions.env": (
                    'TEMURIN_VERSION="25.0.5"\nTEMURIN_BUILD="25.0.5+8"\n# X_VERSION="1-ea"\n'
                ),
                "examples/uv.lock": '[[package]]\nname = "foo"\nversion = "2026.1"\n',
            },
            check_prerelease,
            False,
            "",
        ),
        (
            "variant option",
            {"examples/05-jvm-costs/java/A.java": 'String o = "--honest";\n'},
            check_variant_names,
            False,
            "--honest",
        ),
        (
            "variant verify.sh array",
            {"examples/05-jvm-costs/verify.sh": "JAVA_VARIANTS=(naive lie-detector)\n"},
            check_variant_names,
            False,
            "lie-detector",
        ),
        (
            "variant report field",
            {
                "examples/05-jvm-costs/results/r02-run1/x.json": {
                    **GOOD_REPORT,
                    "variant": "cheating-cache",
                }
            },
            check_variant_names,
            False,
            "cheating",
        ),
        (
            "variant file slug",
            {"examples/05-jvm-costs/results/r02-run1/java-lies.json": "{}"},
            check_variant_names,
            False,
            "lies",
        ),
        (
            "variant good",
            {
                "examples/05-jvm-costs/verify.sh": "V=(naive)\nrun --unwarmed --client x\n",
                "examples/05-jvm-costs/java/A.java": 'String o = "--unwarmed", c = "--client";\n',
            },
            check_variant_names,
            False,
            "",
        ),
    ]
    bad = 0
    # The page-level checks take parsed pages / names, not a root.
    tabs = '{% include codetabs.html langs="C++|Java" %}\n\n```java\na\n```\n```cpp\nb\n```\n'
    page = {"_docs": {ROOT / "_docs" / "x.md": ({}, tabs)}}
    page_ok = {
        "_docs": {
            ROOT / "_docs" / "x.md": (
                {},
                tabs.replace("```java", "~~~X").replace("cpp", "java").replace("~~~X", "```cpp"),
            )
        }
    }
    for name, run, want in [
        (
            "codetabs wrong order",
            lambda: check_codetabs(page),
            "labelled 'C++' but its fence is ```java",
        ),
        ("codetabs right order", lambda: check_codetabs(page_ok), ""),
        (
            "diagrams-yml chapter 7 has one",
            lambda: check_diagram_counts([7], ["07-a", "08-a", "08-b"]),
            "chapter 7 has 1",
        ),
        ("diagrams-yml all have two", lambda: check_diagram_counts([7], ["07-a", "07-b"]), ""),
    ]:
        saved, failures = failures, []
        run()
        got, failures = failures, saved
        ok = any(want in f for f in got) if want else not got
        print(f"{'ok  ' if ok else 'BAD '} {name}: {got[0].splitlines()[0] if got else 'passes'}")
        bad += not ok
    for name, tree, check, git, want in cases:
        got = planted(tree, check, git)
        if want:
            ok = any(want in f for f in got)
            shown = got[0].splitlines()[0] if got else "no failure raised"
        else:
            ok, shown = not got, (got[0] if got else "passes")
        print(f"{'ok  ' if ok else 'BAD '} {name}: {shown}")
        bad += not ok
    total = len(cases) + 4
    print(f"\nself-test: {total - bad}/{total} cases behave")
    return 1 if bad else 0


# ---------------------------------------------------------------- result
def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    pages = check_front_matter()
    check_liquid(pages)
    check_figures(pages)
    check_codetabs(pages)
    check_shell_syntax()
    check_chronicle()
    check_means(pages)
    check_no_jfr(ROOT)
    check_java_flags(ROOT)
    check_vm_runs(ROOT)
    check_prerelease(ROOT)
    check_variant_names(ROOT)
    if failures:
        print()
        print("\n".join(failures))
        print(f"\n{len(failures)} check(s) failed")
        return 1
    print("\nvalidate: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
