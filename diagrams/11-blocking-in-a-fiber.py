"""Figure 11.3: a blocking call in a fiber and the neighbours.

Regenerate from the repo root:  python3 diagrams/11-blocking-in-a-fiber.py
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
        "h": 190,
        "label": "C++ fibers on one carrier thread: 1,000 tasks, 50 blocking calls of 2,000 us",
    },
    {
        "x": 20,
        "y": 244,
        "w": 840,
        "h": 182,
        "label": "Python asyncio twin (gil build): 50 tasks, the same blocking call in a coroutine",
    },
]

carrier = box(40, 78, 150, 56, "user", "Carrier thread", "runs every fiber")
blocker = box(250, 78, 210, 56, "accent", "Fiber with the call", "std::this_thread::sleep_for")
neigh = box(520, 78, 200, 56, "sub", "Neighbour fibers", "wake late, behind it")
res1 = box(
    250,
    162,
    300,
    62,
    "ink",
    "Neighbours' wake lateness p99",
    "no blocking call: 52 us",
    "2 ms blocking call: 1,917-1,952 us",
)

loop = box(40, 278, 150, 56, "ghost", "Event-loop thread", "runs every coroutine")
pyblock = box(250, 278, 210, 56, "ghost", "Coroutine with the call", "time.sleep, 2 ms")
pyneigh = box(520, 278, 200, 56, "ghost", "Neighbour coroutines", "wake late, behind it")
res2 = box(
    250,
    358,
    300,
    62,
    "ink",
    "Neighbours' wake lateness p99",
    "no blocking call: 1,305-1,308 us",
    "2 ms blocking call: 2,672-2,859 us",
)

nodes = [carrier, blocker, neigh, res1, loop, pyblock, pyneigh, res2]

edges = [
    edge(right(carrier), left(blocker), amber=True),
    edge(right(blocker), left(neigh), amber=True, label="blocks it", lx=0, ly=-10),
    edge(bottom(blocker, 0.5), top(res1, 0.35)),
    edge(right(loop), left(pyblock), amber=True),
    edge(right(pyblock), left(pyneigh), amber=True),
    edge(bottom(pyblock, 0.5), top(res2, 0.35)),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "A blocking call in a fiber holds every fiber on its carrier",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 448,
        "text": (
            "Wake lateness p99: per-run median of 3 alternations in C++, one measurement "
            "per run in Python; range across 3 runs."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("11-blocking-in-a-fiber", 880, 460, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "11-blocking-in-a-fiber.svg"))
    json.loads((Path(g.OUT) / "11-blocking-in-a-fiber.excalidraw").read_text(encoding="utf-8"))
    print("ok: 11-blocking-in-a-fiber")
