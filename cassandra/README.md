# Apache Cassandra — masterless ring (NOT STARTED)

Status: not started. Do after Redis. This file records the plan + known gotchas.

Files planned here: `run_cassandra.sh`, `docker-compose-cassandra-3.yml`, `docker-compose-cassandra-5.yml`.

## Setup

- Image: official `cassandra` image (pin exact tag, e.g. 5.x), one node per container on `tp2-net`.
- Topology: peer-to-peer gossip ring — no primary, no init command. Per-node env:
  `CASSANDRA_CLUSTER_NAME`, `CASSANDRA_SEEDS=cass1` (use `cass1,cass2` for 5 nodes),
  `CASSANDRA_ENDPOINT_SNITCH=GossipingPropertyFileSnitch`, `CASSANDRA_DC=DC1`, `CASSANDRA_RACK=RAC1`.
- **Start the seed node first, wait for it to be Up, then start the others staggered** — starting
  all 5 at once on one machine makes the ring flap (this is the "cluster not initially stable"
  warning from the TP guide).
- **Heap — the one documented exception to "no limits"**: the official image sizes its JVM heap from
  host RAM; five default nodes exceed the 15 GB WSL2 allocation. Set per container:
  `MAX_HEAP_SIZE=1G`, `HEAP_NEWSIZE=200M`. Explain this exception in the paper.

## Keyspace / replication factor — verify before trusting any number

The YCSB `cassandra-cql` binding uses keyspace `ycsb` and may auto-create it with an unwanted
replication factor (historically SimpleStrategy RF=1 — which would silently store every write once
and fake the replication experiment). Safer pattern: pre-create the keyspace yourself before load:

```bash
docker exec cass1 cqlsh -e "CREATE KEYSPACE IF NOT EXISTS ycsb WITH replication = {'class':'SimpleStrategy','replication_factor':3};"   # =5 for 5-node
```

Check in cqlsh what RF the keyspace actually has before recording results.

## Consistency

Pick a driver consistency level and use it everywhere (QUORUM is the closest analog of Mongo's
`w=majority`: 2/3 nodes, 3/5 nodes). Check the `cassandra-cql` binding README for the exact
property name and record the setting in `../results/commands.txt`.

## Health gate / wipe / YCSB

```bash
docker exec cass1 nodetool status        # gate: every node UN (expect ~1–2 min boot per node)
docker exec cass1 cqlsh -e "TRUNCATE ycsb.usertable;"   # or DROP KEYSPACE + re-create, pick one
docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -w /ycsb eclipse-temurin:11-jre \
  bin/ycsb.sh run cassandra-cql -P workloads/workloada \
  -p hosts=cass1 \
  -p recordcount=100000 -p operationcount=100000 -threads 16
```

The driver discovers the ring from one contact point. `run_cassandra.sh` mirrors the mongo loop;
outputs `../results/cassandra_results.csv` (db=cassandra).
