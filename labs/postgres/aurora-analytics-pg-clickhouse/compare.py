#!/usr/bin/env python3
"""Compare every target's correctness CSV with R (DuckDB, the reference) and write out/report-q2.md.

    python3 compare.py --sf 1 [--targets A,B,P,...] [--fail-on-mismatch] [--tag ice]

Per query and target: match (same result hash as R) | mismatch | syntax | error (timeout, oom, spill, error) |
not run (the target's CSV has no row for the query, e.g. a --queries subset). Times are not compared. For a mismatch the report shows both row counts and whether the
per-column sums agree, which tells a wrong answer from a tie order at a LIMIT or a rounding edge.
--tag TAG compares the CSVs run.py wrote with --tag TAG (sf<N>-correctness-TAG.csv) of the targets with the untagged R
reference, and writes out/report-q2-TAG.md. Without it nothing changes.
The last row per query wins (the CSVs are append-only; a re-run replaces the verdict).
"""
import argparse
import csv
import json
import os
import re
import sys
from decimal import Decimal, InvalidOperation

LAB_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.environ.get("LAB_OUT", os.path.join(LAB_DIR, "out"))
ORDER = ["A", "B", "C", "D", "E", "P", "P-s3", "PG"]


def query_key(name):
    m = re.fullmatch(r"query(\d+)(?:_(\d+))?", name)
    return (int(m.group(1)), int(m.group(2) or 0)) if m else (10 ** 6, 0)


def load(target, sf, tag=""):
    path = os.path.join(OUT_DIR, target, "sf%d-correctness%s.csv" % (sf, "-" + tag if tag else ""))
    if not os.path.isfile(path):
        return None
    rows = {}
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            rows[r["query"]] = r
    return rows


def sums_close(a, b):
    try:
        x, y = json.loads(a), json.loads(b)
    except (TypeError, ValueError):
        return False
    if len(x) != len(y):
        return False
    for u, v in zip(x, y):
        if (u is None) != (v is None):
            return False
        if u is None:
            continue
        try:
            du, dv = Decimal(u), Decimal(v)
        except InvalidOperation:
            return False
        if abs(du - dv) > max(Decimal("0.05"), abs(dv) * Decimal("0.000001")):
            return False
    return True


def duck_version(ref):
    for r in ref.values():
        try:
            return json.loads(r["versions"]).get("duckdb", "?")
        except ValueError:
            pass
    return "?"


def verdict(ref, row):
    """-> (verdict, detail)"""
    if row is None:
        return "not run", ""
    st = row["status"]
    if st == "syntax":
        return "syntax", row["error"][:120]
    if st != "ok":
        return "error", "%s: %s" % (st, row["error"][:120])
    if ref is None or ref["status"] != "ok":
        return "error", "no reference"
    if row["result_hash"] == ref["result_hash"]:
        return "match", ""
    close = sums_close(row["col_sums"], ref["col_sums"])
    return "mismatch", "rows %s vs R %s; column sums %s" % (row["rows"], ref["rows"],
                                                           "agree" if close else "differ")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sf", type=int, required=True)
    ap.add_argument("--targets", default="")
    ap.add_argument("--fail-on-mismatch", action="store_true")
    ap.add_argument("--tag", default="", help="compare the CSVs written with run.py --tag TAG (R stays untagged)")
    a = ap.parse_args()

    ref = load("R", a.sf)
    if ref is None:
        sys.exit("no reference: %s" % os.path.join(OUT_DIR, "R", "sf%d-correctness.csv" % a.sf))
    wanted = [t for t in a.targets.split(",") if t] or ORDER
    data = {}
    for t in wanted:
        d = load(t, a.sf, a.tag)
        if d is not None:
            data[t] = d
    if not data:
        sys.exit("no target CSV found for sf%d under %s" % (a.sf, OUT_DIR))
    targets = [t for t in ORDER if t in data] + [t for t in data if t not in ORDER]

    queries = sorted(ref, key=query_key)
    res = {t: {q: verdict(ref.get(q), data[t].get(q)) for q in queries} for t in targets}

    out = ["# Q2 - does each target return the correct answer (SF%d)" % a.sf, "",
           "Reference: R = DuckDB %s over the same generated data. Result = rows sorted, numbers rounded to "
           "2 decimals, NULL as `\\N`, sha256 compared. %d queries in the reference." % (
               duck_version(ref), len(queries)), "",
           "| target | match | mismatch | syntax | error | not run |", "|---|---|---|---|---|---|"]
    for t in targets:
        c = {k: sum(1 for q in queries if res[t][q][0] == k) for k in ("match", "mismatch", "syntax", "error", "not run")}
        out.append("| %s | %d | %d | %d | %d | %d |" % (t, c["match"], c["mismatch"], c["syntax"], c["error"],
                                                       c["not run"]))
    out += ["", "| query | R rows | " + " | ".join(targets) + " |", "|---|---|" + "---|" * len(targets)]
    for q in queries:
        out.append("| %s | %s | %s |" % (q, ref[q]["rows"] or ref[q]["status"],
                                         " | ".join(res[t][q][0] for t in targets)))
    bad = [(t, q) for t in targets for q in queries if res[t][q][0] not in ("match", "not run")]
    if bad:
        out += ["", "## Not matching", "", "| target | query | verdict | detail |", "|---|---|---|---|"]
        for t, q in bad:
            v, d = res[t][q]
            out.append("| %s | %s | %s | %s |" % (t, q, v, d.replace("|", "/")))
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "report-q2%s.md" % ("-" + a.tag if a.tag else ""))
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print("\n".join(out[4:6 + len(targets)]))
    print("%d not matching of %d x %d; wrote %s" % (len(bad), len(queries), len(targets), path))
    if a.fail_on_mismatch and bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
