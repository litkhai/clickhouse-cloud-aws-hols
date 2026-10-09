#!/bin/bash
# Generate TPC-DS with the DuckDB tpcds extension and write one Parquet directory per table.
#   ./01-generate.sh --sf N [--work DIR] [--dest DIR] [--memory-limit 24GB] [--dry-run]
# Runs on the generator. Database: <work>/tpcds-sf<N>.duckdb (stays: it is target R's data).
# --dest DIR   write the Parquet under DIR/<table>/ (local rehearsal); default s3://$BUCKET/$S3_PREFIX/sf<N>
# --dry-run    print the DuckDB SQL, run nothing
# Out: out/datagen-sf<N>.csv = table,rows,files,bytes,seconds,duckdb_version
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SF=""; DEST=""; MEMLIMIT=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sf) SF="${2:?--sf needs a value}"; shift 2 ;;
    --work) WORK_DIR="${2:?--work needs a value}"; shift 2 ;;
    --dest) DEST="${2:?--dest needs a value}"; shift 2 ;;
    --memory-limit) MEMLIMIT="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$SF" ] || die "--sf N is required"
case "$SF" in *[!0-9]*|'') die "--sf must be an integer" ;; esac

if [ -z "$DEST" ]; then
  load_config
  require_keys BUCKET S3_PREFIX AWS_REGION
  DEST="s3://$BUCKET/$S3_PREFIX/sf$SF"
fi
DEST="${DEST%/}"
DB="$WORK_DIR/tpcds-sf$SF.duckdb"
TMP="$WORK_DIR/duckdb-tmp-sf$SF"
mkdir -p "$WORK_DIR" "$OUT_DIR" "$TMP"
case "$DEST" in s3://*) ;; *) mkdir -p "$DEST" ;; esac
command -v duckdb >/dev/null || [ "$DRY" = 1 ] || die "duckdb CLI is not installed"

# ---- SQL ---------------------------------------------------------------------------------------------
setup_sql() {
  echo "INSTALL tpcds; LOAD tpcds;"
  # without --memory-limit DuckDB uses its default (80% of RAM)
  [ -z "$MEMLIMIT" ] || echo "SET memory_limit='$MEMLIMIT';"
  echo "SET temp_directory='$TMP';"
}
dest_sql() { # secret for S3 destinations
  case "$DEST" in
    s3://*) echo "INSTALL httpfs; LOAD httpfs; CREATE OR REPLACE SECRET lab_s3 (TYPE S3, PROVIDER credential_chain, REGION '$AWS_REGION');" ;;
  esac
}
copy_sql() { # copy_sql <table>
  local t="$1" k q
  k=$(fact_order_key "$t")
  if [ -n "$k" ]; then q="SELECT * FROM $t ORDER BY $k"; else q="SELECT * FROM $t"; fi
  echo "COPY ($q) TO '$DEST/$t/' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 122880, FILE_SIZE_BYTES '256MB', OVERWRITE);"
}

if [ "$DRY" = 1 ]; then
  echo "-- database: $DB"
  setup_sql; echo "CALL dsdgen(sf=$SF);"
  dest_sql
  for t in $TPCDS_TABLES; do copy_sql "$t"; done
  exit 0
fi

LOG_FILE="$OUT_DIR/datagen-sf$SF.log"
: > "$LOG_FILE"
DUCKV=$(duckdb -noheader -list -c "SELECT version()")
log "duckdb $DUCKV, sf=$SF, db=$DB, dest=$DEST, memory_limit=${MEMLIMIT:-default}"

if [ -f "$DB" ]; then
  log "$DB exists: reusing it (delete it to regenerate)"
else
  T0=$(now)
  rm -f "$DB.part" "$DB.part.wal"
  { setup_sql; echo "CALL dsdgen(sf=$SF);"; } | duckdb -noheader -list "$DB.part" 2>&1 >/dev/null | tee -a "$LOG_FILE"
  [ -s "$DB.part" ] || die "dsdgen did not create $DB"
  mv "$DB.part" "$DB"
  log "dsdgen: $(elapsed "$T0" "$(now)") s"
fi

CSV="$OUT_DIR/datagen-sf$SF.csv"
echo "table,rows,files,bytes,seconds,duckdb_version" > "$CSV"
for t in $TPCDS_TABLES; do
  T0=$(now)
  { setup_sql; dest_sql; copy_sql "$t"; } | duckdb -noheader -list "$DB" 2>&1 >/dev/null | tee -a "$LOG_FILE"
  T1=$(now)
  ROWS=$(duckdb -noheader -list "$DB" -c "SELECT count(*) FROM $t")
  read -r FILES BYTES < <(parquet_stats "$DEST/$t/")
  echo "$t,$ROWS,$FILES,$BYTES,$(elapsed "$T0" "$T1"),$DUCKV" >> "$CSV"
  log "$t rows=$ROWS files=$FILES bytes=$BYTES"
done
log "wrote $CSV"
