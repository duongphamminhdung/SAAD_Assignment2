#!/usr/bin/env bash
# TP2 — MongoDB benchmark driver (same protocol as run_redis.sh / run_cassandra.sh)
#
# For each node config (3, 5) x workload x rep: dropDatabase -> load -> run.
# Replica set rs0 (1 primary + N-1 secondaries), writes w=majority, reads from the
# primary (YCSB driver default).
# Results: ../results/mongo_results.csv, raw logs in ../results/raw/, exact
# commands in ../results/commands.txt.
#
# Full run (defaults, matching the other DBs):
#   ./run_mongo.sh
# Quick smoke test:
#   RECORDCOUNT=1000 OPERATIONCOUNT=1000 REPS=1 WORKLOADS="workloada" NODE_CONFIGS="3" ./run_mongo.sh
#
# WORKLOADS entries are YCSB core workloads (workloada..workloade) or a file name in
# ../workloads/ (e.g. the custom workload), which is mounted into the YCSB container.
#
# Resumable: a (nodes, workload, rep) whose run log exists is skipped. The run log is
# only moved into place after it was validated and appended to the CSV.
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

trap 'echo "run_mongo.sh FAILED (nodes=${NODES:-?} workload=${WL:-?} rep=${REP:-?}); see results/raw/" >&2' ERR

[ -d "$YCSB_HOME" ] || { echo "YCSB not found at $YCSB_HOME (set YCSB_HOME)" >&2; exit 1; }
[ -x "$YCSB_HOME/bin/ycsb.sh" ] || { echo "$YCSB_HOME/bin/ycsb.sh missing" >&2; exit 1; }

# One cluster at a time: refuse to benchmark while another DB's containers run.
others="$(docker ps --format '{{.Names}}' | grep -E '^(redis|cass)[0-9]+$' || true)"
if [ -n "$others" ]; then
  echo "other DB containers are running, stop them first: $others" >&2; exit 1
fi
docker network create tp2-net 2>/dev/null || true

# Run a mongosh expression against the replica set (routes to the current primary,
# whichever node that is).
msh() { docker exec mongo1 mongosh --quiet "mongodb://${HOSTPORTS}/?replicaSet=rs0" --eval "$1"; }

# Parse a YCSB log: "[READ], AverageLatency(us), 214.5" -> CSV rows prefixed with
# db,nodes,workload,rep. Run-phase logs only (load logs are kept in raw/).
append_csv() {
  awk -F', ' -v p="$1,$2,$3,$4," \
    'NF==3 && $1 ~ /^\[/ && $3 ~ /^-?[0-9.]+([eE][-+]?[0-9]+)?$/ { gsub(/[\[\]]/, "", $1); print p $1 "," $2 "," $3 }' \
    "$5" >> "$CSV"
}

