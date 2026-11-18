#!/usr/bin/env bash
# TP2 — Redis benchmark driver (same protocol as run_mongo.sh)
#
# For each node config (3, 5) x workload x rep: FLUSHALL -> load -> run.
# Results: ../results/redis_results.csv, raw logs in ../results/raw/, exact
# commands in ../results/commands.txt.
#
# Full run (defaults, matching the Mongo experiments):
#   ./run_redis.sh
# Quick smoke test (small params, one workload, one rep, 3 nodes only):
#   RECORDCOUNT=1000 OPERATIONCOUNT=1000 REPS=1 WORKLOADS="workloada" NODE_CONFIGS="3" ./run_redis.sh
#
# Resumable: a (workload, rep) whose run log already exists and completed is
# skipped, so an interrupted full run can simply be restarted.
set -euo pipefail

DB=redis
RECORDCOUNT="${RECORDCOUNT:-100000}"
OPERATIONCOUNT="${OPERATIONCOUNT:-100000}"
THREADS="${THREADS:-16}"
REPS="${REPS:-10}"
WORKLOADS="${WORKLOADS:-workloada workloadb workloadc workloadd workloade}"
NODE_CONFIGS="${NODE_CONFIGS:-3 5}"
YCSB_HOME="${YCSB_HOME:-$HOME/ycsb-0.17.0}"
YCSB_IMAGE="eclipse-temurin:11-jre"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
RAW="$RESULTS_DIR/raw"
mkdir -p "$RAW"
CSV="$RESULTS_DIR/${DB}_results.csv"
CMDS="$RESULTS_DIR/commands.txt"
[ -f "$CSV" ] || echo "db,nodes,workload,rep,section,metric,value" > "$CSV"
touch "$CMDS"

trap 'echo "run_redis.sh FAILED (nodes=${NODES:-?} workload=${WL:-?} rep=${REP:-?}); last log: results/raw/" >&2' ERR

[ -d "$YCSB_HOME" ] || { echo "YCSB not found at $YCSB_HOME (set YCSB_HOME)" >&2; exit 1; }
docker network create tp2-net 2>/dev/null || true

# Parse a YCSB log: lines like "[READ], AverageLatency(us), 214.5" -> CSV rows
# prefixed with db,nodes,workload,rep. Run-phase logs only (that is what the
# analysis uses; load logs are kept in raw/ for the appendix).
append_csv() {
  awk -F', ' -v p="$1,$2,$3,$4," \
    'NF==3 && $1 ~ /^\[/ && $3 ~ /^[0-9.]+$/ { gsub(/[\[\]]/, "", $1); print p $1 "," $2 "," $3 }' \
    "$5" >> "$CSV"
}

for NODES in $NODE_CONFIGS; do
  SLAVES=$((NODES - 1))
  COMPOSE="$SCRIPT_DIR/docker-compose-redis-${NODES}.yml"
  echo "== ${NODES}-node cluster: bring up"
  docker compose -f "$COMPOSE" up -d

  # Health gate: wait until redis1 is master with all replicas connected.
  # (Replaces Mongo's wait for PRIMARY/SECONDARY states.)
  echo -n "== waiting for role:master + connected_slaves:${SLAVES} "
  ok=0
  for _ in $(seq 1 120); do
    out="$(docker exec redis1 redis-cli INFO replication 2>/dev/null || true)"
    if printf '%s' "$out" | grep -q 'role:master'; then
      if printf '%s' "$out" | grep -q "connected_slaves:${SLAVES}"; then
        ok=1; break
      fi
    fi
    echo -n "."; sleep 1
  done
  echo
  if [ "$ok" != 1 ]; then echo "cluster never became healthy" >&2; exit 1; fi

  for WL in $WORKLOADS; do
    for REP in $(seq 1 "$REPS"); do
      LOADLOG="$RAW/${DB}_${NODES}n_${WL}_rep${REP}_load.log"
      RUNLOG="$RAW/${DB}_${NODES}n_${WL}_rep${REP}_run.log"
      if [ -s "$RUNLOG" ] && grep -q 'OVERALL' "$RUNLOG"; then
        echo "-- skip ${WL} rep${REP} (already done)"
        continue
      fi

      # Wipe (replaces Mongo dropDatabase). FLUSHALL on the master propagates
      # to replicas; wait until a replica reports DBSIZE 0.
      docker exec redis1 redis-cli FLUSHALL > /dev/null
      for _ in $(seq 1 30); do
        s="$(docker exec redis2 redis-cli DBSIZE 2>/dev/null || echo 1)"
        if [ "$s" = "0" ]; then break; fi
        sleep 0.5
      done

      echo "-- ${WL} rep${REP}: load"
      docker run --rm --network tp2-net -v "$YCSB_HOME":/ycsb -w /ycsb "$YCSB_IMAGE" \
        bin/ycsb.sh load redis -P "workloads/${WL}" \
        -p "redis.host=redis1" -p "redis.port=6379" \
        -p "recordcount=$RECORDCOUNT" -p "operationcount=$OPERATIONCOUNT" -threads "$THREADS" \
        > "$LOADLOG" 2>&1

      echo "-- ${WL} rep${REP}: run"
      docker run --rm --network tp2-net -v "$YCSB_HOME":/ycsb -w /ycsb "$YCSB_IMAGE" \
        bin/ycsb.sh run redis -P "workloads/${WL}" \
        -p "redis.host=redis1" -p "redis.port=6379" \
        -p "recordcount=$RECORDCOUNT" -p "operationcount=$OPERATIONCOUNT" -threads "$THREADS" \
        > "$RUNLOG" 2>&1

      append_csv "$DB" "$NODES" "$WL" "$REP" "$RUNLOG"

      {
        echo "# redis ${NODES} nodes ${WL} rep${REP}"
        echo "docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -w /ycsb eclipse-temurin:11-jre bin/ycsb.sh load redis -P workloads/${WL} -p \"redis.host=redis1\" -p \"redis.port=6379\" -p recordcount=$RECORDCOUNT -p operationcount=$OPERATIONCOUNT -threads $THREADS"
        echo "docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -w /ycsb eclipse-temurin:11-jre bin/ycsb.sh run redis -P workloads/${WL} -p \"redis.host=redis1\" -p \"redis.port=6379\" -p recordcount=$RECORDCOUNT -p operationcount=$OPERATIONCOUNT -threads $THREADS"
      } >> "$CMDS"
    done
  done

  docker compose -f "$COMPOSE" down
done

echo "== done; CSV: $CSV"
