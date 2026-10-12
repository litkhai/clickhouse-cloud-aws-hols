#!/usr/bin/env bash
# Removes the ClickPipe and the lab database. The service itself is left as it was.
set -euo pipefail
cd "$(dirname "$0")"
: "${CH_HOST:?}" "${CH_USER:?}" "${CH_PASSWORD:?}"
terraform -chdir=terraform destroy -auto-approve -input=false
clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" \
  -q "DROP DATABASE IF EXISTS mask_lab SYNC"
