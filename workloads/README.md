# Custom workload — proposal (team decision needed)

The assignment requires one custom workload derived from a **concrete, quantified usage scenario**
(users, operation frequency, …) that **differs from A–E** and is justified. Below are three
candidates, each already written as a YCSB workload file in this folder and smoke-tested
(1,000 records/ops, 3 nodes) on **all three databases**: every operation returned `OK`.

**→ The team picks one** (see *Decision* at the bottom). The chosen file gets renamed
`workload_custom` (and the other two deleted) before the recorded runs.

All candidates keep the shared protocol unchanged: `recordcount=100000`,
`operationcount=100000`, `threads=16`, default 10 fields × 100 B, passed on the command line.

## Summary

| | 1. E-commerce cart | 2. IoT telemetry | 3. Social viral event |
|---|---|---|---|
| File | `custom_ecommerce` | `custom_iot` | `custom_social` |
| Mix | 70% read · 25% read-modify-write · 5% insert | **93% insert** · 6% read · 1% short scan | 65% read · 30% update · 5% insert |
| Key distribution | zipfian | latest | **hotspot**: 1% of keys get 60% of ops |
| Write share | 30% | **93%** | 35% |
| Closest standard workload | YCSB F (50 read / 50 RMW), *not* in A–E | none (A–E are all read-dominated or 50/50) | A (50/50), but different distribution |
| Main question it answers | cost of read-then-write round trips under replication | which DB ingests fastest with durable replicated writes | how each DB copes with write contention on a few hot keys |

---

## 1. E-commerce shopping cart at a sales peak — `custom_ecommerce`

**Scenario.** An online store during a flash sale. 20,000 shoppers are on the site at the same
time. Each cart is one record (the 10 fields = cart lines / session data).

| Per shopper, per minute | Count | YCSB operation |
|---|---|---|
| View cart / product summary | 3 | `read` |
| Change cart (add/remove item → read cart, write it back) | 1 | `readmodifywrite` |
| Start a new cart / session | 0.2 | `insert` |
| **Total** | **4.2 ops/min** → 20,000 × 4.2 / 60 ≈ **1,400 ops/s** | |

Mix: 3/4.2 = 71% read, 1/4.2 = 24% RMW, 0.2/4.2 = 5% insert → **70 / 25 / 5**.
`zipfian` (a minority of very active shoppers), `readallfields=true`, `writeallfields=false`
(one cart line changes).

**Why it differs from A–E.** None of A–E contains read-modify-write.

**What we expect to see.**
- MongoDB: each RMW = a primary read plus a `w=majority` write → latency of the RMW roughly
  read + update; 5 nodes should cost more (majority = 3 instead of 2).
- Cassandra: RMW = QUORUM read + QUORUM write, two network round trips, no locking.
- Redis: lowest latency (in-memory, single master), replication is asynchronous.

**Risk.** Reviewers may see it as "workload F with inserts"; YCSB's RMW is not atomic in any
binding (read and write are two separate requests). Mention this in the paper.

## 2. IoT sensor telemetry with live dashboards — `custom_iot` ⭐ recommended

**Scenario.** A building / factory monitoring platform. Each sensor reading is one record.

| Actor | Volume | Rate | YCSB operation |
|---|---|---|---|
| Sensors reporting a reading | 3,000 sensors, every 5 s | 600 /s | `insert` |
| Dashboards showing the latest value | 40 screens, 1 refresh/s | 40 /s | `read` (latest) |
| Analysts loading a short trend (≤ 20 readings) | 8 analysts, every 2 s | 4 /s | `scan` (length 1–20) |
| **Total** | | **644 ops/s** | |

Mix: 600/644 = 93.2% insert, 40/644 = 6.2% read, 4/644 = 0.6% scan → **93 / 6 / 1**.
`requestdistribution=latest` (dashboards look at the newest data), `maxscanlength=20`.

**Why it differs from A–E.** It is the only **write-dominated** workload: A–E have at most 50%
writes (A) and at most 5% inserts (D, E). Write-heavy ingestion is exactly where the three data
models are expected to diverge most, so it adds the most new information to the comparison.

**What we expect to see.**
- Cassandra: log-structured writes (commit log + memtable) → inserts are cheap; this is the
  workload where it should come closest to the others or beat MongoDB.
