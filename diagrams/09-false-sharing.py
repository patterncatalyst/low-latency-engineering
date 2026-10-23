"""Figure 9.4: five camera counters in one cache line.

Regenerate from the repo root:  python3 diagrams/09-false-sharing.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")


def box(x, y, w, h, style, *lines):
    return {"x": x, "y": y, "w": w, "h": h, "style": style, "lines": list(lines)}


def top(n, f=0.5):
    return (round(n["x"] + n["w"] * f), n["y"])


def bottom(n, f=0.5):
    return (round(n["x"] + n["w"] * f), n["y"] + n["h"])


def left(n, f=0.5):
    return (n["x"], round(n["y"] + n["h"] * f))


def right(n, f=0.5):
    return (n["x"] + n["w"], round(n["y"] + n["h"] * f))


def edge(a, b, **kw):
    return {"x1": a[0], "y1": a[1], "x2": b[0], "y2": b[1], **kw}


bands = [
    {
        "x": 20,
        "y": 44,
        "w": 840,
        "h": 180,
        "label": "adjacent-counters: five 8 B counters in one 64 B line",
    },
    {"x": 20, "y": 234, "w": 840, "h": 190, "label": "pair-padded: one counter per 128 B range"},
]

cams_a = [box(40 + 80 * i, 76, 76, 40, "user", f"camera {i}") for i in range(5)]
line = box(40, 154, 390, 50, "accent", "One 64 B cache line", "counters 0-4, 8 B apart")
res_a1 = box(
    470, 76, 380, 46, "ink", "L1 misses per increment", "C++ store 0.093-0.095, rmw 0.43-0.44"
)
res_a2 = box(
    470,
    134,
    380,
    46,
    "ink",
    "Batch p50, 1,000 increments",
    "store 5,119-5,163 ns, rmw 51.9-55.9 us",
)

cams_b = [box(40 + 80 * i, 266, 76, 40, "user", f"camera {i}") for i in range(5)]
ranges = [box(40 + 80 * i, 346, 76, 40, "sub", "128 B") for i in range(5)]
res_b1 = box(
    470, 262, 380, 46, "ink", "L1 misses per increment", "C++ store 0.00015-0.00016, rmw 0.0002"
)
res_b2 = box(
    470,
    318,
    380,
    46,
    "ink",
    "Batch p50, 1,000 increments",
    "store 1,606-1,616 ns, rmw 4.89-4.90 us",
)
res_b3 = box(470, 374, 380, 40, "sub", "64 B padding, store batch p50", "1,656-1,676 ns (observed)")

nodes = cams_a + [line, res_a1, res_a2] + cams_b + ranges + [res_b1, res_b2, res_b3]

edges = [edge(bottom(c), top(line, (c["x"] + 38 - 40) / 390), amber=True) for c in cams_a]
edges += [edge((430, 164), left(res_a1, 0.8)), edge((430, 192), left(res_a2, 0.8))]
edges += [edge(bottom(c), top(r)) for c, r in zip(cams_b, ranges, strict=True)]
edges += [
    edge((436, 356), left(res_b1, 0.8)),
    edge((436, 366), left(res_b2, 0.8)),
    edge((436, 380), left(res_b3, 0.5), dashed=True),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Neighbouring counters share one line, so the writers take it from each other",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 444,
        "text": (
            "Misses per increment fall 609-617x (C++) and 270-287x (Java) with padding; "
            "store batches move about 3x, rmw about 10x."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("09-false-sharing", 880, 460, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "09-false-sharing.svg"))
    json.loads((Path(g.OUT) / "09-false-sharing.excalidraw").read_text(encoding="utf-8"))
    print("ok: 09-false-sharing")
