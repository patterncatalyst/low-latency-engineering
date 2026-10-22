#!/usr/bin/env bash
# wordcount.sh - prose word count per chapter; exit 1 when a chapter is outside
# 1,900-2,500 words. Counts exactly as _plans/r01-chapters.md specifies: the text
# after the front matter, without fenced code, include tags ({% ... %}) and table
# rows. Overview pages (front matter `overview: true`) are skipped.
#
#   scripts/wordcount.sh            # every _docs/*.md chapter
#   scripts/wordcount.sh FILE...    # chosen files
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN=${WORDCOUNT_MIN:-1900}
MAX=${WORDCOUNT_MAX:-2500}

if (($#)); then files=("$@"); else files=("$ROOT"/_docs/*.md); fi

fail=0
printf '%-48s %6s  %s\n' chapter words status
for f in "${files[@]}"; do
  # Skip overview pages.
  if sed -n '2,/^---$/p' "$f" | grep -qE '^overview:[[:space:]]*true'; then
    printf '%-48s %6s  %s\n' "$(basename "$f")" - "skipped (overview)"
    continue
  fi
  n=$(python3 -I - "$f" <<'PY'
import re
import sys

text = open(sys.argv[1]).read().split('---', 2)[2]
text = re.sub(r'```.*?```', '', text, flags=re.S)
text = re.sub(r'\{%.*?%\}', '', text)
text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('|'))
print(len(re.findall(r"[A-Za-z0-9][\w'.-]*", text)))
PY
  )
  if ((n < MIN || n > MAX)); then
    status="OUTSIDE ${MIN}-${MAX}"
    fail=1
  else
    status=ok
  fi
  printf '%-48s %6d  %s\n' "$(basename "$f")" "$n" "$status"
done
exit "$fail"
