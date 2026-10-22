"""Figure 0.1 — the sortation line and the scan-to-divert budget.

Regenerate from the repo root:  python3 diagrams/00-sortation-line.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

Y = 110  # station row
H = 70
W = 120
xs = [30, 170, 310, 450, 590, 730]
stations = [
    ("sub", ["Checkweigher", "weight stream"]),
    ("sub", ["Dimensioner", "L x W x H"]),
    ("accent", ["Scanner", "barcode + confidence"]),
    ("sub", ["Labeler", "label applied"]),
    ("ghost", ["", ""]),
    ("accent", ["Diverter", "lane command"]),
]

nodes = []
for x, (style, lines) in zip(xs, stations, strict=True):
    if style != "ghost":
        nodes.append({"x": x, "y": Y, "w": W, "h": H, "style": style, "lines": lines})

# belt
nodes.append({"x": 30, "y": Y + H + 14, "w": 820, "h": 6, "style": "kernel", "lines": [""]})

# controller and encoder
nodes += [
    {
        "x": 380,
        "y": 290,
        "w": 200,
        "h": 70,
        "style": "ink",
        "lines": ["Sort controller", "sense -> decide -> act"],
    },
    {
        "x": 30,
        "y": 290,
        "w": 200,
        "h": 70,
        "style": "kernel",
        "lines": ["PLC / encoder", "belt-position ticks"],
    },
]

# edge "lx"/"ly" are offsets from the arrow midpoint
edges = [
    {"x1": 370, "y1": Y + H, "x2": 440, "y2": 290, "label": "sense", "lx": -24, "ly": 0},
    {
        "x1": 580,
        "y1": 325,
        "x2": 790,
        "y2": Y + H,
        "amber": True,
        "label": "act",
        "lx": 18,
        "ly": 10,
    },
    {"x1": 230, "y1": 325, "x2": 380, "y2": 325, "label": "clock", "lx": 0, "ly": -8},
    {
        "x1": 370,
        "y1": 60,
        "x2": 790,
        "y2": 60,
        "bidir": True,
        "amber": True,
        "label": "scanner to diverter: 1.2 m at 2.5 m/s",
        "lx": 0,
        "ly": -8,
    },
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "scan-to-divert deadline = distance / belt speed ~ 480 ms",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {"x": 850, "y": Y + H + 40, "text": "belt flow ->", "anchor": "end", "size": 12},
    {
        "x": 440,
        "y": 395,
        "text": "The belt never waits: a late decision is a mis-sort.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("00-sortation-line", 880, 420, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom

    xml.dom.minidom.parse(os.path.join(g.OUT, "00-sortation-line.svg"))
    json.load(open(os.path.join(g.OUT, "00-sortation-line.excalidraw")))
    print("ok: 00-sortation-line")
