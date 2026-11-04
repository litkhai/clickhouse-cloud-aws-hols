#!/usr/bin/env bash
# The whole lab in the order it was run on 2026-11-04 (README "Results"). Each step is also a file you can run alone.
# Needs: terraform, uv, clickhouse (client), aws CLI, curl, python3; AWS credentials for ap-northeast-2;
#   CHC_KEY CHC_SECRET ORG_ID SERVICE_ID CH_HOST CH_USER CH_PASSWORD — an existing ClickHouse Cloud service
#   in the same region whose IP access list lets you in. Attaching the first UDF restarts it: use a test service.
#   terraform/terraform.tfvars (owner, ttl, allowed_cidr_blocks; create_udf_user = false if an SCP forbids IAM users).
set -euo pipefail
cd "$(dirname "$0")"
: "${CHC_KEY:?}" "${CHC_SECRET:?}" "${ORG_ID:?}" "${SERVICE_ID:?}" "${CH_HOST:?}" "${CH_USER:?}" "${CH_PASSWORD:?}"
USERS=${USERS:-1000000} TENANTS=${TENANTS:-8}
q() { clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" "$@"; }
pg() { uv run -q --with 'psycopg[binary]' pg.py "$@"; }
step() { printf '\n== %s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

step "terraform apply (Aurora PostgreSQL 16 + logical replication, KMS key, kms:Decrypt-only principal)"
terraform -chdir=terraform init -input=false >/dev/null
terraform -chdir=terraform apply -auto-approve -input=false
export PGHOST=$(terraform -chdir=terraform output -raw pg_host) PGUSER=$(terraform -chdir=terraform output -raw pg_user)
export PGPASSWORD=$(terraform -chdir=terraform output -raw pg_password) PGDATABASE=app
export LAB_CP_PASSWORD=${LAB_CP_PASSWORD:-$(openssl rand -hex 16)}

step "source schema, ClickPipes user and publication"
pg -c "SHOW rds.logical_replication"
pg -f pg/01-schema.sql

step "generate $USERS users ($TENANTS tenants, one data key each) and COPY into Aurora"
uv run -q --with boto3 --with cryptography --with 'psycopg[binary]' gen.py --users "$USERS" --tenants "$TENANTS" --name run --pg

step "ClickHouse: SQL functions, targets, plaintext keys for path B, expected values"
q -q "CREATE DATABASE IF NOT EXISTS raw"
q --queries-file sql/10-functions.sql
q --queries-file sql/20-targets.sql
q -q "INSERT INTO keys.plain_keys FORMAT TSV" < out/run/plain_keys.tsv
q --multiquery -q "CREATE DATABASE IF NOT EXISTS lab; CREATE TABLE IF NOT EXISTS lab.expected (user_id String, props String, email String, phone String) ENGINE = MergeTree ORDER BY user_id"
q -q "INSERT INTO lab.expected FORMAT TSV" < out/run/expected.tsv

step "UDF kms_unwrap: build, upload, attach (first UDF = rolling restart)"
./udf-deploy.sh

step "ClickPipe (Postgres CDC) -> raw.users, wait for Running"
./clickpipe-create.sh

step "decrypting views, backfill (timed), checks"
q --queries-file sql/30-mvs.sql
q --time --queries-file sql/31-backfill.sql
q --time --queries-file sql/32-backfill-b.sql
for t in users_a users_b; do q --param_t=$t --queries-file sql/40-verify.sql; done
q --param_t=users_a --queries-file sql/41-types.sql
echo "next: ./cdc-changes.sh (updates, deletes, per-row keys), then sql/42-verify-final.sql, sql/50-exposure.sql"