# Appendix copy of a command: portable paths (~/ycsb-0.17.0, ./workloads), and any
# argument with shell-special characters (the URL has '?' and '&') in double quotes.
fmt_cmd() {
  local out="" a ycsb_rep='~/ycsb-0.17.0:' wl_rep='./workloads:'
  for a in "$@"; do
    a="${a/#"$YCSB_HOME:"/$ycsb_rep}"
    a="${a/#"$CUSTOM_WL_DIR:"/$wl_rep}"
    case "$a" in *[\&\?\ ]*) a="\"$a\"" ;; esac
    out="$out $a"
  done
  echo "${out# }"
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
  HOSTPORTS="$(seq -s, -f 'mongo%g:27017' 1 "$NODES")"
  URL="mongodb://${HOSTPORTS}/ycsb?replicaSet=rs0&w=majority"

  echo "== ${NODES}-node replica set: bring up"
  docker compose -f "$COMPOSE" down -v --remove-orphans > /dev/null 2>&1 || true
  docker compose -f "$COMPOSE" up -d

  # Wait until mongod accepts connections, then initiate the replica set.
  for _ in $(seq 1 60); do
    docker exec mongo1 mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' > /dev/null 2>&1 && break
    sleep 1
  done
  MEMBERS="$(for i in $(seq 1 "$NODES"); do printf '{_id:%d,host:"mongo%d:27017"},' $((i - 1)) "$i"; done)"
  docker exec mongo1 mongosh --quiet --eval "rs.initiate({_id:'rs0',members:[${MEMBERS%,}]}).ok"

  # Health gate: exactly 1 PRIMARY and NODES-1 SECONDARY.
  echo -n "== waiting for 1 PRIMARY + $((NODES - 1)) SECONDARY "
  ok=0
  for _ in $(seq 1 120); do
    states="$(docker exec mongo1 mongosh --quiet --eval \
      'rs.status().members.map(m => m.stateStr).join(" ")' 2>/dev/null || true)"
    p="$(printf '%s\n' $states | grep -c '^PRIMARY$' || true)"
    s="$(printf '%s\n' $states | grep -c '^SECONDARY$' || true)"
    if [ "$p" = 1 ] && [ "$s" = $((NODES - 1)) ]; then ok=1; break; fi
    echo -n "."; sleep 2
  done
  echo
  if [ "$ok" != 1 ]; then echo "replica set never became healthy: $states" >&2; exit 1; fi
  msh 'rs.status().members.map(m => m.name + " " + m.stateStr).join("\n")' \
    | tee "$RAW/${DB}_${NODES}n_rs_status.txt"

  for WL in $WORKLOADS; do
    MOUNT_CUSTOM=()
    if [ -f "$CUSTOM_WL_DIR/$WL" ] && [ -f "$YCSB_HOME/workloads/$WL" ]; then
      # Never let a repo file silently replace a standard YCSB workload (e.g. workloada).
      echo "workloads/$WL exists in the repo AND in YCSB core workloads; rename the repo file" >&2; exit 1
    elif [ -f "$CUSTOM_WL_DIR/$WL" ]; then
      MOUNT_CUSTOM=(-v "$CUSTOM_WL_DIR":/tp2-workloads:ro); WLFILE="/tp2-workloads/$WL"
    else
      WLFILE="workloads/$WL"
    fi

    for REP in $(seq 1 "$REPS"); do
      LOADLOG="$RAW/${DB}_${NODES}n_${WL}_rep${REP}_load.log"
      RUNLOG="$RAW/${DB}_${NODES}n_${WL}_rep${REP}_run.log"
      if [ -s "$RUNLOG" ]; then echo "-- skip ${NODES}n ${WL} rep${REP} (already done)"; continue; fi

      # Wipe: drop the ycsb database on the primary (majority-acknowledged), then
      # verify it is gone before loading.
      msh "db.getSiblingDB('ycsb').dropDatabase({w:'majority'}).ok" > /dev/null
      left="$(msh "db.getSiblingDB('ycsb').usertable.countDocuments()")"
      if [ "$left" != "0" ]; then echo "dropDatabase left $left documents" >&2; exit 1; fi

      for PHASE in load run; do
        CMD=(docker run --rm --network tp2-net -v "$YCSB_HOME":/ycsb ${MOUNT_CUSTOM[@]+"${MOUNT_CUSTOM[@]}"} -w /ycsb "$YCSB_IMAGE"
             bin/ycsb.sh "$PHASE" mongodb -P "$WLFILE"
             -p "mongodb.url=$URL"
             -p "recordcount=$RECORDCOUNT" -p "operationcount=$OPERATIONCOUNT" -threads "$THREADS")
        if [ "$PHASE" = load ]; then OUT="$LOADLOG"; else OUT="$RUNLOG.tmp"; fi
        echo "-- ${NODES}n ${WL} rep${REP}: $PHASE"
        "${CMD[@]}" > "$OUT" 2>&1
        check_log "$OUT"
        # Appendix copy: readable, portable paths, URL quoted (it contains '&').
        { echo "# mongo ${NODES} nodes ${WL} rep${REP} ${PHASE}"; fmt_cmd "${CMD[@]}"; } >> "$CMDS"
      done

      # Per-container CPU/RAM right after the run: evidence the limits held (no OOM).
      docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' \
        $(seq -f 'mongo%g' 1 "$NODES") >> "$RUNLOG.tmp" 2>&1 || true

      append_csv "$DB" "$NODES" "$WL" "$REP" "$RUNLOG.tmp"
      mv "$RUNLOG.tmp" "$RUNLOG"
    done
  done

  # -v: drop the anonymous /data/db and /data/configdb volumes so they do not pile up on disk.
  docker compose -f "$COMPOSE" down -v
done

echo "== done; CSV: $CSV"
