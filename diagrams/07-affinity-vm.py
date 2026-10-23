"""Figure 7.3 — pinning the decide thread to an isolated vCPU (VM).

Regenerate from the repo root:  python3 diagrams/07-affinity-vm.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {"x": 20, "y": 44, "w": 840, "h": 330, "label": "Host (runs the VM)"},
    {
        "x": 40,
        "y": 68,
        "w": 640,
        "h": 214,
        "label": "Guest lowlat-target: isolcpus=3 nohz_full=3 rcu_nocbs=3",
    },
]

nodes = [
    {"x": 60, "y": 100, "w": 160, "h": 60, "style": "user", "lines": ["stress-ng", "--cpu 3, guest CPUs 0-2"]},
    {"x": 250, "y": 100, "w": 170, "h": 60, "style": "kernel", "lines": ["vCPU 0-2", "free over host CPUs 0-15"]},
    {"x": 250, "y": 200, "w": 170, "h": 60, "style": "user", "lines": ["Decide thread", "unpinned, CPUs 0-3"]},
    {"x": 490, "y": 100, "w": 170, "h": 60, "style": "accent", "lines": ["Decide thread", "pinned: AffinityLock(3)"]},
    {"x": 490, "y": 200, "w": 170, "h": 60, "style": "kernel", "lines": ["vCPU 3 (isolated)", "kernel keeps tasks off it"]},
    {"x": 720, "y": 200, "w": 130, "h": 60, "style": "kernel", "lines": ["host CPU 13", "a pin, not isolation"]},
    {
        "x": 235,
        "y": 306,
        "w": 200,
        "h": 60,
        "style": "ink",
        "lines": ["VM: unpinned", "involuntary 174,388-313,298", "hand-off p99.9 1.09-1.86 ms"],
    },
    {
        "x": 475,
        "y": 306,
        "w": 200,
        "h": 60,
        "style": "ink",
        "lines": ["VM: pinned", "involuntary 0-5", "hand-off p99.9 51-55 us"],
    },
]

edges = [
    {"x1": 220, "y1": 130, "x2": 250, "y2": 130},
    {"x1": 335, "y1": 200, "x2": 335, "y2": 160},
    {"x1": 575, "y1": 160, "x2": 575, "y2": 200, "amber": True},
    {"x1": 660, "y1": 230, "x2": 720, "y2": 230, "amber": True, "label": "vcpupin", "lx": 0, "ly": -8},
    {"x1": 335, "y1": 260, "x2": 335, "y2": 306},
    {"x1": 575, "y1": 260, "x2": 575, "y2": 306, "amber": True},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Pinning to an isolated vCPU keeps stress-ng off the decide thread",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 400,
        "text": "VM only, never compared with host runs. p99.9: median of 3 alternations per run.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("07-affinity-vm", 880, 420, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom

    xml.dom.minidom.parse(os.path.join(g.OUT, "07-affinity-vm.svg"))
    json.load(open(os.path.join(g.OUT, "07-affinity-vm.excalidraw")))
    print("ok: 07-affinity-vm")
