"""Figure 9.2: a node map against a flat map.

Regenerate from the repo root:  python3 diagrams/09-node-vs-flat-map.py
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
        "h": 170,
        "label": "node-map: std::unordered_map<std::string, ParcelState>",
    },
    {
        "x": 20,
        "y": 226,
        "w": 840,
        "h": 170,
        "label": "flat-map: absl::flat_hash_map<uint64_t, uint32_t> and columns",
    },
]

key1 = box(40, 76, 110, 56, "user", "Barcode", "18 digits")
bucket = box(210, 76, 120, 56, "sub", "Bucket", "load 1")
node = box(390, 76, 140, 56, "sub", "Node", "ParcelState, load 2")
string = box(590, 76, 150, 56, "sub", "Heap string", "key text, load 3")
res_a = box(40, 148, 250, 50, "ink", "2 allocations per insert", "C++ exact; Java 128 B/op")
res_b = box(305, 148, 250, 50, "ink", "Hub lookup p50", "C++ 389-393 ns, Java 321-322 ns")
res_c = box(570, 148, 250, 50, "ink", "LL read misses per lookup", "5.94 (cachegrind, exact)")

key2 = box(40, 258, 110, 56, "user", "Barcode", "packed uint64")
group = box(210, 258, 200, 56, "accent", "Probe group", "control bytes and slots")
cols = box(470, 258, 170, 56, "accent", "Columns", "indexed by the slot")
res_d = box(
    40, 330, 250, 50, "ink", "0 allocations after reserve", "C++ exact; Java 0.014-0.016 B/op"
)
res_e = box(305, 330, 250, 50, "ink", "Hub lookup p50", "C++ 113 ns, Java 57-58 ns")
res_f = box(570, 330, 250, 50, "ink", "LL read misses per lookup", "0.70 (cachegrind, exact)")

nodes = [key1, bucket, node, string, res_a, res_b, res_c, key2, group, cols, res_d, res_e, res_f]

edges = [
    edge(right(key1), left(bucket)),
    edge(right(bucket), left(node)),
    edge(right(node), left(string)),
    edge(right(key2), left(group), amber=True),
    edge(right(group), left(cols), amber=True),
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Three dependent loads and two allocations against one probe group and none",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 424,
        "text": (
            "Hub lookup p50, node-map over flat-map: 3.43-3.48x in C++ and "
            "5.53-5.67x in Java (median of 3 per run)."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("09-node-vs-flat-map", 880, 440, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom
    from pathlib import Path

    xml.dom.minidom.parse(os.path.join(g.OUT, "09-node-vs-flat-map.svg"))
    json.loads((Path(g.OUT) / "09-node-vs-flat-map.excalidraw").read_text(encoding="utf-8"))
    print("ok: 09-node-vs-flat-map")
