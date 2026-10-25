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
                 -Dchronicle.analytics.disable=true to surefire (argLine) and to exec
                 (an <argument> or the <commandlineArgs> string);
                 a Java source naming net.openhft.chronicle disables analytics itself
  listings       every code fence in _docs/NN-*.md that the chapter ties to a source file
                 (a backticked `File.java` in the prose before it, else any file of the
                 fence's language in the chapter's example) reproduces that source: each
                 chunk between `// ...` / `# ...` elision lines is a contiguous run of
                 lines of one candidate file (trailing whitespace ignored)
  means          "mean latency"/"average latency" fail (unless the sentence negates it);
                 every other use of mean/average in _docs is printed for review
  no-jfr         no *.jfr file is tracked by git (the JFR evidence is the text summaries)
  java-flags     every Java run report of chapters 5-13 under results/r0[2-9]-* has a non-empty
                 build.flags (the -gc-pause reports derived from a JFR are exempt)
  hw-source      every report with runtime.hw_counters names a non-empty `source`
  placement      every report with runtime.placement has a non-empty `cpus` list; every
                 report of chapters 9 on under results/r03-* or later carries runtime.placement
                 (pinned threads), except the reports UNPINNED_REPORTS lists as unpinned by design
  no-raw-tool-output
                 no cachegrind.out.* file, jcstress HTML report or *.bin.gz is tracked
                 (the JSON summary and the jcstress text summary are the evidence)
  tool-versions  tools.perf is major.minor (never a kernel build) and tools.valgrind is
                 major.minor[.patch], in every profile.json and every report's profile
  vm-runs        every results/*vm-run*/ has vm/LABEL = vm, and every report and profile in
                 it records profile.virt.type = kvm
  env-labels     every Chapter 13 report under results/r04-* or later (lowlat-report, place-probe,
                 pool, steal) has runtime.environment.kind equal to its lane directory (host/,
                 vm/, container-*/; steal.json is the guest's and the simulator's lateness.json in a
                 container lane may be the guest's); vm and container lanes carry a non-empty
                 guest_profile, a lowlat-report there records profile.virt.type = kvm, and a
                 container report names container.image with an exact tag and an image_digest
                 sha256:<64 hex> equal to containers/IMAGES.lock
  lang-floor     no CMake file, CMakePresets.json or Containerfile names a C++ standard below 23
                 (CMAKE_CXX_STANDARD, cxx_std_NN, -std=c++NN); every pom.xml resolves
                 maven.compiler.release (or the compiler plugin's release, through its parent
                 chain) >= 25; every pyproject.toml requires-python and .python-version are >= 3.14;
                 a Containerfile naming a JDK or a Python names >= 25 / >= 3.14
  image-pins     every Containerfile/Dockerfile FROM (a previous stage or scratch aside) has an
                 exact tag, never latest, and an @sha256:<64 hex> digest; compose and script image
                 references are not parsed
  no-privileged  no --privileged, --cap-add=ALL, seccomp=unconfined or `privileged: true` in a
                 tracked shell script, YAML file (compose, workflows) or Containerfile, outside
                 NO_PRIVILEGED_ALLOW (empty)
  ft-reports     a report whose build.compiler says "free-threading" has runtime.python_build
                 "free-threaded" and build.gil_enabled false; a "free-threaded" report has a
                 free-threading build.compiler; only a notes marker gil_reenabled=PYTHON_GIL=1
                 (a deliberate GIL-on control) is exempt, and FT_KNOWN_MISLABELLED lists the frozen
                 Ch9 r03 reports written before the identity was taken from the binary
  versions-consumers
                 each pin in VERSION_CONSUMERS (Boost, liburing, Quarkus platform, uvloop, protobuf
                 Java/Python, the Chapter 13 toolchain ARGs) appears verbatim in its consumer file
                 (ci.yml may instead source versions.env and name $BOOST_SHA256)
  prerelease     no EA/prerelease version in a pom.xml (dependency, plugin, parent, *.version
                 property), pyproject.toml, uv.lock, versions.env or CMake pin
  variant-names  a variant, option or slug is named for its defect (--naive, --unwarmed),
                 never honest/lie/lies/lying/cheat: verify.sh arrays, "--option" strings in
                 sources, result file names, report `variant` fields
  host-ids       nothing in a tracked file identifies the development machine or its owner:
                 no absolute home-directory path (under /home or /Users), not the runtime
                 account name or hostname (both read at run time, never written), no CPU
                 model number (i3/i5/i7/i9-NNNN, Ryzen N, Xeon), no product_name other than
                 "redacted", no host kernel build number (N.N.N-N.fcNN.x86_64) outside the
                 SRPM pin files
                 (scripts/scrub-host-ids.py rewrites a tree that fails it)

    python3 scripts/validate.py --self-test   plants a bad case for each new check
                                              in a temporary tree and requires it to fail
"""

import fnmatch
import getpass
import gzip
import json
import re
import socket
import subprocess
import sys
import tempfile
import tomllib
import xml.dom.minidom
import xml.parsers.expat
from collections.abc import Callable, Iterator
from pathlib import Path, PurePosixPath

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
            labels = m.group(1).split("|")
            want = len(labels)
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
EXEC_PLUGIN = re.compile(
    r"<plugin>(?:(?!</plugin>).)*?<artifactId>\s*exec-maven-plugin\s*</artifactId>.*?</plugin>",
    re.S,
)
EXEC_ARG = re.compile(
    r"<argument>\s*" + re.escape(ANALYTICS_FLAG) + r"\s*</argument>"
    r"|<commandlineArgs>[^<]*" + re.escape(ANALYTICS_FLAG)
)
JAVA_GUARD = ("ChronicleAnalytics.disable(", "chronicle.analytics.disable")


def check_chronicle(root: Path) -> None:
    poms = javas = 0
    for p in walk(root, "pom.xml"):
        text = XML_COMMENT.sub("", p.read_text(encoding="utf-8"))
        if not CHRONICLE_DEP.search(DEP_MGMT.sub("", text)):
            continue
        poms += 1
        if not ARG_LINE.search(text):
            fail("chronicle", f"{relto(root, p)}: surefire <argLine> lacks {ANALYTICS_FLAG}")
        for block in EXEC_PLUGIN.findall(text):
            if not EXEC_ARG.search(block):
                fail("chronicle", f"{relto(root, p)}: exec arguments lack {ANALYTICS_FLAG}")
    for p in walk(root, "*.java"):
        code = JAVA_COMMENT.sub("", p.read_text(encoding="utf-8"))
        if "net.openhft.chronicle" not in code:
            continue
        javas += 1
        if not any(g in code for g in JAVA_GUARD):
            fail(
                "chronicle",
                f"{relto(root, p)}: names net.openhft.chronicle but never calls "
                "ChronicleAnalytics.disable() or sets chronicle.analytics.disable",
            )
    print(f"chronicle: {poms} pom(s), {javas} source file(s) checked")


# ---------------------------------------------------------------- listings vs source
LISTING_EXT = {
    "java": {".java"},
    "cpp": {".cpp", ".hpp", ".h", ".cc"},
    "c++": {".cpp", ".hpp", ".h", ".cc"},
    "python": {".py"},
    "py": {".py"},
}
ELISION = re.compile(r"^\s*(//|#)\s*\.\.\.\s*$")
NAMED_SOURCE = re.compile(r"`([\w./-]+)`")


def names_source(path: Path, token: str) -> bool:
    """True when a backticked token names the file: `a/File.java`, `File.java`, or `File.member`
    for a capitalised (Java class) stem."""
    if "." in token and path.as_posix().endswith("/" + token.lstrip("/")):
        return True
    head = token.split(".")[0]
    return head[:1].isupper() and head == path.stem


def listing_sources(root: Path, doc: Path) -> list[Path]:
    """Source files of the chapter's example, plus the shared kits it builds on."""
    num = doc.name.split("-")[0]
    dirs = sorted((root / "examples").glob(f"{num}-*")) if (root / "examples").is_dir() else []
    if not dirs:
        return []
    dirs += [d for d in (root / "examples" / "common", root / "contracts") if d.is_dir()]
    return [
        p
        for d in dirs
        for p in sorted(d.rglob("*"))
        if p.is_file()
        and p.suffix in {".java", ".cpp", ".hpp", ".h", ".cc", ".py"}
        and not SKIP_DIRS & set(p.relative_to(root).parts)
    ]


def listing_chunks(body: list[str]) -> list[tuple[int, list[str]]]:
    """Split a fence body at elision lines into (offset of first line, lines) chunks."""
    chunks: list[tuple[int, list[str]]] = []
    cur: list[str] = []
    start = 0
    for i, line in enumerate(body):
        if ELISION.match(line):
            if cur:
                chunks.append((start, cur))
            cur, start = [], i + 1
        else:
            if not cur:
                start = i
            cur.append(line.rstrip())
    if cur:
        chunks.append((start, cur))
    trimmed = []
    for offset, chunk in chunks:
        while chunk and not chunk[0].strip():
            chunk, offset = chunk[1:], offset + 1
        while chunk and not chunk[-1].strip():
            chunk = chunk[:-1]
        if chunk:
            trimmed.append((offset, chunk))
    return trimmed


def contains_run(haystack: list[str], needle: list[str]) -> bool:
    n = len(needle)
    return any(haystack[i : i + n] == needle for i in range(len(haystack) - n + 1))


def check_listings(root: Path) -> None:
    fences = chunks_checked = 0
    cache: dict[Path, list[str]] = {}

    def lines_of(p: Path) -> list[str]:
        if p not in cache:
            cache[p] = [x.rstrip() for x in p.read_text(encoding="utf-8").splitlines()]
        return cache[p]

    for doc in sorted((root / "_docs").glob("[0-9][0-9]-*.md")):
        sources = listing_sources(root, doc)
        if not sources:
            continue
        lines = doc.read_text(encoding="utf-8").splitlines()
        prose: list[str] = []  # prose since the previous fence
        named: list[str] = []  # file names the latest prose paragraph gives
        i = 0
        while i < len(lines):
            fence = FENCE.match(lines[i])
            if not fence:
                if lines[i].strip() and not CODETABS.search(lines[i]):
                    prose.append(lines[i])
                i += 1
                continue
            marker, lang = fence.group(2), fence.group(3).lower()
            if prose:
                named = NAMED_SOURCE.findall(" ".join(prose[-6:]))
                prose = []
            j = i + 1
            while j < len(lines) and not lines[j].lstrip().startswith(marker):
                j += 1
            body = lines[i + 1 : j]
            if lang in LISTING_EXT:
                exts = LISTING_EXT[lang]
                mine = [p for p in sources if p.suffix in exts]
                by_name = [p for p in mine if any(names_source(p, n) for n in named)]
                candidates = by_name or mine
                fences += 1
                for offset, chunk in listing_chunks(body):
                    chunks_checked += 1
                    if not any(contains_run(lines_of(p), chunk) for p in candidates):
                        where = ", ".join(sorted({p.name for p in by_name})) or f"any {lang} source"
                        fail(
                            "listings",
                            f"{relto(root, doc)}:{i + 2 + offset}: {lang} listing "
                            f"({len(chunk)} lines from {chunk[0].strip()[:60]!r}) "
                            f"is not a verbatim run of {where}",
                        )
            i = j + 1
    print(f"listings: {fences} fence(s), {chunks_checked} chunk(s) checked")


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
    try:
        res = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True)
    except FileNotFoundError:  # git is not installed
        res = None
    if res is not None and res.returncode == 0:
        return res.stdout.splitlines()
    return [relto(root, p) for p in root.rglob("*") if p.is_file()]


