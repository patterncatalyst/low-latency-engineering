# r01-vm-smoke

`ALLOW_BUSY=1 VM=1 ./verify.sh`, 2026-10-21, with `lowlat-target` running
(PREEMPT_RT guest kernel, snapshot `lab-ready-rt`).

- Host reports (`cpp.json`, `python.json`, `java.json`) were recorded on a busy
  host (the lab VM was running). They prove the smoke path only; never quote
  them. The publishable host runs are in `r01-run1..3`.
- `vm/` is guest output, labelled `vm`: one unpinned, untuned 60 s cyclictest
  thread. Never compare it with bare-metal numbers.
