"""Figure 3.2 — a 200 ms stall seen by four clocks.

Regenerate from the repo root:  python3 diagrams/03-coordinated-omission.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {"x": 20, "y": 44, "w": 840, "h": 170, "label": "UDP run: ~200 parcels queue behind the stall"},
    {
        "x": 20,
        "y": 226,
        "w": 840,
        "h": 170,
        "label": "Closed-loop client: 1 request per 1 ms, same stall",
    },
]

nodes = [
    {"x": 40, "y": 106, "w": 150, "h": 56, "style": "user", "lines": ["Consumer", "stalls 200 ms"]},
    {
        "x": 290,
        "y": 72,
        "w": 250,
        "h": 56,
        "style": "sub",
        "lines": ["receipt-time", "clock starts at dequeue"],
    },
    {
        "x": 290,
        "y": 140,
        "w": 250,
        "h": 56,
        "style": "accent",
        "lines": ["intended-time", "clock starts at belt schedule"],
    },
    {
        "x": 630,
        "y": 72,
        "w": 220,
        "h": 56,
        "style": "ink",
        "lines": ["p99 5.1-5.4 us", "C++: stall hidden"],
    },
    {
        "x": 630,
        "y": 140,
        "w": 220,
        "h": 56,
        "style": "ink",
        "lines": ["p99 100.3-100.5 ms", "C++; Java 100.8-101.5 ms"],
    },
    {
        "x": 40,
        "y": 288,
        "w": 150,
        "h": 56,
        "style": "user",
        "lines": ["Client", "waits for each reply"],
    },
    {
        "x": 290,
        "y": 254,
        "w": 250,
        "h": 56,
        "style": "sub",
        "lines": ["closed-loop naive", "1 slow sample in 10,000"],
    },
    {
        "x": 290,
        "y": 322,
        "w": 250,
        "h": 56,
        "style": "accent",
        "lines": ["closed-loop corrected", "back-fills ~199 missed"],
    },
    {
        "x": 630,
        "y": 254,
        "w": 220,
        "h": 56,
        "style": "ink",
        "lines": ["p99 1.0 us", "C++; Java 6.9-7.0 us"],
    },
    {
        "x": 630,
        "y": 322,
        "w": 220,
        "h": 56,
        "style": "ink",
        "lines": ["p99 98.2 ms", "C++; Java 99.1-99.3 ms"],
    },
]

edges = [
    {"x1": 190, "y1": 120, "x2": 290, "y2": 100},
    {"x1": 190, "y1": 148, "x2": 290, "y2": 168, "amber": True},
    {"x1": 540, "y1": 100, "x2": 630, "y2": 100},
    {"x1": 540, "y1": 168, "x2": 630, "y2": 168, "amber": True},
    {"x1": 190, "y1": 302, "x2": 290, "y2": 282},
    {"x1": 190, "y1": 330, "x2": 290, "y2": 350, "dashed": True, "amber": True},
    {"x1": 540, "y1": 282, "x2": 630, "y2": 282},
    {"x1": 540, "y1": 350, "x2": 630, "y2": 350, "amber": True},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "A 200 ms stall: only the schedule clock and the back-fill see it",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 420,
        "text": "Dashed: samples the stalled client never took, added back by the correction.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("03-coordinated-omission", 880, 440, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "03-coordinated-omission.svg"))
    json.loads((Path(g.OUT) / "03-coordinated-omission.excalidraw").read_text(encoding="utf-8"))
    print("ok: 03-coordinated-omission")
