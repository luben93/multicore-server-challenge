#!/usr/bin/env bash
# Local load test: fresh DB copy, start a submission pinned to SRV_CPUS, warm up, then measure with loadgen pinned
# to LG_CPUS. Reports req/s, latencies, errors, and CPU-µs per request for the app and for Postgres.
#   bench.sh <submission-dir> <users> <think-scale> [measure_s=60] [ramp_s=20]
# env: TEMPLATE (conduit_seed), SRV_CPUS (0-2), LG_CPUS (3), WARM_USERS (1000), WARM_S (30), KEEP=1 keeps server up,
#      PORT (3000), TAG (label), ARTICLES (500000 or 10000 for dev)
set -euo pipefail
source /etc/profile.d/challenge-env.sh
# one load test at a time on this machine (several agents share it)
exec 9>/opt/tools/bench.lock; flock 9
DIR="$(cd "$1" && pwd)"; USERS=$2; SCALE=$3; MEAS=${4:-60}; RAMP=${5:-20}
TEMPLATE=${TEMPLATE:-conduit_seed}; SRV_CPUS=${SRV_CPUS:-0-2}; LG_CPUS=${LG_CPUS:-3}
WARM_USERS=${WARM_USERS:-1000}; WARM_S=${WARM_S:-30}; PORT=${PORT:-3000}; TAG=${TAG:-$(basename "$DIR")}
ARTICLES=${ARTICLES:-$([ "$TEMPLATE" = conduit_dev ] && echo 10000 || echo 500000)}
OUT=/opt/tools/results/$TAG-u$USERS-s$SCALE-$(date +%H%M%S); mkdir -p "$OUT"
DB=bench_db; PSQL="psql -X -q -v ON_ERROR_STOP=1 -d postgres"
$PSQL -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
psql -X -q -d $DB -c "VACUUM ANALYZE" >/dev/null 2>&1 || true
export DATABASE_URL="postgres://conduit:conduit@127.0.0.1:5432/$DB" JWT_SECRET=multicore-server-challenge HOST=127.0.0.1 PORT
fuser -k $PORT/tcp >/dev/null 2>&1 || true
(cd "$DIR" && exec taskset -c $SRV_CPUS bash start.sh) > "$OUT/server.log" 2>&1 &
SPID=$!
for _ in $(seq 120); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 0.5; done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" || { echo "server not up"; tail -20 "$OUT/server.log"; exit 1; }
APPPID=$(pgrep -P $SPID | head -1 || true); [ -z "$APPPID" ] && APPPID=$SPID
# descend exec chains: pick the deepest child (java/kexe) of the start.sh tree
while c=$(pgrep -P $APPPID | head -1) && [ -n "$c" ]; do APPPID=$c; done
echo "app pid $APPPID ($(cat /proc/$APPPID/comm))"
ticks() { awk '{print $14+$15}' /proc/$1/stat 2>/dev/null || echo 0; }
pgticks() { local s=0; for p in $(pgrep -u postgres); do t=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null || echo 0); s=$((s+t)); done; echo $s; }
if [ "$WARM_S" -gt 0 ]; then
  taskset -c $LG_CPUS /opt/tools/loadgen run -target http://127.0.0.1:$PORT -users $WARM_USERS -ramp 5s -measure ${WARM_S}s -tail 2s \
    -secret $JWT_SECRET -articles $ARTICLES -think-scale 0.2 -run-id warm$RANDOM -q -out "$OUT/warm.json" >/dev/null 2>&1 || true
  sleep 3
fi
RUNID=r$(date +%s)
START=$(( $(date +%s%3N) + 2000 ))
taskset -c $LG_CPUS /opt/tools/loadgen run -target http://127.0.0.1:$PORT -users $USERS -ramp ${RAMP}s -measure ${MEAS}s -tail 3s \
  -secret $JWT_SECRET -articles $ARTICLES -think-scale $SCALE -run-id $RUNID -start-at $START -q -out "$OUT/box0.json" > "$OUT/lg.log" 2>&1 &
LGPID=$!
# sample CPU exactly over the measure window
sleep $(awk -v s=$START -v r=$RAMP 'BEGIN{ printf "%.3f", (s + r*1000)/1000 - systime() }' | awk '{print ($1>0)?$1:0}')
A0=$(ticks $APPPID); P0=$(pgticks); T0=$(date +%s%3N); RSS0=$(awk '/VmRSS/{print $2}' /proc/$APPPID/status)
sleep $MEAS
A1=$(ticks $APPPID); P1=$(pgticks); T1=$(date +%s%3N); RSS1=$(awk '/VmRSS/{print $2}' /proc/$APPPID/status)
FDS=$(ls /proc/$APPPID/fd | wc -l)
wait $LGPID || true
/opt/tools/loadgen merge -o "$OUT/merged.json" "$OUT/box0.json" > "$OUT/merged.txt" 2>&1 || true
HZ=$(getconf CLK_TCK)
python3 - "$OUT" $A0 $A1 $P0 $P1 $T0 $T1 $HZ $RSS1 $FDS "$TAG" $USERS $SCALE <<'PY'
import json,sys
out,a0,a1,p0,p1,t0,t1,hz,rss,fds,tag,users,scale=sys.argv[1:]
a=(int(a1)-int(a0))/int(hz); p=(int(p1)-int(p0))/int(hz); win=(int(t1)-int(t0))/1000
m=json.load(open(out+"/merged.json"))
o=m.get("overall",m)
def g(*ks):
    for k in ks:
        if k in o: return o[k]
    return None
rps=g("rps","req_per_s"); n=g("count","requests")
req = rps*win if rps else 0
line=f"{tag} users={users} scale={scale} rps={rps:.0f} p50={g('p50_ms')} p95={g('p95_ms')} p99={g('p99_ms')} err={g('error_rate')} | app={a/win*100:.0f}%cpu pg={p/win*100:.0f}%cpu | app_us/req={a/req*1e6:.1f} pg_us/req={p/req*1e6:.1f} total_us/req={(a+p)/req*1e6:.1f} | rss={int(rss)//1024}MB fds={fds} pass={m['verdict']['pass']} lgcpu={m['boxes'][0]['proc_cpu_avg_measure_pct']:.0f}% {';'.join(m['verdict'].get('fail_reasons') or [])}"
print(line); open(out+"/summary.txt","w").write(line+"\n")
open("/opt/tools/results/ALL.txt","a").write(line+"\n")
PY
if [ "${KEEP:-0}" != 1 ]; then pkill -P $SPID 2>/dev/null || true; kill $SPID 2>/dev/null || true; sleep 1; kill -9 $APPPID 2>/dev/null || true; fi
