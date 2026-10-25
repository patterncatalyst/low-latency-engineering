"""Figure 13.2: a CPU quota against a cpuset.

Regenerate from the repo root:  python3 diagrams/13-quota-vs-cpuset.py
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
        "h": 162,
        "label": "container-cpu-quota: --cpus=2 is 200 ms of CPU per 100 ms period, on any CPU",
    },
    {"x": 36, "y": 68, "w": 262, "h": 80, "label": "100 ms period"},
    {"x": 304, "y": 68, "w": 262, "h": 80, "label": "100 ms period"},
    {"x": 572, "y": 68, "w": 262, "h": 80, "label": "100 ms period"},
    {
        "x": 20,
        "y": 216,
        "w": 840,
        "h": 168,
        "label": "container-cpuset: --cpuset-cpus=2,3 is two CPUs and no budget",
    },
    {"x": 36, "y": 240, "w": 262, "h": 80, "label": "100 ms period"},
    {"x": 304, "y": 240, "w": 262, "h": 80, "label": "100 ms period"},
    {"x": 572, "y": 240, "w": 262, "h": 80, "label": "100 ms period"},
]

run_q = [box(46 + 268 * i, 94, 120, 44, "user", "Run", "quota used up") for i in range(3)]
thr_q = [box(206 + 268 * i, 94, 90, 44, "accent", "Throttled", "to period end") for i in range(3)]
res_q = box(
    36,
    156,
    798,
    44,
    "ink",
    "Lane container-cpu-quota",
    "nr_throttled 206-207, throttled 37.8-40.7 s, consumer p99.9 53,412-55,575 us",
)

run_c = [
    box(46 + 268 * i, 266, 242, 44, "user", "Run", "2 CPUs, no budget, no gaps") for i in range(3)
]
res_c = box(
    36,
    328,
    798,
    44,
    "ink",
    "Lane container-cpuset",
    "nr_throttled 0, throttled 0.0 s, consumer p99.9 2,912-4,067 us",
)

nodes = [*run_q, *thr_q, res_q, *run_c, res_c]

edges = [edge(right(run_q[i]), left(thr_q[i]), amber=True) for i in range(3)]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "A quota stops the whole cgroup at the period edge; a cpuset only shares two CPUs",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 404,
        "text": (
            "Four busy workers beside the consumer in both lanes; three periods drawn. "
            "Consumer p99.9, quota over cpuset: 13.16-18.91x."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("13-quota-vs-cpuset", 880, 424, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "13-quota-vs-cpuset.svg"))
    json.loads((Path(g.OUT) / "13-quota-vs-cpuset.excalidraw").read_text(encoding="utf-8"))
    print("ok: 13-quota-vs-cpuset")
