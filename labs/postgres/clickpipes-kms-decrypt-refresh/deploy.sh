#!/usr/bin/env bash
# The whole lab in the order it ran on 2026-11-04 (RUN-2026-11-04.md). Each step is also a file you can run alone.
# Needs: terraform, uv, clickhouse (client), aws CLI, curl, python3; AWS credentials for ap-northeast-2;
#   CHC_KEY CHC_SECRET ORG_ID SERVICE_ID CH_HOST CH_USER CH_PASSWORD — a ClickHouse Cloud test service in the same
#   region (attaching the first UDF restarts it); terraform/terraform.tfvars (see the .example).
set -euo pipefail
cd "$(dirname "$0")"
: "${CHC_KEY:?}" "${CHC_SECRET:?}" "${ORG_ID:?}" "${SERVICE_ID:?}" "${CH_HOST:?}" "${CH_USER:?}" "${CH_PASSWORD:?}"
USERS=${USERS:-1000000} TENANTS=${TENANTS:-8}
q() { clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" "$@"; }
pg() { uv run -q --with 'psycopg[binary]' pg.py "$@"; }
step() { printf '\n== %s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

step "terraform apply (Aurora PostgreSQL 16 + logical replication, KMS key, kms:Decrypt-only principal bound to Cloud egress IPs)"
terraform -chdir=terraform init -input=false >/dev/null
terraform -chdir=terraform apply -auto-approve -input=false
export PGHOST=$(terraform -chdir=terraform output -raw pg_host) PGUSER=$(terraform -chdir=terraform output -raw pg_user)
export PGPASSWORD=$(terraform -chdir=terraform output -raw pg_password) PGDATABASE=app
export LAB_CP_PASSWORD=${LAB_CP_PASSWORD:-$(openssl rand -hex 16)}
export UDF_ROLE_ARN=${UDF_ROLE_ARN:-$(terraform -chdir=terraform output -raw udf_role_arn)}

step "source schema, ClickPipes user and publication; $USERS users ($TENANTS data keys) → Aurora"
pg -c "SHOW rds.logical_replication"
pg -f pg/01-schema.sql
uv run -q --with boto3 --with cryptography --with 'psycopg[binary]' gen.py --users "$USERS" --tenants "$TENANTS" --name run --pg

step "ClickHouse: functions, serving tables, plaintext keys (dictionary path), expected values"
q -q "CREATE DATABASE IF NOT EXISTS raw"
q --queries-file sql/10-functions.sql
q --queries-file sql/20-targets.sql
q -q "INSERT INTO keys.plain_keys FORMAT TSV" < out/run/plain_keys.tsv
q --multiquery -q "CREATE DATABASE IF NOT EXISTS lab; CREATE TABLE IF NOT EXISTS lab.expected (user_id String, props String, email String, phone String) ENGINE = MergeTree ORDER BY user_id; CREATE TABLE IF NOT EXISTS lab.expected_r (user_id String, props String, email String, phone String, ver UInt8, deleted UInt8 DEFAULT 0) ENGINE = ReplacingMergeTree(ver) ORDER BY user_id"
q -q "INSERT INTO lab.expected FORMAT TSV" < out/run/expected.tsv
q -q "INSERT INTO lab.expected_r (user_id, props, email, phone, ver) SELECT user_id, props, email, phone, 0 FROM lab.expected"

step "UDF kms_decrypt_row: build (requirements.txt), upload, attach — first UDF = rolling restart"
./udf-deploy.sh || true   # the trailing SYSTEM RELOAD can fail on the pod being replaced; the first version loads at startup
until [ "$(q -q "SELECT count() FROM clusterAllReplicas(default, system.functions) WHERE name = 'kms_decrypt_row'" 2>/dev/null)" -ge 1 ]; do sleep 10; done

step "ClickPipe (Postgres CDC) → raw.users, then the refreshable MVs"
./clickpipe-create.sh
q --queries-file sql/30-rmvs.sql
until [ "$(q -q "SELECT (SELECT count() FROM app.users_kms FINAL) = (SELECT count() FROM raw.users FINAL WHERE _peerdb_is_deleted = 0) AND (SELECT count() FROM app.users_dict FINAL) = (SELECT count() FROM raw.users FINAL WHERE _peerdb_is_deleted = 0)")" = 1 ]; do sleep 10; done
for t in users_kms users_dict; do q --param_t=$t --queries-file sql/40-verify.sql; done
q --queries-file sql/60-monitor.sql
echo "next: ./cdc-changes.sh, then sql/42-verify-final.sql; access checks: sql/70-access.sql"
