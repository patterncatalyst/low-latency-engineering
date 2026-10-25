"""Figure 13.3: what each runtime thinks it has.

Regenerate from the repo root:  python3 diagrams/13-cpu-count-views.py
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
    {"x": 20, "y": 44, "w": 410, "h": 322, "label": "container-cpu-quota: --cpus=2"},
    {"x": 450, "y": 44, "w": 410, "h": 322, "label": "container-cpuset: --cpuset-cpus=2,3"},
]

lim_q = box(36, 74, 90, 280, "kernel", "Limit", "--cpus=2")
cpp_q = box(
    166,
    74,
    256,
    70,
    "accent",
    "C++ hardware_concurrency(): 4",
    "affinity mask 4, cgroup-aware pool 2",
    "pool by hardware_concurrency 4",
)
py_q = box(166, 156, 256, 50, "accent", "Python process_cpu_count(): 4", "os.cpu_count() 4")
jv_q = box(
    166,
    218,
    256,
    58,
    "user",
    "Java availableProcessors(): 2",
    "virtual-thread scheduler 2",
    "GC threads 2",
)
qk_q = box(
    166,
    288,
    256,
    62,
    "user",
    "Quarkus service",
    "2 event-loop threads running",
    "8 workers (configured)",
)

lim_c = box(466, 74, 90, 280, "kernel", "Limit", "cpuset", "2,3")
cpp_c = box(
    596,
    74,
    256,
    70,
    "accent",
    "C++ hardware_concurrency(): 4",
    "affinity mask 2, cgroup-aware pool 2",
    "pool by hardware_concurrency 4",
)
py_c = box(596, 156, 256, 50, "user", "Python process_cpu_count(): 2", "os.cpu_count() 4")
jv_c = box(
    596,
    218,
    256,
    58,
    "user",
    "Java availableProcessors(): 2",
    "virtual-thread scheduler 2",
    "GC threads 2",
)
qk_c = box(
    596,
    288,
    256,
    62,
    "user",
    "Quarkus service",
    "2 event-loop threads running",
    "8 workers (configured)",
)

q = [cpp_q, py_q, jv_q, qk_q]
c = [cpp_c, py_c, jv_c, qk_c]
nodes = [lim_q, *q, lim_c, *c]

edges = [edge(right(lim_q, (n["y"] + n["h"] / 2 - 74) / 280), left(n)) for n in q]
edges += [edge(right(lim_c, (n["y"] + n["h"] / 2 - 74) / 280), left(n)) for n in c]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "One container, one limit: C++, Python and Java read different counts",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 388,
        "text": (
            "Amber answers ignore the limit. The vm lane, 4 vCPUs and no limit: "
            "C++ 4, Python 4, Java 4."
        ),
        "anchor": "middle",
        "size": 12,
    },
    {
        "x": 440,
        "y": 406,
        "text": (
            "Quarkus: the 8 workers are set by configuration; event-loop threads "
            "are counted as running."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("13-cpu-count-views", 880, 422, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "13-cpu-count-views.svg"))
    json.loads((Path(g.OUT) / "13-cpu-count-views.excalidraw").read_text(encoding="utf-8"))
    print("ok: 13-cpu-count-views")
