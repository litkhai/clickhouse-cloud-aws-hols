#!/usr/bin/env bash
# Create the Postgres CDC ClickPipe: Aurora public.users -> raw.users (ReplacingMergeTree, ClickPipes default).
# Needs CHC_KEY CHC_SECRET ORG_ID SERVICE_ID PGHOST LAB_CP_PASSWORD. ClickPipes API (beta),
# docs integrations/clickpipes/programmatic-access/openapi + postgres FAQ, read 2026-11-04.
set -euo pipefail
cd "$(dirname "$0")"
: "${CHC_KEY:?}" "${CHC_SECRET:?}" "${ORG_ID:?}" "${SERVICE_ID:?}" "${PGHOST:?}" "${LAB_CP_PASSWORD:?}"
API="https://api.clickhouse.cloud/v1/organizations/$ORG_ID/services/$SERVICE_ID/clickpipes"
api() { curl -sS -u "$CHC_KEY:$CHC_SECRET" -H 'Content-Type: application/json' "$@"; }
body=$(python3 - <<PY
import json, os
print(json.dumps({
  "name": "kms-lab-users",
  "source": {"postgres": {
    "type": "aurorapostgres", "host": os.environ["PGHOST"], "port": 5432, "database": "app",
    "credentials": {"username": "clickpipes_user", "password": os.environ["LAB_CP_PASSWORD"]},
    "settings": {"replicationMode": "cdc", "publicationName": "clickpipes",
                 "syncIntervalSeconds": int(os.environ.get("SYNC_INTERVAL", "10")), "pullBatchSize": 100000},
    "tableMappings": [{"sourceSchemaName": "public", "sourceTable": "users", "targetTable": "users"}]}},
  "destination": {"database": "raw"}}))
PY
)
resp=$(api -X POST "$API" -d "$body")
pipe=$(python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["result"]["id"])' <<<"$resp" 2>/dev/null) || { echo "$resp"; exit 1; }
echo "pipe $pipe"; echo "$pipe" > out/pipe_id
start=$SECONDS
while :; do
  st=$(api "$API/$pipe" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["state"])')
  echo "$(date -u +%T) $st"; case "$st" in Running) break ;; Failed) exit 1 ;; esac; sleep 20
done
echo "create -> Running: $((SECONDS - start)) s"
