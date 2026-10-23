# r02-ab: did the last change to the measured code move the latency?

An interleaved A/B of two trees of this repository on one host. Chapter 1 and
Chapter 5 cite it for one claim: the host's steady-window p50 moves between runs
of the same binary, and it moved the same way before and after the last change
to the measured paths.

## What was compared

| Tree | Commit | What it is |
|---|---|---|
| old | `d419992` | the tree before the last code change to the measured paths |
| new | `1e0d435` | the tree after it (the tree the committed `r02-run1..3` were taken from) |

`git diff --stat d419992 1e0d435 -- examples ':(exclude)examples/*/results/**'` lists the change. The A/B asks
whether it moved any Chapter 5 percentile.

## Method

- Each tree was checked out on its own and built with the `release` preset
  (`scripts/ab1/build.sh`, which calls the helpers in `examples/_lib/lib.sh`).
- Each run is the tree's own `verify.sh` lane command, started with `SKIP_BUILD=1`
  and an empty `RESULTS_DIR`. `scripts/ab2/warm.sh` is the `warmed` lane of the
  tree's `verify.sh` copied verbatim, so one Java variant can be repeated cheaply.
- Runs alternate old, then new, within every pair, so slow drift in the host
  affects both trees.
- Before every run the driver waits until the one-minute load average is below
  2.0. The `load1` column in `ab.csv` is the value the run's own profile recorded;
  its maximum is 1.84. `runs-ab1.log` and `runs-ab2.log` carry the load average
  before and after every run.
- No CPU pinning, tuning or real-time kernel was used. The host is the same
  machine as the committed runs (profile `virt.type` none, governor
  `powersave`, tuned `balanced`).

Two sets:

| Set | Runs | What |
|---|---|---|
| `ab1` | 6 pairs | every Chapter 5 lane (`java-unwarmed`, `java-warmed`, `java-aot-cache`, `cpp-tracker`) from `05-jvm-costs/verify.sh`, plus the Chapter 0 lane as a control. Driven by `drive.sh` (pairs 1-3 of both lanes), then `drive2.sh` (00, pairs 4-6) and `drive3.sh` (05, pairs 4-6). |
| `ab2` | 12 pairs | only `java-warmed`, because `ab1` gave a high steady p50 (above 130 us) in 1 of 6 old runs and 4 of 6 new runs. Driven by `scripts/ab2/drive.sh`. |

The Chapter 0 control lane failed in pairs 1-3 after its C++ report: the Python
consumer exited before binding its UDP port (`No module named 'lowlat'`, the
generated protobuf module was not on the path). Only the C++ numbers of pairs 1-3
exist, and pairs 4-6 were run again with all three languages. `runs-ab1.log` shows `rc=1` for those three pairs.

Windows follow the report names. `first-2000` is the first 2,000 events, `steady`
is everything after them, and `run` is the whole report. All numbers below are
microseconds from HdrHistogram percentiles in the reports; `ab.csv` has the same
values in nanoseconds.

## Files

| File | What |
|---|---|
| `ab.csv` | one row per report: `set,pair,tree,lane,variant,window,p50_ns,p99_ns,p999_ns,load1` (240 rows). Written by `scripts/extract.py` from the report JSONs, never by hand. |
| `runs-ab1.log`, `runs-ab2.log` | driver logs: load average before and after every run, and each run's exit code |
| `scripts/ab1/`, `scripts/ab2/` | build and driver scripts. `AB_DIR` replaces the scratch directory they ran in; it holds `ab-old/`, `ab-new/` and `out/`. `scripts/ab2/drive.sh` runs `warm.sh` from its own directory. |
| `scripts/extract.py` | `ab.csv` from the reports |
| `scripts/analyze.py` | the tables below from `ab.csv` |
| `scripts/ab2/stats.py` | the original statistics script of `ab2`, kept for the record. It reads the report JSONs; `analyze.py` gives the same p-values from `ab.csv`. |

