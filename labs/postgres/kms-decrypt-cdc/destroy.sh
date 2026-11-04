#!/usr/bin/env bash
# Removes what deploy.sh created: the ClickPipe, the UDF (detach + delete), the lab databases, then Terraform.
# The ClickHouse Cloud service itself is not deleted here (deploy.sh did not create it).
set -euo pipefail
cd "$(dirname "$0")"
: "${CHC_KEY:?}" "${CHC_SECRET:?}" "${ORG_ID:?}" "${SERVICE_ID:?}"
API="https://api.clickhouse.cloud/v1/organizations/$ORG_ID"
api() { curl -sS -u "$CHC_KEY:$CHC_SECRET" -H 'Content-Type: application/json' "$@"; }
if [ -s out/pipe_id ]; then api -X DELETE "$API/services/$SERVICE_ID/clickpipes/$(cat out/pipe_id)" >/dev/null && echo "pipe deleted"; fi
api -X DELETE "$API/udfs/kms_unwrap/attachments/$SERVICE_ID" >/dev/null || true
sleep 30
api -X DELETE "$API/udfs/kms_unwrap" >/dev/null && echo "udf deleted" || true
if [ -n "${CH_HOST:-}" ]; then
  clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" --multiquery -q \
    "DROP DATABASE IF EXISTS app; DROP DATABASE IF EXISTS keys; DROP DATABASE IF EXISTS lab; DROP DATABASE IF EXISTS raw; DROP USER IF EXISTS analyst;
     DROP FUNCTION IF EXISTS dec_props; DROP FUNCTION IF EXISTS dec_val; DROP FUNCTION IF EXISTS enc_blob;"
fi
terraform -chdir=terraform destroy -auto-approve -input=false
