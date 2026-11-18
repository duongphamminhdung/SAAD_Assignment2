#!/usr/bin/env bash
# TP2 — Cassandra benchmark driver (same protocol as run_mongo.sh / run_redis.sh)
#
# For each node config (3, 5) x workload x rep: TRUNCATE -> load -> run.
# Keyspace ycsb is created by this script with RF = node count; YCSB uses QUORUM
# for reads and writes (closest analogue of Mongo w=majority: 2/3, 3/5).
# Results: ../results/cassandra_results.csv, raw logs in ../results/raw/, exact
# commands in ../results/commands.txt.
#
# Full run (defaults, matching the other DBs):
#   ./run_cassandra.sh
# Quick smoke test:
#   RECORDCOUNT=1000 OPERATIONCOUNT=1000 REPS=1 WORKLOADS="workloada" NODE_CONFIGS="3" ./run_cassandra.sh
#
# WORKLOADS entries are YCSB core workloads (workloada..workloade) or a file name in
# ../workloads/ (e.g. the custom workload), which is mounted into the YCSB container.
#
# Resumable: a (nodes, workload, rep) whose run log exists is skipped. The run log is
# only moved into place after it was validated and appended to the CSV.
set -euo pipefail

DB=cassandra
RECORDCOUNT="${RECORDCOUNT:-100000}"
OPERATIONCOUNT="${OPERATIONCOUNT:-100000}"
THREADS="${THREADS:-16}"
REPS="${REPS:-10}"
WORKLOADS="${WORKLOADS:-workloada workloadb workloadc workloadd workloade}"
NODE_CONFIGS="${NODE_CONFIGS:-3 5}"
CONSISTENCY="${CONSISTENCY:-QUORUM}"
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

trap 'echo "run_cassandra.sh FAILED (nodes=${NODES:-?} workload=${WL:-?} rep=${REP:-?}); see results/raw/" >&2' ERR

[ -d "$YCSB_HOME" ] || { echo "YCSB not found at $YCSB_HOME (set YCSB_HOME)" >&2; exit 1; }
[ -x "$YCSB_HOME/bin/ycsb.sh" ] || { echo "$YCSB_HOME/bin/ycsb.sh missing" >&2; exit 1; }

# One cluster at a time: refuse to benchmark while another DB's containers run.
others="$(docker ps --format '{{.Names}}' | grep -E '^(mongo|redis)[0-9]+$' || true)"
if [ -n "$others" ]; then
  echo "other DB containers are running, stop them first: $others" >&2; exit 1
fi
docker network create tp2-net 2>/dev/null || true

cql() { docker exec cass1 cqlsh --request-timeout=120 -e "$1"; }