The raw report JSONs (about 5.7 MB) are not committed. To rebuild `ab.csv`:
`python3 scripts/extract.py AB1_OUT AB2_OUT > ab.csv`.

## Results

`high` counts steady-window p50s above 130 us. The cut is a description of this data,
chosen after `ab1` ran, not a threshold set in advance. The tests compare
old with new on the steady p50: Fisher's exact test on the high counts, and a
two-sided Mann-Whitney U test (normal approximation with tie correction, then a
200,000-draw permutation test with seed 1).

```
## Steady-window percentiles per run (us), old | new

ab1 cpp-tracker
  pair  1:     99.9 / 187.9 / 239.2 |    104.6 / 186.5 / 222.6
  pair  2:    132.4 / 286.7 / 300.0 |    159.9 / 194.3 / 310.5
  pair  3:     96.6 / 183.8 / 210.0 |     94.0 / 177.3 / 195.6
  pair  4:     99.2 / 288.8 / 302.1 |    149.0 / 189.8 / 245.5
  pair  5:    146.8 / 189.4 / 223.1 |     97.2 / 188.5 / 212.1
  pair  6:     67.5 / 177.5 / 220.9 |     94.8 / 180.0 / 204.9

ab1 java-aot-cache
  pair  1:    139.1 / 212.6 / 275.5 |    166.9 / 213.6 / 308.0
  pair  2:     89.5 / 334.8 / 365.3 |    109.2 / 213.1 / 262.9
  pair  3:    107.7 / 204.9 / 246.0 |    159.2 / 440.3 / 480.5
  pair  4:    149.5 / 207.5 / 286.2 |    175.1 / 218.5 / 273.2
  pair  5:    169.0 / 212.0 / 277.2 |     81.9 / 334.6 / 367.4
  pair  6:    111.7 / 214.1 / 304.4 |    111.7 / 207.2 / 260.6

ab1 java-unwarmed
  pair  1:    144.9 / 214.5 / 284.2 |    162.9 / 226.3 / 303.1
  pair  2:    173.8 / 230.3 / 391.2 |    158.1 / 212.9 / 264.7
  pair  3:    167.6 / 212.9 / 278.8 |    104.7 / 206.5 / 321.8
  pair  4:     96.6 / 204.2 / 235.8 |    175.1 / 218.6 / 317.2
  pair  5:    175.6 / 231.4 / 321.5 |    149.5 / 421.6 / 472.1
  pair  6:    119.7 / 228.5 / 341.0 |    113.7 / 208.1 / 283.6

ab1 java-warmed
  pair  1:    105.7 / 199.2 / 233.3 |    105.6 / 200.3 / 242.6
  pair  2:    107.4 / 200.3 / 244.1 |    154.5 / 203.0 / 244.4
  pair  3:    108.7 / 201.1 / 240.1 |    172.8 / 217.9 / 289.0
  pair  4:     76.8 / 193.3 / 242.7 |    102.3 / 196.6 / 236.7
  pair  5:    155.0 / 327.7 / 344.1 |    171.1 / 205.7 / 261.0
  pair  6:    103.9 / 194.6 / 219.3 |    163.6 / 204.9 / 249.0

ab2 java-warmed
  pair  1:    104.9 / 207.0 / 257.5 |    125.4 / 393.0 / 417.3
  pair  2:    106.7 / 204.5 / 269.6 |    106.4 / 201.0 / 236.2
  pair  3:    108.0 / 203.6 / 257.7 |     77.6 / 323.6 / 349.7
  pair  4:    160.9 / 215.2 / 291.6 |    104.5 / 202.2 / 240.3
  pair  5:    111.2 / 206.6 / 266.5 |    159.5 / 205.7 / 253.6
  pair  6:    154.6 / 209.2 / 277.8 |    105.2 / 200.1 / 267.8
  pair  7:    116.5 / 209.8 / 284.9 |    146.0 / 203.5 / 250.5
  pair  8:    105.5 / 207.5 / 255.9 |    106.8 / 202.5 / 263.7
  pair  9:     78.0 / 311.3 / 336.6 |     88.6 / 312.1 / 331.8
  pair 10:    101.2 / 354.0 / 372.0 |    104.8 / 322.0 / 336.4
  pair 11:     76.6 / 183.4 / 266.5 |    104.1 / 201.0 / 253.2
  pair 12:    169.9 / 203.5 / 259.5 |    106.4 / 202.2 / 237.2

## Medians over pairs (us), steady window; high = p50 > 130 us
set variant lane | old p50 p99 p99.9 high | new p50 p99 p99.9 high
ab1 cpp-tracker 05 | 99.6 188.7 231.2 2/6 | 100.9 187.5 217.3 2/6
ab1 java-aot-cache 05 | 125.4 212.3 281.7 3/6 | 135.5 216.1 290.6 3/6
ab1 java-unwarmed 05 | 156.2 221.5 302.8 4/6 | 153.8 215.7 310.1 4/6
ab1 java-warmed 05 | 106.6 199.7 241.4 1/6 | 159.0 204.0 246.7 4/6
ab2 java-warmed 05 | 107.4 207.2 268.0 3/12 | 105.8 203.0 258.6 2/12

## Steady p50: high counts and tests (old vs new)
ab1 (6 pairs) cpp-tracker: high old 2/6 new 2/6; Fisher p=1.000; Mann-Whitney p(normal)=0.749 p(perm)=0.818; median old 99.6 new 100.9
ab1 (6 pairs) java-aot-cache: high old 3/6 new 3/6; Fisher p=1.000; Mann-Whitney p(normal)=0.688 p(perm)=0.730; median old 125.4 new 135.5
ab1 (6 pairs) java-unwarmed: high old 4/6 new 4/6; Fisher p=1.000; Mann-Whitney p(normal)=0.749 p(perm)=0.818; median old 156.2 new 153.8
ab1 (6 pairs) java-warmed: high old 1/6 new 4/6; Fisher p=0.242; Mann-Whitney p(normal)=0.200 p(perm)=0.240; median old 106.6 new 159.0
ab2 (12 pairs) java-warmed: high old 3/12 new 2/12; Fisher p=1.000; Mann-Whitney p(normal)=0.488 p(perm)=0.513; median old 107.4 new 105.8
ab1+ab2 (18 pairs) java-warmed: high old 4/18 new 6/18; Fisher p=0.711; Mann-Whitney p(normal)=0.728 p(perm)=0.743; median old 107.0 new 106.4
```

