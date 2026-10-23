"""Figure 10.3: a sequence lock against a shared mutex.

Regenerate from the repo root:  python3 diagrams/10-seqlock.py
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
    {"x": 20, "y": 44, "w": 840, "h": 180, "label": "seqlock: the writer never waits for readers"},
    {"x": 20, "y": 236, "w": 840, "h": 172, "label": "shared-mutex: the writer waits for readers"},
]

w1 = box(40, 76, 150, 50, "accent", "Bump sequence", "odd")
w2 = box(230, 76, 150, 50, "accent", "Write fields", "snapshot and checksum")
w3 = box(420, 76, 150, 50, "accent", "Bump sequence", "even")
r1 = box(40, 150, 130, 50, "user", "Read sequence", "s1")
r2 = box(200, 150, 130, 50, "user", "Read data", "copy the fields")
r3 = box(360, 150, 130, 50, "user", "Read sequence", "s2")
retry = box(520, 150, 130, 50, "ghost", "Retry", "s1 odd or s1 != s2")
res_s = box(
    640, 76, 200, 72, "ink", "Writer p99", "C++ 25-32 ns, Java 206-234 ns", "torn snapshots 0"
)

x1 = box(40, 262, 210, 50, "sub", "Exclusive lock", "waits for the readers")
x2 = box(290, 262, 150, 50, "sub", "Write fields", "snapshot and checksum")
x3 = box(480, 262, 120, 50, "sub", "Unlock")
rd = box(40, 340, 210, 50, "user", "Shared lock", "three readers hold it")
res_m = box(640, 262, 200, 72, "ink", "Writer p99", "C++ 5,979-6,603 ns", "Java 8,083-8,287 ns")

nodes = [w1, w2, w3, r1, r2, r3, retry, res_s, x1, x2, x3, rd, res_m]

edges = [
    edge(right(w1), left(w2), amber=True),
    edge(right(w2), left(w3), amber=True),
    edge(right(w3), left(res_s, 0.3), amber=True),
    edge(right(r1), left(r2)),
    edge(right(r2), left(r3)),
    edge(right(r3), left(retry), dashed=True),
    edge(right(x1), left(x2)),
    edge(right(x2), left(x3)),
    edge(right(x3), left(res_m, 0.3)),
    edge(top(rd), bottom(x1), label="blocks", lx=26, ly=0),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Readers retry instead of blocking, so the writer's tail stays short",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 424,
        "text": (
            "Writer p99, lock over seqlock: 205.5-231.0x in C++ and 34.5-37.1x in "
            "Java (StampedLock), with 0 torn snapshots."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("10-seqlock", 880, 440, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "10-seqlock.svg"))
    json.loads((Path(g.OUT) / "10-seqlock.excalidraw").read_text(encoding="utf-8"))
    print("ok: 10-seqlock")
