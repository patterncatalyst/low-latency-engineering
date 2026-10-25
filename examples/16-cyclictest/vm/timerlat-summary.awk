# timerlat-summary.awk - reduce `rtla timerlat hist` output to one line per column:
#
#   awk -f timerlat-summary.awk rtla.out
#   irq   count=119987 over=0 min=1 max=41 p50=3 p99=9 p99_9=27
#   thread count=119987 over=0 min=4 max=63 p50=9 p99=21 p99_9=44
#
# rtla prints a header (`Index   IRQ-003   Thr-003 ...`), one row per non-empty bucket (bucket index, then a count per
# column) and the trailer rows `over:`, `count:`, `min:`, `avg:` and `max:`. The `avg:` row is never read and nothing
# here computes an average. A percentile is the lower edge of the bucket that holds that rank (rank = round-half-up of
# p x count / 100, at least 1), in the unit rtla prints (microseconds; nanoseconds with -n). A rank beyond the buckets
# (it falls in `over`) prints `over`, so a run whose range was too small says so instead of reporting a wrong number.
# Columns: IRQ-nnn is irq, Thr-nnn thread, Usr-nnn user.

function kind(s,    p) {
  p = tolower(substr(s, 1, 3))
  if (p == "irq") return "irq"
  if (p == "thr") return "thread"
  if (p == "usr") return "user"
  return ""
}

function pct(c, p,    rank, cum, i) {
  rank = int(p / 100 * total[c] + 0.5)
  if (rank < 1) rank = 1
  cum = 0
  for (i = 1; i <= nrows; i++) {
    cum += cnt[c, i]
    if (cum >= rank) return edge[i]
  }
  return "over"
}

/^Index/ {
  ncol = NF - 1
  for (c = 1; c <= ncol; c++) name[c] = kind($(c + 1))
  next
}
/^[0-9]+[ \t]/ {
  if (ncol == 0) next
  nrows++
  edge[nrows] = $1
  for (c = 1; c <= ncol; c++) cnt[c, nrows] = $(c + 1) + 0
  next
}
/^over:/ { for (c = 1; c <= ncol; c++) over[c] = $(c + 1) + 0; next }
/^count:/ { for (c = 1; c <= ncol; c++) total[c] = $(c + 1) + 0; next }
/^min:/ { for (c = 1; c <= ncol; c++) min[c] = $(c + 1) + 0; next }
/^max:/ { for (c = 1; c <= ncol; c++) max[c] = $(c + 1) + 0; next }

END {
  if (ncol == 0 || nrows == 0) { print "timerlat-summary: no histogram found in the input" > "/dev/stderr"; exit 1 }
  for (c = 1; c <= ncol; c++) {
    if (name[c] == "") continue
    # `count:` is the total of the column when rtla prints it; otherwise the sum of the buckets and the overflow.
    if (!(c in total)) { t = over[c] + 0; for (i = 1; i <= nrows; i++) t += cnt[c, i]; total[c] = t }
    printf "%s count=%d over=%d min=%s max=%s p50=%s p99=%s p99_9=%s\n", name[c], total[c], over[c] + 0,
      (c in min) ? min[c] : "null", (c in max) ? max[c] : "null", pct(c, 50), pct(c, 99), pct(c, 99.9)
  }
}
