"""Figure 5.2 — escape analysis removes the allocation.

Regenerate from the repo root:  python3 diagrams/05-escape-analysis.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

LANES = [
    (
        "escaping: the decision is stored in a field",
        "sub",
        ["new DivertDecision", "stored, so it escapes"],
        "ink",
        ["gc.alloc.rate.norm", "~24 B/op"],
        False,
    ),
    (
        "scalar-replaced: read and dropped in the loop",
        "accent",
        ["Scalar replacement", "fields live in registers"],
        "ink",
        ["gc.alloc.rate.norm", "< 1 B/op"],
        True,
    ),
    (
        "--no-escape-analysis: -XX:-DoEscapeAnalysis",
        "ghost",
        ["Scalar replacement", "absent, object is built"],
        "ink",
        ["gc.alloc.rate.norm", "~24 B/op"],
        False,
    ),
]

bands = []
nodes = []
edges = []
for i, (label, style, mid, rstyle, res, amber) in enumerate(LANES):
    y0 = 44 + i * 110
    cy = y0 + 59
    bands.append({"x": 20, "y": y0, "w": 840, "h": 100, "label": label})
    nodes += [
        {
            "x": 40,
            "y": y0 + 32,
            "w": 170,
            "h": 54,
            "style": "user",
            "lines": ["JMH decide()", "one call per parcel"],
        },
        {"x": 290, "y": y0 + 32, "w": 290, "h": 54, "style": style, "lines": mid},
        {"x": 660, "y": y0 + 32, "w": 190, "h": 54, "style": rstyle, "lines": res},
    ]
    edges += [
        {"x1": 210, "y1": cy, "x2": 290, "y2": cy, "amber": amber},
        {"x1": 580, "y1": cy, "x2": 660, "y2": cy, "amber": amber},
    ]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "C2 removes an object that never leaves the method",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 388,
        "text": (
            "An allocation is a TLAB bump; its cost is the bytes "
            "it adds to the next young collection."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("05-escape-analysis", 880, 408, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "05-escape-analysis.svg"))
    json.loads((Path(g.OUT) / "05-escape-analysis.excalidraw").read_text(encoding="utf-8"))
    print("ok: 05-escape-analysis")
