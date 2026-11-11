#!/usr/bin/env bash
# Removes what deploy.sh created: the ClickPipe, the UDF (detach + delete), the lab databases, then Terraform
# and out/ (plaintext data keys). The ClickHouse Cloud service itself is not deleted here.
set -euo pipefail
cd "$(dirname "$0")"
: "${CHC_KEY:?}" "${CHC_SECRET:?}" "${ORG_ID:?}" "${SERVICE_ID:?}"
API="https://api.clickhouse.cloud/v1/organizations/$ORG_ID"
api() { curl -sS -u "$CHC_KEY:$CHC_SECRET" -H 'Content-Type: application/json' "$@"; }
if [ -s out/pipe_id ]; then api -X DELETE "$API/services/$SERVICE_ID/clickpipes/$(cat out/pipe_id)" >/dev/null && echo "pipe deleted"; fi
if [ -n "${CH_HOST:-}" ]; then
  clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" --multiquery -q \
    "DROP VIEW IF EXISTS app.users_rmv; DROP DATABASE IF EXISTS app; DROP DATABASE IF EXISTS lab; DROP DATABASE IF EXISTS raw;" || true
fi
api -X DELETE "$API/udfs/api_decrypt_props/attachments/$SERVICE_ID" >/dev/null || true
sleep 30
api -X DELETE "$API/udfs/api_decrypt_props" >/dev/null && echo "udf deleted" || true
terraform -chdir=terraform destroy -auto-approve -input=false
rm -rf out
