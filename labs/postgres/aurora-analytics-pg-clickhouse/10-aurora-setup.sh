#!/bin/bash
# Aurora side: stage 0 (is aurora_analytics there?) and the 24 foreign tables over the Parquet files.
#   ./10-aurora-setup.sh --sf N [--dry-run]
# Run on the generator (it reaches Aurora and has config.env). --dry-run prints the SQL only.
# Out: out/<target>/step0.result (pass / fail + error text), schema-sf<N>.txt (\d of each table),
#      setup-sf<N>.txt (query_mem, shared_buffers, cache size, count, EXPLAIN ANALYZE), 10-aurora-setup-sf<N>.log.
# Exit code: 0 pass, 1 stage 0 or a later step failed.
#
# Names (feature, server, functions, columns) are from the Aurora User Guide, read 2026-10-09:
#   https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-analytics-tutorial.html
#     (CREATE EXTENSION aurora_analytics; foreign server aurora_analytics_server;
#      CREATE FOREIGN TABLE ... () SERVER ... OPTIONS (location, format, region))
#   https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-analytics-sql-functions-reference.html
#     (aurora_analytics_cache_size(), aurora_analytics_clear_cache(), aurora_analytics_stat_statements()
#      with analytics_cache_hit_bytes / analytics_remote_read_bytes)
#   https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-analytics-configuration-parameters.html
#     (aurora_analytics.query_mem)
# The task text names the pages "Monitoring and troubleshooting" and "Technical reference"; the guide's
# table of contents (read 2026-10-09) has no pages of those names, the three above hold the content.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SF=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sf) SF="${2:?--sf needs a value}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$SF" in *[!0-9]*|'') die "--sf N is required (integer)" ;; esac

load_config
require_keys AWS_REGION BUCKET S3_PREFIX AURORA_CLASS
TARGET=$(target_letter)
if [ "$DRY" = 1 ]; then
  aurora_psql() { echo "-- aurora_psql $*" >&2; if [ "${1:-}" != "-c" ]; then cat >&2; fi; }
else
  set_log "$TARGET" "10-aurora-setup-sf$SF"
fi
R="$OUT_DIR/$TARGET"
mkdir -p "$R"
BASE="s3://$BUCKET/$S3_PREFIX/sf$SF"

# ---- stage 0 -----------------------------------------------------------------------------------------
fail0() { # fail0 <text>
  [ "$DRY" = 1 ] || { printf 'fail\n%s\n' "$1" > "$R/step0.result"; }
  echo "stage 0 FAILED: $1" >&2
  exit 1
}
STEP0_ERR=$(aurora_psql 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS aurora_analytics;
SELECT extname, extversion FROM pg_extension WHERE extname = 'aurora_analytics';
SELECT srvname FROM pg_foreign_server WHERE srvname = 'aurora_analytics_server';
SELECT version();
SQL
) || fail0 "$STEP0_ERR"
if [ "$DRY" != 1 ]; then
  echo "$STEP0_ERR" | grep -q 'aurora_analytics_server' || fail0 "extension created but pg_foreign_server has no aurora_analytics_server: $STEP0_ERR"
  printf 'pass\n%s\n' "$STEP0_ERR" > "$R/step0.result"
else
  echo "$STEP0_ERR"
fi

# ---- foreign tables ----------------------------------------------------------------------------------
{
  echo "CREATE SCHEMA IF NOT EXISTS sf$SF;"
  for t in $TPCDS_TABLES; do
    echo "DROP FOREIGN TABLE IF EXISTS sf$SF.$t;"
    echo "CREATE FOREIGN TABLE sf$SF.$t () SERVER aurora_analytics_server OPTIONS (location '$BASE/$t/', format 'parquet', region '$AWS_REGION');"
  done
} | aurora_psql -q > /dev/null

{
  for t in $TPCDS_TABLES; do echo "\\d sf$SF.$t"; done
} | aurora_psql > "$R/schema-sf$SF.txt"

aurora_psql > "$R/setup-sf$SF.txt" <<SQL
SHOW aurora_analytics.query_mem;
SHOW shared_buffers;
SELECT aurora_analytics_cache_size() AS cache_size_bytes, pg_size_pretty(aurora_analytics_cache_size()) AS cache_size;
SELECT count(*) FROM sf$SF.store_sales;
EXPLAIN ANALYZE SELECT count(*) FROM sf$SF.store_sales;
SELECT pg_size_pretty(aurora_analytics_cache_size()) AS cache_size_after;
SQL
echo "done: $R/step0.result  $R/schema-sf$SF.txt  $R/setup-sf$SF.txt"
