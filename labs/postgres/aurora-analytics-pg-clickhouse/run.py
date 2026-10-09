#!/usr/bin/env python3
"""Run the TPC-DS query set against one target and append the results to out/<target>/sf<N>-<phase>.csv.

    uv run --python 3.12 --with 'psycopg[binary]' --with duckdb==1.5.6 run.py \
        --target A|B|C|D|E|P|P-s3|R --sf N --phase correctness|scale \
        [--queries query01,14_1 ...] [--warm 3] [--timeout 600] \
        [--cold clear-cache|reboot|none] [--r-db PATH] [--pause 5] [--resume]

Targets: A-E Aurora (aurora_analytics foreign tables), P the pg_clickhouse front end over ClickHouse
MergeTree tables, P-s3 the same front end over the S3-engine tables, R DuckDB on the generator.
PG is for the local rehearsal only: plain PostgreSQL in the front-end image (database $PGPLAIN_DB,
default "plain", on the PGFRONT_* host) over the same data loaded by COPY.

The query set is work/queries/*.sql (02-queries.sh). Same query text, same order, concurrency 1.
scale = one cold run, then --warm warm runs; when the cold run is not ok the warm runs are recorded
as `skipped` (so a small target cannot burn queries x 4 x timeout on queries it cannot run).
Per run: all rows are fetched; canonical form = rows sorted, numbers rounded to 2 decimals,
NULL as \\N; sha256 of that, the row count and the per-column sums of the numeric columns.
Status: ok | timeout (SQLSTATE 57014) | oom | spill | syntax (SQLSTATE class 42) | error | skipped.
"""
import argparse
import csv
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

LAB_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.environ.get("LAB_OUT", os.path.join(LAB_DIR, "out"))
WORK_DIR = os.environ.get("LAB_WORK", os.path.join(LAB_DIR, "work"))

FIELDS = ["run_id", "ts_start", "ts_end", "target", "instance_class", "sf", "phase", "query", "run_type",
          "iter", "seconds", "status", "rows", "result_hash", "col_sums", "pushdown", "cache_hit_bytes",
          "s3_read_bytes", "versions", "error"]

AURORA_CLASSES = {
    "A": ("db.t4g.medium",),
    "B": ("db.t4g.large",),
    "C": ("db.serverless",),
    "D": ("db.r8g.large",),
    "E": ("db.r8gd.large", "db.r8gd.xlarge"),
}

# caches ClickHouse Cloud may or may not accept; every outcome is recorded
CH_CACHES = ["MARK CACHE", "UNCOMPRESSED CACHE", "INDEX MARK CACHE", "INDEX UNCOMPRESSED CACHE",
             "MMAP CACHE", "QUERY CACHE", "FILESYSTEM CACHE", "PAGE CACHE"]


# ---------------------------------------------------------------------------------------------------
def load_config():
    path = os.environ.get("CONFIG_ENV", os.path.join(LAB_DIR, "config.env"))
    if not os.path.isfile(path):
        sys.exit("config file not found: %s" % path)
    cfg = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if re.fullmatch(r"[A-Za-z0-9_]+", k):
                cfg[k] = v
    return cfg


def need(cfg, *keys):
    missing = [k for k in keys if not cfg.get(k)]
    if missing:
        sys.exit("missing or empty in config: %s" % " ".join(missing))


def query_key(name):
    m = re.fullmatch(r"query(\d+)(?:_(\d+))?", name)
    return (int(m.group(1)), int(m.group(2) or 0)) if m else (10 ** 6, 0)


def list_queries(selected):
    qdir = os.path.join(WORK_DIR, "queries")
    names = sorted((f[:-4] for f in os.listdir(qdir) if f.endswith(".sql")), key=query_key) \
        if os.path.isdir(qdir) else []
    if not names:
        sys.exit("no queries in %s (run ./02-queries.sh)" % qdir)
    if not selected or selected == ["all"]:
        return names
    want = []
    for t in selected:
        t = t.strip()
        if not t:
            continue
        t = t if t.startswith("query") else "query" + t.zfill(2)
        if t not in names:
            sys.exit("unknown query %s" % t)
        want.append(t)
    return sorted(set(want), key=query_key)


