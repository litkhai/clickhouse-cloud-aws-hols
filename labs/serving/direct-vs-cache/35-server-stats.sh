#!/bin/bash
# Server-side stats per run, read afterwards from system.query_log on every replica.
#   ./35-server-stats.sh <stamp> <first UTC time> <last UTC time>   e.g. 20261107T-run3 '2026-11-07 04:37:00' '2026-11-07 06:45:00'
# Writes results/<stamp>/server-posthoc.jsonl (one line per log_comment). Used when the in-run stats
# query failed (it did while the service was autoscaling: ALL_CONNECTION_TRIES_FAILED).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
load_ch
STAMP=${1:?stamp}; FROM=${2:?from}; TO=${3:?to}
ch --param_from="$FROM" --param_to="$TO" -q "
SELECT log_comment AS run_id,
       countIf(type = 'QueryFinish') AS queries,
       countIf(type != 'QueryFinish') AS failed,
       round(avgIf(query_duration_ms, type = 'QueryFinish'), 2) AS avg_ms,
       quantileIf(0.99)(query_duration_ms, type = 'QueryFinish') AS p99_ms,
       sum(read_rows) AS read_rows, sum(read_bytes) AS read_bytes,
       countIf(query_cache_usage = 'Read') AS qc_read, countIf(query_cache_usage = 'Write') AS qc_write,
       sum(ProfileEvents['OSCPUVirtualTimeMicroseconds']) AS cpu_us,
       uniqExact(hostname) AS replicas,
       groupUniqArrayIf(exception_code, exception_code != 0) AS exception_codes
FROM clusterAllReplicas(default, system.query_log)
WHERE event_time BETWEEN toDateTime({from:String}) AND toDateTime({to:String})
  AND match(log_comment, '^(s1|s2|s3|floor)-') AND type != 'QueryStart'
GROUP BY run_id ORDER BY run_id
SETTINGS skip_unavailable_shards = 1
FORMAT JSONEachRow" > "$LAB_DIR/results/$STAMP/server-posthoc.jsonl"
wc -l < "$LAB_DIR/results/$STAMP/server-posthoc.jsonl"
