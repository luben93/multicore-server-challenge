#!/usr/bin/env bash
# Brings the lab back after a container restart: box sysctls, Postgres 18 pinned to CPUs 0-1.
set -uo pipefail
for kv in "net/core/somaxconn 65535" "net/ipv4/tcp_max_syn_backlog 65535" "net/ipv4/tcp_tw_reuse 1" "vm/max_map_count 65530" "net/ipv4/ip_local_port_range 1024 65535"; do
  set -- $kv; k=$1; shift; echo "$*" > /proc/sys/$k 2>/dev/null || echo "cannot set $k"
done
mkdir -p /var/run/postgresql && chown postgres /var/run/postgresql
if ! su postgres -c "/opt/pg18/bin/pg_ctl -D /var/lib/pg18/data status" >/dev/null 2>&1; then
  su postgres -c "taskset -c ${PG_CPUS:-0-1} /opt/pg18/bin/pg_ctl -D /var/lib/pg18/data -l /var/lib/pg18/log.txt start -w" >/dev/null
fi
psql -h 127.0.0.1 -U postgres -Atc "select datname from pg_database where datname like 'conduit%' order by 1" | tr '\n' ' '; echo
taskset -pc $(head -1 /var/lib/pg18/data/postmaster.pid)
