#!/usr/bin/env python3
"""Generate users inside Aurora with pgcrypto (pg/10-upsert.sql), in chunks, and export what ClickHouse should hold.

  load.py upsert --from 0 --to 999999 --ver 1 [--rev 0] [--chunk 50000]
  load.py expected > out/expected.tsv        # user_id, tenant_id, n, props_md5, ver
  load.py check                              # decrypt one stored value here and compare with the generator

The data keys are read from out/keys/v*.json (keys.py) and set as settings of this session only.
Env: PGHOST PGUSER PGPASSWORD (database app). Run with: uv run --with 'psycopg[binary]' --with cryptography load.py …
"""
import argparse
import base64
import glob
import json
import os
import sys
import time

import psycopg

HERE = os.path.dirname(os.path.abspath(__file__))


def connect():
    c = psycopg.connect(dbname="app", sslmode="require", autocommit=True)
    for path in sorted(glob.glob(os.path.join(HERE, "out", "keys", "v*.json"))):
        ver = os.path.basename(path)[1:-5]
        for col, k in json.load(open(path)).items():
            c.execute("SELECT set_config(%s, %s, false), set_config(%s, %s, false)",
                      (f"lab.key_{col}_{ver}", k["key"], f"lab.iv_{col}_{ver}", k["iv"]))
    return c


def upsert(a):
    sql = open(os.path.join(HERE, "pg", "10-upsert.sql")).read()
    t0 = time.time()
    with connect() as c:
        for lo in range(a.frm, a.to + 1, a.chunk):
            hi = min(lo + a.chunk - 1, a.to)
            c.execute(sql, {"a": lo, "b": hi, "ver": a.ver, "rev": a.rev})
            print(f"  {hi + 1 - a.frm:>9} rows  {time.time() - t0:6.1f} s", file=sys.stderr)
    print(f"upsert {a.frm}..{a.to} ver {a.ver} rev {a.rev}: {time.time() - t0:.1f} s")


def expected(_):
    with connect() as c, c.cursor().copy(
            "COPY (SELECT user_id, tenant_id, n, props_md5, ver FROM lab_expected ORDER BY user_id) TO STDOUT") as cp:
        for chunk in cp:
            sys.stdout.buffer.write(chunk)


def check(_):
    """pgcrypto and the decrypt API must agree on the format: decrypt one value with Python's cryptography."""
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    with connect() as c:
        n, tenant, stored, email = c.execute(
            "SELECT n, tenant_id, (SELECT encrypted_user_properties FROM users u WHERE u.user_id = x.user_id), "
            "(SELECT encrypted_email FROM users u WHERE u.user_id = x.user_id) FROM lab_expected x ORDER BY user_id LIMIT 1").fetchone()
        plain = c.execute("SELECT lab_plain(%s, 0), lab_email(%s)", (n, n)).fetchone()
    ok = 0
    for col, value, want in [("props", stored["city"], plain[0]["city"]), ("props", stored["memo"], plain[0]["memo"]),
                             ("email", email, plain[1])]:
        ver, b64 = value.split(":", 1)
        k = json.load(open(os.path.join(HERE, "out", "keys", f"v{ver}.json")))[col]
        d = Cipher(algorithms.AES(bytes.fromhex(k["key"])), modes.CBC(bytes.fromhex(k["iv"]))).decryptor()
        u = padding.PKCS7(128).unpadder()
        got = (u.update(d.update(base64.b64decode(b64)) + d.finalize()) + u.finalize()).decode()
        print(f"{col}: {value[:24]}… -> {got!r} (expected {want!r})")
        ok += got == want
    assert ok == 3, "pgcrypto output does not decrypt as AES-256-CBC/PKCS#7 with the fixed IV"
    print("format check: 3/3")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("upsert")
    u.add_argument("--from", dest="frm", type=int, required=True)
    u.add_argument("--to", type=int, required=True)
    u.add_argument("--ver", type=int, required=True)
    u.add_argument("--rev", type=int, default=0)
    u.add_argument("--chunk", type=int, default=50000)
    sub.add_parser("expected")
    sub.add_parser("check")
    a = ap.parse_args()
    {"upsert": upsert, "expected": expected, "check": check}[a.cmd](a)


if __name__ == "__main__":
    main()
