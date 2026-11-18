# SAAD_Assignment2 — LOG8430E TP2

Performance comparison of three NoSQL databases with YCSB: **MongoDB vs Redis vs Apache Cassandra**,
each deployed as a replicated cluster of 3 containers and 5 containers.

## Deadlines & deliverables (Moodle)

| Item | Due | File |
|------|-----|------|
| Presentation slides | Nov 30, 23:59 | `TP2_[TeamName]_ppt.pdf` |
| Research paper (IEEE format) | Dec 5, 23:59 | `TP2_[TeamName].pdf` |
| Appendix (exact commands, 1 successful full run per DB, raw values table) | with paper | `TP2_[TeamName]_Appendix.pdf` |
| Config archive (these folders) | with paper | `TP2_[TeamName]_Configs` |

Presentations: Nov 24 and Dec 1, 10 min + 2 min Q&A, at least 2 presenters, each team asks 2 questions.
Team name: **TBD**.

## Repository layout

```
mongo/       replica-set setup + run script      (A–E done on 3 & 5 nodes; custom workload pending)
redis/       1 master + N replicas               (in progress)
cassandra/   masterless ring                     (scripts done, smoke-tested)
results/     CSVs, raw YCSB logs, commands.txt   (appendix evidence)
```

## Shared experiment protocol — identical for all three databases

Any parameter change must be applied to **all** databases and both configurations, and re-runs redone.

- **Machine:** all recorded runs come from ONE machine (spec below) — never mix machines.
- **One cluster at a time:** `docker compose down` the other databases' stacks before benchmarking.
- YCSB 0.17.0, executed from an `eclipse-temurin:11-jre` container on docker network `tp2-net`.
- Parameters: `recordcount=100000`, `operationcount=100000`, `threads=16`.
- Workloads: core A–E **plus one custom workload** (scenario TBD by the team).
- 10 repetitions per (database × node-config × workload); each rep = **wipe → load → run**.
- CSV schema: `db,nodes,workload,rep,section,metric,value`.

## Test machine (source of all results)

Intel Core Ultra 7 155H (16C/22T), 32 GB RAM (WSL2 allocated 15 GB), Windows 11 Home + WSL2 Ubuntu,
Docker Desktop 4.36.0 / Docker Engine 27.3.1 (WSL2 backend), data on drive D:.

## Status board

- [ ] Choose team name
- [ ] Define custom workload scenario (needed for ALL databases; Mongo must re-run a custom-workload pass)
- [x] Redis: scripts written + smoke-tested locally (owner: Dung) — recorded runs on the test machine pending
- [x] Cassandra: scripts written + smoke-tested locally (3 & 5 nodes, 2 CPU / 2 GB per node) — recorded runs on the test machine pending
- [ ] Push Mongo files + results from teammate's machine into `mongo/` and `results/`
- [ ] Stats (mean, CI) + plots from the CSVs
- [ ] IEEE paper (LaTeX template on Moodle)
- [ ] Slides (results must be complete before Nov 30)
