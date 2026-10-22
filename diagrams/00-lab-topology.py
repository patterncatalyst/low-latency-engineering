"""Figure 0.2 — the lab: an unprivileged host and the lowlat-target guest.

Regenerate from the repo root:  python3 diagrams/00-lab-topology.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import generate_diagram as g  # noqa: E402

g.OUT = os.path.join(ROOT, "assets", "diagrams")

bands = [
    {
        "x": 20,
        "y": 44,
        "w": 840,
        "h": 340,
        "label": "Host: unprivileged user space (no NAT, bridge or firewall change)",
    },
    {
        "x": 430,
        "y": 70,
        "w": 410,
        "h": 300,
        "label": "Guest: lowlat-target (KVM)",
        "fill": "#f3f3ee",
    },
]

nodes = [
    {"x": 40, "y": 90, "w": 170, "h": 60, "style": "user", "lines": ["lab-ssh.sh", "ssh client"]},
    {
        "x": 40,
        "y": 190,
        "w": 170,
        "h": 60,
        "style": "sub",
        "lines": ["libvirt-ssh-proxy", "ssh to vsock"],
    },
    {"x": 40, "y": 290, "w": 170, "h": 60, "style": "sub", "lines": ["passt", "user-mode network"]},
    {
        "x": 240,
        "y": 90,
        "w": 150,
        "h": 60,
        "style": "sub",
        "lines": ["Docker Engine", "host containers"],
    },
    {
        "x": 450,
        "y": 100,
        "w": 175,
        "h": 60,
        "style": "user",
        "lines": ["cyclictest", "realtime-tests"],
    },
    {"x": 645, "y": 100, "w": 175, "h": 60, "style": "sub", "lines": ["linuxptp", "chrony, tuned"]},
    {
        "x": 450,
        "y": 190,
        "w": 175,
        "h": 60,
        "style": "kernel",
        "lines": ["Linux kernel", "PREEMPT_RT"],
    },
    {
        "x": 645,
        "y": 190,
        "w": 175,
        "h": 60,
        "style": "sub",
        "lines": ["Docker", "guest containers"],
    },
    {
        "x": 450,
        "y": 290,
        "w": 175,
        "h": 56,
        "style": "sub",
        "lines": ["lab-ready", "tooled baseline"],
    },
    {
        "x": 645,
        "y": 290,
        "w": 175,
        "h": 56,
        "style": "sub",
        "lines": ["lab-ready-rt", "RT kernel snapshot"],
    },
]

edges = [
    {"x1": 125, "y1": 150, "x2": 125, "y2": 190, "amber": True},
    {
        "x1": 210,
        "y1": 220,
        "x2": 450,
        "y2": 220,
        "amber": True,
        "label": "ssh over AF_VSOCK",
        "lx": 0,
        "ly": -8,
    },
    {"x1": 480, "y1": 250, "x2": 210, "y2": 320, "label": "outbound traffic", "lx": 10, "ly": 22},
]

notes = [
    {
        "x": 440,
        "y": 28,
        "text": "Everything privileged runs in the guest; the host stays unchanged",
        "anchor": "middle",
        "size": 14,
        "bold": True,
        "color": "#b8650a",
    },
    {
        "x": 440,
        "y": 410,
        "text": "VM numbers and bare-metal numbers are never compared.",
        "anchor": "middle",
        "size": 12,
    },
]

g.emit("00-lab-topology", 880, 425, bands=bands, nodes=nodes, edges=edges, notes=notes)

if __name__ == "__main__":
    import json
    import xml.dom.minidom

    xml.dom.minidom.parse(os.path.join(g.OUT, "00-lab-topology.svg"))
    json.load(open(os.path.join(g.OUT, "00-lab-topology.excalidraw")))
    print("ok: 00-lab-topology")
