"""Figure 12.1: readiness against completion on the receive path.

Regenerate from the repo root:  python3 diagrams/12-readiness-vs-completion.py
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
    {"x": 20, "y": 44, "w": 410, "h": 340, "label": "Readiness: epoll_wait, then recvmsg"},
    {
        "x": 450,
        "y": 44,
        "w": 410,
        "h": 340,
        "label": "Completion: io_uring with a multishot recvmsg",
    },
]

sock = box(100, 78, 250, 50, "kernel", "UDP socket queue", "datagrams wait here")
ep = box(100, 156, 250, 50, "user", "epoll_wait", "returns: the socket is ready")
rm = box(100, 234, 250, 50, "user", "recvmsg", "takes one datagram")
res_l = box(
    40,
    312,
    370,
    62,
    "ink",
    "System calls per parcel (C++, saturation)",
    "epoll 1.379-1.417: recvmsg 1, epoll_wait 0.379-0.417",
    "recvmmsg 0.573-0.614",
)

arm = box(
    466,
    78,
    186,
    62,
    "kernel",
    "Multishot recvmsg",
    "stays armed; re-armed",
    "when the kernel ends it",
)
buf = box(672, 78, 158, 62, "sub", "Provided buffer ring", "kernel picks a buffer")
cq = box(500, 164, 310, 50, "accent", "Completion queue", "one entry per datagram")
reap = box(500, 240, 310, 50, "user", "Reap every queued entry", "io_uring_enter only to wait")
res_r = box(
    470,
    312,
    370,
    62,
    "ink",
    "System calls per parcel (C++, saturation)",
    "io_uring_enter 0.062-0.068",
    "14.7-16.2 completions per io_uring_enter",
)

nodes = [sock, ep, rm, res_l, arm, buf, cq, reap, res_r]

edges = [
    edge(bottom(sock), top(ep), amber=True, label="kernel crossing", lx=52, ly=2),
    edge(bottom(ep), top(rm), amber=True, label="kernel crossing", lx=52, ly=2),
    edge(bottom(rm, 0.5), top(res_l, 0.5)),
    edge(left(buf), right(arm), dashed=True),
    edge(bottom(arm, 0.5), top(cq, round((559 - 500) / 310, 4))),
    edge(bottom(cq), top(reap), amber=True, label="io_uring_enter", lx=46, ly=2),
    edge(bottom(reap, 0.5), top(res_r, 0.5)),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": (
            "One io_uring_enter reaps 14.7-16.2 completions; "
            "epoll pays a recvmsg per parcel plus epoll_wait"
        ),
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 408,
        "text": (
            "60 kHz x 4 cameras for 3 s: per-run median of 3 alternations, "
            "range across 3 runs; the counts depend on load."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("12-readiness-vs-completion", 880, 424, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "12-readiness-vs-completion.svg"))
    json.loads((Path(g.OUT) / "12-readiness-vs-completion.excalidraw").read_text(encoding="utf-8"))
    print("ok: 12-readiness-vs-completion")
