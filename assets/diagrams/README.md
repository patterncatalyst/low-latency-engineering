# Diagrams

Each figure is a pair: `name.svg` (embedded) and `name.excalidraw` (editable).
Specs live in `diagrams/name.py` at the repo root; regenerate with
`python3 diagrams/name.py`. Never hand-edit the generated files.

| File | Figure | Used in |
|---|---|---|
| `00-sortation-line` | 0.1 The sortation line and the scan-to-divert budget | Ch0 · Setup |
| `00-lab-topology` | 0.2 The VM lab: an unprivileged host and a PREEMPT_RT guest | Ch0 · Setup |
| `00-measurement-pipeline` | 0.3 From the line simulator to a checked report | Ch0 · Setup |
| `01-batch-vs-per-parcel` | 1.1 Per-parcel handling against batch-32 | Ch1 · Latency vs bandwidth |
| `01-bimodal-tail` | 1.2 One slow parcel in a hundred | Ch1 · Latency vs bandwidth |
| `02-littles-law` | 2.1 Little's Law on the line | Ch2 · Little's Law and Amdahl's Law |
| `02-amdahl-phases` | 2.2 Amdahl's Law in phases at N = 1, 2 and 4 | Ch2 · Little's Law and Amdahl's Law |
| `03-three-clocks` | 3.1 Where each clock starts | Ch3 · Measuring correctly |
| `03-coordinated-omission` | 3.2 A 200 ms stall, seen four ways | Ch3 · Measuring correctly |
| `04-three-harnesses` | 4.1 One workload, three harnesses | Ch4 · Benchmark harnesses |
| `04-dead-code-elimination` | 4.2 Dead-code elimination | Ch4 · Benchmark harnesses |
