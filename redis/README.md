# Redis — 1 master + N replicas

Status: scripts complete (`run_redis.sh`, `docker-compose-redis-3.yml`,
`docker-compose-redis-5.yml`, `redis.conf`). Smoke-tested on macOS (M2, colima/vz) with
tiny parameters — smoke results were discarded. **Recorded runs must happen on the shared
test machine** (same box as the Mongo experiments), full defaults, via:

```bash
./run_redis.sh                       # full: 2 configs x A–E x 10 reps
# smoke: RECORDCOUNT=1000 OPERATIONCOUNT=1000 REPS=1 WORKLOADS="workloada" NODE_CONFIGS="3" ./run_redis.sh
```

Decisions pinned (document these in the paper): image `redis:7.4`; persistence disabled
(`--save "" --appendonly no`) to keep BGSAVE fork noise out of the measurements; no CPU/RAM
limits (parity with Mongo); resumable — finished (workload, rep) pairs are skipped on restart.

## Setup

- Image: `redis:7.4` (pin exact tag; record it for the paper), one container per node on `tp2-net`,
  no CPU/RAM limits.
- Topology: asynchronous replication — redis1 = master; redis2..N = replicas. No init step
  (no rs.initiate equivalent): the replication link is declared at container start.

```bash
# redis1 (master)
command: redis-server --protected-mode no
# redis2..redisN (replicas)
command: redis-server --protected-mode no --replicaof redis1 6379
```

- Open decision (pick one, use for both configs, document in paper): keep default RDB auto-save
  or disable with `--save ""` (default save rules can trigger BGSAVE mid-benchmark → fork noise).

## Bring-up & health gate

```bash
docker compose -f docker-compose-redis-3.yml up -d
# gate: until role:master AND connected_slaves:2   (3-node) / connected_slaves:4   (5-node)
docker exec redis1 redis-cli INFO replication
```

Smoke test before YCSB (required by the TP guide): `PING` → PONG; SET a key on redis1, GET it on
redis2 (replica reads OK, replica writes refused); DBSIZE equal on both.

## YCSB

Binding: `redis` (no topology discovery — point it at the master only).

```bash
docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -w /ycsb eclipse-temurin:11-jre \
  bin/ycsb.sh run redis -P workloads/workloada \
  -p "redis.host=redis1" -p redis.port=6379 \
  -p recordcount=100000 -p operationcount=100000 -threads 16
```

## Wipe between reps (replaces Mongo's dropDatabase)

```bash
docker exec redis1 redis-cli FLUSHALL   # propagates to replicas; verify DBSIZE 0 on a replica
```

`run_redis.sh` mirrors `run_mongo.sh`: configs {3,5} × workloads {A–E, custom} × reps {1..10},
each rep FLUSHALL → load → run, outputs `../results/redis_results.csv` (db=redis) + raw logs + commands.

## Architectural notes for the report (differences to document, not to "fix")

- Replication is asynchronous and the YCSB binding issues no WAIT → no `w=majority` equivalent.
- All reads AND writes hit the master → 3→5 nodes changes write-side replication fan-out, not reads.
- No read-preference concept (unlike the Mongo driver).
