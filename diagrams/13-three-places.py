"""Figure 13.1: three places the same decide path runs.

Regenerate from the repo root:  python3 diagrams/13-three-places.py
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
    {"x": 20, "y": 44, "w": 840, "h": 382, "label": "Bare-metal host"},
    {"x": 40, "y": 142, "w": 800, "h": 272, "label": "KVM guest, 4 vCPUs"},
    {"x": 60, "y": 240, "w": 760, "h": 166, "label": "Docker container in the guest"},
]

host_add = box(
    44, 74, 270, 58, "user", "host lane", "simulators and consumer", "on the host, loopback"
)
host_res = box(
    350, 74, 470, 58, "ink", "lane host", "emit lateness p99 62-64 us", "consumer p99 97-98 us"
)

vm_add = box(
    64,
    172,
    270,
    58,
    "user",
    "vm lane",
    "native in the guest, VM exits",
    "steal ticks 0-1 of 8,848-9,886",
)
vm_res = box(
    370, 172, 430, 58, "ink", "lane vm", "emit lateness p99 80-83 us", "consumer p99 99-101 us"
)

hn_add = box(
    84,
    270,
    270,
    58,
    "user",
    "container-host-net lane",
    "guest network namespace",
    "seccomp: io_uring_setup EPERM",
)
hn_res = box(
    390,
    270,
    410,
    58,
    "ink",
    "lane container-host-net",
    "emit lateness p99 81-89 us",
    "consumer p99 101-104 us",
)

br_add = box(
    84,
    338,
    270,
    58,
    "user",
    "container-bridge lane",
    "simulators in the guest,",
    "consumer in the container",
)
br_res = box(
    390,
    338,
    410,
    58,
    "ink",
    "lane container-bridge",
    "emit lateness p99 85-103 us",
    "consumer p99 105-140 us",
)

nodes = [host_add, host_res, vm_add, vm_res, hn_add, hn_res, br_add, br_res]

edges = [
    edge(right(host_add), left(host_res)),
    edge(right(vm_add), left(vm_res)),
    edge(right(hn_add), left(hn_res)),
    edge(right(br_add), left(br_res)),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Compare lanes inside one run; every value is labelled by lane",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 446,
        "text": (
            "Emit lateness is the simulator's jitter floor. 10 kHz x 20 s per lane: per-run "
            "median of 3 alternations, range across 3 runs."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("13-three-places", 880, 456, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "13-three-places.svg"))
    json.loads((Path(g.OUT) / "13-three-places.excalidraw").read_text(encoding="utf-8"))
    print("ok: 13-three-places")
