#!/usr/bin/env bash
# usage: build.sh TREE
T=$1
cd "$T/examples/05-jvm-costs"
. ../_lib/lib.sh
build_cpp jvmcosts-consumer jvmcosts-bench jvm-costs-test line-simulator line-consumer
build_java "$LOWLAT_EXAMPLES/05-jvm-costs/java"
build_java "$LOWLAT_EXAMPLES/common/line-simulator/consumers/java"
py_sync
