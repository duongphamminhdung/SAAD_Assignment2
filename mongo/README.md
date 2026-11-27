# MongoDB — replica set (A–E)

Status: 3-node complete (A–E × 10 reps). 5-node at 38/50 — workloadd 8/10, workloade 0/10 —
interrupted when the test Mac ran out of disk (host-level, not a DB failure; all recorded reps
passed the failed-operation check). To resume on any machine: re-run `./run_mongo.sh` with
`NODE_CONFIGS=5` — completed reps are skipped automatically via their run logs in
`../results/raw/`. Custom-workload pass still pending (run it once the team defines the scenario).

Files: `run_mongo.sh`, `docker-compose-mongo-3.yml`, `docker-compose-mongo-5.yml` — written to
match the documented protocol above (same loop structure as `redis/run_redis.sh`, same CSV schema)
plus the 2 CPU / 2 GB container limits. Teammate: verify against your originals (or replace them
here) so the repo holds the exact files used for the recorded runs.

## Setup

- Image: `mongo:7.0`, one container per node on network `tp2-net`.
- **Resource limits (team decision 2026-11-18): every container capped at 2 CPUs / 2 GB RAM**
  (`deploy.resources.limits: cpus "2", memory 2g`) — same limits as Redis and Cassandra.
  ⚠️ If the recorded A–E runs were made WITHOUT these limits, they must be re-run with them
  (the protocol requires identical limits across all 3 databases).
- Topology: replica set `rs0` — 1 primary + 2 secondaries (3-node) or 1 primary + 4 secondaries (5-node).
- Each node runs: `mongod --replSet rs0 --bind_ip_all --oplogSize 1024`
  (oplog capped at 1 GB/node; uncapped it grows to ~50 GB/node and fills the disk).
- Write concern `w=majority` (in the connection URL; also the MongoDB 7 default).
- Read preference: `primary` (YCSB driver default).

## Bring-up

```bash
docker network create tp2-net          # once
docker compose -f docker-compose-mongo-3.yml up -d
docker exec mongo1 mongosh --quiet --eval 'rs.initiate({_id:"rs0",members:[{_id:0,host:"mongo1:27017"},{_id:1,host:"mongo2:27017"},{_id:2,host:"mongo3:27017"}]})'
# 5-node: same with mongo4/mongo5 appended (run_mongo.sh generates this per node count)
# wait until: 1 PRIMARY + N SECONDARY
```

## Run

`./run_mongo.sh` — per config (3, 5) × workload (A–E) × rep (1..10): dropDatabase → load → run.
Resumable (skips finished reps), aborts on first error. Outputs go to `../results/`.

Example YCSB command (3-node, workload A, run phase):

```bash
docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -w /ycsb eclipse-temurin:11-jre \
  bin/ycsb.sh run mongodb -P workloads/workloada \
  -p "mongodb.url=mongodb://mongo1:27017,mongo2:27017,mongo3:27017/ycsb?replicaSet=rs0&w=majority" \
  -p recordcount=100000 -p operationcount=100000 -threads 16
```

(`load` phase is identical with `load` instead of `run`.)

## Outputs

- `../results/raw/` — raw load/run logs (appendix evidence)
- `../results/mongo_results.csv` — db,nodes,workload,rep,section,metric,value
- `../results/commands.txt` — exact commands executed (appendix)
