"""Figure 1.1 — batch-of-32 against per-parcel handling at the same arrival rate.

Regenerate from the repo root:  python3 diagrams/01-batch-vs-per-parcel.py
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {"x": 20, "y": 44, "w": 840, "h": 126, "label": "Per-parcel: handle on arrival"},
    {"x": 20, "y": 190, "w": 840, "h": 170, "label": "Batch-32: hold until 32 arrive"},
]

nodes = []
edges = []
# per-parcel lane: parcel i -> done
for i in range(7):
    x = 260 + i * 60
    nodes.append({"x": x, "y": 64, "w": 44, "h": 30, "style": "sub", "lines": [str(i + 1)]})
    nodes.append({"x": x, "y": 118, "w": 44, "h": 30, "style": "accent", "lines": ["done"]})
    edges.append({"x1": x + 22, "y1": 94, "x2": x + 22, "y2": 118})
nodes.append({"x": 735, "y": 105, "w": 120, "h": 56, "style": "ink",
              "lines": ["p50 74-186 us", "C++, Python, Java"]})
edges.append({"x1": 664, "y1": 133, "x2": 735, "y2": 133})

# batch lane
labels = ["1", "2", "3", "4", "...", "32"]
for i, t in enumerate(labels):
    x = 260 + i * 60
    nodes.append({"x": x, "y": 214, "w": 44, "h": 30,
                  "style": "ghost" if t == "..." else "sub", "lines": [t]})
    edges.append({"x1": x + 22, "y1": 244, "x2": x + 22, "y2": 300,
                  "amber": i == 0,
                  **({"label": "first parcel waits ~31 ms", "lx": -78, "ly": 4} if i == 0 else {})})
nodes.append({"x": 260, "y": 300, "w": 364, "h": 46, "style": "accent",
              "lines": ["handle 32 together"]})
nodes.append({"x": 735, "y": 300, "w": 120, "h": 46, "style": "ink",
              "lines": ["p50 15.2-16.1 ms", "C++, Python, Java"]})
edges.append({"x1": 624, "y1": 323, "x2": 735, "y2": 323})

notes = [
    {"x": 440, "y": 28, "text": "Same arrivals, equal throughput: batching makes the first parcel wait ~31 ms",
     "anchor": "middle", "size": 14, "bold": True, "color": "#b8650a"},
    {"x": 440, "y": 384, "text": "Both designs handle 1 kHz arrivals, less than 1 % apart in throughput.",
     "anchor": "middle", "size": 12},
]

g.emit("01-batch-vs-per-parcel", 880, 400, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json, xml.dom.minidom
    xml.dom.minidom.parse(os.path.join(g.OUT, "01-batch-vs-per-parcel.svg"))
    json.load(open(os.path.join(g.OUT, "01-batch-vs-per-parcel.excalidraw")))
    print("ok: 01-batch-vs-per-parcel")
