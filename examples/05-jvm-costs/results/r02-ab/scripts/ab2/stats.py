import json
import math
import random
import statistics
import sys


def fisher_exact(t):
    (a, b), (c, d) = t
    r1 = a + b
    r2 = c + d
    c1 = a + c
    n = r1 + r2

    def pr(x):
        return math.comb(r1, x) * math.comb(r2, c1 - x) / math.comb(n, c1)

    p0 = pr(a)
    return 0, sum(
        pr(x) for x in range(max(0, c1 - r2), min(r1, c1) + 1) if pr(x) <= p0 * (1 + 1e-9)
    )


def mwu(x, y):
    allv = sorted(x + y)
    rk = {}
    i = 0
    while i < len(allv):
        j = i
        while j < len(allv) and allv[j] == allv[i]:
            j += 1
        for v in [allv[i]]:
            rk[v] = (i + j + 1) / 2
        i = j
    U = sum(rk[v] for v in x) - len(x) * (len(x) + 1) / 2
    n1, n2 = len(x), len(y)
    N = n1 + n2
    from collections import Counter

    tie = sum(c**3 - c for c in Counter(allv).values())
    var = n1 * n2 / 12 * ((N + 1) - tie / (N * (N - 1)))
    z = (U - n1 * n2 / 2) / math.sqrt(var)
    two = math.erfc(abs(z) / math.sqrt(2))
    one = 0.5 * math.erfc(z / math.sqrt(2))
    # permutation
    random.seed(1)
    cnt = 0
    M = 200000
    obs = abs(U - n1 * n2 / 2)
    for _ in range(M):
        random.shuffle(allv)
        u = sum(rk[v] for v in allv[:n1]) - n1 * (n1 + 1) / 2  # ranks by value; ties share
        if abs(u - n1 * n2 / 2) >= obs - 1e-9:
            cnt += 1
    return U, two, one, cnt / M


S, K = sys.argv[1], sys.argv[2]


def get(path):
    p = json.load(open(path))["percentiles"]
    return [p["p50"] / 1e3, p["p99"] / 1e3, p["p99_9"] / 1e3]


d = {"old": [], "new": []}
for t in d:
    for i in range(1, 7):
        d[t].append((f"A{i}", get(f"{K}/05-jvm-costs-{t}-{i}/java-warmed-steady.json")))
    for i in range(1, 13):
        d[t].append((f"B{i}", get(f"{S}/out/{t}-{i}/java-warmed-steady.json")))
for i in range(18):
    o, n = d["old"][i], d["new"][i]
    print(
        o[0],
        "old {:.1f} {:.1f} {:.1f}".format(*tuple(o[1])),
        "| new {:.1f} {:.1f} {:.1f}".format(*tuple(n[1])),
    )


def rep(lo, hi, name):
    o = [x[1][0] for x in d["old"][lo:hi]]
    n = [x[1][0] for x in d["new"][lo:hi]]
    ho = sum(v > 130 for v in o)
    hn = sum(v > 130 for v in n)
    print(
        name,
        f"high old {ho}/{len(o)} new {hn}/{len(n)}",
        f"fisher p={fisher_exact([[hn, len(n) - hn], [ho, len(o) - ho]])[1]:.3f}",
        "MWU U_new={:.1f} z-two={:.3f} z-one(new>old)={:.3f} perm-two={:.3f}".format(*mwu(n, o)),
        f"medians old {statistics.median(o):.1f} new {statistics.median(n):.1f}",
    )


rep(6, 18, "new12")
rep(0, 18, "all18")
