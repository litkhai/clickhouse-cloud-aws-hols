#!/usr/bin/env python3
"""Generate users whose jsonb holds AES-256-CBC values under KMS-wrapped data keys.

Envelope encryption, as an application would do it:
  1. KMS GenerateDataKey (AES_256) per key_ref -> plaintext key + encrypted blob.
  2. Each sensitive value -> "enc:v1:" + base64(iv(16 B) || AES-256-CBC(PKCS7)).
  3. Only the encrypted blob is stored (data_keys table); the plaintext key is dropped.

--key-mode tenant : one data key per tenant (KMS calls = tenants)
--key-mode row    : one data key per user   (KMS calls = users)

Each users row carries its encrypted data key (edk, base64 KMS blob) next to the data, the usual
envelope layout — so a consumer needs no join to find the key.

Writes:
  out/<name>/users.tsv       user_id, tenant_id, edk, external_user_id, email_enc, phone_enc, properties (jsonb text), updated_at
  out/<name>/plain_keys.tsv  key id (sha256 of edk, hex), plaintext data key (hex) — only for the "key kept in ClickHouse" path; sensitive
  out/<name>/expected.tsv    user_id, plaintext properties as canonical JSON (string values), email, phone — for checks
With --pg, also COPYs users into Postgres (env PGHOST PGUSER PGPASSWORD PGDATABASE).

Run with: uv run --with boto3 --with cryptography [--with 'psycopg[binary]'] gen.py ...
"""
import argparse
import base64
import hashlib
import json
import os
import random
import sys
import time

import boto3
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

PLANS = ["free", "basic", "pro", "enterprise"]
CITIES = ["서울", "부산", "인천", "대구", "광주", "대전", "Tokyo", "Singapore"]


def enc(key, plaintext):
    iv = os.urandom(16)
    p = padding.PKCS7(128).padder()
    data = p.update(plaintext.encode()) + p.finalize()
    e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return "enc:v1:" + base64.b64encode(iv + e.update(data) + e.finalize()).decode()


def tsv(v):
    return str(v).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--users", type=int, default=10000)
    ap.add_argument("--tenants", type=int, default=2)
    ap.add_argument("--key-mode", choices=["tenant", "row"], default="tenant")
    ap.add_argument("--key-alias", default="alias/kms-decrypt-cdc-lab")
    ap.add_argument("--name", default="local")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--offset", type=int, default=0, help="first user number (to add users later)")
    ap.add_argument("--pg", action="store_true")
    ap.add_argument("--pg-table", default="users", help="COPY target (a staging table for updates)")
    a = ap.parse_args()

    random.seed(a.seed)
    kms = boto3.client("kms")
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", a.name)
    os.makedirs(out, exist_ok=True)

    keys = {}  # key_ref -> (plaintext, blob_b64)
    kms_calls = 0
    t0 = time.time()

    def key_for(ref):
        nonlocal kms_calls
        if ref not in keys:
            r = kms.generate_data_key(KeyId=a.key_alias, KeySpec="AES_256")
            kms_calls += 1
            keys[ref] = (r["Plaintext"], base64.b64encode(r["CiphertextBlob"]).decode())
        return keys[ref][0]

    users, expected = [], []
    for i in range(a.offset, a.offset + a.users):
        uid = f"u{i:09d}"
        tenant = f"t{i % a.tenants:03d}"
        ref = tenant if a.key_mode == "tenant" else uid
        k = key_for(ref)
        email = f"user{i}@example.com"
        phone = f"010-{random.randint(1000, 9999)}-{random.randint(1000, 9999)}"
        name = random.choice(["김민준", "이서연", "박지호", "최수아", "Alex Kim", "Mina Park"])
        birthday = f"19{random.randint(60, 99)}-{random.randint(1, 12):02d}-{random.randint(1, 28):02d}"
        plain = {
            "plan": random.choice(PLANS),
            "visits": random.randint(0, 500),
            "lastVisitedAt": f"2026-{random.randint(1, 10):02d}-{random.randint(1, 28):02d}T{random.randint(0, 23):02d}:00:00Z",
            "marketingOptIn": random.random() < 0.6,
            "city": random.choice(CITIES),
            "name": name,           # encrypted
            "birthday": birthday,   # encrypted
            "memo": f"메모 {i}",     # encrypted
        }
        stored = dict(plain)
        for f in ("name", "birthday", "memo"):
            stored[f] = enc(k, plain[f])
        users.append([uid, tenant, keys[ref][1], f"ext-{i}", enc(k, email), enc(k, phone),
                      json.dumps(stored, ensure_ascii=False), "2026-11-04 00:00:00+00"])
        canon = {kk: (json.dumps(v) if isinstance(v, bool) else str(v)) for kk, v in plain.items()}
        expected.append([uid, json.dumps(canon, ensure_ascii=False, sort_keys=True), email, phone])

    with open(os.path.join(out, "plain_keys.tsv"), "w") as f:
        for ref, (plain, blob) in keys.items():  # key id = sha256(edk) — survives key rotation
            f.write(f"{hashlib.sha256(blob.encode()).hexdigest().upper()}\t{plain.hex()}\n")
    with open(os.path.join(out, "users.tsv"), "w") as f:
        for r in users:
            f.write("\t".join(tsv(v) for v in r) + "\n")
    with open(os.path.join(out, "expected.tsv"), "w") as f:
        for r in expected:
            f.write("\t".join(tsv(v) for v in r) + "\n")
    print(f"users={a.users} tenants={a.tenants} key_mode={a.key_mode} "
          f"GenerateDataKey calls={kms_calls} seconds={time.time() - t0:.1f} out={out}")

    if a.pg:
        import psycopg
        with psycopg.connect(sslmode="require") as c, c.cursor() as cur:
            for t, path in ((a.pg_table, "users.tsv"),):
                with open(os.path.join(out, path), "rb") as f, cur.copy(f"COPY {t} FROM STDIN") as cp:
                    while chunk := f.read(1 << 20):
                        cp.write(chunk)
            c.commit()
        print("COPY into Postgres done")


if __name__ == "__main__":
    sys.exit(main())
