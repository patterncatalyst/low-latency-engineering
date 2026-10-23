"""Figure 7.1 — the hand-off between the receive and decide threads.

Regenerate from the repo root:  python3 diagrams/07-handoff-topology.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {"x": 20, "y": 216, "w": 840, "h": 170, "label": "Per variant, 200,000 parcels"},
]

nodes = [
    {
        "x": 40,
        "y": 50,
        "w": 150,
        "h": 60,
        "style": "user",
        "lines": ["Receive thread", "parse, hand off"],
    },
    {
        "x": 250,
        "y": 50,
        "w": 170,
        "h": 60,
        "style": "accent",
        "lines": ["Hand-off", "65,536 slots"],
    },
    {
        "x": 480,
        "y": 50,
        "w": 150,
        "h": 60,
        "style": "user",
        "lines": ["Decide thread", "lane, deadline"],
    },
    {
        "x": 690,
        "y": 50,
        "w": 160,
        "h": 60,
        "style": "kernel",
        "lines": ["Command channel", "UDP, not the data queue"],
    },
    {
        "x": 690,
        "y": 150,
        "w": 160,
        "h": 60,
        "style": "sub",
        "lines": ["Audit journal", "chronicle-journal and", "write-per-parcel only"],
    },
    {
        "x": 40,
        "y": 244,
        "w": 250,
        "h": 50,
        "style": "sub",
        "lines": ["blocking-queue", "ArrayBlockingQueue, parks"],
    },
    {
        "x": 315,
        "y": 244,
        "w": 250,
        "h": 50,
        "style": "accent",
        "lines": ["agrona-spsc", "busy-spin idle strategy"],
    },
    {
        "x": 590,
        "y": 244,
        "w": 250,
        "h": 50,
        "style": "accent",
        "lines": ["disruptor", "BusySpinWaitStrategy"],
    },
    {
        "x": 40,
        "y": 322,
        "w": 250,
        "h": 48,
        "style": "ink",
        "lines": ["voluntary ctx switches", "199,523-199,540"],
    },
    {
        "x": 315,
        "y": 322,
        "w": 250,
        "h": 48,
        "style": "ink",
        "lines": ["voluntary ctx switches", "29-47"],
    },
    {
        "x": 590,
        "y": 322,
        "w": 250,
        "h": 48,
        "style": "ink",
        "lines": ["voluntary ctx switches", "37-41"],
    },
]

edges = [
    {"x1": 190, "y1": 80, "x2": 250, "y2": 80, "amber": True},
    {"x1": 420, "y1": 80, "x2": 480, "y2": 80, "amber": True},
    {"x1": 630, "y1": 80, "x2": 690, "y2": 80},
    {"x1": 600, "y1": 110, "x2": 690, "y2": 175, "dashed": True},
    {"x1": 335, "y1": 110, "x2": 250, "y2": 244, "dashed": True},
    {
        "x1": 335,
        "y1": 110,
        "x2": 440,
        "y2": 244,
        "dashed": True,
        "label": "swap one in",
        "lx": 40,
        "ly": 4,
    },
    {"x1": 335, "y1": 110, "x2": 715, "y2": 244, "dashed": True},
    {"x1": 165, "y1": 294, "x2": 165, "y2": 322},
    {"x1": 440, "y1": 294, "x2": 440, "y2": 322},
    {"x1": 715, "y1": 294, "x2": 715, "y2": 322},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "The idle strategy spins instead of parking the decide thread",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 410,
        "text": (
            "Context switches counted on the decide thread, 10 kHz x "
            "20 s; the command channel is separate."
        ),
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("07-handoff-topology", 880, 430, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom

    xml.dom.minidom.parse(os.path.join(g.OUT, "07-handoff-topology.svg"))
    json.load(open(os.path.join(g.OUT, "07-handoff-topology.excalidraw")))
    print("ok: 07-handoff-topology")
