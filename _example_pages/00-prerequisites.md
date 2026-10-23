---
layout: plan
title: "Example 00: lab smoke test"
order: 0
permalink: /examples/00-prerequisites/
card_eyebrow: "Example 00 · Chapter 0"
card_title: "Lab smoke test"
card_blurb: "The simulator and all three consumers on loopback: 5,000 parcels, none dropped, a schema-valid report with the machine profile from each language."
description: "The simulator and all three consumers on loopback: 5,000 parcels, none dropped, a schema-valid report with the machine profile from each language."
languages: "C++ · Python · Java"
---

Chapter 0 proves the toolchain end to end before any latency claim is made. The C++ line simulator emits parcels at 1 kHz for 5 s; the C++, Python and Java consumers each receive all 5,000 over loopback and write a `lowlat-report/1` that carries the machine profile. The percentile columns are a smoke number, not a result.

## Run

```bash
examples/00-prerequisites/verify.sh
```

`verify.sh` builds what it needs, captures the machine profile, runs the example and writes reports to `results/latest/`. It refuses to measure while a `lowlat-*` VM is running unless `ALLOW_BUSY=1` is set, and it never changes the host.

## What `verify.sh` asserts

- `scripts/check-prereqs.sh` exits 0.
- Each consumer reports `count = 5000` and `dropped = 0`.
- Each report validates against the schema, carries the machine profile and passes `lowlat-report check`.
- With `VM=1` (and `ALLOW_BUSY=1`, because the guest must be running): the guest passes `check-prereqs.sh --vm`, runs `cyclictest`, and its profile reports a virtual machine. The output is labelled `vm` and is never compared with a bare-metal number.

It held on the quiet-host runs `r02-run1..3`; the VM path ran once (`results/r01-vm-smoke/`, labelled VM).

## Chapter and source

- Chapter: [Chapter 0, Setup: toolchains, the VM lab and the line simulator]({{ '/docs/00-prerequisites/' | relative_url }})
- Source: [`examples/00-prerequisites/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/00-prerequisites), with its `README.md`, the three language directories and the committed `results/r02-run1..3/`.

