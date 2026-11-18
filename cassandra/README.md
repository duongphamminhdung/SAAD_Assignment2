# Apache Cassandra — masterless ring

Status: scripts complete (`run_cassandra.sh`, `docker-compose-cassandra-3.yml`,
`docker-compose-cassandra-5.yml`). Smoke-tested on a Linux dev box (Docker Engine 26.1,
Compose v2.30.3): 3-node A/E and 5-node A/D at 1000 records, plus one full-size rep (100k)
of A and E on 3 nodes — all ops `Return=OK`, RF verified, no OOM. Smoke results discarded.
**Recorded runs must happen on the shared test machine.**

```bash
./run_cassandra.sh                    # full: 2 configs x A–E x 10 reps
# smoke: RECORDCOUNT=1000 OPERATIONCOUNT=1000 REPS=1 WORKLOADS="workloada" NODE_CONFIGS="3" ./run_cassandra.sh
```

Measured on the dev box (estimate, re-measure on the test machine): ring bring-up ~4 min
(3 nodes) / ~5–6 min (5 nodes); per full-size rep ~1 min for A–D, ~3 min for E (scans)
→ roughly 3 h for all 100 Cassandra A–E runs.

## Decisions pinned (document these in the paper)

| | Value | Why |
|---|---|---|
| Image | `cassandra:5.0.9` | YCSB 0.17 driver (DataStax 3.0.0, protocol v4) verified working |
| Per-node limits | `cpus: 2`, `mem_limit: 2g` (`NODE_CPUS`/`NODE_MEM` override for debugging only) | same limits must apply to every DB — see top-level README |
| JVM heap | `MAX_HEAP_SIZE=1G`, `HEAP_NEWSIZE=256M` | default heap is sized from host RAM (~3.75 GB/node), would not fit in 2 GB |
| Topology | 1 DC/1 rack, `GossipingPropertyFileSnitch`, 16 vnodes; seeds `cass1` (3n) / `cass1,cass2` (5n) | |
| Start order | sequential via `depends_on: service_healthy` (healthcheck: native transport active) | Cassandra refuses concurrent bootstraps; ring flaps otherwise |
| Replication | keyspace `ycsb`, `SimpleStrategy`, **RF = node count** (3 / 5), created + verified by the script | every node holds a full copy, like the Mongo replica set |
| Consistency | `QUORUM` reads and writes (2/3, 3/5) | closest analogue of Mongo `w=majority` |
| Wipe per rep | `TRUNCATE ycsb.usertable` + check `count(*) = 0` | |
| `auto_snapshot` | `false` (sed in the entrypoint) | otherwise each TRUNCATE leaves a full snapshot on disk |

## Bring-up & health gate (manual equivalent of the script)

```bash
docker network create tp2-net                                   # once
docker compose -f docker-compose-cassandra-3.yml up -d --wait   # nodes join one by one
docker exec cass1 nodetool status                               # gate: every node UN
docker exec cass1 cqlsh -e "CREATE KEYSPACE IF NOT EXISTS ycsb WITH replication = {'class':'SimpleStrategy','replication_factor':3};"
docker exec cass1 cqlsh -e "CREATE TABLE IF NOT EXISTS ycsb.usertable (y_id varchar PRIMARY KEY, field0 varchar, field1 varchar, field2 varchar, field3 varchar, field4 varchar, field5 varchar, field6 varchar, field7 varchar, field8 varchar, field9 varchar);"
```

## YCSB

```bash
docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -w /ycsb eclipse-temurin:11-jre \
  bin/ycsb.sh run cassandra-cql -P workloads/workloada \
  -p hosts=cass1,cass2,cass3 \
  -p cassandra.readconsistencylevel=QUORUM -p cassandra.writeconsistencylevel=QUORUM \
  -p recordcount=100000 -p operationcount=100000 -threads 16
```

## Script behaviour

- Refuses to start while any `mongoN` / `redisN` container is running (one DB at a time).
- Aborts on a YCSB phase without `[OVERALL]` or with any `Return=ERROR/NOT_FOUND/...`.
- Appends `docker stats` (CPU, memory per node) to every run log — evidence the limits held.
- Resumable: a run log is only moved into place after validation + CSV append.
- Custom workload: put the file in `../workloads/<name>` and add `<name>` to `WORKLOADS`.
- Tears down with `docker compose down -v` (removes the anonymous data volumes).

Outputs: `../results/cassandra_results.csv` (db=cassandra), `../results/raw/`, `../results/commands.txt`.

## Notes for the report

- Memory: after a full-size workload E rep each node reported ~1.5–1.8 GiB of 2 GiB in
  `docker stats` (includes reclaimable page cache). No OOM kill — keep an eye on the logged
  stats during the recorded runs, especially with 5 nodes.
- 3→5 nodes with RF = nodes: every node stores everything, QUORUM waits for 3 instead of 2
  replicas → expect equal or lower throughput at 5 nodes (no sharding benefit).
- YCSB prints JDK "illegal reflective access" warnings from netty 4.0 on Java 11 — harmless.