def walk(root: Path, pattern: str) -> Iterator[Path]:
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
FLAGS_TO_CHAPTER = 13
RUN_DIR = re.compile(r"r0[2-9]-")


def check_java_flags(root: Path) -> None:
    n = 0
    for path in walk(root / "examples", "*.json"):
        parts = path.relative_to(root / "examples").parts
        if len(parts) < 4 or parts[1] != "results" or not RUN_DIR.match(parts[2]):
            continue
        if not (
            parts[0][:2].isdigit() and FLAGS_FROM_CHAPTER <= int(parts[0][:2]) <= FLAGS_TO_CHAPTER
        ):
            continue
        report = load_report(path)
        if report is None or report.get("language") != "java":
            continue
        if str(report.get("variant", "")).endswith("-gc-pause"):
            continue  # pauses derived from the run's JFR; the run report has the flags
        n += 1
        if not str((report.get("build") or {}).get("flags") or "").strip():
            fail("java-flags", f"{relto(root, path)}: Java report has no build.flags")
    print(f"java-flags: {n} Java report(s) in chapters {FLAGS_FROM_CHAPTER}-{FLAGS_TO_CHAPTER}")


def example_reports(root: Path) -> Iterator[tuple[Path, list[str], dict]]:
    """Every lowlat-report under examples/*/results/, with its path parts below examples/."""
    for path in walk(root / "examples", "*.json"):
        parts = list(path.relative_to(root / "examples").parts)
        if len(parts) < 4 or parts[1] != "results":
            continue
        report = load_report(path)
        if report is not None:
            yield path, parts, report


def check_hw_source(root: Path) -> None:
    n = 0
    for path, _, report in example_reports(root):
        hw = (report.get("runtime") or {}).get("hw_counters")
        if hw is None:
            continue
        n += 1
        if not isinstance(hw, dict) or not str(hw.get("source") or "").strip():
            fail("hw-source", f"{relto(root, path)}: runtime.hw_counters names no source")
    print(f"hw-source: {n} report(s) with hw_counters")


# Chapters whose r03-and-later reports come from pinned threads, and the reports in them that are
# deliberately unpinned. Each entry is a glob matched from the right of the path below the run
# directory (Path.match), so "lateness.json" matches any lane's lateness.json.
PINNED_FROM_CHAPTER = 9
PINNED_FROM_RUN = 3
UNPINNED_REPORTS = {
    # Ch10: the single-thread store-cost benchmarks (Google Benchmark and JMH measure one thread, so
    # there is nothing to place).
    "10-lockfree-waitfree": (
        "cpp-seq-cst.json",
        "cpp-release-acquire.json",
        "java-seq-cst.json",
        "java-release-acquire.json",
    ),
    # Ch11: the OS-thread and platform/virtual-thread memory and neighbour runs leave placement to
    # the kernel scheduler by design (10,000 OS threads can't share the pinned cores), and the
    # virtual-thread pinning run counts JFR events, not latency.
    "11-stackful-stackless": (
        "cpp-parked-os-thread.json",
        "cpp-neighbours-os-thread-alt*.json",
        "java-parked-*.json",
        "java-pinning-virtual-thread.json",
        "python/python-*-parked-threads.json",
    ),
    # Ch12: the Quarkus reports are written by the open-loop client, a load generator; the service
    # is confined to four cores with taskset but its threads are not individually pinned.
    "12-io-engines": ("quarkus/*.json",),
    # Ch13: the line simulator's emit-lateness report and the Quarkus client's reports come from
    # unpinned programs by design (the simulators and the open-loop client are load generators,
    # not pinned experiment threads).
    "13-where-code-runs": ("lateness.json", "client.json", "client-lateness.json"),
}


def unpinned_by_design(parts: list[str]) -> bool:
    below_run = PurePosixPath(*parts[3:])
    return any(below_run.match(pat) for pat in UNPINNED_REPORTS.get(parts[0], ()))


def check_placement(root: Path) -> None:
    n = pinned = 0
    for path, parts, report in example_reports(root):
        place = (report.get("runtime") or {}).get("placement")
        if place is not None:
            n += 1
            cpus = place.get("cpus") if isinstance(place, dict) else None
            if not (isinstance(cpus, list) and cpus):
                fail("placement", f"{relto(root, path)}: runtime.placement has no cpus")
            continue
        m = re.match(r"r0*(\d+)-", parts[2])
        chapter = parts[0][:2]
        if not (m and int(m.group(1)) >= PINNED_FROM_RUN and chapter.isdigit()):
            continue
        if int(chapter) < PINNED_FROM_CHAPTER or unpinned_by_design(parts):
            continue
        pinned += 1
        fail("placement", f"{relto(root, path)}: pinned-example report has no runtime.placement")
    print(f"placement: {n} report(s) with placement, {pinned} pinned report(s) without")


def check_raw_tool_output(root: Path) -> None:
    bad = []
    for f in tracked_files(root):
        name = Path(f).name
        parts = set(Path(f).parts)
        if name.startswith("cachegrind.out."):
            bad.append((f, "raw cachegrind output; commit the JSON summary"))
        elif name.endswith(".bin.gz"):
            bad.append((f, "a *.bin.gz result store (jcstress); commit the text summary"))
        elif name.endswith(".html") and ("results" in parts or any("jcstress" in x for x in parts)):
            if f.startswith("examples/"):
                bad.append((f, "an HTML report under results/ (jcstress); commit the text summary"))
    for f, why in bad:
        fail("no-raw-tool-output", f"{f}: {why}")
    print(f"no-raw-tool-output: {len(bad)} tracked raw tool output file(s)")


TOOL_VERSION = {
    "perf": re.compile(r"\d+\.\d+"),  # a kernel build number must never appear
    "valgrind": re.compile(r"\d+\.\d+(\.\d+)?"),
}


