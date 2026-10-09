#!/bin/bash
# ClickHouse Cloud over the Iceberg tables of 30-iceberg.sh, from the generator.
#   ./22-clickhouse-iceberg.sh --sf N [--dry-run]
# (a) Glue catalog smoke check (Beta). Database glue_cat, ENGINE = DataLakeCatalog, catalog_type = 'glue', region,
#     aws_role_arn = CHC_S3_ROLE_ARN (v26.2+), with allow_database_glue_catalog = 1. One namespace per table name,
#     so the tables are `<iceberg_db>.<t>_sf<N>` (backticks). Count of every table -> out/P/glue-catalog-sf<N>.csv
#     (table,rows,expected_rows,seconds,status,error). A failure is a result: the exact error text goes into the CSV
#     and the script goes on. Docs (read 2026-10-09): https://clickhouse.com/docs/use-cases/data-lake/glue-catalog
#     (the page says Glue "only supports Iceberg tables"; the Beta label is from the lab's task text).
# (b) Database ice_sf<N>, one table per TPC-DS table over the same files, plain names, for the 103-query run through
#     pg_clickhouse (./21-pgfront-setup.sh --sf N --db ice_sf<N>, then run.py --schema ice_sf<N> --tag ice):
#       CREATE TABLE ice_sf<N>.<t> ENGINE = IcebergS3('https://$BUCKET.s3.$AWS_REGION.amazonaws.com/iceberg/sf<N>/<t>/',
#         'Parquet', extra_credentials(role_arn = '$CHC_S3_ROLE_ARN'))
#     Docs (read 2026-10-09): Iceberg table engine, IcebergS3(url, [NOSIGN | key, secret, [token]], format,
#     [compression], [extra_credentials]) "an optional extra_credentials parameter can be used to pass a role_arn for
#     role-based access in ClickHouse Cloud": https://clickhouse.com/docs/engines/table-engines/integrations/iceberg
#     and "Secure S3". Count per table against out/datagen-sf<N>.csv -> out/P/iceberg-sf<N>.csv
#     (table,rows,expected_rows,seconds,status). Exit 1 when (b) fails or a count differs.
# --dry-run    print the SQL, run nothing
# Out: also out/P/22-clickhouse-iceberg-sf<N>.log.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SF=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sf) SF="${2:?--sf needs a value}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$SF" in *[!0-9]*|'') die "--sf N is required (integer)" ;; esac

load_config
require_keys CH_HOST CH_USER CH_PASSWORD BUCKET AWS_REGION CHC_S3_ROLE_ARN GLUE_ICEBERG_DB
if [ "$DRY" = 1 ]; then
  ch_client() { echo "-- ch_client $*" >&2; }
else
  set_log P "22-clickhouse-iceberg-sf$SF"
fi
mkdir -p "$OUT_DIR/P"
DATAGEN="$OUT_DIR/datagen-sf$SF.csv"
GLUE_SETTING=--allow_database_glue_catalog=1
expected_rows() {
  [ -f "$DATAGEN" ] || return 0
  awk -F, -v t="$1" '$1 == t { print $2 }' "$DATAGEN"
}
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/chice.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

# try_ch <ch_client args>: OUT = stdout, ERR = stderr on one line (no commas, no double quotes), returns the exit code
try_ch() {
  local rc=0
  OUT=$(ch_client "$@" 2>"$TMPD/err") || rc=$?
  sleep 0.3   # the log's stderr tee runs in the background
  [ "$DRY" = 0 ] || cat "$TMPD/err" >&2
  ERR=$(tr '\n' ' ' < "$TMPD/err" | tr ',"' ";'" | cut -c1-700)
  return $rc
}

ch_client --query "SELECT version()" > "$OUT_DIR/P/clickhouse-version.txt" || die "cannot reach ClickHouse at $CH_HOST"
log "ClickHouse $(cat "$OUT_DIR/P/clickhouse-version.txt")"
[ -f "$DATAGEN" ] || log "WARNING: $DATAGEN not found, row counts will not be compared with the generator"

