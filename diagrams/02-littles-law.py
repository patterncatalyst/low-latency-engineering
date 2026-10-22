"""Figure 2.1 — the consumer as a queue: L = lambda x W.

Regenerate from the repo root:  python3 diagrams/02-littles-law.py
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [{"x": 230, "y": 70, "w": 420, "h": 170, "label": "Consumer (the system)"}]

nodes = [
    {"x": 20, "y": 110, "w": 150, "h": 64, "style": "user",
     "lines": ["line-simulator", "1000 parcels/s"]},
    {"x": 250, "y": 110, "w": 170, "h": 64, "style": "accent",
     "lines": ["Queue: L parcels", "waiting + in service"]},
    {"x": 470, "y": 110, "w": 160, "h": 64, "style": "sub",
     "lines": ["Handler", "variable service time"]},
    {"x": 690, "y": 110, "w": 160, "h": 64, "style": "sub",
     "lines": ["Departures", "10,000 parcels"]},
    {"x": 250, "y": 268, "w": 170, "h": 60, "style": "user",
     "lines": ["L sampler", "counts every 997 us"]},
    {"x": 470, "y": 268, "w": 180, "h": 60, "style": "sub",
     "lines": ["W-bar (model input)", "done - intended emit"]},
    {"x": 300, "y": 358, "w": 340, "h": 66, "style": "ink",
     "lines": ["L sampled vs lambda x W-bar",
               "C++  -0.6 to +0.7 %",
               "Java +0.9 to +4.0 %"]},
]

edges = [
    {"x1": 170, "y1": 142, "x2": 250, "y2": 142, "amber": True,
     "label": "lambda", "lx": 0, "ly": -8},
    {"x1": 420, "y1": 142, "x2": 470, "y2": 142},
    {"x1": 630, "y1": 142, "x2": 690, "y2": 142},
    {"x1": 335, "y1": 268, "x2": 335, "y2": 174, "label": "counts L", "lx": 36, "ly": 30},
    {"x1": 560, "y1": 174, "x2": 560, "y2": 268, "label": "per-parcel W", "lx": 48, "ly": -20},
    {"x1": 335, "y1": 328, "x2": 335, "y2": 358},
    {"x1": 560, "y1": 328, "x2": 560, "y2": 358},
]

notes = [
    {"x": 440, "y": 28, "text": "L = lambda x W: parcels in the system = arrival rate x residence time",
     "anchor": "middle", "size": 14, "bold": True, "color": "#b8650a"},
    {"x": 440, "y": 448, "text": "W-bar is a modelling input to the law, never a reported latency.",
     "anchor": "middle", "size": 12},
]

g.emit("02-littles-law", 880, 460, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json, xml.dom.minidom
    xml.dom.minidom.parse(os.path.join(g.OUT, "02-littles-law.svg"))
    json.load(open(os.path.join(g.OUT, "02-littles-law.excalidraw")))
    print("ok: 02-littles-law")
