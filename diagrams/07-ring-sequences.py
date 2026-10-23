"""Figure 7.2 — sequences and slots in a ring buffer.

Regenerate from the repo root:  python3 diagrams/07-ring-sequences.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {"x": 40, "y": 118, "w": 760, "h": 100, "label": "Ring of 8 slots (illustration)"},
]

SLOTS = [
    ("accent", "seq 8"),
    ("accent", "seq 9"),
    ("accent", "seq 10"),
    ("ghost", "next: 11"),
    ("ghost", "seq 4 done"),
    ("accent", "seq 5"),
    ("accent", "seq 6"),
    ("accent", "seq 7"),
]

nodes = []
for i, (style, text) in enumerate(SLOTS):
    nodes.append(
        {"x": 60 + 90 * i, "y": 150, "w": 80, "h": 50, "style": style, "lines": [f"slot {i}", text]}
    )
nodes += [
    {
        "x": 280,
        "y": 56,
        "w": 180,
        "h": 54,
        "style": "user",
        "lines": ["Producer", "cursor: own cache line"],
    },
    {
        "x": 460,
        "y": 250,
        "w": 180,
        "h": 54,
        "style": "user",
        "lines": ["Consumer", "cursor: own cache line"],
    },
    {
        "x": 40,
        "y": 250,
        "w": 380,
        "h": 54,
        "style": "sub",
        "lines": ["slot = sequence & (slots - 1)", "power of two (65,536 in run)"],
    },
    {
        "x": 680,
        "y": 250,
        "w": 170,
        "h": 54,
        "style": "ghost",
        "lines": ["Full ring", "the producer would wait"],
    },
]

edges = [
    {
        "x1": 370,
        "y1": 110,
        "x2": 370,
        "y2": 150,
        "amber": True,
        "label": "publish seq 11",
        "lx": 54,
        "ly": 0,
    },
    {"x1": 550, "y1": 200, "x2": 550, "y2": 250, "label": "read seq 5", "lx": 40, "ly": 0},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "A sequence only grows; masking turns it into a slot",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 340,
        "text": (
            "Producer and consumer each write one cursor and read "
            "the other, so neither takes a lock."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("07-ring-sequences", 880, 360, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom

    xml.dom.minidom.parse(os.path.join(g.OUT, "07-ring-sequences.svg"))
    json.load(open(os.path.join(g.OUT, "07-ring-sequences.excalidraw")))
    print("ok: 07-ring-sequences")
