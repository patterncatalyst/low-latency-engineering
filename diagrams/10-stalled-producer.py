"""Figure 10.4: a claimed but unpublished slot.

Regenerate from the repo root:  python3 diagrams/10-stalled-producer.py
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
        "h": 200,
        "label": "Fetch-add log (slot numbers illustrate the 1,000,000-slot log)",
    }
]

producer = box(200, 74, 140, 50, "user", "Producer", "sleeps 1 ms")
s41 = box(40, 176, 140, 50, "sub", "slot 41", "published, read")
s42 = box(200, 176, 140, 50, "accent", "slot 42", "claimed, unpublished")
s43 = box(360, 176, 140, 50, "sub", "slot 43", "published, waiting")
s44 = box(520, 176, 140, 50, "sub", "slot 44", "published, waiting")
consumer = box(200, 284, 140, 56, "user", "Consumer", "stopped at slot 42")
result = box(
    520,
    284,
    320,
    56,
    "ink",
    "Consumer wait at the stalled slot",
    "C++ 1.05-1.07 ms, Java 1.11-1.14 ms",
)

nodes = [producer, s41, s42, s43, s44, consumer, result]

edges = [
    edge(bottom(producer), top(s42), dashed=True, label="claim, then sleep", lx=62, ly=2),
    edge(top(consumer), bottom(s42), amber=True, label="waits", lx=30, ly=0),
    edge(right(consumer), left(result), amber=True),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "A wait-free claim does not make the consumer wait-free",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 364,
        "text": "The claim is wait-free; the consumer waits for the slowest producer.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("10-stalled-producer", 880, 380, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "10-stalled-producer.svg"))
    json.loads((Path(g.OUT) / "10-stalled-producer.excalidraw").read_text(encoding="utf-8"))
    print("ok: 10-stalled-producer")
