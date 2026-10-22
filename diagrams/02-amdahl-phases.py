"""Figure 2.2 — one batch as a parallel phase and a serial phase at N = 1, 2, 4.

Regenerate from the repo root:  python3 diagrams/02-amdahl-phases.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

X0 = 110          # time origin
PAR1 = 630        # parallel phase width at N = 1 (same time scale in every lane)
SER = 66          # serial phase width, identical in every lane
RH, GAP = 22, 4   # row height and gap

bands, nodes = [], []
lanes = [(1, 50), (2, 114), (4, 200)]
for n, ytop in lanes:
    rows = n
    h = 16 + rows * RH + (rows - 1) * GAP + 18 if n < 4 else 126
    if n == 1:
        h = 56
    if n == 2:
        h = 78
    bands.append({"x": 20, "y": ytop, "w": 840, "h": h, "label": f"N = {n}"})
    par = PAR1 / n
    y0 = ytop + 16
    for r in range(rows):
        nodes.append({"x": X0, "y": y0 + r * (RH + GAP), "w": round(par), "h": RH,
                      "style": "sub", "lines": ["parallel scan" if n == 1 else "scan"]})
    bx = X0 + round(par) + 4
    nodes.append({"x": bx, "y": y0, "w": 4, "h": rows * RH + (rows - 1) * GAP,
                  "style": "kernel", "lines": [""]})
    nodes.append({"x": bx + 12, "y": y0, "w": SER, "h": RH, "style": "accent",
                  "lines": ["serial"]})
    nodes.append({"x": bx + 12 + SER + 8, "y": y0, "w": 4, "h": rows * RH + (rows - 1) * GAP,
                  "style": "kernel", "lines": [""]})

nodes.append({"x": 400, "y": 210, "w": 450, "h": 110, "style": "ink",
              "lines": ["N = 4 speedup, predicted -> measured",
                        "C++              3.11x -> 2.83-2.84x",
                        "Python threads   3.08x -> 0.48-0.52x",
                        "Python processes 3.04-3.05x -> 2.93-3.01x",
                        "Java        3.08-3.09x -> 2.74x"]})

notes = [
    {"x": 440, "y": 28,
        "text": "The serial phase never shrinks, so N workers give less than N times",
     "anchor": "middle", "size": 14, "bold": True, "color": "#b8650a"},
    {"x": 560, "y": 148, "text": "serial fraction s ~ 0.095-0.099 (C++, Java),",
     "size": 12},
    {"x": 560, "y": 166, "text": "measured as lock time / wall time at N = 1",
     "size": 12},
    {"x": 110, "y": 350,
        "text": "grey bar = barrier; amber = serial phase (one worker at a time holds the lock)",
     "size": 12},
    {"x": 850, "y": 350, "text": "time ->", "anchor": "end", "size": 12},
    {"x": 440, "y": 385,
        "text": "Speedup is capped at 1 / s; the measured value sits under the prediction.",
     "anchor": "middle", "size": 12},
]

g.emit("02-amdahl-phases", 880, 405, bands=bands, nodes=nodes, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    xml.dom.minidom.parse(os.path.join(g.OUT, "02-amdahl-phases.svg"))
    json.load(open(os.path.join(g.OUT, "02-amdahl-phases.excalidraw")))
    print("ok: 02-amdahl-phases")
