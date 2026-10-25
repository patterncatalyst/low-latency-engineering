---
title: "Draft upstream report: cyclictest 2.11 defaults to CLOCK_REALTIME"
render_with_liquid: false
description: "Unfiled draft bug report for rt-tests. cyclictest v2.11 sleeps on CLOCK_REALTIME without -c although its help text says monotonic is the default. Kept in _plans (not published); filed only with the user's OK."
---

**Status: draft, not filed.** The user decided on 2026-10-25 to keep this in the repository and not send it yet. Filing it is
outward-facing and needs the user's OK. `_plans` isn't rendered on the site (`output: false` in `_config.yml`).

**Where it would go:** the rt-tests maintainers, through the linux-rt-users list (`linux-rt-users@vger.kernel.org`), which is
how rt-tests patches and reports are sent. Upstream tree: `https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git`.

**How we found it:** r05 S0 fact check of cyclictest's options, then confirmed with strace in the lab guest in S1
(`_plans/dependency-pins.md`, "Runtime facts for Ch14-16 prose" and "r05 guest probes (S1)").

**Effect on this book:** every r05 cyclictest call passes `--clock=monotonic` explicitly (`examples/_lib/lib.sh`
`cyclictest_run`). Ch16's `naive` lane keeps the default on purpose and names the clock it gets.

---

## Draft report

**Subject:** `[PATCH/BUG] cyclictest: default clock is CLOCK_REALTIME since "Centralize clock option parsing"`

Since commit 222b801 ("cyclictest: Centralize clock option parsing"), first released in v2.11, cyclictest uses
`CLOCK_REALTIME` when `-c`/`--clock` isn't given. The help text still says monotonic is the default:

```
-c CLOCK --clock=CLOCK     select clock
                           0 = CLOCK_MONOTONIC
                           1 = CLOCK_REALTIME
                           monotonic (default)
```

### Cause

v2.10 selected the clock by index, and the index defaulted to the monotonic entry:

```c
static int clocksel = 0;
static int clocksources[] = {
	CLOCK_MONOTONIC,
	CLOCK_REALTIME,
};
...
		par->clock = clocksources[clocksel];
```

222b801 replaced the index with a clock id and moved the parsing into `handleclock()`:

```c
static clockid_t used_clock;
...
		case 'c':
		case OPT_CLOCK:
			error |= handleclock(optarg); break;
...
		par->clock = used_clock;
```

`handleclock()` is the only assignment to `used_clock`, and it runs only when `-c`/`--clock` is given. Without it,
`used_clock` keeps its zero initialisation, and `CLOCK_REALTIME` is 0 on Linux. The commit message describes the change as a
refactor, plus an off-by-one fix in the argument check, so the change of default looks unintended. `main` is at the v2.11
commit (62da2be), so it's still present.

### Reproducer

On a Fedora 44 KVM guest, `realtime-tests-2.11-1.fc44`, kernel 7.2.11 (stock and PREEMPT_RT both show it):

```
$ sudo strace -f -e trace=clock_nanosleep cyclictest -q -l 3 -i 1000 -t 1
[pid N] clock_nanosleep(CLOCK_REALTIME, TIMER_ABSTIME, {tv_sec=1792959081, ...}, NULL) = 0

$ sudo strace -f -e trace=clock_nanosleep cyclictest -q -l 3 -i 1000 -t 1 --clock=monotonic
[pid N] clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, {tv_sec=107, ...}, NULL) = 0
```

(The other `clock_nanosleep(CLOCK_REALTIME, 0, ...)` in the trace is the main thread's relative sleep, with or without `-c`.)

### Why it matters

- **Clock steps:** absolute `CLOCK_REALTIME` sleeps follow `settimeofday()` and clock steps. An NTP or chrony step during a run
  can show up as a wake far off its intended time, or as a run that stalls, which isn't scheduling latency.
- **Comparisons across versions:** results from v2.10 and earlier (monotonic) and v2.11 (realtime) aren't taken against the
  same clock, although the command line is the same.
- **Documentation:** users who read the help text, or the man page, believe they're on the monotonic clock.

### Suggested fix

Initialise the variable to the documented default:

```c
static clockid_t used_clock = CLOCK_MONOTONIC;
```

Then optionally add a test or a `--verbose` line that prints the clock in use. The JSON output could also record it: it has
`"cmdline:"` today but no clock field.

---

## Before filing (checklist)

- [ ] Re-check `main` for a fix (as of 2026-10-25 it is the v2.11 commit, 62da2be).
- [ ] Re-check the man page text in `src/cyclictest/cyclictest.8` at the same commit, and quote it if it also says monotonic.
- [ ] Decide report or patch. A one-line patch with `Fixes: 222b801` is the usual form on linux-rt-users.
- [ ] Remove anything that identifies the lab host. The reproducer above names only the guest's distribution and kernel
      series, never the host.
- [ ] The user's OK to send.
