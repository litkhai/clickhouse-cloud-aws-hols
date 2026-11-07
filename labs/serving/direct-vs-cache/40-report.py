#!/usr/bin/env python3
"""Markdown tables from one result stamp.

    python3 40-report.py results/<stamp> > results/<stamp>/REPORT.md

Standard library only. Reads floor/s1/kv/s2/s3 .jsonl as written by cachebench; missing files
are skipped. Numbers are printed as measured, nothing is derived beyond per-second rates.
"""
import json
import sys
from pathlib import Path


POSTHOC = {}


def load(d, name):
    p = d / f"{name}.jsonl"
    if not p.exists():
        return []
    rows = [json.loads(line) for line in p.read_text().splitlines() if line.strip()]
    for r in rows:  # in-run stats missing → the ones 35-server-stats.sh read afterwards
        if not r.get("server") and r.get("run_id") in POSTHOC:
            r["server"] = POSTHOC[r["run_id"]]
            r["server_from"] = "posthoc"
    return rows


def num(v):
    """ClickHouse JSON quotes 64-bit integers; turn numeric strings back into numbers."""
    if isinstance(v, str):
        try:
            return int(v)
        except ValueError:
            try:
                return float(v)
            except ValueError:
                return v
    return v


def f(v, nd=1):
    v = num(v)
    if v is None or v == "":
        return "–"
    if isinstance(v, float):
        return f"{v:,.{nd}f}"
    if isinstance(v, int):
        return f"{v:,}"
    return str(v)


def lat(r, k):
    return f((r.get("lat_ms") or {}).get(k), 2)


def errs(r):
    e = r.get("errors") or {}
    return ", ".join(f"{k} {v}" for k, v in sorted(e.items())) or "0"


def srv(r, k, nd=1):
    return f((r.get("server") or {}).get(k), nd)


def per_s(r):
    d = r.get("duration_s") or 0
    return f(r.get("backend_calls", 0) / d) if d else "–"


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(row) + " |" for row in rows]
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = Path(sys.argv[1])
    ph = d / "server-posthoc.jsonl"
    if ph.exists():
        for line in ph.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                POSTHOC[r["run_id"]] = r
    print(f"# Results {d.name}\n")

    rs = load(d, "floor")
    if rs:
        print("## Floor (cheapest round trip)\n")
        print(table(["system", "conc", "QPS", "p50 ms", "p99 ms", "errors"],
                    [[r["arm"], f(r["conc"]), f(r["qps"]), lat(r, "p50"), lat(r, "p99"), errs(r)] for r in rs]))

    rs = load(d, "s1")
    if rs:
        print("## S1 ad-hoc aggregation\n")
        rs.sort(key=lambda r: (r.get("space", 0), r["arm"], r["conc"]))
        print(table(["space", "arm", "conc", "QPS", "p50 ms", "p99 ms", "hit ratio", "to CH /s",
                     "CH avg ms", "CH p99 ms", "QC reads", "distinct keys", "errors"],
                    [[f(r.get("space")), r["arm"], f(r["conc"]), f(r["qps"]), lat(r, "p50"), lat(r, "p99"),
                      f(r.get("hit_ratio"), 3), per_s(r), srv(r, "avg_ms"), srv(r, "p99_ms"),
                      srv(r, "qc_read"), f(r.get("distinct_keys")), errs(r)] for r in rs]))

    rs = load(d, "kv")
    if rs:
        print("## Serving-store load (from cachelab.user_stats)\n")
        print(table(["target", "rows", "seconds", "rows/s", "Valkey used_memory", "errors"],
                    [[r.get("arm") or r.get("target", "?"), f(r.get("rows")), f(r.get("seconds")),
                      f(r.get("rows_per_s")), f(r.get("vk_used_memory")), errs(r)] for r in rs]))

    rs = load(d, "s2")
    if rs:
        print("## S2 point lookup\n")
        rs.sort(key=lambda r: (r["arm"], r["conc"]))
        print(table(["arm", "conc", "QPS", "p50 ms", "p99 ms", "p99.9 ms", "hit ratio", "to CH /s",
                     "CH avg ms", "CH p99 ms", "errors"],
                    [[r["arm"], f(r["conc"]), f(r["qps"]), lat(r, "p50"), lat(r, "p99"), lat(r, "p999"),
                      f(r.get("hit_ratio"), 3), per_s(r), srv(r, "avg_ms"), srv(r, "p99_ms"), errs(r)]
                     for r in rs]))

    rs = load(d, "s3")
    if rs:
        print("## S3 hot dashboard with 1 insert batch/s\n")
        rs.sort(key=lambda r: (r["conc"], r["arm"], r.get("ttl_s", 0)))
        print(table(["arm", "TTL s", "conc", "QPS", "p50 ms", "p99 ms", "to CH /s", "CH peak /s",
                     "stale p50 s", "stale p99 s", "QC reads", "CH CPU s", "errors"],
                    [[r["arm"], f(r.get("ttl_s")), f(r["conc"]), f(r["qps"]), lat(r, "p50"), lat(r, "p99"),
                      per_s(r), f(r.get("backend_peak_per_s")),
                      f((r.get("staleness_s") or {}).get("p50"), 1), f((r.get("staleness_s") or {}).get("p99"), 1),
                      srv(r, "qc_read"),
                      f(num((r.get("server") or {}).get("cpu_us") or 0) / 1e6, 1), errs(r)] for r in rs]))


if __name__ == "__main__":
    main()