# ---------------------------------------------------------------------------------------------------
# canonical form of a result
def canon_value(v):
    if v is None:
        return "\\N"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float, Decimal)):
        try:
            d = v if isinstance(v, Decimal) else (Decimal(v) if isinstance(v, int) else Decimal(repr(v)))
            if not d.is_finite():
                return str(d)
            q = d.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            return "0.00" if q == 0 else format(q, "f")  # no "-0.00"
        except InvalidOperation:
            return str(v)
    if isinstance(v, (datetime.datetime, datetime.date, datetime.time)):
        return v.isoformat()
    if isinstance(v, (bytes, bytearray, memoryview)):
        return bytes(v).hex()
    return str(v).rstrip(" ")  # char(n) padding is not a difference


def summarize(rows):
    """-> (result_hash, row_count, col_sums_json)"""
    canon = sorted("|".join(canon_value(v) for v in r) for r in rows)
    h = hashlib.sha256("\n".join(canon).encode("utf-8", "replace")).hexdigest()
    sums = []
    ncol = len(rows[0]) if rows else 0
    for i in range(ncol):
        total, seen = Decimal(0), False
        for r in rows:
            v = r[i]
            if isinstance(v, bool) or v is None or not isinstance(v, (int, float, Decimal)):
                continue
            try:
                total += v if isinstance(v, (int, Decimal)) else Decimal(repr(v))
                seen = True
            except InvalidOperation:
                pass
        sums.append(format(total.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP), "f") if seen else None)
    return h, len(rows), json.dumps(sums)


# ---------------------------------------------------------------------------------------------------
class WatchdogTimeout(Exception):
    """The query outlived --timeout and was ended with pg_terminate_backend()."""


def classify(exc):
    """-> (status, message)"""
    msg = " ".join(str(exc).split())
    state = getattr(exc, "sqlstate", None) or ""
    low = msg.lower()
    kind = type(exc).__name__
    if ("[Aurora Analytics] Out of Memory Error" in msg or state == "53200" or "out of memory error" in low
            or "memory_limit_exceeded" in low or ("memory limit" in low and "exceeded" in low)
            or kind == "OutOfMemoryException"):
        return "oom", msg
    if (state == "53100" or "no space left" in low or ("spill" in low and ("space" in low or "disk" in low))
            or "out of disk" in low or (kind == "IOException" and "disk" in low)):
        return "spill", msg
    if state == "57014" or kind in ("InterruptException", "WatchdogTimeout"):
        return "timeout", msg
    if state.startswith("42") or kind in ("ParserException", "BinderException", "CatalogException"):
        return "syntax", msg
    return "error", msg


# ---------------------------------------------------------------------------------------------------
class Target:
    """One connection to one target; subclasses implement connect/execute/cold."""

    def __init__(self, args, cfg):
        self.args, self.cfg = args, cfg
        self.pushdown_cache = {}

    def instance_class(self):
        return ""

    def versions(self):
        return {}

    def stats(self):
        return None

    def explain(self, sql):
        return None

    def cold(self):
        pass

    def close(self):
        pass