def check_tool_versions(root: Path) -> None:
    n = 0

    def check(where: str, profile: object) -> None:
        nonlocal n
        tools = profile.get("tools") if isinstance(profile, dict) else None
        if not isinstance(tools, dict):
            return
        n += 1
        for tool, rx in TOOL_VERSION.items():
            # null is profile.sh's record of a tool that isn't installed (the lab guest has no
            # valgrind); any string must be a clean version
            if (
                tool in tools
                and tools[tool] is not None
                and not (isinstance(tools[tool], str) and rx.fullmatch(tools[tool]))
            ):
                fail("tool-versions", f"{where}: tools.{tool} is {tools[tool]!r}, not {rx.pattern}")

    for path in walk(root / "examples", "*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError, OSError:
            continue
        if not isinstance(data, dict):
            continue
        if str(data.get("schema", "")).startswith("lowlat-report/"):
            check(relto(root, path), data.get("profile"))
        elif str(data.get("schema", "")).startswith("lowlat-profile/"):
            check(relto(root, path), data)
    print(f"tool-versions: {n} profile(s)")


def check_vm_runs(root: Path) -> None:
    runs = 0
    for run in sorted((root / "examples").glob("*/results/**/*vm-run*")):
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
            if not isinstance(data, dict):
                continue
            if load_report(path) is not None:
                prof = data.get("profile")
                if not isinstance(prof, dict):
                    fail("vm-runs", f"{relto(root, path)}: report has no profile")
                    continue
            else:
                prof = data
            if str(prof.get("schema", "")) != "lowlat-profile/1":
                continue
            virt = (prof.get("virt") or {}).get("type")
            if virt != "kvm":
                fail("vm-runs", f"{relto(root, path)}: profile.virt.type is {virt!r}, need 'kvm'")
    print(f"vm-runs: {runs} vm-run director(ies)")


# ---------------------------------------------------------------- r04 environment and build checks
ENV_FROM_RUN = 4  # Chapter 13 reports from r04 on carry runtime.environment
ENV_SCHEMAS = ("lowlat-report/", "lowlat-place-probe/", "lowlat-pool/", "lowlat-steal/")
ENV_LANE = re.compile(r"host|vm|container-[a-z0-9-]+")
# Reports that carry no runtime.environment by design: the Quarkus client's emit-lateness sidecar.
ENV_UNLABELLED = {"client-lateness.json"}
# Reports whose environment is the guest's, not the lane's: steal ticks are read from the guest's
# /proc/stat, and the line simulator (lateness.json) runs in the guest outside the container.
ENV_KIND_EXCEPTIONS = {
    ("steal.json", "vm"): {"vm"},
    ("steal.json", "container"): {"vm"},
    ("lateness.json", "container"): {"vm", "container"},
}
IMAGE_REF = re.compile(r"[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*")
IMAGE_DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def images_lock(root: Path) -> dict[str, str]:
    """Image name:tag -> digest from Chapter 13's IMAGES.lock (field 1, name:tag@sha256:...)."""
    lock = root / "examples" / "13-where-code-runs" / "containers" / "IMAGES.lock"
    out: dict[str, str] = {}
    if lock.is_file():
        for line in lock.read_text(encoding="utf-8").splitlines():
            fields = line.split()
            if fields and not fields[0].startswith("#") and "@" in fields[0]:
                name, digest = fields[0].split("@", 1)
                out[name] = digest
    return out


def check_env_labels(root: Path) -> None:
    n = 0
    lock = images_lock(root)
    seen_lanes: set[tuple[str, str, str]] = set()
    for ch in sorted((root / "examples").glob("13-*")):
        for path in walk(ch, "*.json"):
            parts = path.relative_to(ch).parts
            run = re.match(r"r0*(\d+)-", parts[1]) if len(parts) > 3 else None
            if parts[0] != "results" or not run or int(run.group(1)) < ENV_FROM_RUN:
                continue
            lane = parts[2]
            if not ENV_LANE.fullmatch(lane):
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except ValueError:
                continue
            if not (isinstance(data, dict) and str(data.get("schema", "")).startswith(ENV_SCHEMAS)):
                continue
            n += 1
            seen_lanes.add((ch.name, parts[1], lane))
            where = relto(root, path)
            lane_kind = lane.split("-")[0]
            runtime = data.get("runtime")
            env = runtime.get("environment") if isinstance(runtime, dict) else None
            if not isinstance(env, dict):
                if path.name not in ENV_UNLABELLED:
                    fail("env-labels", f"{where}: no runtime.environment")
                continue
            kind = env.get("kind")
            allowed = ENV_KIND_EXCEPTIONS.get((path.name, lane_kind), {lane_kind})
            if kind not in allowed:
                fail(
                    "env-labels",
                    f"{where}: runtime.environment.kind is {kind!r}, lane {lane}/ needs "
                    f"{' or '.join(sorted(allowed))!r}",
                )
            if kind in ("vm", "container") and not str(env.get("guest_profile") or "").strip():
                fail(
                    "env-labels", f"{where}: {kind} report has no runtime.environment.guest_profile"
                )
            if lane_kind != "host" and str(data.get("schema", "")).startswith("lowlat-report/"):
                prof = data.get("profile")
                virt = (
                    ((prof or {}).get("virt") or {}).get("type") if isinstance(prof, dict) else None
                )
                if virt != "kvm":
                    fail("env-labels", f"{where}: profile.virt.type is {virt!r}, need 'kvm'")
            if kind == "container":
                box = env.get("container")
                box = box if isinstance(box, dict) else {}
                image, digest = str(box.get("image") or ""), str(box.get("image_digest") or "")
                if not IMAGE_REF.fullmatch(image) or image.rsplit(":", 1)[1] == "latest":
                    fail(
                        "env-labels",
                        f"{where}: container.image {image!r} is not name:tag with an exact tag",
                    )
                if not IMAGE_DIGEST.fullmatch(digest):
                    fail(
                        "env-labels",
                        f"{where}: container.image_digest {digest!r} is not sha256:<64 hex>",
                    )
                elif lock.get(image) != digest:
                    fail(
                        "env-labels",
                        f"{where}: {image} digest {digest[:19]}... differs from IMAGES.lock "
                        f"({(lock.get(image) or 'not listed')[:19]})",
                    )
    print(f"env-labels: {n} Chapter 13 report(s) in {len(seen_lanes)} lane(s) of r04 or later runs")


# ---------------------------------------------------------------- language floor
CXX_FLOOR = 23
JDK_FLOOR = 25
PY_FLOOR = (3, 14)
CXX_STD = [
    re.compile(r"set\(\s*CMAKE_CXX_STANDARD\s+(\w+)", re.I),
    re.compile(r"-DCMAKE_CXX_STANDARD=(\w+)"),
    re.compile(r'"CMAKE_CXX_STANDARD"\s*:\s*"?(\w+)'),
    re.compile(r"cxx_std_(\w+)"),
    re.compile(r"-std=(?:c|gnu)\+\+(\w+)"),
]
JDK_NAMED = re.compile(r"(?:temurin|openjdk|jdk|java)[-:]?(\d{2})\b|TEMURIN_BUILD=(\d+)", re.I)
PY_NAMED = re.compile(r"(?:python[-:]?|--python[ =])3\.(\d+)", re.I)
# C++98 ranks as 3 (the 2003 revision), below every floor
CXX_YEAR = {"98": 3, "0x": 11, "1y": 14, "1z": 17, "2a": 20, "2b": 23, "2c": 26}
PROPS_BLOCK = re.compile(r"<properties>(.*?)</properties>", re.S)
PROP = re.compile(r"<([\w.\-]+)>([^<]*)</\1>")
COMPILER_PLUGIN = re.compile(
    r"<artifactId>\s*maven-compiler-plugin\s*</artifactId>.*?</plugin>", re.S
)
RELEASE = re.compile(r"<release>\s*([^<]+?)\s*</release>")
PARENT = re.compile(r"<parent>.*?</parent>", re.S)
REL_PATH = re.compile(r"<relativePath>\s*([^<]*?)\s*</relativePath>")


def cxx_standard(token: str) -> int | None:
    """The C++ standard a CMake/compiler token names as a two-digit year, None when unknown."""
    if token in CXX_YEAR:
        return CXX_YEAR[token]
    return int(token) if token.isdigit() else None


def is_containerfile(name: str) -> bool:
    return name.startswith(("Containerfile", "Dockerfile")) or name.endswith(
        (".Containerfile", ".Dockerfile")
    )


def code_lines(text: str) -> str:
    return "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))


def pom_release(path: Path, depth: int = 0) -> str | None:
    """maven.compiler.release, or the compiler plugin's <release>, through the parent chain."""
    texts: list[str] = []
    cur: Path | None = path
    while cur is not None and cur.is_file() and depth < 8:
        text = XML_COMMENT.sub("", cur.read_text(encoding="utf-8"))
        texts.append(text)
        parent = PARENT.search(text)
        if not parent:
            break
        rp = REL_PATH.search(parent.group(0))
        nxt = (cur.parent / (rp.group(1) if rp else "../pom.xml")).resolve()
        cur = nxt / "pom.xml" if nxt.is_dir() else nxt
        depth += 1
    props: dict[str, str] = {}
    for text in reversed(texts):  # the child's properties override its parents'
        for block in PROPS_BLOCK.findall(text):
            props.update(PROP.findall(block))
    value = props.get("maven.compiler.release")
    for text in texts:
        for plugin in COMPILER_PLUGIN.findall(text):
            m = RELEASE.search(plugin)
            if m and value is None:
                value = m.group(1)
    if value is not None:
        value = re.sub(r"\$\{([^}]+)\}", lambda m: props.get(m.group(1), m.group(0)), value)
    return value


def check_lang_floor(root: Path) -> None:
    cxx = poms = pys = 0

    def floor(where: str, what: str, found: int | None, minimum: int) -> None:
        if found is None or found < minimum:
            fail("lang-floor", f"{where}: {what} is below the floor {minimum}")

    for f in tracked_files(root):
        p = root / f
        if SKIP_DIRS & set(Path(f).parts) or not p.is_file():
            continue
        name = p.name
        if name == "pom.xml":
            poms += 1
            value = pom_release(p)
            if value is None or not value.isdigit():
                fail("lang-floor", f"{f}: maven.compiler.release does not resolve ({value!r})")
            elif int(value) < JDK_FLOOR:
                fail("lang-floor", f"{f}: maven.compiler.release {value} is below JDK {JDK_FLOOR}")
        elif name == "pyproject.toml":
            pys += 1
            try:
                spec = (tomllib.loads(p.read_text(encoding="utf-8")).get("project") or {}).get(
                    "requires-python"
                )
            except tomllib.TOMLDecodeError as exc:
                fail("lang-floor", f"{f}: not valid TOML ({exc})")
                continue
            m = re.search(r"(?:>=|~=|==|>)\s*(\d+)\.(\d+)", str(spec or ""))
            if not m or (int(m.group(1)), int(m.group(2))) < PY_FLOOR:
                fail(
                    "lang-floor",
                    f"{f}: requires-python {spec!r} is below Python {PY_FLOOR[0]}.{PY_FLOOR[1]}",
                )
        elif name == ".python-version":
            m = re.match(r"\s*(\d+)\.(\d+)", p.read_text(encoding="utf-8"))
            if not m or (int(m.group(1)), int(m.group(2))) < PY_FLOOR:
                fail("lang-floor", f"{f}: Python version is below {PY_FLOOR[0]}.{PY_FLOOR[1]}")
        elif (
            name in ("CMakeLists.txt", "CMakePresets.json")
            or p.suffix == ".cmake"
            or is_containerfile(name)
        ):
            cxx += 1
            text = code_lines(p.read_text(encoding="utf-8"))
            for rx in CXX_STD:
                for tok in rx.findall(text):
                    std = cxx_standard(tok)
                    if std is None or std < CXX_FLOOR:
                        fail("lang-floor", f"{f}: C++ standard {tok!r} is below C++{CXX_FLOOR}")
            if is_containerfile(name):
                for m in JDK_NAMED.finditer(text):
                    jdk = int(m.group(1) or m.group(2))
                    floor(f, f"JDK {jdk}", jdk, JDK_FLOOR)
                for m in PY_NAMED.finditer(text):
                    if int(m.group(1)) < PY_FLOOR[1]:
                        fail("lang-floor", f"{f}: Python 3.{m.group(1)} is below 3.{PY_FLOOR[1]}")
    print(f"lang-floor: {cxx} CMake/Containerfile(s), {poms} pom(s), {pys} pyproject(s)")


# ---------------------------------------------------------------- image pins
FROM_LINE = re.compile(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?", re.I | re.M)
ARG_DEFAULT = re.compile(r"^\s*ARG\s+(\w+)=(\S+)", re.M)


def check_image_pins(root: Path) -> None:
    files = froms = 0
    for f in tracked_files(root):
        p = root / f
        if SKIP_DIRS & set(Path(f).parts) or not is_containerfile(p.name) or not p.is_file():
            continue
        files += 1
        text = code_lines(p.read_text(encoding="utf-8"))
        args = dict(ARG_DEFAULT.findall(text))
        stages: set[str] = set()
        for m in FROM_LINE.finditer(text):
            image, alias = m.group(1), m.group(2)
            if alias:
                stages.add(alias.lower())
            if image.lower() == "scratch" or image.lower() in stages:
                continue
            froms += 1
            image = re.sub(r"\$\{?(\w+)\}?", lambda v, a=args: a.get(v.group(1), v.group(0)), image)
            ref, _, digest = image.partition("@")
            tag = ref.rsplit("/", 1)[-1].partition(":")[2]
            if "$" in image:
                fail("image-pins", f"{f}: FROM {m.group(1)} has an ARG with no default")
            elif not tag:
                fail("image-pins", f"{f}: FROM {image} has no tag")
            elif tag == "latest":
                fail("image-pins", f"{f}: FROM {image} uses :latest")
            elif not IMAGE_DIGEST.fullmatch(digest):
                fail("image-pins", f"{f}: FROM {image} has no @sha256:<64 hex> digest")
    print(f"image-pins: {froms} FROM line(s) in {files} Containerfile(s)")


# ---------------------------------------------------------------- no privileged containers
# Tracked scripts, compose files, Containerfiles and workflows. A (path, pattern name) entry here
# is an explicit, reviewed exception; the tree needs none.
NO_PRIVILEGED_ALLOW: set[tuple[str, str]] = set()
PRIVILEGED = {
    "--privileged": re.compile(r"--privileged\b"),
    "--cap-add=ALL": re.compile(r"--cap-add[= ]\s*['\"]?ALL\b", re.I),
    "seccomp=unconfined": re.compile(r"seccomp[=:]\s*['\"]?unconfined", re.I),
    "privileged: true": re.compile(r"\bprivileged:\s*['\"]?true\b", re.I),
}


def check_no_privileged(root: Path) -> None:
    n = 0
    for f in tracked_files(root):
        p = root / f
        name = p.name
        if SKIP_DIRS & set(Path(f).parts) or not p.is_file():
            continue
        if not (
            p.suffix in {".sh", ".bash", ".yml", ".yaml"}
            or is_containerfile(name)
            or name == "Makefile"
        ):
            continue
        n += 1
        for lineno, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for label, rx in PRIVILEGED.items():
                if rx.search(line) and (f, label) not in NO_PRIVILEGED_ALLOW:
                    fail("no-privileged", f"{f}:{lineno}: {label}: {line.strip()[:100]}")
    print(f"no-privileged: {n} script/compose/Containerfile/workflow file(s)")


# ---------------------------------------------------------------- free-threaded lane identity
GIL_CONTROL = "gil_reenabled=PYTHON_GIL=1"
# Ch9 r03 free-threaded counter reports were written before the S3 tightening: the harness recorded
# the driver's build (build.compiler without "free-threading", build.gil_enabled true) while the
# worker ran the free-threaded interpreter (its notes say gil_enabled=False). Frozen measurements;
# the r04 reports (Ch11, Ch12) and Ch10 carry the binary's own identity.
FT_KNOWN_MISLABELLED = (
    "09-eliminating-work/results/*/python/counters-threads-free-threaded-*.json",
)


def check_ft_reports(root: Path) -> None:
    n = known = 0
    for path, parts, report in example_reports(root):
        build = report.get("build") or {}
        runtime = report.get("runtime") or {}
        ft_binary = "free-threading" in str(build.get("compiler") or "")
        label = runtime.get("python_build")
        if not ft_binary and label != "free-threaded":
            continue
        n += 1
        if GIL_CONTROL in str(report.get("notes") or ""):
            continue
        where = relto(root, path)
        problems = []
        if ft_binary and label != "free-threaded":
            problems.append(f"free-threading build but runtime.python_build is {label!r}")
        if ft_binary and build.get("gil_enabled") is not False:
            problems.append(
                f"free-threading build but build.gil_enabled is {build.get('gil_enabled')!r}"
            )
        if label == "free-threaded" and not ft_binary:
            problems.append(
                "runtime.python_build is 'free-threaded', build.compiler lacks 'free-threading'"
            )
        if problems and any(fnmatch.fnmatch("/".join(parts), pat) for pat in FT_KNOWN_MISLABELLED):
            known += 1
            continue
        for problem in problems:
            fail("ft-reports", f"{where}: {problem}")
    print(f"ft-reports: {n} free-threaded report(s), {known} known r03 mislabel(s) listed")


# ---------------------------------------------------------------- versions.env consumers
# (variable, consumer file, how the consumer holds it)
#   text    the value appears verbatim in the file
#   arg     a Containerfile `ARG VAR=value` line holds it
#   sourced the value appears verbatim, or the file sources versions.env and names $VAR
VERSION_CONSUMERS: list[tuple[str, str, str]] = [
    ("BOOST_VERSION", "examples/cmake/deps.cmake", "text"),
    ("BOOST_URL", "examples/cmake/deps.cmake", "text"),
    ("BOOST_SHA256", "examples/cmake/deps.cmake", "text"),
    ("BOOST_SHA256", ".github/workflows/ci.yml", "sourced"),
    ("LIBURING_VERSION", "examples/cmake/deps.cmake", "text"),
    ("LIBURING_URL", "examples/cmake/deps.cmake", "text"),
    ("LIBURING_SHA256", "examples/cmake/deps.cmake", "text"),
    ("QUARKUS_PLATFORM_VERSION", "examples/12-io-engines/quarkus/pom.xml", "text"),
    ("UVLOOP_VERSION", "examples/12-io-engines/io-py/pyproject.toml", "text"),
    ("PROTOBUF_JAVA_VERSION", "examples/pom.xml", "text"),
    ("PROTOBUF_PYTHON_VERSION", "examples/common/proto-py/pyproject.toml", "text"),
    ("CMAKE_VERSION", "examples/13-where-code-runs/containers/cpp/Containerfile", "arg"),
    ("CMAKE_SHA256", "examples/13-where-code-runs/containers/cpp/Containerfile", "arg"),
    ("NINJA_VERSION", "examples/13-where-code-runs/containers/cpp/Containerfile", "arg"),
    ("NINJA_SHA256", "examples/13-where-code-runs/containers/cpp/Containerfile", "arg"),
    ("TEMURIN_BUILD", "examples/13-where-code-runs/containers/java/Containerfile", "arg"),
    ("TEMURIN_URL", "examples/13-where-code-runs/containers/java/Containerfile", "arg"),
    ("TEMURIN_SHA256", "examples/13-where-code-runs/containers/java/Containerfile", "arg"),
    ("MAVEN_VERSION", "examples/13-where-code-runs/containers/java/Containerfile", "arg"),
    ("MAVEN_SHA256", "examples/13-where-code-runs/containers/java/Containerfile", "arg"),
    ("UV_VERSION", "examples/13-where-code-runs/containers/python/Containerfile", "arg"),
    ("UV_SHA256", "examples/13-where-code-runs/containers/python/Containerfile", "arg"),
]
ENV_ASSIGN = re.compile(r'^([A-Z][A-Z0-9_]*)="([^"]*)"', re.M)


def check_versions_consumers(root: Path, table: list[tuple[str, str, str]] | None = None) -> None:
    table = VERSION_CONSUMERS if table is None else table
    env_file = root / "versions.env"
    pins = (
        dict(ENV_ASSIGN.findall(env_file.read_text(encoding="utf-8"))) if env_file.is_file() else {}
    )
    for var, consumer, how in table:
        value = pins.get(var)
        path = root / consumer
        if value is None:
            fail("versions-consumers", f"versions.env has no {var} (consumer {consumer})")
        elif not path.is_file():
            fail("versions-consumers", f"{consumer}: consumer of {var} is missing")
        else:
            text = path.read_text(encoding="utf-8")
            if how == "arg":
                ok = f"ARG {var}={value}\n" in text + "\n"
            elif how == "sourced":
                ok = value in text or (
                    "versions.env" in text and re.search(rf"\$\{{?{var}\b", text) is not None
                )
            else:
                ok = value in text
            if not ok:
                fail(
                    "versions-consumers",
                    f"{consumer}: {var}={value[:48]} not found "
                    f"{'as an ARG default' if how == 'arg' else 'verbatim'}",
                )
    print(
        f"versions-consumers: {len(table)} pin/consumer pair(s), {len(pins)} pin(s) in versions.env"
    )


# A version is a prerelease when a separator or digit is followed by one of these words.
PRERELEASE = re.compile(
    r"(?i)(?:^|[-._+]|(?<=\d))(?:ea|snapshot|alpha|beta|rc|preview|early-access|milestone|dev|"
    r"jep\d+(?:ea)?|m|b|pre|nightly)(?:\d*)(?=$|[-._+])|\d(?:a|b|rc)\d+(?:$|[-._+])|-ea\b"
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
        project = data.get("project", {})
        specs = list(project.get("dependencies", []))
        specs += data.get("build-system", {}).get("requires", [])
        for group in (
            *project.get("optional-dependencies", {}).values(),
            *data.get("dependency-groups", {}).values(),
        ):
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
        if path.suffix == ".json" and "results" in path.relative_to(root).parts:
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


# ---------------------------------------------------------------- host-ids
# The repository is public: a tracked file must not name the machine or its owner.
# The patterns are generic; the account name and hostname are read at run time.
# scripts/scrub-host-ids.py holds the replacements and is the way to fix a failure.
HOST_ID_PATTERNS: list[tuple[str, re.Pattern[str], str]] = [
    ("home path", re.compile(r"/(?:home|Users)/[^/\s\"'`)<>]+/"), "absolute home path"),
    ("cpu model", re.compile(r"\bi[3579]-\d{4,5}[A-Z]*\b"), "Intel CPU model number"),
    ("cpu model", re.compile(r"\bRyzen \d"), "AMD CPU model"),
    ("cpu model", re.compile(r"\bXeon\b"), "Xeon CPU name"),
    (
        "product_name",
        re.compile(r'"product_name"\s*:\s*"(?!redacted")'),
        'product_name is not "redacted"',
    ),
    (
        "kernel build",
        re.compile(r"\b\d+\.\d+\.\d+-\d+\.fc\d+\.x86_64\b"),
        "host kernel with a build number",
    ),
]
# Files that may hold what the guard looks for: the table that removes it, this guard, and the
# SRPM pin of the disposable lab guest's kernel build (a dependency pin, not the host's kernel).
HOST_ID_SELF = {"scripts/scrub-host-ids.py", "scripts/validate.py"}
HOST_ID_KERNEL_PINS = {
    "scripts/lab/build-rt-kernel.sh",
    "scripts/lab/install-rt-kernel.sh",
    "scripts/lab/README.md",
    "_plans/dependency-pins.md",
}
# Names too common to look for as words (a CI runner's account is "runner").
HOST_ID_COMMON = {"root", "user", "runner", "fedora", "ubuntu", "admin", "localhost", "github"}


def runtime_names() -> list[str]:
    """The account name and hostname of this machine, read now; never written anywhere."""
    names = []
    for read in (getpass.getuser, socket.gethostname):
        try:
            name = read()
        except OSError, KeyError:
            continue
        if len(name) >= 4 and name.lower() not in HOST_ID_COMMON:
            names.append(name)
    return names


def check_host_ids(root: Path, names: list[str] | None = None) -> None:
    names = runtime_names() if names is None else names
    word = [(n, re.compile(rf"(?<![A-Za-z0-9_]){re.escape(n)}(?![A-Za-z0-9_])")) for n in names]
    n_files = 0
    for name in tracked_files(root):
        path = root / name
        if name in HOST_ID_SELF or not path.is_file():
            continue
        try:
            raw = path.read_bytes()
            if raw[:2] == b"\x1f\x8b":
                raw = gzip.decompress(raw)
            text = raw.decode("utf-8")
        except OSError, EOFError, UnicodeDecodeError:
            continue  # binary
        n_files += 1
        for label, pat, what in HOST_ID_PATTERNS:
            if label == "kernel build" and name in HOST_ID_KERNEL_PINS:
                continue
            if m := pat.search(text):
                line = text.count("\n", 0, m.start()) + 1
                fail("host-ids", f"{name}:{line}: {what}; run scripts/scrub-host-ids.py")
        for _, pat in word:
            if pat.search(text):
                line = text.count("\n", 0, pat.search(text).start()) + 1  # type: ignore[union-attr]
                fail(
                    "host-ids",
                    f"{name}:{line}: the runtime account name or hostname; run scrub-host-ids.py",
                )
    print(f"host-ids: {n_files} text file(s)")


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


def collect_failures(run: Callable[[], None]) -> list[str]:
    """Run a check and return the failures it raised, leaving the global list untouched."""
    global failures
    saved, failures = failures, []
    try:
        run()
        return failures
    finally:
        failures = saved


def planted(
    tree: dict[str, str | dict], check: Callable[[Path], None], git: bool = False
) -> list[str]:
    """Run `check` on a temporary tree holding `tree`; return the failures it raised."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name, content in tree.items():
            put(root, name, content)
        if git:
            subprocess.run(["git", "-C", tmp, "init", "-q"], check=True)
            subprocess.run(["git", "-C", tmp, "add", "-A"], check=True)
        return collect_failures(lambda: check(root))


CHRONICLE_POM = (
    "<project><dependencies><dependency><artifactId>chronicle-queue</artifactId></dependency>"
    "</dependencies><build><plugins>"
    "<plugin><artifactId>maven-surefire-plugin</artifactId><configuration>"
    "<argLine>-Dchronicle.analytics.disable=true</argLine></configuration></plugin>"
    "{}</plugins></build></project>"
)
EXEC_CMD_GOOD = (
    "<plugin><artifactId>exec-maven-plugin</artifactId><configuration><commandlineArgs>"
    "-Dchronicle.analytics.disable=true -cp %classpath Main</commandlineArgs>"
    "</configuration></plugin>"
)
EXEC_CMD_BAD = (
    "<plugin><artifactId>exec-maven-plugin</artifactId><configuration><commandlineArgs>"
    "-cp %classpath Main</commandlineArgs></configuration></plugin>"
)
LISTED_SRC = (
    "class A {\n    int f() {\n    int a = 1;\n    int b = 2;\n    return a + b;\n    }\n}\n"
)


def listing_doc(prose_name: str, body: str, lang: str = "java") -> str:
    return f"# Chapter\n\nThe listing shows {prose_name}.\n\n```{lang}\n{body}\n```\n"


# ---- planted-tree builders for the r04 checks
IMG = "lowlat/place-cpp:r04"
DIGEST = "sha256:" + "a" * 64
ENV_DIR = "examples/13-where-code-runs"
LOCK = {f"{ENV_DIR}/containers/IMAGES.lock": f"# comment\n{IMG}@{DIGEST} ubi@sha256:{'b' * 64}\n"}


def env_report(lane: str, **env: object) -> dict:
    """A Chapter 13 consumer report for `lane`, its environment overridden by `env`."""
    kind = lane.split("-")[0]
    environment: dict = {"kind": kind}
    if kind != "host":
        environment["guest_profile"] = "lab-ready-r04/stock-unpinned"
    if kind == "container":
        environment["container"] = {"runtime": "docker", "image": IMG, "image_digest": DIGEST}
    environment.update(env)
    virt = {"type": "none" if kind == "host" else "kvm"}
    return {
        **GOOD_REPORT,
        "example": "13-where-code-runs",
        "runtime": {"environment": environment},
        "profile": {"schema": "lowlat-profile/1", "virt": virt},
    }


def env_path(lane: str, name: str = "cpp/consumer.json") -> str:
    return f"{ENV_DIR}/results/r04-run1/{lane}/alt1/{name}"


def ft_report(compiler: str, build: str, gil: bool, notes: str = "") -> dict:
    return {
        **GOOD_REPORT,
        "language": "python",
        "build": {"compiler": compiler, "gil_enabled": gil},
        "runtime": {"python_build": build},
        "notes": notes,
    }


FT_COMPILER = "3.14.9 free-threading build (main) [Clang 23.1.3 ]"
GIL_COMPILER = "3.14.9 (main) [Clang 23.1.3 ]"
FT_PATH = "examples/11-stackful-stackless/results/r04-run1/python/python-free-threaded-x.json"
BASE = "registry.access.redhat.com/ubi10/ubi-minimal:10.2-1@sha256:" + "c" * 64


def pom_with(release: str | None, parent: str | None = None) -> str:
    props = f"<properties><maven.compiler.release>{release}</maven.compiler.release></properties>"
    head = f"<parent><relativePath>{parent}</relativePath></parent>" if parent else ""
    return f"<project>{head}{props if release is not None else ''}</project>"


# A made-up host kernel build for the planted cases: never a real machine's.
HOST_KERNEL_BUILD = "9.9.9-100.fc99.x86_64"


def self_test() -> int:
    r = "examples/05-jvm-costs/results/r02-run1/java-naive.json"
    r10 = "examples/10-lockfree-waitfree/results/r03-run1/java/java-x.json"
    h = "examples/09-eliminating-work/results/r03-run1/cpp/x.json"
    u = "examples/10-lockfree-waitfree/results/r03-run1/cpp/cpp-seq-cst.json"
    uq = "examples/12-io-engines/results/r04-run1/quarkus/event-loop-alt1.json"
    pq = "examples/12-io-engines/results/r04-run1/cpp/epoll-sat-alt1.json"

    def prof(perf: str, valgrind: str) -> dict:
        return {"schema": "lowlat-profile/1", "tools": {"perf": perf, "valgrind": valgrind}}

    vm = "examples/07-offheap-lockfree/results/r02-vm-run1"
    vm_report = {**GOOD_REPORT, "profile": {"schema": "lowlat-profile/1", "virt": {"type": "kvm"}}}
    pom = (
        "<project><dependencies><dependency><artifactId>x</artifactId><version>{}</version>"
        "</dependency></dependencies></project>"
    )
    cases: list[tuple[str, dict, Callable[[Path], None], bool, str]] = [
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
            "java-flags r03 chapter 10 bad",
            {r10: {**GOOD_REPORT, "build": {"compiler": "c", "flags": ""}}},
            check_java_flags,
            False,
            "no build.flags",
        ),
        ("java-flags r03 chapter 10 good", {r10: GOOD_REPORT}, check_java_flags, False, ""),
        (
            "java-flags r04 chapter 13 bad",
            {
                "examples/13-where-code-runs/results/r04-run1/host/alt1/java/x.json": {
                    **GOOD_REPORT,
                    "build": {"compiler": "c", "flags": ""},
                }
            },
            check_java_flags,
            False,
            "no build.flags",
        ),
        (
            "java-flags r04 chapter 11 good",
            {"examples/11-stackful-stackless/results/r04-run1/java-x.json": GOOD_REPORT},
            check_java_flags,
            False,
            "",
        ),
        (
            "hw-source bad",
            {h: {**GOOD_REPORT, "runtime": {"hw_counters": {"per_op": {"cycles": 1}}}}},
            check_hw_source,
            False,
            "names no source",
        ),
        (
            "hw-source good",
            {h: {**GOOD_REPORT, "runtime": {"hw_counters": {"source": "perf"}}}},
            check_hw_source,
            False,
            "",
        ),
        (
            "placement empty cpus",
            {h: {**GOOD_REPORT, "runtime": {"placement": {"cpus": []}}}},
            check_placement,
            False,
            "has no cpus",
        ),
        (
            "placement missing in a pinned example",
            {h: GOOD_REPORT},
            check_placement,
            False,
            "no runtime.placement",
        ),
        (
            "placement unpinned store-cost benchmark",
            {u: GOOD_REPORT},
            check_placement,
            False,
            "",
        ),
        (
            "placement unpinned-by-design glob (Ch12 Quarkus client)",
            {uq: GOOD_REPORT},
            check_placement,
            False,
            "",
        ),
        (
            "placement glob does not cover a pinned lane",
            {pq: GOOD_REPORT},
            check_placement,
            False,
            "no runtime.placement",
        ),
        (
            "placement good",
            {h: {**GOOD_REPORT, "runtime": {"placement": {"cpus": [1, 2]}}}},
            check_placement,
            False,
            "",
        ),
        (
            "no-raw-tool-output cachegrind",
            {"examples/09-x/results/r03-run1/cachegrind.out.123": "x"},
            check_raw_tool_output,
            True,
            "raw cachegrind output",
        ),
        (
            "no-raw-tool-output jcstress html",
            {"examples/10-x/results/r03-run1/jcstress/index.html": "x"},
            check_raw_tool_output,
            True,
            "jcstress",
        ),
        (
            "no-raw-tool-output bin.gz",
            {"examples/10-x/results/r03-run1/x.bin.gz": "x"},
            check_raw_tool_output,
            True,
            "bin.gz",
        ),
        (
            "no-raw-tool-output good",
            {
                "examples/10-x/results/r03-run1/cachegrind/a.json": "{}",
                "examples/10-x/results/r03-run1/jcstress-summary.txt": "x",
                "_site/index.html": "x",
            },
            check_raw_tool_output,
            True,
            "",
        ),
        (
            "tool-versions perf kernel build",
            {"examples/09-x/results/r03-run1/profile.json": prof("7.2.11-200.fc44", "3.27.1")},
            check_tool_versions,
            False,
            "tools.perf",
        ),
        (
            "tool-versions valgrind garbage",
            {"examples/09-x/results/r03-run1/profile.json": prof("7.2", "valgrind-3.27.1")},
            check_tool_versions,
            False,
            "tools.valgrind",
        ),
        (
            "tool-versions report profile",
            {h: {**GOOD_REPORT, "profile": prof("7.2.11", "3.27")}},
            check_tool_versions,
            False,
            "tools.perf",
        ),
        (
            "tool-versions good",
            {"examples/09-x/results/r03-run1/profile.json": prof("7.2", "3.27.1")},
            check_tool_versions,
            False,
            "",
        ),
        (
            "vm-runs no LABEL",
            {f"{vm}/vm/profile.json": vm_report["profile"]},
            check_vm_runs,
            False,
            "no vm/LABEL",
        ),
        (
            "vm-runs report without profile",
            {
                f"{vm}/vm/LABEL": "vm\n",
                f"{vm}/vm/r1/j.json": {k: v for k, v in vm_report.items() if k != "profile"},
            },
            check_vm_runs,
            False,
            "report has no profile",
        ),
        (
            "vm-runs nested run dir",
            {
                "examples/07-offheap-lockfree/results/r02/extra-vm-run2/vm/LABEL": "lab\n",
            },
            check_vm_runs,
            False,
            "LABEL is not",
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
            "prerelease pom b01",
            {"examples/pom.xml": pom.format("2.0.0-b01")},
            check_prerelease,
            False,
            "2.0.0-b01",
        ),
        (
            "prerelease pom nightly",
            {"examples/pom.xml": pom.format("3.1.0-nightly")},
            check_prerelease,
            False,
            "nightly",
        ),
        (
            "prerelease build-system",
            {"examples/pyproject.toml": '[build-system]\nrequires=["setuptools==80.0.0rc1"]\n'},
            check_prerelease,
            False,
            "80.0.0rc1",
        ),
        (
            "prerelease optional-dependencies",
            {
                "examples/pyproject.toml": (
                    '[project]\nname="x"\n[project.optional-dependencies]\n'
                    'extra=["foo>=1.0.0-pre1"]\n'
                )
            },
            check_prerelease,
            False,
            "pre1",
        ),
        (
            "chronicle guard only in a comment",
            {
                "examples/07-offheap-lockfree/java/A.java": (
                    "import net.openhft.chronicle.queue.ChronicleQueue;\n"
                    "// ChronicleAnalytics.disable() would go here\n"
                )
            },
            check_chronicle,
            False,
            "never calls",
        ),
        (
            "chronicle guard in code",
            {
                "examples/07-offheap-lockfree/java/A.java": (
                    "import net.openhft.chronicle.queue.ChronicleQueue;\n"
                    "class A { static { System.setProperty("
                    '"chronicle.analytics.disable", "true"); } }\n'
                )
            },
            check_chronicle,
            False,
            "",
        ),
        (
            "chronicle exec commandlineArgs good",
            {"examples/07-offheap-lockfree/java/pom.xml": CHRONICLE_POM.format(EXEC_CMD_GOOD)},
            check_chronicle,
            False,
            "",
        ),
        (
            "chronicle exec commandlineArgs missing flag",
            {"examples/07-offheap-lockfree/java/pom.xml": CHRONICLE_POM.format(EXEC_CMD_BAD)},
            check_chronicle,
            False,
            "exec arguments lack",
        ),
        (
            "chronicle flag only outside the exec plugin",
            {
                "examples/07-offheap-lockfree/java/pom.xml": CHRONICLE_POM.format(
                    EXEC_CMD_BAD
                ).replace(
                    "<build>", "<properties><x>" + ANALYTICS_FLAG + "</x></properties><build>"
                )
            },
            check_chronicle,
            False,
            "exec arguments lack",
        ),
        (
            "listings matching",
            {
                "examples/03-x/A.java": LISTED_SRC,
                "_docs/03-x.md": listing_doc("`A.java`", "    int b = 2;\n    return a + b;"),
            },
            check_listings,
            False,
            "",
        ),
        (
            "listings matching across an elision",
            {
                "examples/03-x/A.java": LISTED_SRC,
                "_docs/03-x.md": listing_doc(
                    "`A.java`", "    int a = 1;\n    // ...\n    return a + b;"
                ),
            },
            check_listings,
            False,
            "",
        ),
        (
            "listings drifted",
            {
                "examples/03-x/A.java": LISTED_SRC,
                "_docs/03-x.md": listing_doc("`A.java`", "    int b = 3;\n    return a + b;"),
            },
            check_listings,
            False,
            "not a verbatim run of A.java",
        ),
        (
            "listings unattributed command fence skipped",
            {
                "examples/03-x/A.java": LISTED_SRC,
                "_docs/03-x.md": listing_doc("`A.java`", "ignored", lang="bash"),
            },
            check_listings,
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
            "host-ids home path",
            {"_docs/a.md": "report: /ho" + "me/bob/x/cpp.json\n"},
            check_host_ids,
            False,
            "absolute home path",
        ),
        (
            "host-ids macOS path",
            {"README.md": "see /Us" + "ers/bob/Dev\n"},
            check_host_ids,
            False,
            "absolute home path",
        ),
        (
            "host-ids runtime names",
            {"x/log.txt": "ran as planted-account on planted-host\n"},
            lambda r: check_host_ids(r, ["planted-account"]),
            False,
            "account name or hostname",
        ),
        (
            "host-ids hostname",
            {"x/log.txt": "host planted-host up\n"},
            lambda r: check_host_ids(r, ["planted-account", "planted-host"]),
            False,
            "account name or hostname",
        ),
        (
            "host-ids intel model",
            {"_docs/a.md": "the i9-99999X core\n"},
            check_host_ids,
            False,
            "Intel CPU model number",
        ),
        ("host-ids ryzen", {"_docs/a.md": "a Ryzen 7 5800X\n"}, check_host_ids, False, "AMD CPU"),
        ("host-ids xeon", {"_docs/a.md": "an Xeon server\n"}, check_host_ids, False, "Xeon"),
        (
            "host-ids product_name",
            {"examples/05-jvm-costs/results/r02-run1/p.json": '{"product_name": "Some Laptop 1"}'},
            check_host_ids,
            False,
            'not "redacted"',
        ),
        (
            "host-ids kernel build",
            {
                "examples/05-jvm-costs/results/r02-run1/profile.json": '{"release": "'
                + HOST_KERNEL_BUILD
                + '"}'
            },
            check_host_ids,
            False,
            "kernel with a build number",
        ),
        (
            "host-ids good",
            {
                "examples/05-jvm-costs/results/r02-run1/profile.json": {
                    "product_name": "redacted",
                    "kernel": {"release": "7.2", "version": "PREEMPT_DYNAMIC"},
                    "cpu": {"model": "Intel 8-core/16-thread laptop CPU"},
                },
                "examples/00-prerequisites/results/r01-vm-smoke/vm/profile.json": {
                    "kernel": {"release": "7.2.11-200.lowlatrt.fc44.x86_64+rt"}
                },
                "scripts/lab/build-rt-kernel.sh": f"KERNEL_NVR=kernel-{HOST_KERNEL_BUILD}\n",
                "_docs/a.md": "report: <repo>/examples/x.json and ~/.cache/lowlat\n",
            },
            lambda r: check_host_ids(r, ["planted-account"]),
            False,
            "",
        ),
        # ---- r04 S17 checks
        (
            "env-labels wrong kind",
            {**LOCK, env_path("vm"): env_report("vm", kind="host")},
            check_env_labels,
            False,
            "kind is 'host', lane vm/ needs 'vm'",
        ),
        (
            "env-labels vm without guest_profile",
            {**LOCK, env_path("vm"): env_report("vm", guest_profile="")},
            check_env_labels,
            False,
            "no runtime.environment.guest_profile",
        ),
        (
            "env-labels vm not kvm",
            {
                **LOCK,
                env_path("vm"): {
                    **env_report("vm"),
                    "profile": {"schema": "lowlat-profile/1", "virt": {"type": "none"}},
                },
            },
            check_env_labels,
            False,
            "need 'kvm'",
        ),
        (
            "env-labels missing environment",
            {**LOCK, env_path("host"): {**GOOD_REPORT, "runtime": {}}},
            check_env_labels,
            False,
            "no runtime.environment",
        ),
        (
            "env-labels container latest tag",
            {
                **LOCK,
                env_path("container-cpuset"): env_report(
                    "container-cpuset",
                    container={
                        "runtime": "docker",
                        "image": "lowlat/place-cpp:latest",
                        "image_digest": DIGEST,
                    },
                ),
            },
            check_env_labels,
            False,
            "exact tag",
        ),
        (
            "env-labels container tagless",
            {
                **LOCK,
                env_path("container-cpuset"): env_report(
                    "container-cpuset",
                    container={
                        "runtime": "docker",
                        "image": "lowlat/place-cpp",
                        "image_digest": DIGEST,
                    },
                ),
            },
            check_env_labels,
            False,
            "exact tag",
        ),
        (
            "env-labels container digest not sha256",
            {
                **LOCK,
                env_path("container-cpuset"): env_report(
                    "container-cpuset",
                    container={"runtime": "docker", "image": IMG, "image_digest": "abc"},
                ),
            },
            check_env_labels,
            False,
            "not sha256:<64 hex>",
        ),
        (
            "env-labels container digest differs from IMAGES.lock",
            {
                **LOCK,
                env_path("container-cpuset"): env_report(
                    "container-cpuset",
                    container={
                        "runtime": "docker",
                        "image": IMG,
                        "image_digest": "sha256:" + "d" * 64,
                    },
                ),
            },
            check_env_labels,
            False,
            "differs from IMAGES.lock",
        ),
        (
            "env-labels good lanes",
            {
                **LOCK,
                env_path("host"): env_report("host"),
                env_path("vm"): env_report("vm"),
                env_path("container-cpuset"): env_report("container-cpuset"),
                # the guest's steal ticks and a container lane's simulator are labelled vm
                env_path("container-bridge", "steal.json"): {
                    "schema": "lowlat-steal/1",
                    "runtime": {"environment": {"kind": "vm", "guest_profile": "g"}},
                },
                env_path("container-bridge", "cpp/lateness.json"): env_report("vm"),
                env_path("container-bridge", "quarkus/client-lateness.json"): GOOD_REPORT,
                # an older run is out of scope
                f"{ENV_DIR}/results/r03-run1/host/a.json": env_report("vm"),
            },
            check_env_labels,
            False,
            "",
        ),
        (
            "lang-floor cmake C++20",
            {"examples/a/CMakeLists.txt": "set(CMAKE_CXX_STANDARD 20)\n"},
            check_lang_floor,
            False,
            "C++ standard '20' is below C++23",
        ),
        (
            "lang-floor cxx_std_17",
            {"examples/a/CMakeLists.txt": "target_compile_features(x PUBLIC cxx_std_17)\n"},
            check_lang_floor,
            False,
            "'17' is below C++23",
        ),
        (
            "lang-floor Containerfile -std=c++20",
            {"c/Containerfile": "RUN g++ -std=c++20 x.cpp\n"},
            check_lang_floor,
            False,
            "'20' is below C++23",
        ),
        (
            "lang-floor pom release 21",
            {"examples/a/pom.xml": pom_with("21")},
            check_lang_floor,
            False,
            "release 21 is below JDK 25",
        ),
        (
            "lang-floor parentless pom without release",
            {"examples/a/pom.xml": pom_with(None)},
            check_lang_floor,
            False,
            "does not resolve",
        ),
        (
            "lang-floor pom inherits a low release",
            {
                "examples/pom.xml": pom_with("21"),
                "examples/a/pom.xml": pom_with(None, "../pom.xml"),
            },
            check_lang_floor,
            False,
            "release 21 is below JDK 25",
        ),
        (
            "lang-floor pyproject 3.12",
            {"examples/a/pyproject.toml": '[project]\nname = "a"\nrequires-python = ">=3.12"\n'},
            check_lang_floor,
            False,
            "below Python 3.14",
        ),
        (
            "lang-floor Containerfile names JDK 21",
            {"c/Containerfile": "ARG U=https://example.org/temurin21-binaries/jdk-21.0.5.tar.gz\n"},
            check_lang_floor,
            False,
            "JDK 21 is below the floor 25",
        ),
        (
            "lang-floor Containerfile names Python 3.12",
            {"c/Containerfile": "RUN uv venv --python 3.12 /opt/venv\n"},
            check_lang_floor,
            False,
            "Python 3.12 is below 3.14",
        ),
        (
            "lang-floor good",
            {
                "examples/pom.xml": pom_with("25"),
                "examples/a/pom.xml": pom_with(None, "../pom.xml"),
                "examples/b/pom.xml": pom_with("${java.version}").replace(
                    "<properties>", "<properties><java.version>25</java.version>"
                ),
                "examples/CMakeLists.txt": (
                    "if(CMAKE_CXX_STANDARD LESS 23)\nendif()\nset(CMAKE_CXX_STANDARD 23)\n"
                    "target_compile_features(x PUBLIC cxx_std_26)\n# cxx_std_17 in a comment\n"
                ),
                "examples/a/pyproject.toml": (
                    '[project]\nname = "a"\nrequires-python = ">=3.14,<4"\n'
                ),
                "examples/.python-version": "3.14.9\n",
                "c/Containerfile": (
                    "ARG U=https://example.org/temurin25-binaries/jdk-25.0.5.tar.gz\n"
                    "ARG TEMURIN_BUILD=25.0.5+8\nRUN g++ -std=c++23 x.cpp\n"
                ),
            },
            check_lang_floor,
            False,
            "",
        ),
        (
            "image-pins tagless FROM",
            {"c/Containerfile": f"FROM registry.example.org/ubi@sha256:{'c' * 64}\n"},
            check_image_pins,
            False,
            "has no tag",
        ),
        (
            "image-pins :latest",
            {"c/Containerfile": f"FROM registry.example.org/ubi:latest@sha256:{'c' * 64}\n"},
            check_image_pins,
            False,
            "uses :latest",
        ),
        (
            "image-pins no digest",
            {"c/Containerfile": "FROM registry.example.org/ubi:10.2\n"},
            check_image_pins,
            False,
            "no @sha256",
        ),
        (
            "image-pins unresolved ARG",
            {"c/Containerfile": "ARG BASE\nFROM $BASE\n"},
            check_image_pins,
            False,
            "ARG with no default",
        ),
        (
            "image-pins good",
            {
                "c/Containerfile": (
                    f"ARG B={BASE}\nFROM --platform=linux/amd64 $B AS build\n"
                    f"FROM {BASE} AS runtime\nFROM build AS again\nFROM scratch\n"
                )
            },
            check_image_pins,
            False,
            "",
        ),
        (
            "no-privileged --privileged",
            {"scripts/run.sh": "docker run --rm --privileged img\n"},
            check_no_privileged,
            False,
            "scripts/run.sh:1: --privileged",
        ),
        (
            "no-privileged --cap-add=ALL",
            {"compose.yaml": "services:\n  a:\n    command: docker run --cap-add=ALL img\n"},
            check_no_privileged,
            False,
            "--cap-add=ALL",
        ),
        (
            "no-privileged seccomp=unconfined",
            {"x/run.sh": "docker run --security-opt seccomp=unconfined img\n"},
            check_no_privileged,
            False,
            "seccomp=unconfined",
        ),
        (
            "no-privileged seccomp:unconfined in a workflow",
            {".github/workflows/ci.yml": "options: --security-opt seccomp:unconfined\n"},
            check_no_privileged,
            False,
            "seccomp=unconfined",
        ),
        (
            "no-privileged good",
            {
                "x/run.sh": (
                    "# no --privileged here\ndocker run --cpuset-cpus=2,3 "
                    "--security-opt seccomp=iouring.json img\n"
                ),
                "x/README.md": "never --privileged\n",
            },
            check_no_privileged,
            False,
            "",
        ),
        (
            "ft-reports free-threading build labelled gil",
            {FT_PATH: ft_report(FT_COMPILER, "gil", False)},
            check_ft_reports,
            False,
            "runtime.python_build is 'gil'",
        ),
        (
            "ft-reports free-threading build with the GIL back",
            {FT_PATH: ft_report(FT_COMPILER, "free-threaded", True)},
            check_ft_reports,
            False,
            "build.gil_enabled is True",
        ),
        (
            "ft-reports free-threaded label on a GIL build",
            {FT_PATH: ft_report(GIL_COMPILER, "free-threaded", True)},
            check_ft_reports,
            False,
            "build.compiler lacks 'free-threading'",
        ),
        (
            "ft-reports good",
            {
                FT_PATH: ft_report(FT_COMPILER, "free-threaded", False),
                FT_PATH.replace("-x", "-gil"): ft_report(GIL_COMPILER, "gil", True),
                FT_PATH.replace("-x", "-control"): ft_report(
                    FT_COMPILER, "gil", True, "control; gil_reenabled=PYTHON_GIL=1"
                ),
            },
            check_ft_reports,
            False,
            "",
        ),
        (
            "ft-reports known r03 mislabel listed",
            {
                "examples/09-eliminating-work/results/r03-run1/python/"
                "counters-threads-free-threaded-pair-padded.json": ft_report(
                    GIL_COMPILER, "free-threaded", True
                )
            },
            check_ft_reports,
            False,
            "",
        ),
        (
            "versions-consumers drifted URL",
            {
                "versions.env": 'X_URL="https://example.org/x-2.tar.gz"\n',
                "c.cmake": "URL https://example.org/x-1.tar.gz\n",
            },
            lambda r: check_versions_consumers(r, [("X_URL", "c.cmake", "text")]),
            False,
            "c.cmake: X_URL=https://example.org/x-2.tar.gz not found verbatim",
        ),
        (
            "versions-consumers ARG default drifted",
            {"versions.env": 'M_VERSION="3.9.16"\n', "Containerfile": "ARG M_VERSION=3.9.15\n"},
            lambda r: check_versions_consumers(r, [("M_VERSION", "Containerfile", "arg")]),
            False,
            "as an ARG default",
        ),
        (
            "versions-consumers workflow neither repeats nor sources the pin",
            {"versions.env": 'B_SHA256="abc"\n', "ci.yml": "run: echo hi\n"},
            lambda r: check_versions_consumers(r, [("B_SHA256", "ci.yml", "sourced")]),
            False,
            "B_SHA256=abc not found",
        ),
        (
            "versions-consumers missing consumer",
            {"versions.env": 'B_SHA256="abc"\n'},
            lambda r: check_versions_consumers(r, [("B_SHA256", "ci.yml", "sourced")]),
            False,
            "consumer of B_SHA256 is missing",
        ),
        (
            "versions-consumers good",
            {
                "versions.env": 'B_SHA256="abc"\nQ="3.40.1.1"\nM="3.9.16"\n',
                "ci.yml": '. ./versions.env\necho "$B_SHA256"\n',
                "pom.xml": "<v>3.40.1.1</v>",
                "Containerfile": "ARG M=3.9.16\n",
            },
            lambda r: check_versions_consumers(
                r,
                [
                    ("B_SHA256", "ci.yml", "sourced"),
                    ("Q", "pom.xml", "text"),
                    ("M", "Containerfile", "arg"),
                ],
            ),
            False,
            "",
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
    bad = checked = 0
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
        got = collect_failures(run)
        ok = any(want in f for f in got) if want else not got
        print(f"{'ok  ' if ok else 'BAD '} {name}: {got[0].splitlines()[0] if got else 'passes'}")
        bad += not ok
        checked += 1
    for name, tree, check, git, want in cases:
        got = planted(tree, check, git)
        if want:
            ok = any(want in f for f in got)
            shown = got[0].splitlines()[0] if got else "no failure raised"
        else:
            ok, shown = not got, (got[0] if got else "passes")
        print(f"{'ok  ' if ok else 'BAD '} {name}: {shown}")
        bad += not ok
        checked += 1
    print(f"\nself-test: {checked - bad}/{checked} cases behave")
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
    check_chronicle(ROOT)
    check_listings(ROOT)
    check_means(pages)
    check_no_jfr(ROOT)
    check_java_flags(ROOT)
    check_hw_source(ROOT)
    check_placement(ROOT)
    check_raw_tool_output(ROOT)
    check_tool_versions(ROOT)
    check_vm_runs(ROOT)
    check_env_labels(ROOT)
    check_lang_floor(ROOT)
    check_image_pins(ROOT)
    check_no_privileged(ROOT)
    check_ft_reports(ROOT)
    check_versions_consumers(ROOT)
    check_prerelease(ROOT)
    check_variant_names(ROOT)
    check_host_ids(ROOT)
    if failures:
        print()
        print("\n".join(failures))
        print(f"\n{len(failures)} check(s) failed")
        return 1
    print("\nvalidate: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
