#!/usr/bin/env bash
# Capacity search on the 2-core partition (server + Postgres on CPUs 0-1, loadgen on 2-3):
# runs bench.sh at increasing user counts until a run fails, prints the last pass.
#   capacity.sh <submission-dir> <tag> [think-scale=0.2] [users list...]
set -uo pipefail
DIR=$1; TAG=$2; SCALE=${3:-0.2}; shift 3 2>/dev/null || shift $#
LIST=${*:-"6000 9000 11000 13000 15000 17000 19000"}
export SRV_CPUS=${SRV_CPUS:-0-1} LG_CPUS=${LG_CPUS:-2-3}
last=""
for u in $LIST; do
  line=$(TAG=$TAG /opt/tools/bench.sh "$DIR" "$u" "$SCALE" ${MEAS:-60} ${RAMP:-20} 2>&1 | tail -1)
  echo "$line"
  case "$line" in *pass=True*) last="$line" ;; *) break ;; esac
done
echo "LAST PASS: ${last:-none}"
