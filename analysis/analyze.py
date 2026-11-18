# /// script
# requires-python = ">=3.10"
# dependencies = ["pandas>=2.0", "matplotlib>=3.7", "scipy>=1.10"]
# ///
"""TP2 analysis: merge the per-DB YCSB CSVs -> mean + 95% CI tables and figures.

Input : results/<db>_results.csv  (db,nodes,workload,rep,section,metric,value; run phase only)
Output: results/analysis/
          summary.csv                every (db, nodes, workload, section, metric): n, mean, std, 95% CI
          throughput.{md,tex}        throughput table (mean ± CI half-width)
          latency.{md,tex}           avg / p95 / p99 latency per operation type
          scaling.md                 3 -> 5 node change in throughput per DB/workload
          raw_values.{csv,tex}       per-rep raw values for the Appendix (before aggregation)
          fig_throughput.{pdf,png}   grouped bars + 95% CI error bars
          fig_latency_<stat>.{pdf,png}  small multiples, one panel per operation type
          checks.txt                 completeness / failed-operation report

Usage (from the repo root):
  uv run analysis/analyze.py                    # or: pip install -r analysis/requirements.txt
  uv run analysis/analyze.py --results some/dir --expected-reps 10

CI: Student t interval, mean ± t(0.975, n-1) · s / sqrt(n), over the n repetitions.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402
from scipy import stats  # noqa: E402

# ---------------------------------------------------------------------------
# Presentation constants
# ---------------------------------------------------------------------------
DB_ORDER = ["mongodb", "redis", "cassandra"]
DB_LABEL = {"mongodb": "MongoDB", "mongo": "MongoDB", "redis": "Redis", "cassandra": "Cassandra"}
# Categorical slots 1-3 of the validated reference palette (all-pairs CVD-safe on white).
DB_COLOR = {"mongodb": "#2a78d6", "redis": "#eb6834", "cassandra": "#1baf7a"}
INK, INK_2, GRID = "#0b0b0b", "#52514e", "#e4e3df"

OPS = ["READ", "UPDATE", "INSERT", "SCAN", "READ-MODIFY-WRITE"]
LAT_STATS = {
    "avg": "AverageLatency(us)",
    "p95": "95thPercentileLatency(us)",
    "p99": "99thPercentileLatency(us)",
}
THROUGHPUT = ("OVERALL", "Throughput(ops/sec)")


def wl_label(w: str) -> str:
    """workloada -> A; anything else (custom workload) keeps its name."""
    if w.startswith("workload") and len(w) == len("workload") + 1:
        return w[-1].upper()
    return w


def wl_sort_key(w: str):
    lab = wl_label(w)
    return (len(lab) > 1, lab)  # A..E first, then custom names


def ci95(values: pd.Series) -> tuple[float, float, float, float]:
    v = values.dropna().astype(float)
    n = len(v)
    mean = v.mean() if n else math.nan
    std = v.std(ddof=1) if n > 1 else math.nan
    half = stats.t.ppf(0.975, n - 1) * std / math.sqrt(n) if n > 1 else math.nan
    return n, mean, std, half


# ---------------------------------------------------------------------------
# Load + check
# ---------------------------------------------------------------------------
def load(results: Path) -> pd.DataFrame:
    files = sorted(results.glob("*_results.csv"))
    if not files:
        sys.exit(f"no *_results.csv in {results}")
    df = pd.concat([pd.read_csv(f) for f in files], ignore_index=True)
    df["db"] = df["db"].str.lower().replace({"mongo": "mongodb"})
    df["value"] = pd.to_numeric(df["value"], errors="coerce")
    # A resumed script may have appended the same rep twice: keep the last occurrence.
    df = df.drop_duplicates(["db", "nodes", "workload", "rep", "section", "metric"], keep="last")
    print(f"loaded {len(df)} rows from {', '.join(f.name for f in files)}")
    return df


def checks(df: pd.DataFrame, expected_reps: int) -> list[str]:
    out = []
    reps = df.groupby(["db", "nodes", "workload"])["rep"].nunique()
    for (db, nodes, wl), n in reps.items():
        if n != expected_reps:
            out.append(f"INCOMPLETE  {db} {nodes}n {wl_label(wl)}: {n}/{expected_reps} reps")
    combos = {(db, n, w) for db, n, w in reps.index}
    for db in sorted(df["db"].unique()):
        for nodes in sorted(df["nodes"].unique()):
            for wl in sorted(df["workload"].unique(), key=wl_sort_key):
                if (db, nodes, wl) not in combos:
                    out.append(f"MISSING     {db} {nodes}n {wl_label(wl)}")
    bad = df[df["metric"].str.startswith("Return=") & (df["metric"] != "Return=OK") & (df["value"] > 0)]
    for r in bad.itertuples():
        out.append(f"FAILED OPS  {r.db} {r.nodes}n {wl_label(r.workload)} rep{r.rep} "
                   f"{r.section} {r.metric}={r.value:g}")
    return out or ["OK: every (db, nodes, workload) has the expected reps and no failed operations"]


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------
def summarize(df: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for key, g in df.groupby(["db", "nodes", "workload", "section", "metric"]):
        n, mean, std, half = ci95(g["value"])
        rows.append((*key, n, mean, std, half, mean - half, mean + half))
    s = pd.DataFrame(rows, columns=["db", "nodes", "workload", "section", "metric",
                                    "n", "mean", "std", "ci95_half", "ci95_low", "ci95_high"])
    s["db_order"] = s["db"].map({d: i for i, d in enumerate(DB_ORDER)}).fillna(99)
    s["wl_order"] = s["workload"].map(lambda w: wl_sort_key(w))
    return s.sort_values(["db_order", "nodes", "wl_order", "section", "metric"]).drop(
        columns=["db_order", "wl_order"])


def pick(s: pd.DataFrame, section: str, metric: str) -> pd.DataFrame:
    return s[(s["section"] == section) & (s["metric"] == metric)]


def fmt(mean: float, half: float, digits: int = 0) -> str:
    if math.isnan(mean):
        return "–"
    if math.isnan(half):
        return f"{mean:,.{digits}f}"
    return f"{mean:,.{digits}f} ± {half:,.{digits}f}"


def ordered(values, key=None):
    return sorted(values, key=key) if key else sorted(values)


def dbs_in(s):
    return [d for d in DB_ORDER if d in set(s["db"])] + sorted(set(s["db"]) - set(DB_ORDER))


# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------
def write_table(rows: list[list[str]], header: list[str], md: Path, tex: Path | None, caption: str):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(r) + " |" for r in rows]
    md.write_text(f"{caption}\n\n" + "\n".join(lines) + "\n")
    if tex is not None:
        esc = lambda x: x.replace("±", r"$\pm$").replace("%", r"\%").replace("_", r"\_")  # noqa: E731
        body = " \\\\\n".join(" & ".join(esc(c) for c in r) for r in rows)
        tex.write_text(
            "\\begin{table}[t]\n\\centering\n\\footnotesize\n"
            f"\\caption{{{esc(caption)}}}\n"
            f"\\begin{{tabular}}{{l{'r' * (len(header) - 1)}}}\n\\hline\n"
            + " & ".join(esc(h) for h in header) + " \\\\\n\\hline\n" + body
            + " \\\\\n\\hline\n\\end{tabular}\n\\end{table}\n")


def throughput_table(s: pd.DataFrame, out: Path):
    t = pick(s, *THROUGHPUT)
    wls = ordered(t["workload"].unique(), wl_sort_key)
    rows = []
    for db in dbs_in(t):
        for nodes in sorted(t["nodes"].unique()):
            r = [f"{DB_LABEL.get(db, db)} ({nodes}n)"]
            for wl in wls:
                x = t[(t.db == db) & (t.nodes == nodes) & (t.workload == wl)]
                r.append(fmt(x["mean"].iloc[0], x["ci95_half"].iloc[0]) if len(x) else "–")
            rows.append(r)
    write_table(rows, ["DB (nodes)"] + [wl_label(w) for w in wls],
                out / "throughput.md", out / "throughput.tex",
                "Throughput (ops/s), mean ± 95% CI half-width over the repetitions")


def latency_table(s: pd.DataFrame, out: Path):
    rows = []
    for db in dbs_in(s):
        for nodes in sorted(s["nodes"].unique()):
            for wl in ordered(s["workload"].unique(), wl_sort_key):
                for op in OPS:
                    cells = []
                    for m in LAT_STATS.values():
                        x = s[(s.db == db) & (s.nodes == nodes) & (s.workload == wl)
                              & (s.section == op) & (s.metric == m)]
                        cells.append(fmt(x["mean"].iloc[0], x["ci95_half"].iloc[0]) if len(x) else None)
                    if any(cells):
                        rows.append([f"{DB_LABEL.get(db, db)} ({nodes}n)", wl_label(wl), op]
                                    + [c or "–" for c in cells])
    write_table(rows, ["DB (nodes)", "Workload", "Operation", "Avg (µs)", "p95 (µs)", "p99 (µs)"],
                out / "latency.md", out / "latency.tex",
                "Latency per operation type (µs), mean ± 95% CI half-width")


def scaling_table(s: pd.DataFrame, out: Path):
    t = pick(s, *THROUGHPUT)
    nodes = sorted(t["nodes"].unique())
    if len(nodes) < 2:
        (out / "scaling.md").write_text("Only one node configuration present.\n")
        return
    lo, hi = nodes[0], nodes[-1]
    wls = ordered(t["workload"].unique(), wl_sort_key)
    rows = []
    for db in dbs_in(t):
        r = [DB_LABEL.get(db, db)]
        for wl in wls:
            a = t[(t.db == db) & (t.nodes == lo) & (t.workload == wl)]["mean"]
            b = t[(t.db == db) & (t.nodes == hi) & (t.workload == wl)]["mean"]
            r.append(f"{(b.iloc[0] / a.iloc[0] - 1) * 100:+.1f}%" if len(a) and len(b) else "–")
        rows.append(r)
    write_table(rows, ["DB"] + [wl_label(w) for w in wls], out / "scaling.md", None,
                f"Throughput change {lo} → {hi} nodes (positive = faster with more nodes)")


def raw_values(df: pd.DataFrame, out: Path):
    """Appendix: the per-rep values before aggregation (throughput + avg latency per op)."""
    keep = df[((df.section == THROUGHPUT[0]) & (df.metric == THROUGHPUT[1]))
              | (df.section.isin(OPS) & (df.metric == LAT_STATS["avg"]))].copy()
    keep["col"] = keep.apply(lambda r: "Throughput(ops/s)" if r.section == "OVERALL"
                             else f"{r.section} avg(µs)", axis=1)
    wide = keep.pivot_table(index=["db", "nodes", "workload", "rep"], columns="col",
                            values="value", aggfunc="first").reset_index()
    order = ["Throughput(ops/s)"] + [f"{o} avg(µs)" for o in OPS]
    wide = wide[["db", "nodes", "workload", "rep"] + [c for c in order if c in wide.columns]]
    wide["workload"] = wide["workload"].map(wl_label)
    wide = wide.sort_values(["db", "nodes", "workload", "rep"])
    wide.to_csv(out / "raw_values.csv", index=False)
    cols = [c for c in wide.columns]
    esc = lambda x: str(x).replace("%", r"\%").replace("_", r"\_").replace("µ", r"$\mu$")  # noqa: E731
    lines = [" & ".join(esc(c) for c in cols) + r" \\ \hline \endhead"]
    for r in wide.itertuples(index=False):
        lines.append(" & ".join("" if (isinstance(v, float) and math.isnan(v))
                                else (f"{v:,.1f}" if isinstance(v, float) else esc(v)) for v in r) + r" \\")
    (out / "raw_values.tex").write_text(
        "% needs \\usepackage{longtable}\n\\footnotesize\n"
        f"\\begin{{longtable}}{{lllr{'r' * (len(cols) - 4)}}}\n"
        "\\caption{Raw YCSB values per repetition (run phase), before aggregation}\\\\\n\\hline\n"
        + "\n".join(lines) + "\n\\hline\n\\end{longtable}\n")


# ---------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------
def style():
    plt.rcParams.update({
        "font.size": 8, "axes.titlesize": 8, "axes.labelsize": 8, "legend.fontsize": 7,
        "xtick.labelsize": 7, "ytick.labelsize": 7,
        "text.color": INK, "axes.labelcolor": INK_2, "xtick.color": INK_2, "ytick.color": INK_2,
        "axes.edgecolor": GRID, "axes.spines.top": False, "axes.spines.right": False,
        "axes.spines.left": False, "axes.grid": True, "axes.grid.axis": "y",
        "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
        "hatch.linewidth": 0.6, "savefig.dpi": 300, "savefig.bbox": "tight",
        "pdf.fonttype": 42,
    })


def tint(hex_color: str, amount: float = 0.55) -> str:
    """Mix with white: 5-node bars are a tint of the DB hue + hatch (texture = secondary encoding)."""
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    mix = lambda c: round(c + (255 - c) * amount)  # noqa: E731
    return f"#{mix(r):02x}{mix(g):02x}{mix(b):02x}"


def bar_style(db: str, nodes: int, nodes_list: list[int]):
    base = DB_COLOR.get(db, "#888888")
    if nodes == nodes_list[0]:
        return dict(facecolor=base, edgecolor="white", linewidth=0.8)
    return dict(facecolor=tint(base), edgecolor=base, hatch="////", linewidth=0.6)


def _cell(sub, db, n, wl):
    x = sub[(sub.db == db) & (sub.nodes == n) & (sub.workload == wl)]
    if not len(x):
        return None
    half = x["ci95_half"].iloc[0]
    return x["mean"].iloc[0], (0.0 if math.isnan(half) else half)


def plain_ticks(ax):
    """Readable log-axis labels: 300, 1k, 30k ... instead of 3x10^2."""
    def f(v, _):
        if v >= 1000:
            return f"{v / 1000:g}k"
        return f"{v:g}"
    ax.yaxis.set_major_locator(matplotlib.ticker.LogLocator(base=10, subs=(1.0, 2.0, 5.0)))
    ax.yaxis.set_minor_locator(matplotlib.ticker.NullLocator())
    ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(f))


def legend_handles(dbs, nodes_list, kind="bar"):
    if kind == "bar":
        return [Patch(label=f"{DB_LABEL.get(db, db)} · {n} nodes", **bar_style(db, n, nodes_list))
                for db in dbs for n in nodes_list]
    return [Line2D([], [], linestyle="none", label=f"{DB_LABEL.get(db, db)} · {n} nodes",
                   **dot_style(db, n, nodes_list)) for db in dbs for n in nodes_list]


def dot_style(db, n, nodes_list):
    base = DB_COLOR.get(db, "#888888")
    filled = n == nodes_list[0]
    return dict(marker="o", markersize=4.5, markeredgewidth=1.1, markeredgecolor=base,
                markerfacecolor=base if filled else "white")


def fig_throughput(s: pd.DataFrame, out: Path):
    """Small multiples, one panel per workload with its own y-scale (E is ~10x lower)."""
    t = pick(s, *THROUGHPUT)
    wls = ordered(t["workload"].unique(), wl_sort_key)
    dbs, nodes_list = dbs_in(t), sorted(t["nodes"].unique())
    groups = [(db, n) for db in dbs for n in nodes_list]
    fig, axes = plt.subplots(1, len(wls), figsize=(7.0, 2.3), squeeze=False)
    for ax, wl in zip(axes[0], wls):
        for i, (db, n) in enumerate(groups):
            c = _cell(t, db, n, wl)
            if c:
                ax.bar(i + (i // len(nodes_list)) * 0.35, c[0], 0.9, yerr=c[1],
                       error_kw=dict(ecolor=INK, elinewidth=0.6, capsize=1.5),
                       **bar_style(db, n, nodes_list))
        ax.set_xticks([])
        ax.set_title(f"Workload {wl_label(wl)}", loc="left", color=INK)
        ax.yaxis.set_major_locator(matplotlib.ticker.MaxNLocator(4))
        ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(
            lambda v, _: f"{v / 1000:g}k" if v >= 1000 else f"{v:g}"))
    axes[0][0].set_ylabel("Throughput (ops/s)")
    fig.suptitle("Throughput per workload — mean of the repetitions, error bars = 95% CI "
                 "(each panel has its own scale)", x=0.01, ha="left", fontsize=8, color=INK)
    fig.legend(handles=legend_handles(dbs, nodes_list), ncol=len(groups) // 2 or 1, frameon=False,
               loc="upper left", bbox_to_anchor=(0.01, 0.02))
    fig.tight_layout()
    for ext in ("pdf", "png"):
        fig.savefig(out / f"fig_throughput.{ext}")
    plt.close(fig)


STAT_TITLE = {"avg": "Average", "p95": "95th-percentile", "p99": "99th-percentile"}


def fig_latency(s: pd.DataFrame, out: Path, stat: str):
    """Dot + CI whisker on a log axis (bars would misstate ratios on log scale)."""
    metric = LAT_STATS[stat]
    lat = s[(s.metric == metric) & s.section.isin(OPS)]
    ops = [o for o in OPS if o in set(lat.section)]
    if not ops:
        return
    dbs, nodes_list = dbs_in(lat), sorted(lat["nodes"].unique())
    groups = [(db, n) for db in dbs for n in nodes_list]
    step = 0.8 / len(groups)
    wls_per_op = {op: ordered(lat[lat.section == op]["workload"].unique(), wl_sort_key) for op in ops}
    fig, axes = plt.subplots(1, len(ops), figsize=(7.0, 2.4), squeeze=False,
                             gridspec_kw=dict(width_ratios=[max(len(wls_per_op[o]), 1.6) for o in ops]))
    for ax, op in zip(axes[0], ops):
        sub, wls = lat[lat.section == op], wls_per_op[op]
        for i, (db, n) in enumerate(groups):
            for j, wl in enumerate(wls):
                c = _cell(sub, db, n, wl)
                if c:
                    ax.errorbar(j - 0.4 + step * (i + 0.5), c[0], yerr=c[1], ecolor=INK, elinewidth=0.6,
                                capsize=1.5, linestyle="none", **dot_style(db, n, nodes_list))
        ax.set_yscale("log")
        plain_ticks(ax)
        ax.set_xticks(range(len(wls)), [wl_label(w) for w in wls])
        ax.set_xlim(-0.5, len(wls) - 0.5)
        ax.tick_params(axis="x", length=0)
        ax.set_title(op, loc="left", color=INK)
    axes[0][0].set_ylabel("Latency (µs, log scale)")
    fig.suptitle(f"{STAT_TITLE[stat]} latency per operation type and workload — mean, "
                 "whiskers = 95% CI", x=0.01, ha="left", fontsize=8, color=INK)
    fig.legend(handles=legend_handles(dbs, nodes_list, kind="dot"), ncol=len(groups) // 2 or 1,
               frameon=False, loc="upper left", bbox_to_anchor=(0.01, 0.02))
    fig.tight_layout()
    for ext in ("pdf", "png"):
        fig.savefig(out / f"fig_latency_{stat}.{ext}")
    plt.close(fig)


# ---------------------------------------------------------------------------
def main():
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--results", type=Path, default=root / "results")
    ap.add_argument("--out", type=Path, default=None, help="default: <results>/analysis")
    ap.add_argument("--expected-reps", type=int, default=10)
    a = ap.parse_args()
    out = a.out or a.results / "analysis"
    out.mkdir(parents=True, exist_ok=True)

    df = load(a.results)
    report = checks(df, a.expected_reps)
    (out / "checks.txt").write_text("\n".join(report) + "\n")
    print("\n".join(report[:15]) + (f"\n... ({len(report) - 15} more in checks.txt)" if len(report) > 15 else ""))

    s = summarize(df)
    s.to_csv(out / "summary.csv", index=False)
    throughput_table(s, out)
    latency_table(s, out)
    scaling_table(s, out)
    raw_values(df, out)

    style()
    fig_throughput(s, out)
    for stat in LAT_STATS:
        fig_latency(s, out, stat)
    print(f"wrote tables and figures to {out}")


if __name__ == "__main__":
    main()
