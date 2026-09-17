#!/usr/bin/env bash
# Start a Redis Cluster on 127.0.0.1:6380-6385 (3 masters, 1 replica each).
# Needs redis-server and redis-cli. Does not start standalone 6379.
#
# Usage:
#   bash script/dev_cluster.sh
#   REDIS_CLUSTER_URL=redis://127.0.0.1:6380 crystal spec
set -euo pipefail

HOST=127.0.0.1
PORTS=(6380 6381 6382 6383 6384 6385)
BASE="${ALUMNA_REDIS_CLUSTER_DIR:-/tmp/alumna-redis-cluster}"

for cmd in redis-server redis-cli; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing $cmd" >&2
    exit 1
  fi
done

for port in "${PORTS[@]}"; do
  if redis-cli -h "$HOST" -p "$port" ping >/dev/null 2>&1; then
    echo "port $port is already in use" >&2
    exit 1
  fi
done

rm -rf "$BASE"
mkdir -p "$BASE"

for port in "${PORTS[@]}"; do
  dir="$BASE/$port"
  mkdir -p "$dir"
  redis-server \
    --port "$port" \
    --bind "$HOST" \
    --cluster-enabled yes \
    --cluster-config-file nodes.conf \
    --cluster-node-timeout 2000 \
    --appendonly no \
    --save "" \
    --dir "$dir" \
    --logfile "$dir/redis.log" \
    --daemonize yes
done

for port in "${PORTS[@]}"; do
  ok=0
  for _ in $(seq 1 50); do
    if redis-cli -h "$HOST" -p "$port" ping >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 0.1
  done
  if [ "$ok" != 1 ]; then
    echo "port $port did not come up" >&2
    cat "$BASE/$port/redis.log" >&2 || true
    exit 1
  fi
done

nodes=()
for port in "${PORTS[@]}"; do
  nodes+=("$HOST:$port")
done

redis-cli --cluster create "${nodes[@]}" --cluster-replicas 1 --cluster-yes

ok=0
for _ in $(seq 1 50); do
  if redis-cli -h "$HOST" -p "${PORTS[0]}" cluster info 2>/dev/null | grep -q 'cluster_state:ok'; then
    ok=1
    break
  fi
  sleep 0.2
done
if [ "$ok" != 1 ]; then
  echo "cluster_state is not ok" >&2
  redis-cli -h "$HOST" -p "${PORTS[0]}" cluster info >&2 || true
  exit 1
fi

echo "REDIS_CLUSTER_URL=redis://$HOST:${PORTS[0]}"
