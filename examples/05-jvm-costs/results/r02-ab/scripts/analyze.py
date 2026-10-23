#!/usr/bin/env python3
"""Print the README tables from ab.csv.  usage: analyze.py ab.csv"""
import csv, math, random, statistics, sys
from collections import Counter, defaultdict

HIGH_US = 130.0  # a steady p50 above this is "high mode" (the p50 distribution splits there)

def fisher(a, b, c, d):
    r1, r2, c1, n = a + b, c + d, a + c, a + b + c + d
    pr = lambda x: math.comb(r1, x) * math.comb(r2, c1 - x) / math.comb(n, c1)
    p0 = pr(a)
    return sum(pr(x) for x in range(max(0, c1 - r2), min(r1, c1) + 1) if pr(x) <= p0 * (1 + 1e-9))

def mwu(x, y):
    """Two-sided Mann-Whitney U, tie-corrected normal approximation, plus a
    200,000-draw permutation p-value (seed 1)."""
    allv = sorted(x + y); rk = {}; i = 0
    while i < len(allv):
        j = i
        while j < len(allv) and allv[j] == allv[i]:
            j += 1
        rk[allv[i]] = (i + j + 1) / 2; i = j
    n1, n2 = len(x), len(y); N = n1 + n2
    U = sum(rk[v] for v in x) - n1 * (n1 + 1) / 2
    tie = sum(c ** 3 - c for c in Counter(allv).values())
    var = n1 * n2 / 12 * ((N + 1) - tie / (N * (N - 1)))
    z = (U - n1 * n2 / 2) / math.sqrt(var)
    two = math.erfc(abs(z) / math.sqrt(2))
    random.seed(1); cnt = 0; obs = abs(U - n1 * n2 / 2); pool = allv[:]
    for _ in range(200000):
        random.shuffle(pool)
        u = sum(rk[v] for v in pool[:n1]) - n1 * (n1 + 1) / 2
        if abs(u - n1 * n2 / 2) >= obs - 1e-9:
            cnt += 1
    return two, cnt / 200000

rows = list(csv.DictReader(open(sys.argv[1])))
def sel(**kw):
    return [r for r in rows if all(r[k] == v for k, v in kw.items())]
def med(v): return statistics.median(v)

print("## Steady-window percentiles per run (us), old | new")
for set_ in ("ab1", "ab2"):
    for var in sorted({r["variant"] for r in sel(set=set_, lane="05", window="steady")}):
        print(f"\n{set_} {var}")
        for p in sorted({int(r["pair"]) for r in sel(set=set_, variant=var, window="steady")}):
            cell = {}
            for t in ("old", "new"):
                r = [x for x in sel(set=set_, variant=var, window="steady", tree=t) if int(x["pair"]) == p][0]
                cell[t] = "%.1f / %.1f / %.1f" % tuple(int(r[k]) / 1e3 for k in ("p50_ns", "p99_ns", "p999_ns"))
            print(f"  pair {p:2d}: {cell['old']:>24} | {cell['new']:>24}")

print("\n## Medians over pairs (us), steady window; high = p50 > %.0f us" % HIGH_US)
print("set variant lane | old p50 p99 p99.9 high | new p50 p99 p99.9 high")
for set_ in ("ab1", "ab2"):
    for var in sorted({r["variant"] for r in sel(set=set_, lane="05", window="steady")}):
        out = []
        for t in ("old", "new"):
            rs = sel(set=set_, variant=var, window="steady", tree=t)
            m = [med([int(r[k]) for r in rs]) / 1e3 for k in ("p50_ns", "p99_ns", "p999_ns")]
            hi = sum(int(r["p50_ns"]) / 1e3 > HIGH_US for r in rs)
            out.append("%.1f %.1f %.1f %d/%d" % (*m, hi, len(rs)))
        print(set_, var, "05 |", " | ".join(out))

def compare(label, var, sets):
    o = [int(r["p50_ns"]) / 1e3 for s in sets for r in sel(set=s, variant=var, window="steady", tree="old")]
    n = [int(r["p50_ns"]) / 1e3 for s in sets for r in sel(set=s, variant=var, window="steady", tree="new")]
    ho, hn = sum(v > HIGH_US for v in o), sum(v > HIGH_US for v in n)
    p_f = fisher(hn, len(n) - hn, ho, len(o) - ho)
    p_z, p_perm = mwu(n, o)
    print(f"{label} {var}: high old {ho}/{len(o)} new {hn}/{len(n)}; Fisher p={p_f:.3f}; "
          f"Mann-Whitney p(normal)={p_z:.3f} p(perm)={p_perm:.3f}; median old {med(o):.1f} new {med(n):.1f}")

print("\n## Steady p50: high-mode counts and tests (old vs new)")
for var in ("cpp-tracker", "java-aot-cache", "java-unwarmed", "java-warmed"):
    compare("ab1 (6 pairs)", var, ("ab1",))
compare("ab2 (12 pairs)", "java-warmed", ("ab2",))
compare("ab1+ab2 (18 pairs)", "java-warmed", ("ab1", "ab2"))
