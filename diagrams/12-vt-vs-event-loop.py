"""Figure 12.3: who holds the 2 ms wait in the Quarkus service.

Regenerate from the repo root:  python3 diagrams/12-vt-vs-event-loop.py
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
        "h": 88,
        "label": "event-loop at 5,000 Hz: a non-blocking timer holds the wait",
    },
    {
        "x": 20,
        "y": 138,
        "w": 840,
        "h": 88,
        "label": "worker-pool at 5,000 Hz: 10 in flight (5,000 Hz x 2 ms) against 8 workers",
    },
    {
        "x": 20,
        "y": 232,
        "w": 840,
        "h": 88,
        "label": "virtual-thread at 5,000 Hz: the sleeping thread unmounts",
    },
    {
        "x": 20,
        "y": 326,
        "w": 840,
        "h": 88,
        "label": "blocking-on-event-loop at 1,850 Hz: the defect, against an event-loop control",
    },
]

h1 = box(40, 70, 190, 52, "user", "Event-loop threads", "4 threads")
m1 = box(280, 70, 270, 52, "sub", "Timer callback", "no thread waits")
r1 = box(600, 70, 240, 52, "ink", "p99, Java", "9.0-10.4 ms")

h2 = box(40, 164, 190, 52, "user", "Worker pool", "8 workers, all active")
m2 = box(280, 164, 270, 52, "kernel", "Queue builds in front", "client in flight up to 5,661-5,677")
r2 = box(600, 164, 240, 52, "ink", "p99, Java", "1,453.3-1,455.4 ms")

h3 = box(40, 258, 190, 52, "user", "Carrier threads", "4 threads")
m3 = box(280, 258, 270, 52, "sub", "Virtual thread sleeps 2 ms", "unmounted, carrier freed")
r3 = box(600, 258, 240, 52, "ink", "p99, Java", "6.5-8.9 ms")

h4 = box(40, 352, 190, 52, "user", "Event-loop threads", "4 threads")
m4 = box(
    280, 352, 270, 52, "accent", "Thread.sleep(2) on the loop", "at most 4 requests in a handler"
)
r4 = box(600, 352, 240, 52, "ink", "p99, Java: 8.2-8.5 ms", "control 3.3 ms, ratio 2.44-2.61x")

nodes = [h1, m1, r1, h2, m2, r2, h3, m3, r3, h4, m4, r4]

edges = [
    edge(right(h1), left(m1)),
    edge(right(m1), left(r1)),
    edge(right(h2), left(m2)),
    edge(right(m2), left(r2)),
    edge(right(h3), left(m3)),
    edge(right(m3), left(r3)),
    edge(right(h4), left(m4), amber=True),
    edge(right(m4), left(r4), amber=True),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Little's law: 10 requests in flight do not fit in 8 workers",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 436,
        "text": (
            "Java, Quarkus on loopback: p99 per-run median of 3 alternations, range across 3 runs; "
            "the defect ratio is observed."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("12-vt-vs-event-loop", 880, 448, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "12-vt-vs-event-loop.svg"))
    json.loads((Path(g.OUT) / "12-vt-vs-event-loop.excalidraw").read_text(encoding="utf-8"))
    print("ok: 12-vt-vs-event-loop")