class PgTarget(Target):
    def __init__(self, args, cfg):
        super().__init__(args, cfg)
        import psycopg  # noqa: F401  (imported here so py_compile and --help need nothing installed)
        self.psycopg = psycopg
        self.conn = None
        t = args.target
        self.is_aurora = t in AURORA_CLASSES
        if self.is_aurora:
            need(cfg, "AURORA_HOST", "AURORA_PORT", "AURORA_USER", "AURORA_DB", "AURORA_SECRET_ARN", "AWS_REGION",
                 "AURORA_CLASS")
            if cfg["AURORA_CLASS"] not in AURORA_CLASSES[t]:
                sys.exit("target %s expects AURORA_CLASS in %s, config.env has %s"
                         % (t, "/".join(AURORA_CLASSES[t]), cfg["AURORA_CLASS"]))
            self.password = self._aurora_password()
            self.params = dict(host=cfg["AURORA_HOST"], port=int(cfg["AURORA_PORT"]), user=cfg["AURORA_USER"],
                               dbname=cfg["AURORA_DB"], sslmode="require")
            self.search_path = "sf%d, public" % args.sf
        else:
            need(cfg, "PGFRONT_HOST", "PGFRONT_PORT", "PGFRONT_USER", "PGFRONT_PASSWORD", "PGFRONT_DB")
            self.password = cfg["PGFRONT_PASSWORD"]
            db = cfg["PGFRONT_DB"]
            if t == "PG":
                db = os.environ.get("PGPLAIN_DB", "plain")
            self.params = dict(host=cfg["PGFRONT_HOST"], port=int(cfg["PGFRONT_PORT"]), user=cfg["PGFRONT_USER"],
                               dbname=db, sslmode=cfg.get("PGFRONT_SSLMODE") or "require")
            self.search_path = "sf%d%s, public" % (args.sf, "_s3" if t == "P-s3" else "")
        self.ch_server = "ch_sf%d%s" % (args.sf, "_s3" if t == "P-s3" else "")
        self.connect()

    def _aurora_password(self):
        out = subprocess.run(
            ["aws", "secretsmanager", "get-secret-value", "--secret-id", self.cfg["AURORA_SECRET_ARN"],
             "--region", self.cfg["AWS_REGION"], "--query", "SecretString", "--output", "text"],
            check=True, capture_output=True, text=True, timeout=60).stdout
        return json.loads(out)["password"]

    def connect(self):
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:
                pass
        self.conn = self.psycopg.connect(password=self.password, connect_timeout=30, autocommit=True,
                                         **self.params)
        with self.conn.cursor() as cur:
            cur.execute("SET search_path = %s" % self.search_path)
            cur.execute("SET statement_timeout = %d" % int(self.args.timeout * 1000))

    def ensure(self):
        if self.conn is None or self.conn.closed or getattr(self.conn, "broken", False):
            self.connect()

    def instance_class(self):
        if self.is_aurora:
            return self.cfg["AURORA_CLASS"]
        if self.args.target == "PG":
            return "local-postgres"
        return "ch-cloud-%sGiB-x%s" % (self.cfg.get("CH_REPLICA_MEMORY_GB", "?"), self.cfg.get("CH_REPLICAS") or "?")

    def one(self, sql):
        with self.conn.cursor() as cur:
            cur.execute(sql)
            return cur.fetchone()

    def versions(self):
        v = {}
        for key, sql in [("server", "SELECT split_part(version(), ' (', 1)")]:
            try:
                v[key] = self.one(sql)[0]
            except Exception as e:
                v[key] = "?: %s" % str(e)[:80]
        extra = []
        if self.is_aurora:
            extra = [("aurora_analytics_ext", "SELECT extversion FROM pg_extension WHERE extname='aurora_analytics'"),
                     ("query_mem", "SHOW aurora_analytics.query_mem")]
        elif self.args.target in ("P", "P-s3"):
            extra = [("pg_clickhouse_ext", "SELECT extversion FROM pg_extension WHERE extname='pg_clickhouse'"),
                     ("clickhouse", "SELECT clickhouse_server_version('%s')" % self.ch_server),
                     ("session_settings", "SHOW pg_clickhouse.session_settings")]
        for key, sql in extra:
            try:
                v[key] = self.one(sql)[0]
            except Exception as e:
                v[key] = "?: %s" % str(e)[:80]
        return v

    def stats(self):
        if not self.is_aurora:
            return None
        try:
            r = self.one("SELECT coalesce(sum(analytics_cache_hit_bytes),0)::bigint, "
                         "coalesce(sum(analytics_remote_read_bytes),0)::bigint FROM aurora_analytics_stat_statements()")
            return int(r[0]), int(r[1])
        except Exception:
            return None

    def execute(self, sql):
        # Watchdog: on Aurora aurora_analytics 1.0.0 (18.6, 2026-10-09) neither statement_timeout nor
        # pg_cancel_backend() stops a running foreign-table query, and it keeps running after the client
        # goes away; pg_terminate_backend() does stop it. So --timeout is enforced from a second connection.
        self.ensure()
        pid = self.conn.info.backend_pid
        fired = threading.Event()

        def terminate():
            fired.set()
            try:
                with self.psycopg.connect(password=self.password, connect_timeout=30, autocommit=True,
                                          **self.params) as c2:
                    c2.execute("SELECT pg_terminate_backend(%s)", (pid,))
            except Exception as e:  # noqa: BLE001
                print("watchdog: pg_terminate_backend(%d) failed: %s" % (pid, e), file=sys.stderr, flush=True)

        timer = threading.Timer(self.args.timeout + 2, terminate)
        timer.daemon = True
        timer.start()
        try:
            with self.conn.cursor() as cur:
                cur.execute(sql)
                return cur.fetchall()
        except Exception as e:
            if fired.is_set():
                raise WatchdogTimeout("terminated by the watchdog (pg_terminate_backend) after %ds; "
                                      "statement_timeout did not stop it: %s" % (self.args.timeout, e)) from e
            raise
        finally:
            timer.cancel()

    def explain(self, sql):
        if self.args.target not in ("P", "P-s3"):
            return None
        if sql in self.pushdown_cache:
            return self.pushdown_cache[sql]
        try:
            self.ensure()
            with self.conn.cursor() as cur:
                cur.execute("EXPLAIN (VERBOSE) " + sql)
                lines = [r[0] for r in cur.fetchall()]
            res = (classify_plan(lines), "\n".join(lines))
        except Exception as e:
            res = ("n/a", "EXPLAIN failed: %s" % e)
        self.pushdown_cache[sql] = res
        return res

    def cold(self):
        mode = self.args.cold
        if mode == "none":
            return
        if self.is_aurora:
            if mode == "reboot":
                iid = self.cfg.get("AURORA_INSTANCE_ID")
                need(self.cfg, "AURORA_INSTANCE_ID", "AWS_REGION")
                try:
                    self.conn.close()
                except Exception:
                    pass
                subprocess.run(["aws", "rds", "reboot-db-instance", "--db-instance-identifier", iid,
                                "--region", self.cfg["AWS_REGION"]], check=True, capture_output=True, timeout=120)
                time.sleep(30)  # the status flips to "rebooting" after a short delay
                subprocess.run(["aws", "rds", "wait", "db-instance-available", "--db-instance-identifier", iid,
                                "--region", self.cfg["AWS_REGION"]], check=True, timeout=1800)
                self.connect()
            else:
                self.ensure()
                self.one("SELECT aurora_analytics_clear_cache()")
        elif self.args.target in ("P", "P-s3"):
            self.ensure()
            notes = []
            for c in CH_CACHES:
                try:
                    with self.conn.cursor() as cur:
                        cur.execute("CALL clickhouse_perform(%s, %s)" % (_lit(self.ch_server), _lit("SYSTEM DROP " + c)))
                    notes.append("SYSTEM DROP %s: ok" % c)
                except Exception as e:
                    notes.append("SYSTEM DROP %s: refused: %s" % (c, " ".join(str(e).split())[:200]))
            d = os.path.join(OUT_DIR, self.args.target)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "cold-caches-sf%d.txt" % self.args.sf), "w") as f:
                f.write("\n".join(notes) + "\n")
        # PG (rehearsal): nothing to drop

    def close(self):
        try:
            self.conn.close()
        except Exception:
            pass


