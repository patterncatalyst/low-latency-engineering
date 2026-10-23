"""Figure 1.2 — one slow parcel in 100 makes the distribution bimodal.

Regenerate from the repo root:  python3 diagrams/01-bimodal-tail.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {"x": 20, "y": 44, "w": 840, "h": 120, "label": "One core, per-parcel handling"},
]

nodes = [
    {"x": 60, "y": 96, "w": 56, "h": 50, "style": "sub", "lines": ["#98"]},
    {"x": 126, "y": 96, "w": 56, "h": 50, "style": "sub", "lines": ["#99"]},
    {
        "x": 196,
        "y": 96,
        "w": 220,
        "h": 50,
        "style": "accent",
        "lines": ["#100 slow path ~2 ms", "busy loop, holds the core"],
    },
    {"x": 426, "y": 96, "w": 56, "h": 50, "style": "sub", "lines": ["#101"]},
    {"x": 492, "y": 96, "w": 56, "h": 50, "style": "sub", "lines": ["#102"]},
    {"x": 558, "y": 96, "w": 56, "h": 50, "style": "sub", "lines": ["#103"]},
    {"x": 624, "y": 96, "w": 56, "h": 50, "style": "sub", "lines": ["#104"]},
    {"x": 40, "y": 250, "w": 230, "h": 70, "style": "ink", "lines": ["Fast mode", "p50 95-232 us"]},
    {
        "x": 400,
        "y": 250,
        "w": 240,
        "h": 70,
        "style": "ink",
        "lines": ["Slow mode", "p99 2.1-6.8 ms", "#100 and the parcels behind it"],
    },
    {
        "x": 670,
        "y": 250,
        "w": 190,
        "h": 70,
        "style": "ghost",
        "lines": ["one summary number", "describes neither group"],
    },
]

edges = [
    {"x1": 154, "y1": 146, "x2": 154, "y2": 250, "label": "p50", "lx": 16, "ly": 0},
    {"x1": 454, "y1": 146, "x2": 454, "y2": 250, "amber": True, "label": "p99", "lx": 16, "ly": 0},
    {"x1": 306, "y1": 146, "x2": 420, "y2": 250, "amber": True},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "p50 stays in the fast mode; p99 lands in the millisecond slow mode",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {"x": 489, "y": 88, "text": "queued behind it", "anchor": "middle", "size": 11},
    {
        "x": 440,
        "y": 365,
        "text": (
            "1 parcel in 100 takes the slow path and delays the next few; the median stays in the fast mode."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("01-bimodal-tail", 880, 385, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "01-bimodal-tail.svg"))
    json.loads((Path(g.OUT) / "01-bimodal-tail.excalidraw").read_text(encoding="utf-8"))
    print("ok: 01-bimodal-tail")
