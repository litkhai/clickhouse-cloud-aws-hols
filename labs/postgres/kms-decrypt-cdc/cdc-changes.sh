#!/usr/bin/env bash
# CDC phase: 10,000 updates with rotated data keys, 1,000 deletes, 10,000 new users with one data key per row.
# Needs the AWS, Postgres and ClickHouse env. Expected values go to lab.expected_r (ReplacingMergeTree by ver).
set -euo pipefail
cd "$(dirname "$0")"
q() { clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" "$@"; }
pg() { uv run -q --with 'psycopg[binary]' pg.py "$@"; }
gen() { uv run -q --with boto3 --with cryptography --with 'psycopg[binary]' gen.py "$@"; }

pg -c "CREATE TABLE IF NOT EXISTS users_stage (LIKE users)"; pg -c "TRUNCATE users_stage"
gen --users 10000 --offset 0 --tenants 8 --seed 7 --name upd --pg --pg-table users_stage
gen --users 10000 --offset 2000000 --tenants 1 --key-mode row --seed 9 --name rowkeys
q -q "INSERT INTO keys.plain_keys FORMAT TSV" < out/upd/plain_keys.tsv      # B learns the rotated keys
q -q "INSERT INTO keys.plain_keys FORMAT TSV" < out/rowkeys/plain_keys.tsv  # and the 10,000 per-row keys
q -q "SYSTEM RELOAD DICTIONARY keys.plain_key_dict"
q -q "INSERT INTO lab.expected_r (user_id, props, email, phone, ver) SELECT *, 1 FROM input('user_id String, props String, email String, phone String') FORMAT TSV" < out/upd/expected.tsv
q -q "INSERT INTO lab.expected_r (user_id, props, email, phone, ver) SELECT *, 0 FROM input('user_id String, props String, email String, phone String') FORMAT TSV" < out/rowkeys/expected.tsv
q -q "INSERT INTO lab.expected_r (user_id, props, email, phone, ver, deleted) SELECT user_id, props, email, phone, 2, 1 FROM lab.expected WHERE user_id BETWEEN 'u000990000' AND 'u000990999'"
date -u +"%T changes start"
pg -f pg/20-apply-updates.sql
pg -c "DELETE FROM users WHERE user_id BETWEEN 'u000990000' AND 'u000990999'"
uv run -q --with 'psycopg[binary]' python3 - <<'PY'
import psycopg
with psycopg.connect(sslmode="require") as c, c.cursor() as cur, open("out/rowkeys/users.tsv","rb") as f, cur.copy("COPY users FROM STDIN") as cp:
    while chunk := f.read(1 << 20): cp.write(chunk)
PY
date -u +"%T changes committed"
