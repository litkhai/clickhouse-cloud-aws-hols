#!/usr/bin/env bash
# Build the api_decrypt_props zip (main.py + requirements.txt + config.json with the API URL and token), upload it,
# create the UDF (or a new version) and attach it to the service. Needs CHC_KEY CHC_SECRET ORG_ID SERVICE_ID
# CH_HOST CH_USER CH_PASSWORD and the terraform outputs. Cloud API UDF endpoints (beta), docs
# products/cloud/api-reference/udf/*, read 2026-11-04.
set -euo pipefail
cd "$(dirname "$0")"
: "${CHC_KEY:?}" "${CHC_SECRET:?}" "${ORG_ID:?}" "${SERVICE_ID:?}"
API="https://api.clickhouse.cloud/v1/organizations/$ORG_ID"
api() { curl -fsS -u "$CHC_KEY:$CHC_SECRET" -H 'Content-Type: application/json' "$@"; }
name=api_decrypt_props
build=out/udf-build; rm -rf "$build"; mkdir -p "$build"
cp udf/$name/main.py udf/$name/requirements.txt "$build/"
( umask 077
  terraform -chdir=terraform output -json | python3 -c 'import json,sys,os; o=json.load(sys.stdin)
json.dump({"api_url":o["api_url"]["value"],"token":o["api_token"]["value"],
           "batch":int(os.environ.get("API_BATCH","500")),"workers":int(os.environ.get("API_WORKERS","4"))}, open(sys.argv[1],"w"))' "$build/config.json" )
( cd "$build" && rm -f ../udf.zip && zip -q -r ../udf.zip main.py requirements.txt config.json )
up=$(api -X POST "$API/udfUploads/url" -d '{}')
upload_id=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["uploadId"])' <<<"$up")
upload_url=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["uploadUrl"])' <<<"$up")
curl -fsS -X PUT --upload-file out/udf.zip "$upload_url" >/dev/null
echo "uploaded $(wc -c < out/udf.zip) bytes, uploadId $upload_id"
body=$(cat <<JSON
{"uploadId":"$upload_id","functionName":"$name","runtime":"python3.11","type":"${UDF_TYPE:-executable}",
 "arguments":[{"name":"tenant_id","type":"String"},{"name":"props","type":"String"}],
 "returnType":"String","returnName":"result","format":"JSONEachRow",
 "maxCommandExecutionTime":${UDF_TIMEOUT:-120},"sandboxType":"netenable","deterministic":false}
JSON
)
if api "$API/udfs/$name" >/dev/null 2>&1; then
  api -X POST "$API/udfs/$name/versions" -d "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d.pop("functionName");print(json.dumps(d))' "$body")" >/dev/null
else
  api -X POST "$API/udfs" -d "$body" >/dev/null
fi
while :; do
  st=$(api "$API/udfs/$name" | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r["status"], r.get("version"), r.get("error") or "")')
  echo "udf: $st"; case "$st" in ready*) break ;; error*) exit 1 ;; esac; sleep 10
done
ver=$(api "$API/udfs/$name" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["version"])')
api -X PUT "$API/udfs/$name/attachments/$SERVICE_ID" -d "{\"version\":$ver}" >/dev/null
while :; do
  st=$(api "$API/udfs/$name/attachments/$SERVICE_ID" | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r["status"], r.get("version"))')
  echo "attachment: $st"; case "$st" in "deployed $ver") break ;; error*) exit 1 ;; esac; sleep 15
done
clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" -q "SYSTEM RELOAD FUNCTION ON CLUSTER default $name" >/dev/null
echo "reloaded $name v$ver"
