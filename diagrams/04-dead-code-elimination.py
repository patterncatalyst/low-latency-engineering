"""Figure 4.2 — dead-code elimination: guarded vs eliminated.

Regenerate from the repo root:  python3 diagrams/04-dead-code-elimination.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {"x": 20, "y": 50, "w": 840, "h": 90},
    {"x": 20, "y": 150, "w": 840, "h": 80},
    {"x": 20, "y": 240, "w": 840, "h": 90},
]

nodes = []
edges = []
for lang, cy, guard, stat, big in (
    ("C++", 95, "DoNotOptimize(result)", "median 4.73 to 4.76 ns", "at least 473x lower"),
    ("Java", 285, "Blackhole.consume(result)", "p50 32 ns", "at least 3,200x lower"),
):
    nodes += [
        {"x": 35, "y": cy - 25, "w": 60, "h": 50, "style": "user", "lines": [lang]},
        {"x": 120, "y": cy - 28, "w": 160, "h": 56, "style": "sub", "lines": ["guarded", guard]},
        {
            "x": 305,
            "y": cy - 28,
            "w": 160,
            "h": 56,
            "style": "ink",
            "lines": [stat, "work measured"],
        },
        {
            "x": 485,
            "y": cy - 28,
            "w": 140,
            "h": 56,
            "style": "accent",
            "lines": ["eliminated", "result unused: removed"],
        },
        {"x": 655, "y": cy - 28, "w": 195, "h": 56, "style": "ghost", "lines": ["~0 ns", big]},
    ]
    edges += [
        {"x1": 95, "y1": cy, "x2": 120, "y2": cy},
        {"x1": 280, "y1": cy, "x2": 305, "y2": cy},
        {"x1": 625, "y1": cy, "x2": 655, "y2": cy, "amber": True, "dashed": True},
    ]

nodes += [
    {"x": 35, "y": 165, "w": 60, "h": 50, "style": "user", "lines": ["Python"]},
    {
        "x": 120,
        "y": 162,
        "w": 730,
        "h": 56,
        "style": "ghost",
        "lines": ["no elimination", "CPython keeps the call; the contrast is warm-up"],
    },
]
edges.append({"x1": 95, "y1": 190, "x2": 120, "y2": 190, "dashed": True})

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Unused result: the optimizer removes the work, so the benchmark times nothing",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 358,
        "text": "The harness cannot prevent it; the benchmark must consume the result.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("04-dead-code-elimination", 880, 380, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom

    xml.dom.minidom.parse(os.path.join(g.OUT, "04-dead-code-elimination.svg"))
    json.load(open(os.path.join(g.OUT, "04-dead-code-elimination.excalidraw")))
    print("ok: 04-dead-code-elimination")
