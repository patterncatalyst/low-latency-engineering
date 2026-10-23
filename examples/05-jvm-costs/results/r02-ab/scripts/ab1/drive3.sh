#!/usr/bin/env bash
S=${AB_DIR:?set AB_DIR to the scratch directory holding ab-old, ab-new and out}
run() { # ex tree pair
  local ex=$1 tree=$2 pair=$3 dir=$S/out/$1-$2-$3
  while :; do l=$(cut -d' ' -f1 /proc/loadavg); awk -v l=$l 'BEGIN{exit !(l>2.0)}' || break; sleep 10; done
  echo "$ex $tree pair$pair loadavg_before=$(cut -d' ' -f1-3 /proc/loadavg)" | tee -a $S/runs.log
  mkdir -p $dir
  (cd $S/ab-$tree/examples/$ex && SKIP_BUILD=1 RESULTS_DIR=$dir ./verify.sh > $dir.log 2>&1; echo "  rc=$? loadavg_after=$(cut -d' ' -f1-3 /proc/loadavg)" | tee -a $S/runs.log)
}
for p in 4 5 6; do for t in old new; do run 05-jvm-costs $t $p; done; done
echo DONE3 >> $S/runs.log