def _lit(s):
    return "'" + s.replace("'", "''") + "'"


def classify_plan(lines):
    """full = one Foreign Scan and nothing else (no local Agg/Join/Sort/CTE/subplan above it)."""
    nodes = [l for l in lines if re.match(r"^\s*(->\s*)?[A-Z][\w ]*?\s+\(cost=", l)]
    extra = [l for l in lines if re.match(r"^\s*(InitPlan|SubPlan|CTE )", l)]
    if len(nodes) == 1 and nodes[0].strip().startswith("Foreign Scan") and not extra:
        return "full"
    return "partial"


class DuckTarget(Target):
    def __init__(self, args, cfg):
        super().__init__(args, cfg)
        import duckdb
        self.duckdb = duckdb
        self.path = args.r_db or os.path.join(WORK_DIR, "tpcds-sf%d.duckdb" % args.sf)
        if not os.path.isfile(self.path):
            sys.exit("DuckDB file not found: %s (run ./01-generate.sh)" % self.path)
        self.con = None
        self.connect()

    def connect(self):
        if self.con is not None:
            self.con.close()
        self.con = self.duckdb.connect(self.path, read_only=True)

    def instance_class(self):
        return "generator-duckdb"

    def versions(self):
        return {"duckdb": self.duckdb.__version__}

    def execute(self, sql):
        timer = threading.Timer(self.args.timeout, self.con.interrupt)
        timer.start()
        try:
            return self.con.execute(sql).fetchall()
        finally:
            timer.cancel()

    def cold(self):
        if self.args.cold != "none":
            self.connect()

    def close(self):
        self.con.close()