# ---- (a) Glue DataLakeCatalog smoke check --------------------------------------------------------------
GCSV="$OUT_DIR/P/glue-catalog-sf$SF.csv"
echo "table,rows,expected_rows,seconds,status,error" > "$GCSV"
try_ch "$GLUE_SETTING" --query "DROP DATABASE IF EXISTS glue_cat SYNC" || true
T0=$(now)
if try_ch "$GLUE_SETTING" --query "CREATE DATABASE glue_cat ENGINE = DataLakeCatalog SETTINGS catalog_type = 'glue', region = '$AWS_REGION', aws_role_arn = '$CHC_S3_ROLE_ARN'"; then
  echo "_create_database,,,$(elapsed "$T0" "$(now)"),ok," >> "$GCSV"
  log "glue_cat created"
  try_ch "$GLUE_SETTING" --query "SHOW TABLES FROM glue_cat" || true   # the names, for the log
  for t in $TPCDS_TABLES; do
    T0=$(now)
    EXP=$(expected_rows "$t")
    if try_ch "$GLUE_SETTING" --query "SELECT count() FROM glue_cat.\`$GLUE_ICEBERG_DB.${t}_sf$SF\`"; then
      ROWS=$OUT; STATUS=ok; ERR=""
      if [ -n "$EXP" ] && [ "$ROWS" != "$EXP" ]; then STATUS=rows_differ; fi
    else
      ROWS=""; STATUS=failed
    fi
    echo "$t,$ROWS,$EXP,$(elapsed "$T0" "$(now)"),$STATUS,$ERR" >> "$GCSV"
    log "glue_cat $t rows=${ROWS:-?} expected=${EXP:-?} $STATUS $ERR"
  done
else
  echo "_create_database,,,$(elapsed "$T0" "$(now)"),failed,$ERR" >> "$GCSV"
  log "glue_cat CREATE DATABASE failed: $ERR"
fi
log "wrote $GCSV (a failure here is a result, not an error of the script)"

# ---- (b) ice_sf<N>: IcebergS3 tables with plain names --------------------------------------------------
DB="ice_sf$SF"
CSV="$OUT_DIR/P/iceberg-sf$SF.csv"
echo "table,rows,expected_rows,seconds,status" > "$CSV"
FAILED=0
ch_client --query "DROP DATABASE IF EXISTS $DB SYNC"
ch_client --query "CREATE DATABASE $DB"
for t in $TPCDS_TABLES; do
  T0=$(now)
  STATUS=ok; ROWS=""
  try_ch --query "CREATE TABLE $DB.$t ENGINE = IcebergS3('https://$BUCKET.s3.$AWS_REGION.amazonaws.com/iceberg/sf$SF/$t/', 'Parquet', extra_credentials(role_arn = '$CHC_S3_ROLE_ARN'))" \
    || { STATUS=create_failed; log "$t: $ERR"; }
  if [ "$STATUS" = ok ]; then
    if try_ch --query "SELECT count() FROM $DB.$t"; then ROWS=$OUT; else STATUS=count_failed; log "$t: $ERR"; fi
  fi
  EXP=$(expected_rows "$t")
  if [ "$STATUS" = ok ] && [ -n "$EXP" ] && [ "$ROWS" != "$EXP" ]; then STATUS=rows_differ; fi
  [ "$STATUS" = ok ] || FAILED=1
  echo "$t,$ROWS,$EXP,$(elapsed "$T0" "$(now)"),$STATUS" >> "$CSV"
  log "$DB.$t rows=${ROWS:-?} expected=${EXP:-?} $STATUS"
done
[ "$FAILED" = 0 ] || { echo "Iceberg tables FAILED, see $CSV" >&2; exit 1; }
log "ok: $CSV"
