"""Figure 11.1: who holds each of 10,000 waits.

Regenerate from the repo root:  python3 diagrams/11-who-holds-the-wait.py
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
        "h": 112,
        "label": "OS threads: every wait owns a kernel stack and a reserved user stack",
    },
    {
        "x": 20,
        "y": 164,
        "w": 840,
        "h": 112,
        "label": "Fibers and virtual threads: a small stack in user space",
    },
    {
        "x": 20,
        "y": 284,
        "w": 840,
        "h": 112,
        "label": "Coroutines: no stack, only a frame",
    },
]

t_hold = box(40, 74, 170, 74, "user", "OS thread", "C++, Python and Java", "threads")
t_stack = box(
    260,
    74,
    240,
    74,
    "kernel",
    "Stacks",
    "kernel stack 16,380-16,384 B (C++)",
    "user stack reserved: 8,192 KiB (C++)",
)
t_res = box(
    550,
    74,
    300,
    74,
    "ink",
    "Per wait: user RSS, address space (B)",
    "C++ 8,774-8,778, 9,245,449",
    "Python 19,228-19,247, 9,266,672-9,266,776",
    "Java 22,805-22,898, 1,044,486-1,044,591",
)

f_hold = box(
    40, 194, 170, 74, "user", "Fiber, virtual thread", "C++ Boost.Fiber,", "Java virtual thread"
)
f_stack = box(
    260,
    194,
    240,
    74,
    "sub",
    "User-space stack",
    "C++ fiber: 65,536 B reserved",
    "Java: heap, 2,063-2,105 B",
)
f_res = box(
    550,
    194,
    300,
    74,
    "ink",
    "Per wait: user RSS, address space (B)",
    "C++ 4,106, 69,645",
    "Java 2,870-3,260, not per task*",
)

c_hold = box(40, 314, 170, 74, "user", "Coroutine", "C++ awaitable,", "Python asyncio task")
c_frame = box(
    260,
    314,
    240,
    74,
    "accent",
    "Heap frame",
    "C++ Task probe frame: 208 B",
    "Python: 1,641 B (tracemalloc)",
)
c_res = box(
    550,
    314,
    300,
    74,
    "ink",
    "Per wait: user RSS, address space (B)",
    "C++ 1,009, not per task*",
    "Python 2,611-2,614, 2,569",
)

nodes = [t_hold, t_stack, t_res, f_hold, f_stack, f_res, c_hold, c_frame, c_res]

edges = [
    edge(right(t_hold), left(t_stack)),
    edge(right(t_stack), left(t_res)),
    edge(right(f_hold), left(f_stack)),
    edge(right(f_stack), left(f_res)),
    edge(right(c_hold), left(c_frame), amber=True),
    edge(right(c_frame), left(c_res), amber=True),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "A parked wait costs a stack, a small stack or only a frame",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 420,
        "text": (
            "10,000 tasks parked on one 1,000 ms timer; bytes per task, range across three runs."
        ),
        "anchor": "middle",
        "size": 12,
    },
    {
        "x": 440,
        "y": 438,
        "text": (
            "* address space grew in steps (Java carrier arenas) or barely, 26 B (C++ frames in "
            "already-mapped heap)"
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("11-who-holds-the-wait", 880, 458, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "11-who-holds-the-wait.svg"))
    json.loads((Path(g.OUT) / "11-who-holds-the-wait.excalidraw").read_text(encoding="utf-8"))
    print("ok: 11-who-holds-the-wait")
