"""Figure 9.1: the working set against the cache hierarchy.

Regenerate from the repo root:  python3 diagrams/09-working-set.py
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
    {"x": 20, "y": 44, "w": 470, "h": 356, "label": "L3: 24 MiB"},
    {"x": 40, "y": 80, "w": 430, "h": 300, "label": "L2: 1.25 MiB"},
    {"x": 60, "y": 306, "w": 390, "h": 56, "label": "L1d: 48 KiB, 64 B lines"},
    {"x": 510, "y": 44, "w": 350, "h": 356, "label": "RAM: the hub trackers, 1,000,000 parcels"},
]

line = box(60, 116, 390, 56, "accent", "Line tracker: 4,800 parcels", "node-map and flat-map")
line_node = box(60, 214, 185, 56, "ink", "47-48 ns", "node-map lookup p50")
line_flat = box(265, 214, 185, 56, "ink", "19-20 ns", "flat-map lookup p50")

hub_node = box(520, 116, 160, 70, "sub", "Hub node-map", "148.1 MB built", "node and string")
hub_flat = box(700, 116, 150, 70, "accent", "Hub flat-map", "126.0 MB built", "index + columns")
res_node = box(520, 226, 160, 70, "ink", "388-394 ns", "lookup p50", "5.04-5.15 LL misses")
res_flat = box(700, 226, 150, 70, "ink", "113-115 ns", "lookup p50", "0.19-0.23 LL misses")
beyond = box(
    520, 326, 330, 56, "ghost", "Both hub maps exceed L3", "148.1 and 126.0 MB against 24 MiB"
)

nodes = [line, line_node, line_flat, hub_node, hub_flat, res_node, res_flat, beyond]

edges = [
    edge((top(line_node)[0], bottom(line)[1]), top(line_node)),
    edge((top(line_flat)[0], bottom(line)[1]), top(line_flat), amber=True),
    edge(bottom(hub_node), top(res_node)),
    edge(bottom(hub_flat), top(res_flat), amber=True),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Lookup cost follows the working set: L2 holds the line tracker, RAM holds the hub",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 424,
        "text": (
            "The 4,800-parcel line tracker fits L2 in both maps; at 1,000,000 "
            "parcels both maps live in RAM and the layout sets the misses."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("09-working-set", 880, 440, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "09-working-set.svg"))
    json.loads((Path(g.OUT) / "09-working-set.excalidraw").read_text(encoding="utf-8"))
    print("ok: 09-working-set")
