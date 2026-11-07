#!/bin/bash
# Create the cachelab database on the ClickHouse Cloud service and load the events.
#   ./10-ch-setup.sh            ROWS=100000000 CHUNK=10000000 by default
# Runs from your machine with `clickhouse client`. Re-running on a loaded database stops
# instead of loading twice (DROP with ./90-ch-cleanup.sh first).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
load_ch

ROWS=${ROWS:-100000000}
CHUNK=${CHUNK:-10000000}

echo "== server"
ch -q "SELECT version(), (SELECT count() FROM clusterAllReplicas(default, system.one)) AS replicas,
       getSetting('max_threads') AS max_threads FORMAT Vertical"

echo "== schema"
ch --multiquery < "$LAB_DIR/sql/10-schema.sql"

HAVE=$(ch -q "SELECT count() FROM cachelab.events")
[ "$HAVE" = "0" ] || die "cachelab.events already has $HAVE rows; drop it first (./90-ch-cleanup.sh)"

# 30 days of history ending at the top of the current hour.
BASE=$(( $(date -u +%s) / 3600 * 3600 - 30 * 86400 ))
echo "== load $ROWS rows in chunks of $CHUNK (base $(date -u -r "$BASE" +%FT%TZ 2>/dev/null || date -u -d "@$BASE" +%FT%TZ))"
OFF=0
while [ "$OFF" -lt "$ROWS" ]; do
  N=$(( ROWS - OFF < CHUNK ? ROWS - OFF : CHUNK ))
  T0=$(date +%s)
  ch --param_base="$BASE" --param_off="$OFF" --param_n="$N" --log_comment="cachelab-load" \
     --queries-file "$LAB_DIR/sql/20-load.sql"
  echo "   $(( OFF + N )) / $ROWS  ($(( $(date +%s) - T0 )) s)"
  OFF=$(( OFF + N ))
done

echo "== check"
ch -q "SELECT
  (SELECT count() FROM cachelab.events)                        AS events,
  (SELECT uniqExact(user_id) FROM cachelab.events)             AS users,
  (SELECT count() FROM cachelab.user_stats FINAL)              AS user_stats_rows,
  (SELECT count() FROM cachelab.events_1m)                     AS rollup_rows,
  (SELECT min(ts) FROM cachelab.events)                        AS first_ts,
  (SELECT max(ts) FROM cachelab.events)                        AS last_ts
FORMAT Vertical"
ch -q "SELECT table, formatReadableSize(sum(data_compressed_bytes)) AS compressed, sum(rows) AS rows
       FROM system.parts WHERE database = 'cachelab' AND active GROUP BY table ORDER BY table"
