"""Figure 6.3 — who reclaims memory in C++, Python and Java.

Regenerate from the repo root:  python3 diagrams/06-refcount-vs-tracing.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

LANES = [
    (
        "C++: the owner frees; there is no collector",
        ["C++", "ownership: free is a call"],
        [
            (
                "sub",
                ["--bulk-free", "destroyed on the hot thread"],
                ["p99.9 latency", "2.08-2.19 ms"],
                False,
            ),
            (
                "accent",
                ["deferred-free", "reclaimer thread destroys it"],
                ["p99.9 latency", "0.135-0.141 ms"],
                True,
            ),
        ],
    ),
    (
        "Python: refcounts free at once; a cycle collector finds cycles",
        ["Python", "refcount + generational GC"],
        [
            (
                "sub",
                ["cyclic-garbage", "reference cycles, gen-2 runs"],
                ["9 gen-2 runs", "p99.9 lat. 138-144 ms"],
                False,
            ),
            (
                "accent",
                ["frozen", "no cycles, gc.freeze()"],
                ["0 gen-2 runs", "p99.9 lat. 0.154-0.168 ms"],
                True,
            ),
        ],
    ),
    (
        "Java: tracing collectors mark what is live",
        ["Java", "tracing, generational"],
        [
            (
                "sub",
                ["--stop-the-world", "full pause walks the heap"],
                ["p99.9 latency", "152-157 ms"],
                False,
            ),
            (
                "accent",
                ["zgc", "concurrent mark and relocate"],
                ["p99.9 latency", "0.135-0.153 ms"],
                True,
            ),
        ],
    ),
]

bands = []
nodes = []
edges = []
for i, (label, lang, rows) in enumerate(LANES):
    y0 = 44 + i * 126
    bands.append({"x": 20, "y": y0, "w": 840, "h": 118, "label": label})
    nodes.append({"x": 40, "y": y0 + 30, "w": 180, "h": 86, "style": "user", "lines": lang})
    for j, (style, mech, res, amber) in enumerate(rows):
        y = y0 + 30 + j * 46
        cy = y + 20
        nodes += [
            {"x": 280, "y": y, "w": 320, "h": 40, "style": style, "lines": mech},
            {"x": 660, "y": y, "w": 190, "h": 40, "style": "ink", "lines": res},
        ]
        edges += [
            {"x1": 220, "y1": cy, "x2": 280, "y2": cy, "amber": amber},
            {"x1": 600, "y1": cy, "x2": 660, "y2": cy, "amber": amber},
        ]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Where reclaim cost lands depends on the runtime and on who frees",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 436,
        "text": "Amber: the variant that keeps reclaim off the latency-critical path.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("06-refcount-vs-tracing", 880, 456, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "06-refcount-vs-tracing.svg"))
    json.loads((Path(g.OUT) / "06-refcount-vs-tracing.excalidraw").read_text(encoding="utf-8"))
    print("ok: 06-refcount-vs-tracing")