# Parse a YCSB log: "[READ], AverageLatency(us), 214.5" -> CSV rows prefixed with
# db,nodes,workload,rep. Run-phase logs only (load logs are kept in raw/).
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
  COMPOSE="$SCRIPT_DIR/docker-compose-cassandra-${NODES}.yml"
  HOSTS="$(seq -s, -f 'cass%g' 1 "$NODES")"

  echo "== ${NODES}-node ring: bring up (nodes join one at a time, can take several minutes)"
  docker compose -f "$COMPOSE" down -v --remove-orphans > /dev/null 2>&1 || true
  docker compose -f "$COMPOSE" up -d --wait --wait-timeout 1200

  # Health gate: every node Up/Normal in nodetool status (replaces Mongo PRIMARY/SECONDARY wait).
  echo -n "== waiting for ${NODES} x UN "
  ok=0
  for _ in $(seq 1 120); do
    un="$(docker exec cass1 nodetool status 2>/dev/null | grep -c '^UN' || true)"
    if [ "$un" = "$NODES" ]; then ok=1; break; fi
    echo -n "."; sleep 5
  done
  echo
  if [ "$ok" != 1 ]; then docker exec cass1 nodetool status >&2 || true; echo "ring never became healthy" >&2; exit 1; fi
  docker exec cass1 nodetool status | tee "$RAW/${DB}_${NODES}n_nodetool_status.txt"

  # Schema: YCSB's cassandra-cql binding does not create it. RF = node count.
  cql "CREATE KEYSPACE IF NOT EXISTS ycsb WITH replication = {'class':'SimpleStrategy','replication_factor':${NODES}};"
  cql "CREATE TABLE IF NOT EXISTS ycsb.usertable (y_id varchar PRIMARY KEY,
       field0 varchar, field1 varchar, field2 varchar, field3 varchar, field4 varchar,
       field5 varchar, field6 varchar, field7 varchar, field8 varchar, field9 varchar);"
  rf="$(cql "SELECT replication FROM system_schema.keyspaces WHERE keyspace_name='ycsb';" \
        | grep -o "'replication_factor': '[0-9]*'" | grep -o '[0-9]*' || true)"
  if [ "$rf" != "$NODES" ]; then echo "keyspace ycsb has RF='$rf', expected $NODES" >&2; exit 1; fi
  echo "== keyspace ycsb RF=$rf, consistency $CONSISTENCY"

  for WL in $WORKLOADS; do
    # Core workloads leave this empty; the ${arr[@]+...} guard keeps the empty
    # expansion safe under `set -u` on bash 3.2 (macOS) as well as on Linux.
    MOUNT_CUSTOM=()
    if [ -f "$CUSTOM_WL_DIR/$WL" ]; then
      MOUNT_CUSTOM=(-v "$CUSTOM_WL_DIR":/tp2-workloads:ro); WLFILE="/tp2-workloads/$WL"
    else
      WLFILE="workloads/$WL"
    fi

    for REP in $(seq 1 "$REPS"); do
      LOADLOG="$RAW/${DB}_${NODES}n_${WL}_rep${REP}_load.log"
      RUNLOG="$RAW/${DB}_${NODES}n_${WL}_rep${REP}_run.log"
      if [ -s "$RUNLOG" ]; then echo "-- skip ${NODES}n ${WL} rep${REP} (already done)"; continue; fi

      # Wipe (replaces Mongo dropDatabase). TRUNCATE needs every node up; with
      # auto_snapshot=false (compose file) it leaves no snapshot behind.
      cql "TRUNCATE ycsb.usertable;"
      left="$(cql "SELECT count(*) FROM ycsb.usertable;" | awk '/^-+$/ {getline; print $1; exit}')"
      if [ "$left" != "0" ]; then echo "TRUNCATE left $left rows" >&2; exit 1; fi

      for PHASE in load run; do
        CMD=(docker run --rm --network tp2-net -v "$YCSB_HOME":/ycsb ${MOUNT_CUSTOM[@]+"${MOUNT_CUSTOM[@]}"} -w /ycsb "$YCSB_IMAGE"
             bin/ycsb.sh "$PHASE" cassandra-cql -P "$WLFILE"
             -p "hosts=$HOSTS"
             -p "cassandra.readconsistencylevel=$CONSISTENCY"
             -p "cassandra.writeconsistencylevel=$CONSISTENCY"
             -p "recordcount=$RECORDCOUNT" -p "operationcount=$OPERATIONCOUNT" -threads "$THREADS")
        if [ "$PHASE" = load ]; then OUT="$LOADLOG"; else OUT="$RUNLOG.tmp"; fi
        echo "-- ${NODES}n ${WL} rep${REP}: $PHASE"
        "${CMD[@]}" > "$OUT" 2>&1
        check_log "$OUT"
        # Appendix copy: readable (no shell escaping) and with the portable ~/ycsb-0.17.0 path.
        { echo "# cassandra ${NODES} nodes ${WL} rep${REP} ${PHASE}"; echo "${CMD[*]}" | sed -e "s#$YCSB_HOME:#~/ycsb-0.17.0:#" -e "s#$CUSTOM_WL_DIR:#./workloads:#"; } >> "$CMDS"
      done

      # Per-container CPU/RAM right after the run: evidence the limits held (no OOM).
      docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' \
        $(seq -f 'cass%g' 1 "$NODES") >> "$RUNLOG.tmp" 2>&1 || true

      append_csv "$DB" "$NODES" "$WL" "$REP" "$RUNLOG.tmp"
      mv "$RUNLOG.tmp" "$RUNLOG"
    done
  done

  # -v: drop the anonymous /var/lib/cassandra volumes so they do not pile up on disk.
  docker compose -f "$COMPOSE" down -v
done

echo "== done; CSV: $CSV"
