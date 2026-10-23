"""Figure 6.2: headroom decides whether allocation stalls.

Regenerate from the repo root:  python3 diagrams/06-headroom-stall.py
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
        "h": 130,
        "label": "Right-sized: -Xms4g -Xmx4g, a live set well under the heap",
    },
    {
        "x": 20,
        "y": 190,
        "w": 840,
        "h": 130,
        "label": "Undersized: heap = 1.05x the live set, same allocation rate",
    },
]

nodes = [
    {
        "x": 40,
        "y": 90,
        "w": 150,
        "h": 60,
        "style": "user",
        "lines": ["Handler", "~400 MB/s of garbage"],
    },
    {
        "x": 230,
        "y": 90,
        "w": 190,
        "h": 60,
        "style": "sub",
        "lines": ["ZGC cycles", "ahead of the rate"],
    },
    {
        "x": 460,
        "y": 90,
        "w": 190,
        "h": 60,
        "style": "ink",
        "lines": ["0 allocation stalls", "p99.9 0.147-0.149 ms"],
    },
    {
        "x": 40,
        "y": 236,
        "w": 150,
        "h": 60,
        "style": "user",
        "lines": ["Handler", "~400 MB/s of garbage"],
    },
    {
        "x": 230,
        "y": 236,
        "w": 190,
        "h": 60,
        "style": "sub",
        "lines": ["ZGC cycles", "free memory runs out"],
    },
    {
        "x": 460,
        "y": 236,
        "w": 180,
        "h": 60,
        "style": "accent",
        "lines": ["allocation stall", "the thread waits"],
    },
    {
        "x": 680,
        "y": 236,
        "w": 170,
        "h": 60,
        "style": "ink",
        "lines": ["530-977 stalls", "p99.9 50.4-113.0 ms"],
    },
]

edges = [
    {"x1": 190, "y1": 120, "x2": 230, "y2": 120},
    {"x1": 420, "y1": 120, "x2": 460, "y2": 120},
    {"x1": 190, "y1": 266, "x2": 230, "y2": 266},
    {"x1": 420, "y1": 266, "x2": 460, "y2": 266, "amber": True},
    {"x1": 640, "y1": 266, "x2": 680, "y2": 266, "amber": True},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "A concurrent collector is only as good as its headroom",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 348,
        "text": (
            "A stall is a pause by another name: the allocating thread waits for the collector."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("06-headroom-stall", 880, 370, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "06-headroom-stall.svg"))
    json.loads((Path(g.OUT) / "06-headroom-stall.excalidraw").read_text(encoding="utf-8"))
    print("ok: 06-headroom-stall")
