"""Figure 6.1: what each collector stops.

Regenerate from the repo root:  python3 diagrams/06-collector-pauses.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

ROWS = [
    ("sub", ["stop-the-world", "all threads stop, full walk"], "158-162 ms", False),
    ("sub", ["g1", "stop-the-world evacuation"], "21.4-22.0 ms", False),
    ("accent", ["zgc", "concurrent mark and relocate"], "0.020-0.039 ms", True),
    ("sub", ["shenandoah-gen", "concurrent evacuation"], "0.61-0.81 ms", False),
]

bands = []
nodes = [
    {
        "x": 40,
        "y": 56,
        "w": 170,
        "h": 300,
        "style": "user",
        "lines": ["Tracker", "10 kHz x 30 s", "4 GB heap, pre-touched", "JFR pause events"],
    },
]
edges = []
for i, (style, lines, pause, amber) in enumerate(ROWS):
    y = 56 + i * 80
    cy = y + 30
    nodes += [
        {"x": 290, "y": y, "w": 300, "h": 60, "style": style, "lines": lines},
        {"x": 670, "y": y, "w": 180, "h": 60, "style": "ink", "lines": ["max GC pause", pause]},
    ]
    edges += [
        {"x1": 210, "y1": cy, "x2": 290, "y2": cy, "amber": amber},
        {"x1": 590, "y1": cy, "x2": 670, "y2": cy, "amber": amber},
    ]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Same bytecode, same allocation: the collector sets the pause",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 388,
        "text": (
            "The pause is half of the tail; the other half is "
            "whether the collector keeps up (Figure 6.2)."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("06-collector-pauses", 880, 408, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "06-collector-pauses.svg"))
    json.loads((Path(g.OUT) / "06-collector-pauses.excalidraw").read_text(encoding="utf-8"))
    print("ok: 06-collector-pauses")
