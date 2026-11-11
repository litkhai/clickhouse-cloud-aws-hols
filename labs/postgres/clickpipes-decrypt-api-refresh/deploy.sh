#!/usr/bin/env bash
# The whole lab in order. Each step is also a file you can run alone.
# Needs: terraform, uv, clickhouse (client), aws CLI, curl, python3; AWS credentials for ap-northeast-2;
#   CHC_KEY CHC_SECRET ORG_ID SERVICE_ID CH_HOST CH_USER CH_PASSWORD — a ClickHouse Cloud test service in the same
#   region (attaching the first UDF restarts it); terraform/terraform.tfvars (see the .example).
set -euo pipefail
cd "$(dirname "$0")"
: "${CHC_KEY:?}" "${CHC_SECRET:?}" "${ORG_ID:?}" "${SERVICE_ID:?}" "${CH_HOST:?}" "${CH_USER:?}" "${CH_PASSWORD:?}"
USERS=${USERS:-1000000}
mkdir -p out

printf '== terraform apply (Aurora PostgreSQL 16 + logical replication, KMS master key, key ring, decrypt API)\n'
terraform -chdir=terraform init -input=false >/dev/null
terraform -chdir=terraform apply -auto-approve -input=false
. ./env.sh
export LAB_CP_PASSWORD=${LAB_CP_PASSWORD:-$(openssl rand -hex 16)}; echo "$LAB_CP_PASSWORD" > out/cp_password; chmod 600 out/cp_password

step "data keys, version 1: props, email, phone (KMS GenerateDataKey) → key ring"
keys --version 1

step "source schema, ClickPipes user and publication; $USERS users generated inside Aurora (pgcrypto)"
pg -c "SHOW rds.logical_replication"
pg -f pg/01-schema.sql
load upsert --from 0 --to $((USERS - 1)) --ver 1
load check

step "the decrypt API refuses callers outside the ClickHouse Cloud egress IPs (this laptop, valid token)"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X POST "$API_URL" -H "authorization: Bearer $(terraform -chdir=terraform output -raw api_token)" -d '{"rows":[]}'

step "ClickHouse: serving table, expected values"
q -q "CREATE DATABASE IF NOT EXISTS raw"
q --queries-file sql/20-targets.sql
reload_expected

step "UDF api_decrypt_props: build, upload, attach — the first UDF on a service = rolling restart"
./udf-deploy.sh || true
until [ "$(q -q "SELECT count() FROM clusterAllReplicas(default, system.functions) WHERE name = 'api_decrypt_props'" 2>/dev/null)" -ge 1 ]; do sleep 10; done

step "from ClickHouse, the API without the token: refused (the IP is allowed, the token is not there)"
q -q "INSERT INTO FUNCTION url('$API_URL', 'RawBLOB', 'x String') SELECT '{\"rows\":[]}'" 2>&1 | grep -o 'HTTP status code: [0-9]*\|401[^,]*' | head -1 || true

step "ClickPipe (Postgres CDC) → raw.users, then the refreshable MV"
./clickpipe-create.sh
q --queries-file sql/30-rmv.sql
wait_caught_up
q --queries-file sql/40-verify.sql
q --queries-file sql/60-monitor.sql
q --param_minutes=60 --queries-file sql/65-refresh-stats.sql
echo "next: ./cdc-changes.sh, ./outage.sh, ./lookups.sh, ./metrics.sh"
