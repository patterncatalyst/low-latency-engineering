"""Figure 5.1 — the JIT tiers and who pays for warm-up.

Regenerate from the repo root:  python3 diagrams/05-jit-tiers.py
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
        "y": 222,
        "w": 840,
        "h": 150,
        "label": "Line run: 1 kHz x 20 s, first window = parcels 0-1,999",
    },
]

nodes = [
    {
        "x": 40,
        "y": 50,
        "w": 200,
        "h": 60,
        "style": "sub",
        "lines": ["Interpreter", "tier 0, bytecode as is"],
    },
    {
        "x": 340,
        "y": 50,
        "w": 200,
        "h": 60,
        "style": "sub",
        "lines": ["C1", "tier 1; 2-3 add profiling"],
    },
    {
        "x": 640,
        "y": 50,
        "w": 200,
        "h": 60,
        "style": "accent",
        "lines": ["C2", "tier 4, optimized code"],
    },
    {
        "x": 340,
        "y": 150,
        "w": 200,
        "h": 50,
        "style": "ghost",
        "lines": ["Deoptimization", "an assumption breaks"],
    },
    {
        "x": 40,
        "y": 246,
        "w": 240,
        "h": 50,
        "style": "user",
        "lines": ["--unwarmed", "binds at once, JIT cold"],
    },
    {
        "x": 320,
        "y": 246,
        "w": 240,
        "h": 50,
        "style": "accent",
        "lines": ["warmed", "replays 20,000 parcels first"],
    },
    {
        "x": 600,
        "y": 246,
        "w": 240,
        "h": 50,
        "style": "accent",
        "lines": ["aot-cache", "classes + profiles, no code"],
    },
    {
        "x": 40,
        "y": 322,
        "w": 240,
        "h": 42,
        "style": "ink",
        "lines": ["first-window p99.9", "13.4-28.5 ms"],
    },
    {
        "x": 320,
        "y": 322,
        "w": 240,
        "h": 42,
        "style": "ink",
        "lines": ["first-window p99.9", "0.29-0.36 ms"],
    },
    {
        "x": 600,
        "y": 322,
        "w": 240,
        "h": 42,
        "style": "ink",
        "lines": ["first-window p99.9", "0.61-3.2 ms"],
    },
]

edges = [
    {"x1": 240, "y1": 80, "x2": 340, "y2": 80, "label": "hot method", "lx": 0, "ly": -8},
    {"x1": 540, "y1": 80, "x2": 640, "y2": 80, "label": "hotter", "lx": 0, "ly": -8},
    {"x1": 700, "y1": 110, "x2": 540, "y2": 170, "dashed": True},
    {"x1": 340, "y1": 175, "x2": 140, "y2": 110, "dashed": True},
    {
        "x1": 520,
        "y1": 246,
        "x2": 790,
        "y2": 110,
        "amber": True,
        "label": "replay -> C2",
        "lx": 45,
        "ly": 16,
    },
    {"x1": 160, "y1": 296, "x2": 160, "y2": 322},
    {"x1": 440, "y1": 296, "x2": 440, "y2": 322},
    {"x1": 720, "y1": 296, "x2": 720, "y2": 322},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "The first parcels pay for warm-up; a replay moves it off the belt",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 398,
        "text": (
            "Time to ready, median of 5 launches: 173-177 ms without "
            "a trained AOT cache, 51-55 ms with one."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("05-jit-tiers", 880, 418, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "05-jit-tiers.svg"))
    json.loads((Path(g.OUT) / "05-jit-tiers.excalidraw").read_text(encoding="utf-8"))
    print("ok: 05-jit-tiers")
