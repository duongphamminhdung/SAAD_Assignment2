# Analysis — mean, 95% CI, tables and figures

`analyze.py` merges every `results/<db>_results.csv` (schema `db,nodes,workload,rep,section,metric,value`,
run phase only, as written by `run_mongo.sh` / `run_redis.sh` / `run_cassandra.sh`) and writes
everything the slides, paper and Appendix need to `results/analysis/`.

```bash
# from the repo root — uv reads the dependencies from the script header
uv run analysis/analyze.py
# or with pip
pip install -r analysis/requirements.txt && python3 analysis/analyze.py

# options
uv run analysis/analyze.py --results path/to/results --out path/to/out --expected-reps 10
```

## Outputs (`results/analysis/`)

| File | Use |
|---|---|
| `checks.txt` | **read first** — missing (db, nodes, workload) combos, incomplete reps, any `Return≠OK` ops |
| `summary.csv` | every (db, nodes, workload, section, metric): n, mean, std, 95% CI half-width / low / high |
| `throughput.md` / `.tex` | throughput table, mean ± CI (LaTeX `table` for the paper) |
| `latency.md` / `.tex` | avg / p95 / p99 latency per operation type and workload |
| `scaling.md` | throughput change 3 → 5 nodes per DB and workload (%) |
| `raw_values.csv` / `.tex` | **Appendix**: per-rep throughput + avg latency per op, before aggregation (`longtable`) |
| `fig_throughput.pdf/.png` | small multiples, one panel per workload (own y-scale), bars + 95% CI |
| `fig_latency_{avg,p95,p99}.pdf/.png` | one panel per operation type, dot + 95% CI whisker, log axis |

Figures are 7 in wide (IEEE two-column `figure*`); use the PDFs in LaTeX, PNGs in slides.

## Method (state this in the paper)

- One sample = one repetition's run phase (fresh wipe → load → run). n = 10 per cell.
- 95% CI = mean ± t(0.975, n−1) · s / √n (Student t, since n is small).
- p95/p99 are YCSB's per-run percentiles; the table reports the **mean of the per-run
  percentiles** across reps (not a percentile of pooled samples).
- Duplicate rows for the same (db, nodes, workload, rep, section, metric), e.g. from a resumed
  script, keep the last occurrence.
- Encoding: hue = database (validated CVD-safe palette), 3 nodes = solid / filled dot,
  5 nodes = hatched tint / hollow dot, so the figures also work in grayscale print.
- The custom workload is picked up automatically (shown under its file name after A–E).
