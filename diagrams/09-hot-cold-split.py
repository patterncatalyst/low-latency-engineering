"""Figure 9.3: a fat record against hot columns.

Regenerate from the repo root:  python3 diagrams/09-hot-cold-split.py
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
    {"x": 20, "y": 44, "w": 840, "h": 150, "label": "fat-record: one 80 B struct per slot"},
    {"x": 20, "y": 206, "w": 840, "h": 202, "label": "hot-cold: sweep columns and a cold column"},
]

s0 = box(40, 90, 80, 56, "sub", "slot 0", "80 B")
s1 = box(130, 90, 80, 56, "sub", "slot 1", "80 B")
s2 = box(220, 90, 80, 56, "sub", "slot 2", "80 B")
sweep_a = box(340, 80, 220, 76, "ink", "Sweep p50", "C++ 4.18-4.21 ms", "Java 9.25-9.27 ms")
miss_a = box(600, 80, 240, 76, "ink", "D1 read misses per slot", "1.2500", "cachegrind, exact")

hot1 = box(40, 240, 210, 50, "accent", "due_tick column", "8 B per slot")
hot2 = box(40, 300, 210, 50, "accent", "state column", "1 B per slot")
cold = box(40, 358, 210, 40, "ghost", "Cold fields", "71 B per slot, aside")
sweep_b = box(340, 262, 220, 76, "ink", "Sweep p50", "C++ 0.57 ms", "Java 0.44 ms")
miss_b = box(600, 262, 240, 76, "ink", "D1 read misses per slot", "0.1406", "cachegrind, exact")

nodes = [s0, s1, s2, sweep_a, miss_a, hot1, hot2, cold, sweep_b, miss_b]

edges = [
    edge(right(s2), left(sweep_a)),
    edge(right(hot1), left(sweep_b, 0.3), amber=True),
    edge(right(hot2), left(sweep_b, 0.7), amber=True),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": (
            "The sweep reads 9 of every 80 bytes; splitting them keeps the other 71 "
            "out of the cache"
        ),
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 424,
        "text": (
            "Fat record over hot-cold sweep p50: 7.31-7.38x in C++, 21.07-21.10x in "
            "Java; D1 read misses per slot 8.89x (exact)."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("09-hot-cold-split", 880, 440, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "09-hot-cold-split.svg"))
    json.loads((Path(g.OUT) / "09-hot-cold-split.excalidraw").read_text(encoding="utf-8"))
    print("ok: 09-hot-cold-split")
