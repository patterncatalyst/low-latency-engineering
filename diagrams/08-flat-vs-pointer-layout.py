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
    {
        "x": 20,
        "y": 44,
        "w": 840,
        "h": 172,
        "label": "object-table: ParcelState[] of 1,000,000 references",
    },
    {
        "x": 20,
        "y": 310,
        "w": 840,
        "h": 108,
        "label": "flat-table: one MemorySegment of 24-byte structs in an Arena",
    },
]

nodes = [
    {
        "x": 40,
        "y": 100,
        "w": 170,
        "h": 70,
        "style": "sub",
        "lines": ["ParcelState[]", "references only"],
    },
    {
        "x": 300,
        "y": 80,
        "w": 150,
        "h": 40,
        "style": "sub",
        "lines": ["ParcelState", "header + fields"],
    },
    {
        "x": 330,
        "y": 124,
        "w": 150,
        "h": 40,
        "style": "sub",
        "lines": ["ParcelState", "header + fields"],
    },
    {
        "x": 310,
        "y": 168,
        "w": 150,
        "h": 40,
        "style": "sub",
        "lines": ["ParcelState", "header + fields"],
    },
    {
        "x": 560,
        "y": 116,
        "w": 290,
        "h": 56,
        "style": "ink",
        "lines": ["sweep of 1,000,000, p50", "5.01-5.03 ms"],
    },
    {
        "x": 40,
        "y": 244,
        "w": 400,
        "h": 52,
        "style": "ghost",
        "lines": ["ParcelState as a value class", "JEP 401: JDK 28 EA only"],
    },
    {"x": 40, "y": 348, "w": 90, "h": 44, "style": "accent", "lines": ["slot 0", "24 B"]},
    {"x": 140, "y": 348, "w": 90, "h": 44, "style": "accent", "lines": ["slot 1", "24 B"]},
    {"x": 240, "y": 348, "w": 90, "h": 44, "style": "accent", "lines": ["slot 2", "24 B"]},
    {"x": 340, "y": 348, "w": 90, "h": 44, "style": "accent", "lines": ["slot 3", "24 B"]},
    {
        "x": 560,
        "y": 342,
        "w": 290,
        "h": 56,
        "style": "ink",
        "lines": ["sweep of 1,000,000, p50", "0.97-1.00 ms"],
    },
]

edges = [
    {"x1": 210, "y1": 115, "x2": 300, "y2": 100},
    {"x1": 210, "y1": 135, "x2": 330, "y2": 144},
    {"x1": 210, "y1": 158, "x2": 310, "y2": 188},
    {"x1": 480, "y1": 144, "x2": 560, "y2": 144},
    {"x1": 430, "y1": 370, "x2": 560, "y2": 370, "amber": True},
    {
        "x1": 125,
        "y1": 244,
        "x2": 125,
        "y2": 170,
        "dashed": True,
        "label": "same flat layout, on the heap",
        "lx": 100,
        "ly": 4,
    },
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
        "y": 440,
        "text": (
            "40 B per object (32 B with compact headers) against 24 B "
            "per flat slot, no header, no pointer."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("08-flat-vs-pointer-layout", 880, 460, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "08-flat-vs-pointer-layout.svg"))
    json.loads((Path(g.OUT) / "08-flat-vs-pointer-layout.excalidraw").read_text(encoding="utf-8"))
    print("ok: 08-flat-vs-pointer-layout")
