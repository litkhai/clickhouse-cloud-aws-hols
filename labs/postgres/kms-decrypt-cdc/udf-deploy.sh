#!/usr/bin/env bash
# Build the kms_unwrap zip (main.py + config.json with the UDF's AWS key), upload it, create the UDF
# and attach it to the service. Needs CHC_KEY CHC_SECRET ORG_ID SERVICE_ID and terraform outputs.
# Cloud API UDF endpoints (beta), docs products/cloud/api-reference/udf/*, read 2026-11-04.
set -euo pipefail
cd "$(dirname "$0")"
: "${CHC_KEY:?}" "${CHC_SECRET:?}" "${ORG_ID:?}" "${SERVICE_ID:?}"
API="https://api.clickhouse.cloud/v1/organizations/$ORG_ID"
api() { curl -fsS -u "$CHC_KEY:$CHC_SECRET" -H 'Content-Type: application/json' "$@"; }
build=out/udf-build; rm -rf "$build"; mkdir -p "$build"
cp udf/kms_unwrap/main.py "$build/"
# Credentials for config.json: the IAM user's access key, or (create_udf_user = false) 1-hour STS
# credentials from the kms:Decrypt-only role — then re-run this script before they expire.
role=${UDF_ROLE_ARN:-$(terraform -chdir=terraform output -raw udf_role_arn)}
( umask 077
  if [ -n "$role" ]; then
    aws sts assume-role --role-arn "$role" --role-session-name kms-unwrap-udf --duration-seconds 3600 --output json \
      | python3 -c 'import json,sys; c=json.load(sys.stdin)["Credentials"]
json.dump({"region":"ap-northeast-2","access_key_id":c["AccessKeyId"],"secret_access_key":c["SecretAccessKey"],"session_token":c["SessionToken"],"expires":c["Expiration"]}, open(sys.argv[1],"w"))' "$build/config.json"
  else
    terraform -chdir=terraform output -json | python3 -c 'import json,sys; o=json.load(sys.stdin)
json.dump({"region":"ap-northeast-2","access_key_id":o["udf_access_key_id"]["value"],"secret_access_key":o["udf_secret_access_key"]["value"]}, open(sys.argv[1],"w"))' "$build/config.json"
  fi )
( cd "$build" && rm -f ../kms_unwrap.zip && zip -q -r ../kms_unwrap.zip main.py config.json )
up=$(api -X POST "$API/udfUploads/url" -d '{}')
upload_id=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["uploadId"])' <<<"$up")
upload_url=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["uploadUrl"])' <<<"$up")
curl -fsS -X PUT --upload-file out/kms_unwrap.zip "$upload_url" >/dev/null
echo "uploaded $(wc -c < out/kms_unwrap.zip) bytes, uploadId $upload_id"
body=$(cat <<JSON
{"uploadId":"$upload_id","functionName":"kms_unwrap","runtime":"python3.11","type":"executable_pool",
 "arguments":[{"name":"edk","type":"String"}],"returnType":"String","format":"TabSeparated",
 "poolSize":${POOL_SIZE:-3},"maxCommandExecutionTime":30,"sandboxType":"netenable","deterministic":true}
JSON
)
if api "$API/udfs/kms_unwrap" >/dev/null 2>&1; then
  api -X POST "$API/udfs/kms_unwrap/versions" -d "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d.pop("functionName");print(json.dumps(d))' "$body")" >/dev/null
else
  api -X POST "$API/udfs" -d "$body" >/dev/null
fi
while :; do
  st=$(api "$API/udfs/kms_unwrap" | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r["status"], r.get("version"), r.get("error") or "")')
  echo "udf: $st"; case "$st" in ready*) break ;; error*) exit 1 ;; esac; sleep 10
done
ver=$(api "$API/udfs/kms_unwrap" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["version"])')
api -X PUT "$API/udfs/kms_unwrap/attachments/$SERVICE_ID" -d "{\"version\":$ver}" >/dev/null
while :; do
  st=$(api "$API/udfs/kms_unwrap/attachments/$SERVICE_ID" | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r["status"], r.get("version"))')
  echo "attachment: $st"; case "$st" in "deployed $ver") break ;; error*) exit 1 ;; esac; sleep 15
done
# A new version of an executable_pool UDF needs a reload on the service (no API call for it, docs 2026-11-04)
clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" -q "SYSTEM RELOAD FUNCTION ON CLUSTER default kms_unwrap" >/dev/null
echo "reloaded kms_unwrap v$ver"
