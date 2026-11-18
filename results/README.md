# Results

What lands here (per database):

- `<db>_results.csv` — columns: `db,nodes,workload,rep,section,metric,value` (input for stats + plots)
- `raw/` — raw YCSB load/run logs per rep. **Required appendix evidence**: at least one complete
  successful run per database. Do NOT gitignore `*.log`.
- `commands.txt` — the exact YCSB command lines executed (goes into the Appendix almost verbatim).

Current state: MongoDB results (CSV + raw logs + commands.txt) exist on the teammate's machine —
push them here when transferred. Redis and Cassandra results will be produced by their runs.

Large-file note: 10 reps × 6 workloads × 2 configs × 3 DBs of raw logs is a lot of text; commit
as-is for now (this repo is private to the team) — if it ever gets heavy we can trim to the reps
needed for the appendix and keep full copies outside git.
