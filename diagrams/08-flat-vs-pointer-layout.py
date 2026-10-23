"""Figure 8.2 — an array of objects against a flat table.

Regenerate from the repo root:  python3 diagrams/08-flat-vs-pointer-layout.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {"x": 20, "y": 44, "w": 840, "h": 180, "label": "object-table: ParcelState[] of 1,000,000 references"},
    {"x": 20, "y": 236, "w": 840, "h": 120, "label": "flat-table: one MemorySegment of 24-byte structs in an Arena"},
]

nodes = [
    {"x": 40, "y": 100, "w": 170, "h": 70, "style": "sub", "lines": ["ParcelState[]", "references only"]},
    {"x": 300, "y": 84, "w": 150, "h": 36, "style": "sub", "lines": ["ParcelState", "header + fields"]},
    {"x": 330, "y": 130, "w": 150, "h": 36, "style": "sub", "lines": ["ParcelState", "header + fields"]},
    {"x": 310, "y": 176, "w": 150, "h": 36, "style": "sub", "lines": ["ParcelState", "header + fields"]},
    {"x": 560, "y": 120, "w": 290, "h": 56, "style": "ink", "lines": ["sweep of 1,000,000, p50", "5.01-5.03 ms"]},
    {"x": 40, "y": 292, "w": 90, "h": 44, "style": "accent", "lines": ["slot 0", "24 B"]},
    {"x": 140, "y": 292, "w": 90, "h": 44, "style": "accent", "lines": ["slot 1", "24 B"]},
    {"x": 240, "y": 292, "w": 90, "h": 44, "style": "accent", "lines": ["slot 2", "24 B"]},
    {"x": 340, "y": 292, "w": 90, "h": 44, "style": "accent", "lines": ["slot 3", "24 B"]},
    {"x": 560, "y": 286, "w": 290, "h": 56, "style": "ink", "lines": ["sweep of 1,000,000, p50", "0.97-1.00 ms"]},
    {
        "x": 40,
        "y": 376,
        "w": 400,
        "h": 56,
        "style": "ghost",
        "lines": ["ParcelState as a value class", "JDK 28 EA, not GA"],
    },
]

edges = [
    {"x1": 210, "y1": 115, "x2": 300, "y2": 102},
    {"x1": 210, "y1": 135, "x2": 330, "y2": 148},
    {"x1": 210, "y1": 158, "x2": 310, "y2": 194},
    {"x1": 480, "y1": 148, "x2": 560, "y2": 148},
    {"x1": 430, "y1": 314, "x2": 560, "y2": 314, "amber": True},
    {"x1": 190, "y1": 376, "x2": 190, "y2": 336, "dashed": True},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Chasing a pointer per parcel costs more than walking one run of memory",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 452,
        "text": "40 B per object (32 B with compact headers) against 24 B per flat slot, no header, no pointer.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("08-flat-vs-pointer-layout", 880, 460, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom

    xml.dom.minidom.parse(os.path.join(g.OUT, "08-flat-vs-pointer-layout.svg"))
    json.load(open(os.path.join(g.OUT, "08-flat-vs-pointer-layout.excalidraw")))
    print("ok: 08-flat-vs-pointer-layout")
