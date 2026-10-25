"""Figure 12.2: thread-per-core against an acceptor and a pool.

Regenerate from the repo root:  python3 diagrams/12-thread-per-core.py
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
    {"x": 20, "y": 44, "w": 410, "h": 358, "label": "Thread-per-core: shared nothing"},
    {"x": 450, "y": 44, "w": 410, "h": 358, "label": "Acceptor and pool: one receive thread"},
]

cam_l = box(60, 74, 330, 40, "kernel", "Four cameras", "UDP, four ports")
t = [
    box(36 + 98 * i, 196, 88, 68, "user", f"Thread {i + 1}", "own socket", "own ring")
    for i in range(4)
]
res_l = box(
    40,
    330,
    370,
    62,
    "ink",
    "Thread-per-core (C++, saturation)",
    "hand-offs per parcel 0, p99 68-69 us (observed)",
    "busiest receiver 384 permille busy",
)

cam_r = box(520, 74, 250, 40, "kernel", "Four cameras", "UDP datagrams")
acc = box(520, 134, 250, 44, "user", "Receive thread", "decodes, hands off")
hand = box(470, 198, 360, 40, "accent", "Hand-off", "one Ch10 log per worker, round robin")
w = [box(466 + 98 * i, 262, 88, 52, "user", f"Worker {i + 1}", "decides") for i in range(4)]
res_r = box(
    470,
    330,
    370,
    62,
    "ink",
    "Acceptor and pool (C++, saturation)",
    "hand-offs per parcel 1, p99 84-90 us (observed)",
    "acceptor 820-822 permille busy",
)

nodes = [cam_l, *t, res_l, cam_r, acc, hand, *w, res_r]

edges = [edge(bottom(cam_l, round((t[i]["x"] + 44 - 60) / 330, 4)), top(t[i])) for i in range(4)]
edges[0]["label"] = "one port per camera"
edges[0]["lx"] = 62
edges[0]["ly"] = -4
edges += [
    edge(bottom(cam_r), top(acc)),
    edge(bottom(acc), top(hand, 0.5)),
]
edges += [edge(bottom(hand, (w[i]["x"] + 44 - 470) / 360), top(w[i])) for i in range(4)]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Shared nothing makes 0 hand-offs per parcel; an acceptor makes 1",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 424,
        "text": (
            "52 kHz x 4 cameras, 3,500 ns of receive work: p99 ratio 0.77-0.82x "
            "(observed, not asserted)."
        ),
        "anchor": "middle",
        "size": 12,
    },
    {
        "x": 440,
        "y": 442,
        "text": (
            "At line rate, 2.5 kHz per camera, one measurement per run, p99 is "
            "98-115 us thread-per-core and "
            "91-113 us acceptor and pool."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("12-thread-per-core", 880, 452, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "12-thread-per-core.svg"))
    json.loads((Path(g.OUT) / "12-thread-per-core.excalidraw").read_text(encoding="utf-8"))
    print("ok: 12-thread-per-core")