## Reading it

- No lane shows a difference between the trees that holds up. The four Chapter 5
  lanes in `ab1` have equal high counts (2/6 against 2/6, 3/6 against 3/6, 4/6
  against 4/6) except `java-warmed` (1/6 old, 4/6 new, Fisher p = 0.24). That is the
  one difference `ab1` found, and it is why `ab2` exists.
- `ab2`, 12 more pairs of `java-warmed` alone, reverses it: 3/12 old against 2/12
  new (Fisher p = 1.0, Mann-Whitney p = 0.49 to 0.51), with medians of 107.4 and
  105.8 us. Over all 18 pairs it is 4/18 against 6/18 (Fisher p = 0.71,
  Mann-Whitney p = 0.73 to 0.74) and medians of 107.0 and 106.4 us. A 12-pair
  set cannot rule out a shift even as large as a doubling of the high count
  (3/12 to 6/12 gives Fisher p = 0.40); it shows only that the spread is
  present in both trees.
- The p50 spread is present in both trees, in every Chapter 5 lane and in the
  Chapter 0 C++ control (C++ p50 102 to 158 us in the old tree, 70 to 157 us in the new one).
  A tree-wide change would not appear in both.
- The cause of the p50 states is not identified. This A/B found no sign that
  the code change caused it.

**Verdict: no shift detected.** Neither set found a difference between the trees,
and the p50 spread is present in both.
