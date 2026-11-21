#!/usr/bin/env bash
# TP2 — MongoDB benchmark driver
#
# For each node config (3, 5) x workload x rep: dropDatabase -> load -> run.
# Results: ../results/mongo_results.csv, raw logs in ../results/raw/, exact
# commands in ../results/commands.txt.
#
# Full run (defaults):
#   ./run_mongo.sh
# Quick smoke test (small params, one workload, one rep, 3 nodes only):
#   RECORDCOUNT=1000 OPERATIONCOUNT=1000 REPS=1 WORKLOADS="workloada" NODE_CONFIGS="3" ./run_mongo.sh
#
# Resumable: a (workload, rep) whose run log already exists and completed is
# skipped, so an interrupted full run can simply be restarted.
set -euo pipefail

DB=mongo
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
CUSTOM_WL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/workloads"
RAW="$RESULTS_DIR/raw"
mkdir -p "$RAW"
CSV="$RESULTS_DIR/${DB}_results.csv"
CMDS="$RESULTS_DIR/commands.txt"
[ -f "$CSV" ] || echo "db,nodes,workload,rep,section,metric,value" > "$CSV"
touch "$CMDS"

trap 'echo "run_mongo.sh FAILED (nodes=${NODES:-?} workload=${WL:-?} rep=${REP:-?}); last log: results/raw/" >&2' ERR

[ -d "$YCSB_HOME" ] || { echo "YCSB not found at $YCSB_HOME (set YCSB_HOME)" >&2; exit 1; }

# One cluster at a time: refuse to benchmark while another DB's containers run.
others="$(docker ps --format '{{.Names}}' | grep -E '^(redis|cass)[0-9]+$' || true)"
if [ -n "$others" ]; then
  echo "other DB containers are running, stop them first: $others" >&2; exit 1
fi
docker network create tp2-net 2>/dev/null || true

# Parse a YCSB log: lines like "[READ], AverageLatency(us), 214.5" -> CSV rows
# prefixed with db,nodes,workload,rep. Run-phase logs only (that is what the
# analysis uses; load logs are kept in raw/ for the appendix).
append_csv() {
  awk -F', ' -v p="$1,$2,$3,$4," \
    'NF==3 && $1 ~ /^\[/ && $3 ~ /^-?[0-9.]+([eE][-+]?[0-9]+)?$/ { gsub(/[\[\]]/, "", $1); print p $1 "," $2 "," $3 }' \
    "$5" >> "$CSV"
}

# A YCSB log is valid when it finished ([OVERALL] present) and no operation failed.
check_log() {
  if ! grep -q '^\[OVERALL\], Throughput' "$1"; then
    echo "YCSB did not finish: $1" >&2; tail -20 "$1" >&2; return 1
  fi
  if grep -qE 'Return=(ERROR|UNEXPECTED_STATE|NOT_FOUND)' "$1"; then
    echo "YCSB reported failed operations: $1" >&2; grep -E 'Return=' "$1" >&2; return 1
  fi
}

