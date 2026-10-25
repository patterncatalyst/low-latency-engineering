"""Figure 11.2: one round trip three ways.

Regenerate from the repo root:  python3 diagrams/11-switch-path.py
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
        "label": "OS threads: a futex wake and a kernel schedule",
    },
    {
        "x": 20,
        "y": 164,
        "w": 840,
        "h": 112,
        "label": "Fibers and virtual threads: a context swap in user space",
    },
    {"x": 20, "y": 284, "w": 840, "h": 112, "label": "Coroutines: a resume by symmetric transfer"},
]

a1 = box(36, 74, 130, 74, "user", "Thread A", "futex wake")
m1 = box(
    206,
    74,
    210,
    74,
    "kernel",
    "Kernel schedule",
    "voluntary switches per",
    "round trip: 2.000 (C++, Java)",
)
b1 = box(456, 74, 130, 74, "user", "Thread B", "resumes")
r1 = box(
    626,
    74,
    224,
    74,
    "ink",
    "Round-trip p50",
    "C++ 3,755-3,777 ns",
    "Python 4,011-4,029 ns",
    "Java 4,115-4,175 ns",
)

a2 = box(36, 194, 130, 74, "user", "Fiber A", "yields")
m2 = box(
    206,
    194,
    210,
    74,
    "sub",
    "Context swap in user space",
    "voluntary switches in",
    "1,020,000 trips: C++ 0, Java 2-6",
)
b2 = box(456, 194, 130, 74, "user", "Fiber B", "resumes")
r2 = box(
    626,
    194,
    224,
    74,
    "ink",
    "Round-trip p50",
    "C++ fiber 205-207 ns",
    "Java virtual thread 399-404 ns",
)

a3 = box(36, 314, 130, 74, "user", "Coroutine A", "co_await")
m3 = box(
    206,
    314,
    210,
    74,
    "accent",
    "Symmetric transfer",
    "voluntary switches in",
    "1,020,000 trips: C++ 0",
)
b3 = box(456, 314, 130, 74, "user", "Coroutine B", "resumes")
r3 = box(626, 314, 224, 74, "ink", "Round-trip p50", "C++ 7-18 ns", "Python asyncio 3,785-3,819 ns")

nodes = [a1, m1, b1, r1, a2, m2, b2, r2, a3, m3, b3, r3]

edges = [
    edge(right(a1), left(m1), amber=True),
    edge(right(m1), left(b1), amber=True),
    edge(right(b1), left(r1)),
    edge(right(a2), left(m2)),
    edge(right(m2), left(b2)),
    edge(right(b2), left(r2)),
    edge(right(a3), left(m3)),
    edge(right(m3), left(b3)),
    edge(right(b3), left(r3)),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "A switch that stays in user space skips the kernel round trip",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 418,
        "text": (
            "p50 of 1,000,000 round trips in batches of 1,000: per-run median of 3 "
            "alternations, range across 3 runs (Python: one measurement per run)."
        ),
        "anchor": "middle",
        "size": 12,
    },
    {
        "x": 440,
        "y": 436,
        "text": (
            "Thread over fiber in C++: 18.25-18.33x. Platform thread over virtual "
            "thread in Java: 10.28-10.48x."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("11-switch-path", 880, 446, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "11-switch-path.svg"))
    json.loads((Path(g.OUT) / "11-switch-path.excalidraw").read_text(encoding="utf-8"))
    print("ok: 11-switch-path")
