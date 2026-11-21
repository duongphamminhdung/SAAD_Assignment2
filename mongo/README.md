# MongoDB — replica set

Status: scripts in the repo and synchronized with the Redis / Cassandra setup (2026-11-21):
`run_mongo.sh`, `docker-compose-mongo-3.yml`, `docker-compose-mongo-5.yml`. Smoke-tested on a
Linux dev box: 3 and 5 nodes × workloads A, E and `custom_iot` × 2 reps at 1,000 records —
all ops `Return=OK`, 1 PRIMARY + N−1 SECONDARY, limits applied, no leftover volumes.

⚠️ **The earlier A–E results (teammate's machine) were recorded without CPU/RAM limits and with
the previous compose files → they must be re-run with these files** (the protocol requires
identical limits across all 3 databases). `run_mongo.sh` here replaces the teammate's local
version — if that version did something different, compare before re-running.

```bash
./run_mongo.sh                    # full: 2 configs x A–E x 10 reps
# smoke: RECORDCOUNT=1000 OPERATIONCOUNT=1000 REPS=1 WORKLOADS="workloada" NODE_CONFIGS="3" ./run_mongo.sh
```

## What is now the same for all three databases

| | Redis | Cassandra | MongoDB |
|---|---|---|---|
| Per-node limits | `deploy.resources.limits` 2 CPUs / 2 GB | same | same |
| Network | external `tp2-net` | same | same (was compose-owned → clashed with the other scripts) |
| Image | `redis:7.4` | `cassandra:5.0.9` | `mongo:7.0.48` (was floating `mongo:7.0`) |
| Run script features | wipe → load → run, resumable | + refuses if another DB runs, aborts on failed ops, per-node `docker stats`, custom workloads from `../workloads/`, `down -v` | same as Cassandra |
| CSV / logs | `results/<db>_results.csv`, `raw/`, `commands.txt` | same | same (`mongo_results.csv`) |

## Setup

- Topology: replica set `rs0` — 1 primary + 2 secondaries (3-node) or 1 primary + 4 secondaries
  (5-node), initiated by `run_mongo.sh` (`rs.initiate` with mongo1..N).
- Each node: `mongod --replSet rs0 --bind_ip_all --oplogSize 1024`
  (oplog capped at 1 GB/node; uncapped it grows to ~50 GB/node and fills the disk).
- With the 2 GB limit, WiredTiger sizes its cache to ~0.5 GB (50% of RAM − 1 GB); the YCSB
  dataset is ~110 MB, so it fits in cache.
- Write concern `w=majority` (in the connection URL): 2/3 or 3/5 nodes acknowledge each write.
- Read preference: `primary` (YCSB driver default) — secondaries hold copies but serve no reads.

## Script steps (manual equivalent)

```bash
docker network create tp2-net                                   # once
docker compose -f docker-compose-mongo-3.yml up -d
docker exec mongo1 mongosh --quiet --eval 'rs.initiate({_id:"rs0",members:[{_id:0,host:"mongo1:27017"},{_id:1,host:"mongo2:27017"},{_id:2,host:"mongo3:27017"}]})'
# gate: rs.status() shows 1 PRIMARY + 2 SECONDARY
# wipe per rep (on the primary, via the replica-set URI):
docker exec mongo1 mongosh --quiet "mongodb://mongo1:27017,mongo2:27017,mongo3:27017/?replicaSet=rs0" \
  --eval "db.getSiblingDB('ycsb').dropDatabase({w:'majority'})"
docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -w /ycsb eclipse-temurin:11-jre \
  bin/ycsb.sh run mongodb -P workloads/workloada \
  -p "mongodb.url=mongodb://mongo1:27017,mongo2:27017,mongo3:27017/ycsb?replicaSet=rs0&w=majority" \
  -p recordcount=100000 -p operationcount=100000 -threads 16
docker compose -f docker-compose-mongo-3.yml down -v              # -v: remove the data volumes
```

## Outputs

- `../results/raw/` — raw load/run logs + `mongo_<N>n_rs_status.txt` (appendix evidence)
- `../results/mongo_results.csv` — db,nodes,workload,rep,section,metric,value (db=`mongo`)
- `../results/commands.txt` — exact commands executed (appendix)