for NODES in $NODE_CONFIGS; do
  COMPOSE="$SCRIPT_DIR/docker-compose-mongo-${NODES}.yml"
  echo "== ${NODES}-node cluster: bring up"
  docker compose -f "$COMPOSE" up -d

  # Connection URL: all node addresses + replicaSet + write concern majority
  # (w=majority = the write is acknowledged by a majority of the set).
  HOSTS=""
  for i in $(seq 1 "$NODES"); do HOSTS+="mongo${i}:27017,"; done
  HOSTS="${HOSTS%,}"
  URL="mongodb://${HOSTS}/ycsb?replicaSet=rs0&w=majority"

  # Wait until mongod on mongo1 answers ping.
  echo -n "== waiting for mongod "
  for _ in $(seq 1 120); do
    out="$(docker exec mongo1 mongosh --quiet --eval 'db.adminCommand("ping").ok' 2>/dev/null || true)"
    [ "$out" = "1" ] && break
    echo -n "."; sleep 1
  done
  echo

  # One-time replica-set init (containers are recreated on every compose up,
  # so the set is fresh each run; the try/catch makes it idempotent anyway).
  MEMBERS=""
  for i in $(seq 1 "$NODES"); do MEMBERS+="{_id:$((i-1)),host:'mongo${i}:27017'},"; done
  MEMBERS="${MEMBERS%,}"
  echo "== rs.initiate (rs0, ${NODES} members)"
  docker exec mongo1 mongosh --quiet --eval "try { rs.status() } catch (e) { rs.initiate({_id:'rs0', members:[${MEMBERS}]}) }" > /dev/null

  # Health gate: wait until 1 PRIMARY + (N-1) SECONDARY (election + initial sync).
  echo -n "== waiting for 1 PRIMARY + $((NODES-1)) SECONDARY "
  ok=0
  EXPECTED="1/$((NODES-1))"
  for _ in $(seq 1 180); do
    out="$(docker exec mongo1 mongosh --quiet --eval "try { const s = rs.status(); print(s.members.filter(m=>m.stateStr==='PRIMARY').length + '/' + s.members.filter(m=>m.stateStr==='SECONDARY').length) } catch (e) { print('pending') }" 2>/dev/null || echo pending)"
    [ "$out" = "$EXPECTED" ] && { ok=1; break; }
    echo -n "."; sleep 1
  done
  echo
  if [ "$ok" != 1 ]; then echo "replica set never became healthy" >&2; exit 1; fi

  for WL in $WORKLOADS; do
    # Core workloads leave MOUNT_CUSTOM empty; ${arr[@]+...} is safe under
    # `set -u` on bash 3.2 (macOS) as well as on Linux.
    MOUNT_CUSTOM=()
    if [ -f "$CUSTOM_WL_DIR/$WL" ]; then
      MOUNT_CUSTOM=(-v "$CUSTOM_WL_DIR":/tp2-workloads:ro); WLFILE="/tp2-workloads/$WL"
    else
      WLFILE="workloads/$WL"
    fi
    for REP in $(seq 1 "$REPS"); do
      LOADLOG="$RAW/${DB}_${NODES}n_${WL}_rep${REP}_load.log"
      RUNLOG="$RAW/${DB}_${NODES}n_${WL}_rep${REP}_run.log"
      if [ -s "$RUNLOG" ] && grep -q 'OVERALL' "$RUNLOG"; then
        echo "-- skip ${WL} rep${REP} (already done)"
        continue
      fi

      # Wipe: drop the YCSB database, then wait until it is gone from
      # listDatabases (secondaries follow via replication). Connect via the
      # replica-set URL so mongosh routes to the CURRENT primary — with 5
      # equal-priority members the primary is not always mongo1.
      docker exec mongo1 mongosh --quiet "$URL" --eval 'db.dropDatabase()' > /dev/null
      for _ in $(seq 1 30); do
        s="$(docker exec mongo1 mongosh --quiet "$URL" --eval 'db.adminCommand({listDatabases:1}).databases.some(d=>d.name==="ycsb") ? "present" : "gone"' 2>/dev/null || echo present)"
        [ "$s" = "gone" ] && break
        sleep 0.5
      done

      echo "-- ${WL} rep${REP}: load"
      docker run --rm --network tp2-net -v "$YCSB_HOME":/ycsb ${MOUNT_CUSTOM[@]+"${MOUNT_CUSTOM[@]}"} -w /ycsb "$YCSB_IMAGE" \
        bin/ycsb.sh load mongodb -P "$WLFILE" \
        -p "mongodb.url=$URL" \
        -p "recordcount=$RECORDCOUNT" -p "operationcount=$OPERATIONCOUNT" -threads "$THREADS" \
        > "$LOADLOG" 2>&1
      check_log "$LOADLOG"

      echo "-- ${WL} rep${REP}: run"
      docker run --rm --network tp2-net -v "$YCSB_HOME":/ycsb ${MOUNT_CUSTOM[@]+"${MOUNT_CUSTOM[@]}"} -w /ycsb "$YCSB_IMAGE" \
        bin/ycsb.sh run mongodb -P "$WLFILE" \
        -p "mongodb.url=$URL" \
        -p "recordcount=$RECORDCOUNT" -p "operationcount=$OPERATIONCOUNT" -threads "$THREADS" \
        > "$RUNLOG" 2>&1
      check_log "$RUNLOG"

      append_csv "$DB" "$NODES" "$WL" "$REP" "$RUNLOG"

      {
        echo "# mongo ${NODES} nodes ${WL} rep${REP}"
        echo "docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -w /ycsb eclipse-temurin:11-jre bin/ycsb.sh load mongodb -P ${WLFILE} -p \"mongodb.url=${URL}\" -p recordcount=$RECORDCOUNT -p operationcount=$OPERATIONCOUNT -threads $THREADS"
        echo "docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -w /ycsb eclipse-temurin:11-jre bin/ycsb.sh run mongodb -P ${WLFILE} -p \"mongodb.url=${URL}\" -p recordcount=$RECORDCOUNT -p operationcount=$OPERATIONCOUNT -threads $THREADS"
      } >> "$CMDS"
    done
  done

  # -v: also drop the anonymous /data/db volumes (the mongo image declares them)
  # so they do not pile up on disk between cluster generations.
  docker compose -f "$COMPOSE" down -v
done

echo "== done; CSV: $CSV"
