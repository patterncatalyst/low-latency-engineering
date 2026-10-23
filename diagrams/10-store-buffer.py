"""Figure 10.2: the store buffer and the induction-gap test.

Regenerate from the repo root:  python3 diagrams/10-store-buffer.py
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


bands = [{"x": 20, "y": 44, "w": 840, "h": 190, "label": "Two induction stations, one gap"}]

sa = box(40, 76, 200, 56, "user", "Station A", "store flagA, load flagB")
sb = box(640, 76, 200, 56, "user", "Station B", "store flagB, load flagA")
bufa = box(40, 162, 200, 56, "accent", "Store buffer A", "flagA = 1 pending")
bufb = box(640, 162, 200, 56, "accent", "Store buffer B", "flagB = 1 pending")
mem = box(330, 162, 220, 56, "kernel", "Shared memory", "flagA = 0, flagB = 0")

ra = box(
    40,
    280,
    400,
    76,
    "ink",
    "release/acquire: both read 0",
    "C++ 2,306,475-9,888,040 of 10,000,000",
    "Java 85.0-98.6 M jcstress samples",
)
rs = box(
    460,
    280,
    400,
    76,
    "ink",
    "seq_cst, volatile: both read 0",
    "C++ 0 of 10,000,000",
    "Java 0 jcstress samples",
)

nodes = [sa, sb, bufa, bufb, mem, ra, rs]

edges = [
    edge(bottom(sa), top(bufa), amber=True, label="store", lx=26, ly=2),
    edge(bottom(sb), top(bufb), amber=True, label="store", lx=26, ly=2),
    edge(right(bufa), left(mem), dashed=True, label="drains later", lx=0, ly=-8),
    edge(left(bufb), right(mem), dashed=True, label="drains later", lx=0, ly=-8),
    edge(right(sa), top(mem, 0.2), label="load reads 0", lx=-30, ly=18),
    edge(left(sb), top(mem, 0.8), label="load reads 0", lx=30, ly=18),
    edge(bottom(mem, 0.25), top(ra, 0.75), amber=True),
    edge(bottom(mem, 0.75), top(rs, 0.25)),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "A store can sit in a buffer while the other station reads the old value",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 384,
        "text": (
            "seq_cst (an xchg store, 4 ns against 0 ns for release) forbids the "
            "both-zero outcome; release/acquire allows it."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("10-store-buffer", 880, 400, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "10-store-buffer.svg"))
    json.loads((Path(g.OUT) / "10-store-buffer.excalidraw").read_text(encoding="utf-8"))
    print("ok: 10-store-buffer")
