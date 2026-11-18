# MongoDB — replica set (DONE for workloads A–E)

Status: experiments complete (3-node and 5-node, workloads A–E, 10 reps each) on the shared test
machine. Custom-workload pass still pending (run it once the team defines the scenario).

Files (to be pushed here from the experiment machine): `run_mongo.sh`,
`docker-compose-mongo-3.yml`, `docker-compose-mongo-5.yml`.

## Setup

- Image: `mongo:7.0`, one container per node on network `tp2-net`, no CPU/RAM limits.
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
