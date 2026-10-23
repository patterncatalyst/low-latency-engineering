"""Figure 10.1: blocking, lock-free and wait-free claims.

Regenerate from the repo root:  python3 diagrams/10-progress-guarantees.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")


def box(x, y, w, h, style, *lines):
    return {"x": x, "y": y, "w": w, "h": h, "style": style, "lines": list(lines)}


def top(n, f=0.5):
    return (round(n["x"] + n["w"] * f), n["y"])


def bottom(n, f=0.5):
    return (round(n["x"] + n["w"] * f), n["y"] + n["h"])


def left(n, f=0.5):
    return (n["x"], round(n["y"] + n["h"] * f))


def right(n, f=0.5):
    return (n["x"] + n["w"], round(n["y"] + n["h"] * f))


def edge(a, b, **kw):
    return {"x1": a[0], "y1": a[1], "x2": b[0], "y2": b[1], **kw}


bands = [
    {"x": 20, "y": 44, "w": 840, "h": 120, "label": "Blocking"},
    {"x": 20, "y": 174, "w": 840, "h": 120, "label": "Lock-free"},
    {"x": 20, "y": 304, "w": 840, "h": 120, "label": "Wait-free claim step"},
]


def row(y, var, mech, r1, r2, amber=False):
    v = box(40, y + 38, 190, 56, "user", *var)
    m = box(270, y + 38, 170, 56, "accent" if amber else "sub", *mech)
    a = box(490, y + 26, 350, 42, "ink", *r1)
    b = box(490, y + 74, 350, 42, "ink", *r2)
    es = [
        edge(right(v), left(m), amber=amber),
        edge(right(m, 0.3), left(a), amber=amber),
        edge(right(m, 0.7), left(b), amber=amber),
    ]
    return [v, m, a, b], es


n1, e1 = row(
    44,
    ("mutex", "std::mutex, ReentrantLock"),
    ("futex sleep", "a loser parks"),
    ("claim p99", "C++ 2,633-2,985 ns, Java 8,187-8,383 ns"),
    ("voluntary switches, least-switching", "C++ 5,406-9,746, Java 47,556-61,712"),
)
n2, e2 = row(
    174,
    ("cas-loop", "CAS retry loop"),
    ("retry", "a failed CAS tries again"),
    ("claim p99", "C++ 478-502 ns, Java 1,409-1,837 ns"),
    ("largest retry count in one claim", "C++ 7-10, Java 27-55"),
)
n3, e3 = row(
    304,
    ("fetch-add", "one lock xadd"),
    ("one step", "1 step per claim, exact"),
    ("claim p99", "C++ 400-468 ns, Java 516-584 ns"),
    ("voluntary switches, most-switching", "C++ 1, Java 1-3"),
    amber=True,
)
nodes = n1 + n2 + n3
edges = e1 + e2 + e3

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Wait-free bounds the steps of a claim, not the time it takes",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 440,
        "text": (
            "Claim p99, mutex over fetch-add: 6.10-6.45x in C++ and 14.13-15.23x in "
            "Java (median of 3 alternations per run)."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("10-progress-guarantees", 880, 456, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "10-progress-guarantees.svg"))
    json.loads((Path(g.OUT) / "10-progress-guarantees.excalidraw").read_text(encoding="utf-8"))
    print("ok: 10-progress-guarantees")
