#!/usr/bin/env bash
S=${AB_DIR:?set AB_DIR to the scratch directory holding ab-old, ab-new and out}
run() { local tree=$1 pair=$2 dir=$S/out/$1-$2
  while :; do l=$(cut -d' ' -f1 /proc/loadavg); awk -v l=$l 'BEGIN{exit !(l>2.0)}' || break; sleep 10; done
  echo "warmed $tree pair$pair loadavg_before=$(cut -d' ' -f1-3 /proc/loadavg)" >> $S/runs.log
  $S/warm.sh $S/ab-$tree $dir > $dir.log 2>&1; echo "  rc=$? loadavg_after=$(cut -d' ' -f1-3 /proc/loadavg)" >> $S/runs.log
}
mkdir -p $S/out
for p in $(seq 1 ${PAIRS:-12}); do run old $p; run new $p; done
echo DONE >> $S/runs.log
