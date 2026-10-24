"""Figure 0.3: the measurement pipeline from simulator to checked report.

Regenerate from the repo root:  python3 diagrams/00-measurement-pipeline.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = []

nodes = [
    {
        "x": 20,
        "y": 175,
        "w": 120,
        "h": 70,
        "style": "user",
        "lines": ["line-simulator", "C++, 1 kHz"],
    },
    {
        "x": 165,
        "y": 175,
        "w": 120,
        "h": 70,
        "style": "kernel",
        "lines": ["UDP datagrams", "127.0.0.1"],
    },
    {"x": 330, "y": 100, "w": 130, "h": 60, "style": "user", "lines": ["C++", "-> HdrHistogram"]},
    {
        "x": 330,
        "y": 190,
        "w": 130,
        "h": 60,
        "style": "user",
        "lines": ["Python", "-> HdrHistogram"],
    },
    {"x": 330, "y": 280, "w": 130, "h": 60, "style": "user", "lines": ["Java", "-> HdrHistogram"]},
    {
        "x": 500,
        "y": 175,
        "w": 160,
        "h": 70,
        "style": "ink",
        "lines": ["lowlat-report/1", "JSON + machine profile"],
    },
    {
        "x": 500,
        "y": 80,
        "w": 160,
        "h": 60,
        "style": "sub",
        "lines": ["profile.sh", "machine profile"],
    },
    {
        "x": 700,
        "y": 175,
        "w": 160,
        "h": 70,
        "style": "accent",
        "lines": ["lowlat-report check", "schema + decode,", "recompute percentiles"],
    },
]

edges = [
    {"x1": 140, "y1": 210, "x2": 165, "y2": 210},
    {"x1": 285, "y1": 195, "x2": 330, "y2": 130},
    {"x1": 285, "y1": 210, "x2": 330, "y2": 220},
    {"x1": 285, "y1": 225, "x2": 330, "y2": 310},
    {"x1": 460, "y1": 130, "x2": 500, "y2": 190},
    {"x1": 460, "y1": 220, "x2": 500, "y2": 210},
    {"x1": 460, "y1": 310, "x2": 500, "y2": 230},
    {"x1": 580, "y1": 140, "x2": 580, "y2": 175},
    {"x1": 660, "y1": 210, "x2": 700, "y2": 210, "amber": True},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Three kits, one report format, one checker",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 375,
        "text": "Percentiles are recomputed from the histogram, never trusted.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("00-measurement-pipeline", 880, 395, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "00-measurement-pipeline.svg"))
    json.loads((Path(g.OUT) / "00-measurement-pipeline.excalidraw").read_text(encoding="utf-8"))
    print("ok: 00-measurement-pipeline")
