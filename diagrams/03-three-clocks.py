"""Figure 3.1 — three clocks on one parcel.

Regenerate from the repo root:  python3 diagrams/03-three-clocks.py
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

# timestamp columns (box centres)
CX = [120, 340, 560, 780]
stamps = [
    ("kernel", ["Intended emit", "belt schedule"]),
    ("user", ["Actual send", "simulator wakes"]),
    ("user", ["Dequeue", "consumer receives"]),
    ("user", ["Done", "work finished"]),
]
nodes = [{"x": c - 65, "y": 60, "w": 130, "h": 56, "style": s, "lines": l}
         for c, (s, l) in zip(CX, stamps)]

# interval bars, left edge at the clock's start
nodes += [
    {"x": 120, "y": 170, "w": 660, "h": 46, "style": "accent",
     "lines": ["intended-time", "schedule -> done: charged every wait"]},
    {"x": 340, "y": 228, "w": 440, "h": 46, "style": "ink",
     "lines": ["closed-loop", "own request send -> done"]},
    {"x": 560, "y": 286, "w": 220, "h": 46, "style": "ink",
     "lines": ["receipt-time", "dequeue -> done"]},
]

edges = [
    {"x1": 185, "y1": 88, "x2": 275, "y2": 88, "label": "wake late", "lx": 0, "ly": -8},
    {"x1": 405, "y1": 88, "x2": 495, "y2": 88, "label": "socket queue", "lx": 0, "ly": -8},
    {"x1": 625, "y1": 88, "x2": 715, "y2": 88, "label": "work", "lx": 0, "ly": -8},
]

notes = [
    {"x": 440, "y": 28, "text": "Same parcel, three clocks: only intended-time starts at the schedule",
     "anchor": "middle", "size": 14, "bold": True, "color": "#b8650a"},
    {"x": 120, "y": 150, "text": "time ->", "anchor": "start", "size": 12},
    {"x": 440, "y": 366, "text": "A stall adds to the first interval; the other two start after the wait.",
     "anchor": "middle", "size": 12},
]

g.emit("03-three-clocks", 880, 390, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json, xml.dom.minidom
    xml.dom.minidom.parse(os.path.join(g.OUT, "03-three-clocks.svg"))
    json.load(open(os.path.join(g.OUT, "03-three-clocks.excalidraw")))
    print("ok: 03-three-clocks")
