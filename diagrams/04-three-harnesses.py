"""Figure 4.1 — three harnesses, one check-digit workload.

Regenerate from the repo root:  python3 diagrams/04-three-harnesses.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [{"x": 215, "y": 50 + 100 * i, "w": 645, "h": 90} for i in range(3)]

lanes = [
    (
        "C++",
        ["Google Benchmark 1.10.0", "DoNotOptimize, 30 repetitions"],
        ["median, p99", "p99 = slowest of 30 reps"],
    ),
    (
        "Python",
        ["pyperf 2.10.0", "6 processes, 3 warm-ups each"],
        ["median, p99", "of 24 measured values"],
    ),
    (
        "Java",
        ["JMH 1.37 SampleTime", "3 forks, warm-up, Blackhole"],
        ["p50, p99, p99.9", "every sampled invocation"],
    ),
]

nodes = [
    {
        "x": 30,
        "y": 135,
        "w": 160,
        "h": 120,
        "style": "accent",
        "lines": ["Check digit", "GS1 mod-10, SSCC-18", "1,024 prefixes"],
    }
]
edges = []
for i, (lang, harness, out) in enumerate(lanes):
    cy = 95 + 100 * i
    nodes += [
        {"x": 235, "y": cy - 25, "w": 90, "h": 50, "style": "user", "lines": [lang]},
        {"x": 365, "y": cy - 28, "w": 250, "h": 56, "style": "sub", "lines": harness},
        {"x": 670, "y": cy - 28, "w": 170, "h": 56, "style": "ink", "lines": out},
    ]
    edges += [
        {"x1": 190, "y1": [150, 195, 240][i], "x2": 235, "y2": cy},
        {"x1": 325, "y1": cy, "x2": 365, "y2": cy},
        {"x1": 615, "y1": cy, "x2": 670, "y2": cy, "amber": True},
    ]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "One workload, three harnesses, each read as median and p99",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 360,
        "text": "Each harness repeats and warms up; read percentiles, not one number.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("04-three-harnesses", 880, 385, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "04-three-harnesses.svg"))
    json.loads((Path(g.OUT) / "04-three-harnesses.excalidraw").read_text(encoding="utf-8"))
    print("ok: 04-three-harnesses")
