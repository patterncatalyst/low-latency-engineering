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
| `05-jit-tiers` | 5.1 JIT tiers and who pays for warm-up | Ch5 · What the JVM costs |
| `05-escape-analysis` | 5.2 Escape analysis removes the allocation | Ch5 · What the JVM costs |
| `06-collector-pauses` | 6.1 What each collector stops | Ch6 · GC for tails |
| `06-headroom-stall` | 6.2 Headroom decides whether allocation stalls | Ch6 · GC for tails |
| `06-refcount-vs-tracing` | 6.3 Who reclaims memory in C++, Python and Java | Ch6 · GC for tails |
| `07-handoff-topology` | 7.1 The hand-off between the receive and decide threads | Ch7 · Off-heap and lock-free Java |
| `07-ring-sequences` | 7.2 Sequences and slots in a ring buffer | Ch7 · Off-heap and lock-free Java |
| `07-affinity-vm` | 7.3 Pinning the decide thread to an isolated vCPU (VM) | Ch7 · Off-heap and lock-free Java |
| `08-zero-copy-decode` | 8.1 Protobuf parse against a flat view | Ch8 · Zero-copy and flat data |
| `08-flat-vs-pointer-layout` | 8.2 An array of objects against a flat table | Ch8 · Zero-copy and flat data |
| `09-working-set` | 9.1 The working set against the cache hierarchy | Ch9 · Eliminating work |
| `09-node-vs-flat-map` | 9.2 A node map against a flat map | Ch9 · Eliminating work |
| `09-hot-cold-split` | 9.3 A fat record against hot columns | Ch9 · Eliminating work |
| `09-false-sharing` | 9.4 Five camera counters in one cache line | Ch9 · Eliminating work |
| `10-progress-guarantees` | 10.1 Blocking, lock-free and wait-free claims | Ch10 · Lock-free and wait-free |
| `10-store-buffer` | 10.2 The store buffer and the induction-gap test | Ch10 · Lock-free and wait-free |
| `10-seqlock` | 10.3 A sequence lock against a shared mutex | Ch10 · Lock-free and wait-free |
| `10-stalled-producer` | 10.4 A claimed but unpublished slot | Ch10 · Lock-free and wait-free |
