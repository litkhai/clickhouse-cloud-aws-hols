#!/usr/bin/env python3
"""Run one sql/NN-*.sql file against ClickHouse Cloud, statement by statement.

Usage: ./ch_run.py sql/20-serving.sql [--only name,name] [--runs N]
Statements are separated by `-- name: <id>` lines. {{BUCKET}}, {{REGION}} and {{CH_ROLE}} are
replaced from .env and terraform outputs. Each statement gets query_id `hol-<id>-<run>-<utc>` so
sql/90-query-stats.sql can read its duration, rows and bytes from system.query_log. A statement
that fails is printed with its error and the run continues (the read-path probes expect errors).
Output goes to the terminal and to results/raw/<file>.log.
"""
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent


def env():
    vals = dict(os.environ)
    for line in (HERE / ".env").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            vals.setdefault(k.strip(), v.strip())
    tf = HERE / "terraform"
    for key, out in (("BUCKET", "bucket"), ("CH_ROLE", "chc_role_arn")):
        if key not in vals:
            vals[key] = subprocess.run(["terraform", "-chdir=" + str(tf), "output", "-raw", out],
                                       capture_output=True, text=True, check=True).stdout.strip()
    vals.setdefault("REGION", vals.get("AWS_REGION", "ap-northeast-2"))
    return vals


def statements(path, vals):
    text = path.read_text()
    for key in ("BUCKET", "REGION", "CH_ROLE"):
        text = text.replace("{{" + key + "}}", vals[key])
    parts = re.split(r"^-- name: *(\S+) *$", text, flags=re.M)
    return [(parts[i], parts[i + 1].strip()) for i in range(1, len(parts), 2)]


def main():
    args = sys.argv[1:]
    path = Path(args[0])
    only = set(args[args.index("--only") + 1].split(",")) if "--only" in args else None
    runs = int(args[args.index("--runs") + 1]) if "--runs" in args else 1
    vals = env()
    log_dir = HERE / "results" / "raw"
    log_dir.mkdir(parents=True, exist_ok=True)
    log = open(log_dir / (path.stem + ".log"), "a")
    base = ["clickhouse", "client", "--secure", "--host", vals["CH_HOST"], "--user", vals["CH_USER"],
            "--password", vals["CH_PASSWORD"], "--format", "PrettyCompactMonoBlock", "--multiquery"]
    for name, sql in statements(path, vals):
        if only and name not in only:
            continue
        for run in range(1, runs + 1):
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
            qid = f"hol-{name}-{run}-{stamp}"
            t0 = time.time()
            p = subprocess.run(base + ["--query_id", qid, "--query", sql], capture_output=True, text=True)
            took = time.time() - t0
            err = "\n".join(l for l in p.stderr.splitlines() if "Unknown settings" not in l)
            shown = sql.replace(vals["CH_ROLE"], "<CH_ROLE>")
            block = (f"### {name} run={run} utc={stamp} query_id={qid} client_seconds={took:.2f} "
                     f"exit={p.returncode}\n{shown}\n{p.stdout}{err}\n")
            print(block, flush=True)
            log.write(block)
            log.flush()


if __name__ == "__main__":
    main()
