"""Figure 8.1 — decode by protobuf parse against a flat view.

Regenerate from the repo root:  python3 diagrams/08-zero-copy-decode.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {"x": 220, "y": 44, "w": 640, "h": 150, "label": "protobuf-decode: a fresh message per datagram"},
    {
        "x": 220,
        "y": 210,
        "w": 640,
        "h": 150,
        "label": "flat-ffm: a reused view, parcel-v1 is 80 bytes",
    },
]

nodes = [
    {
        "x": 40,
        "y": 88,
        "w": 150,
        "h": 226,
        "style": "kernel",
        "lines": ["Receive buffer", "one direct ByteBuffer", "one datagram at a time"],
    },
    {
        "x": 250,
        "y": 88,
        "w": 250,
        "h": 70,
        "style": "sub",
        "lines": ["parseFrom", "ParcelEvent + Dimensions", "+ String barcode"],
    },
    {
        "x": 250,
        "y": 254,
        "w": 250,
        "h": 70,
        "style": "accent",
        "lines": ["FlatView", "MemorySegment.ofBuffer", "VarHandles at fixed offsets"],
    },
    {"x": 580, "y": 88, "w": 250, "h": 70, "style": "ink", "lines": ["544-576 B/op, p50 150-160 ns", "line: 531-591 B/parcel"]},
    {"x": 580, "y": 254, "w": 250, "h": 70, "style": "ink", "lines": ["< 1 B/op, p50 16 ns", "line: 8.76 B/parcel"]},
]

edges = [
    {"x1": 190, "y1": 123, "x2": 250, "y2": 123},
    {"x1": 190, "y1": 289, "x2": 250, "y2": 289, "amber": True},
    {"x1": 500, "y1": 123, "x2": 580, "y2": 123},
    {"x1": 500, "y1": 289, "x2": 580, "y2": 289, "amber": True},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Read the bytes where they landed instead of building an object",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 388,
        "text": "A read-only view of bytes someone else owns: nothing to parse, nothing to allocate.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("08-zero-copy-decode", 880, 410, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom

    xml.dom.minidom.parse(os.path.join(g.OUT, "08-zero-copy-decode.svg"))
    json.load(open(os.path.join(g.OUT, "08-zero-copy-decode.excalidraw")))
    print("ok: 08-zero-copy-decode")