- MongoDB: every insert waits for a majority of the replica set (`w=majority`) → write latency
  dominates; 3 → 5 nodes should hurt.
- Redis: in-memory inserts are fast, but the YCSB Redis binding also adds every key to one sorted
  set (`_indices`, used for scans) → every insert touches the same key. Binding artefact — must be
  listed as a limitation (it affects D and E too).
- The dataset grows by ~93k records during each run (≈ +93% data) — realistic for ingestion.

**Risk.** Small scan share (1%) means scan latency has fewer samples (~1,000 per run) — still
enough for avg/p95, p99 is noisier.

## 3. Social network during a viral event — `custom_social`

**Scenario.** A viral post / celebrity profile: 50,000 active users, and a tiny fraction of
content receives most of the traffic.

| Per user, per minute | Count | YCSB operation |
|---|---|---|
| View post / profile | 6 | `read` |
| Like / reaction (changes a counter field) | 3 | `update` |
| Comment or new post | 0.5 | `insert` |
| **Total** | **9.5 ops/min** → 50,000 × 9.5 / 60 ≈ **7,900 ops/s** | |

Mix: 6/9.5 = 63% read, 3/9.5 = 32% update, 0.5/9.5 = 5% insert → **65 / 30 / 5**.
`requestdistribution=hotspot`, `hotspotdatafraction=0.01`, `hotspotopnfraction=0.60`
(1% of the records = viral content receive 60% of all operations), `writeallfields=false`.

**Why it differs from A–E.** A–E use zipfian, latest or uniform; none uses a hotspot this extreme,
so none measures **write contention on a few keys**.

**What we expect to see.**
- MongoDB: concurrent updates to the same document conflict in WiredTiger → internal retries,
  higher update p99.
- Cassandra: no locks, last-write-wins → contention should barely matter.
- Redis: single-threaded command execution → contention makes little difference either.
- Adding nodes cannot spread the hot keys (every node holds every record in Mongo/Cassandra,
  one master in Redis) → useful to discuss for 3 vs 5 nodes.

**Risk.** Mix alone is close to A (50/50); the justification rests on the distribution.

---

## Recommendation

**Candidate 2 (IoT telemetry)**:
1. It is the most different from A–E (only write-dominated workload), which the assignment
   explicitly asks for.
2. The scenario is easy to quantify and defend (sensor count × reporting interval).
3. It shows the clearest architectural contrast (LSM writes vs majority-acknowledged writes vs
   in-memory), which gives the paper a strong discussion section.

Candidate 3 is a good alternative if the team prefers a contention story; candidate 1 is the
weakest because of its similarity to YCSB workload F.

## How each run script uses it

- `cassandra/run_cassandra.sh`: already supported — `WORKLOADS="... workload_custom"` mounts
  `workloads/` into the YCSB container (`-P /tp2-workloads/workload_custom`).
- `redis/run_redis.sh` and `run_mongo.sh` (not in the repo yet): need the same 3-line change —
  mount `../workloads` read-only and use `-P /tp2-workloads/<name>` when the file exists:
  ```bash
  -v "$REPO/workloads":/tp2-workloads:ro   …   bin/ycsb.sh run <binding> -P /tp2-workloads/workload_custom
  ```
- Smoke-test commands used for this proposal (1,000 records/ops, 3 nodes), e.g. MongoDB:
  ```bash
  docker run --rm --network tp2-net -v ~/ycsb-0.17.0:/ycsb -v ./workloads:/tp2-workloads:ro -w /ycsb \
    eclipse-temurin:11-jre bin/ycsb.sh run mongodb -P /tp2-workloads/custom_iot \
    -p "mongodb.url=mongodb://mongo1:27017,mongo2:27017,mongo3:27017/ycsb?replicaSet=rs0&w=majority" \
    -p recordcount=1000 -p operationcount=1000 -threads 16
  ```

## Decision

- [ ] 1. E-commerce cart
- [ ] 2. IoT telemetry (recommended)
- [ ] 3. Social viral event

Decided by: ____ on ____. Then: rename the chosen file to `workload_custom`, delete the other two,
and add `workload_custom` to the `WORKLOADS` list of every run script.