# ---------------------------------------------------------------------------------------------------
def read_done(path):
    done = {}
    if os.path.isfile(path):
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                done[(r["query"], r["run_type"], r["iter"])] = r["status"]
    return done


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", required=True, choices=["A", "B", "C", "D", "E", "P", "P-s3", "R", "PG"])
    ap.add_argument("--sf", type=int, required=True)
    ap.add_argument("--phase", required=True, choices=["correctness", "scale"])
    ap.add_argument("--queries", default="all", help="comma list, e.g. query01,14_1 (default all)")
    ap.add_argument("--warm", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--cold", default="clear-cache", choices=["clear-cache", "reboot", "none"])
    ap.add_argument("--r-db", default="")
    ap.add_argument("--pause", type=float, default=5.0, help="seconds between queries")
    ap.add_argument("--resume", action="store_true")
    args = ap.parse_args()

    cfg = {} if args.target == "R" else load_config()
    tgt = DuckTarget(args, cfg) if args.target == "R" else PgTarget(args, cfg)
    queries = list_queries([q for q in args.queries.split(",")])

    out_dir = os.path.join(OUT_DIR, args.target)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "sf%d-%s.csv" % (args.sf, args.phase))
    done = read_done(path) if args.resume else {}
    new_file = not os.path.isfile(path)
    run_id = "%s-%s-sf%d-%s" % (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"), args.target, args.sf,
                                args.phase)
    versions = json.dumps(tgt.versions(), sort_keys=True)
    inst = tgt.instance_class()
    explain_dir = os.path.join(out_dir, "explain-sf%d" % args.sf)

    f = open(path, "a", newline="")
    w = csv.DictWriter(f, fieldnames=FIELDS)
    if new_file:
        w.writeheader()
        f.flush()

    def now_iso():
        return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

    def record(q, run_type, it, **kw):
        row = {k: "" for k in FIELDS}
        row.update(run_id=run_id, target=args.target, instance_class=inst, sf=args.sf, phase=args.phase, query=q,
                   run_type=run_type, iter=it, versions=versions)
        row.update(kw)
        w.writerow(row)
        f.flush()
        print("%-10s %-5s %-4s %-8s %9s s  rows=%-6s %s" % (q, run_type, it, row["status"],
                                                          row["seconds"], row["rows"], row["pushdown"]),
              flush=True)

    def one_run(q, sql, run_type, it, pushdown):
        before = tgt.stats()
        ts = now_iso()
        t0 = time.monotonic()
        try:
            rows = tgt.execute(sql)
            secs = time.monotonic() - t0
            h, n, sums = summarize(rows)
            status, err = "ok", ""
        except Exception as e:  # noqa: BLE001 - every failure is a result
            secs = time.monotonic() - t0
            status, err = classify(e)
            h, n, sums = "", "", ""
        after = tgt.stats()
        hit = read = ""
        if before and after:
            hit, read = after[0] - before[0], after[1] - before[1]
        record(q, run_type, it, ts_start=ts, ts_end=now_iso(), seconds="%.3f" % secs, status=status, rows=n,
               result_hash=h, col_sums=sums, pushdown=pushdown, cache_hit_bytes=hit, s3_read_bytes=read,
               error=err[:500])
        return status

    try:
        for qi, q in enumerate(queries):
            with open(os.path.join(WORK_DIR, "queries", q + ".sql")) as qf:
                sql = qf.read()
            pushdown = ""
            ex = tgt.explain(sql)
            if ex:
                pushdown = ex[0]
                os.makedirs(explain_dir, exist_ok=True)
                with open(os.path.join(explain_dir, q + ".txt"), "w") as pf:
                    pf.write(ex[1] + "\n")
            if args.phase == "correctness":
                if (q, "single", "0") not in done:
                    one_run(q, sql, "single", 0, pushdown)
            else:
                cold_status = done.get((q, "cold", "0"))
                if cold_status is None:
                    tgt.cold()
                    cold_status = one_run(q, sql, "cold", 0, pushdown)
                for it in range(1, args.warm + 1):
                    if (q, "warm", str(it)) in done:
                        continue
                    if cold_status not in (None, "ok"):
                        record(q, "warm", it, status="skipped", pushdown=pushdown,
                               error="cold run was %s" % cold_status)
                    else:
                        one_run(q, sql, "warm", it, pushdown)
            if args.pause and qi < len(queries) - 1:
                time.sleep(args.pause)
    finally:
        f.close()
        tgt.close()
    print("wrote %s" % path)


if __name__ == "__main__":
    main()
