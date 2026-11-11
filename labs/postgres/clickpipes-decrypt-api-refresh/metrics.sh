#!/usr/bin/env bash
# Decrypt API side: Lambda invocations, duration, concurrency, throttles over the last N minutes (CloudWatch).
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
mins=${1:-120}
start=$(date -u -v-"${mins}"M +%FT%TZ 2>/dev/null || date -u -d "-$mins min" +%FT%TZ); end=$(date -u +%FT%TZ)
for m in Invocations:Sum Duration:Average Duration:Maximum ConcurrentExecutions:Maximum Throttles:Sum Errors:Sum; do
  aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name "${m%%:*}" --statistics "${m##*:}" \
    --dimensions Name=FunctionName,Value="$LAMBDA_NAME" --start-time "$start" --end-time "$end" --period 60 --output json \
  | python3 -c 'import json,sys
m, s = sys.argv[1], sys.argv[1].split(":")[1]
d = sorted(json.load(sys.stdin)["Datapoints"], key=lambda p: p["Timestamp"])
from datetime import datetime, timezone
utc = lambda t: datetime.fromisoformat(t).astimezone(timezone.utc).strftime("%H:%M")
print(m, "(UTC)", " ".join(utc(p["Timestamp"]) + "=" + format(p[s], ".0f") for p in d if p[s]))' "$m"
done
