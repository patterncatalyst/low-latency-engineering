---
title: "r01 chapters (S21–S25)"
layout: plan
render_with_liquid: false
---

# r01 chapters — S21–S25

One chapter per example, written from the example's code and its committed
S19 results. Binding for every chapter.

## Files

| Step | File | `order` | `part` | Title | Example |
|---|---|---|---|---|---|
| S21 | `_docs/00-prerequisites.md` | 0 | `Prerequisites & the Lab` | Setup: toolchains, the VM lab and the line simulator | `examples/00-prerequisites/` |
| S22 | `_docs/01-latency-distribution.md` | 1 | `Understanding & Measuring Latency` | Latency vs bandwidth: latency is a distribution | `examples/01-latency-distribution/` |
| S23 | `_docs/02-littles-amdahl.md` | 2 | `Understanding & Measuring Latency` | Modelling with Little's Law and Amdahl's Law | `examples/02-littles-amdahl/` |
| S24 | `_docs/03-coordinated-omission.md` | 3 | `Understanding & Measuring Latency` | Measuring correctly: clocks, percentiles and coordinated omission | `examples/03-coordinated-omission/` |
| S25 | `_docs/04-benchmark-harnesses.md` | 4 | `Understanding & Measuring Latency` | Benchmark harnesses: Google Benchmark, pyperf and JMH | `examples/04-benchmark-harnesses/` |

Front matter: `title`, `order`, `part` (exactly as above), `description`
(quoted), `duration`. The Outline page (`_docs/00-outline.md`, `overview: true`)
is not a chapter; do not touch it.

## Shape (the house spine)

1. **Learning objectives** (3–5 bullets).
2. **Why this matters**: the hook, in the sortation-line domain (scan-to-divert
   budget; the belt never waits). Never trading.
3. **Diagram**: the chapter's figures from `_data/diagrams.yml`, embedded with
   `{% include excalidraw.html file="<name>" alt="<alt>" caption="<caption>" %}`
   using exactly the YAML's alt and caption. Every figure of the chapter appears
   once, where it supports the text.
4. **Concept**.
5. **How the code works**: real code copied verbatim from the example's source
   files (name the file), shown in all three languages with
   `{% include codetabs.html langs="C++|Python|Java" %}` followed by one fenced
   block per language in that order. Explain each meaningful call and why it is
   made that way, as if the reader were writing it. Where a language diverges
   (no clean equivalent), say so and teach the divergence; never a language
   shootout.
6. **Measure**: how to run it (`./verify.sh`; the example dir is
   `examples/NN-name/`, "the run script there builds and runs it; its
   `README.md` covers what it does and how to drive it"), then the results.
7. **Cross-check** against an independent tool or method where the example has
   one.
8. **What you learned** (bullets).
9. **For deeper coverage**: only sources already named in the repo (`CLAUDE.md`,
   `_docs/00-outline.md`, `_plans/iteration-plan.md`), e.g. Enberg, *Latency*
   (Manning) as further reading; cross-references to other chapters by name and
   `Part N`. Never invent a book, author, URL or quotation, and never paraphrase
   or adapt a source book's content.
10. **Verification status** footer: behavioural, naming what `verify.sh`
    asserts and the runs (`r01-run1..3`) it held on.

Length: 1,900–2,500 words of prose, excluding front matter, fenced code,
include tags and tables. Count with
`python3 -c "import re,sys;t=open(sys.argv[1]).read().split('---',2)[2];t=re.sub(r'\`\`\`.*?\`\`\`','',t,flags=re.S);t=re.sub(r'\{%.*?%\}','',t);t='\n'.join(l for l in t.splitlines() if not l.lstrip().startswith('|'));print(len(re.findall(r'[A-Za-z0-9][\w\'.-]*',t)))" FILE`.

## Numbers

- Every number in the prose is a configured parameter (from the example's README
  or `verify.sh`) or a value in the committed results:
  `examples/NN-*/results/r01-run{1,2,3}/` (reports `*.json`, percentiles in ns;
  `verify.log`; `recheck.log` in 01). Quote measured values as the range across
  the three runs, rounded sensibly, and say which runs.
- Label every measured number with its profile once per chapter, e.g. "bare-metal
  host, Intel Core i7-11800H, 16 logical CPUs, Fedora 44 kernel
  7.2.11-200.fc44 (PREEMPT_DYNAMIC), governor `powersave`, tuned `balanced`,
  untuned, clocksource `tsc`". Ch1–4 numbers are host bare metal, untuned.
- VM numbers (Ch0 only: `examples/00-prerequisites/results/r01-vm-smoke/vm/`) are
  labelled VM and never compared with bare-metal numbers. The host reports in
  `r01-vm-smoke/` were taken on a busy host: never quote them.
- Never a mean or average latency, anywhere. cyclictest prints `Avg`: never quote
  it. A time-average appears only in Ch2 as a labelled modelling input (W-bar).
- Never a number you cannot point at in a committed file.

## Voice

Apply `lgtm-professional-voice` (`~/.claude/skills/lgtm-professional-voice/SKILL.md`)
while writing and run its `scripts/scan.sh` on the chapter until it reports
0 ban-tier findings. No "honest/honestly/lie" framing of people or methods (a
machine reporting a wrong value may "lie"). No reference to "the roadmap", "the
requirements" or the PRD. No em-dash runs; plain declarative sentences.

## Status

| Step | Status |
|---|---|
| S21 Ch0 | done |
| S22 Ch1 | done |
| S23 Ch2 | done |
| S24 Ch3 | done |
| S25 Ch4 | done |
| Opus validation | done: 11 criteria met after fixes; every number recomputed from r01-run1..3 |
