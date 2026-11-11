#!/usr/bin/env python3
"""Run SQL against the lab's Aurora writer: pg.py -f file.sql | pg.py -c 'SQL'. Env: PGHOST PGUSER PGPASSWORD PGDATABASE, LAB_CP_PASSWORD."""
import os, sys, psycopg
args = sys.argv[1:]
sql = open(args[1]).read() if args[0] == "-f" else args[1]
with psycopg.connect(sslmode="require", autocommit=True) as c:
    if os.environ.get("LAB_CP_PASSWORD"):
        c.execute("SELECT set_config('lab.cp_password', %s, false)", (os.environ["LAB_CP_PASSWORD"],))
    cur = c.execute(sql)
    if cur.description:
        for r in cur.fetchall():
            print("\t".join("" if v is None else str(v) for v in r))
