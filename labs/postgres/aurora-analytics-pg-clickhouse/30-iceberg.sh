#!/bin/bash
# Register the generated TPC-DS Parquet as Iceberg tables in the AWS Glue Data Catalog, through Athena.
#   ./30-iceberg.sh --sf N [--drop]
#   ./30-iceberg.sh --sf N --ddl-only --local DIR      print the Athena DDL for the Parquet under DIR/<table>/, run nothing
# Runs on the generator (needs enable_glue = true in Terraform: GLUE_*, ATHENA_WORKGROUP in config.env).
# Per table (24):
#   1. DuckDB reads the Parquet schema (DESCRIBE over s3://$BUCKET/$S3_PREFIX/sf<N>/<t>/*.parquet, S3 secret
#      credential_chain) and maps it to Athena types: BIGINT bigint, INTEGER int, DECIMAL(p,s) decimal(p,s),
#      VARCHAR string, DATE date, DOUBLE double, BOOLEAN boolean, TIMESTAMP timestamp. Any other type stops the script.
#   2. Athena: CREATE EXTERNAL TABLE IF NOT EXISTS <parquet_db>.<t>_sf<N> (...) STORED AS PARQUET LOCATION '.../sf<N>/<t>/'
#   3. Athena CTAS: CREATE TABLE <iceberg_db>.<t>_sf<N> WITH (table_type='ICEBERG', is_external=false,
#      location='s3://$BUCKET/iceberg/sf<N>/<t>/', format='PARQUET', write_compression='ZSTD') AS SELECT * FROM <parquet_db>.<t>_sf<N>
#      Property names: Athena user guide "CREATE TABLE AS" (CTAS table properties: table_type, is_external,
#      location, format, write_compression), read 2026-10-09:
#      https://docs.aws.amazon.com/athena/latest/ug/create-table-as.html
#      An Iceberg table that already exists is kept (counted, not rebuilt); --drop first to rebuild.
#   4. Athena: SELECT count(*) on the Iceberg table, compared with out/datagen-sf<N>.csv.
# Table names carry the _sf<N> suffix (one Glue database holds every scale factor); 11-aurora-glue.sh drops the
# suffix again on the Aurora side, 22-clickhouse-iceberg.sh creates plain names.
# --drop       DROP TABLE of both sets of tables, and delete s3://$BUCKET/iceberg/sf<N>/ (the Parquet staging data stays)
# --ddl-only   with --local DIR: the DuckDB schema read is local, no AWS call; needs only the duckdb CLI
# Out: out/iceberg-sf<N>.csv = table,rows,expected_rows,seconds,data_scanned_bytes,status (seconds and bytes of the
#      CTAS query), out/iceberg-sf<N>.log. Exit 1 when a count differs from the generator.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SF=""; DROP=0; DDLONLY=0; LOCAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sf) SF="${2:?--sf needs a value}"; shift 2 ;;
    --drop) DROP=1; shift ;;
    --ddl-only) DDLONLY=1; shift ;;
    --local) LOCAL="${2:?--local needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$SF" in *[!0-9]*|'') die "--sf N is required (integer)" ;; esac
[ "$DDLONLY" = 0 ] || [ -n "$LOCAL" ] || die "--ddl-only needs --local DIR"
[ -z "$LOCAL" ] || [ "$DDLONLY" = 1 ] || die "--local is for --ddl-only"
[ "$DDLONLY" = 0 ] || [ "$DROP" = 0 ] || die "--ddl-only and --drop do not combine"

if [ "$DDLONLY" = 1 ]; then
  [ -d "$LOCAL" ] || die "not a directory: $LOCAL"
  BUCKET=BUCKET; S3_PREFIX=tpcds; AWS_REGION=REGION
  GLUE_PARQUET_DB=PARQUET_DB; GLUE_ICEBERG_DB=ICEBERG_DB
else
  load_config
  require_keys BUCKET S3_PREFIX AWS_REGION GLUE_PARQUET_DB GLUE_ICEBERG_DB ATHENA_WORKGROUP
  command -v aws >/dev/null || die "aws CLI is not installed"
fi
command -v duckdb >/dev/null || [ "$DROP" = 1 ] || die "duckdb CLI is not installed"
PARQUET_BASE="s3://$BUCKET/$S3_PREFIX/sf$SF"
ICEBERG_BASE="s3://$BUCKET/iceberg/sf$SF"
ATHENA_TIMEOUT="${ATHENA_TIMEOUT:-3600}"   # seconds per query
ATHENA_POLL="${ATHENA_POLL:-3}"            # seconds between polls
AWS_NET=(--cli-connect-timeout 30 --cli-read-timeout 60)

# ---- schema -> Athena DDL ----------------------------------------------------------------------------
# columns_ddl <csv of DuckDB DESCRIBE>: the column list of the DDL, or exit 1 naming the unsupported type
columns_ddl() {
  python3 - "$1" <<'PY'
import csv, re, sys
MAP = {"BIGINT": "bigint", "INTEGER": "int", "VARCHAR": "string", "DATE": "date",
       "DOUBLE": "double", "BOOLEAN": "boolean", "TIMESTAMP": "timestamp"}
cols = []
for row in csv.reader(open(sys.argv[1])):
    name, typ = row[0], row[1]
    m = re.fullmatch(r"DECIMAL\((\d+),\s*(\d+)\)", typ)
    if m:
        t = "decimal(%s,%s)" % m.groups()
    elif typ in MAP:
        t = MAP[typ]
    else:
        sys.exit("unsupported DuckDB type %s (column %s)" % (typ, name))
    if not re.fullmatch(r"[a-z_][a-z0-9_]*", name):
        sys.exit("column name %r is not lowercase [a-z0-9_]: Glue lower-cases names, the Parquet match would break" % name)
    cols.append("  `%s` %s" % (name, t))
if not cols:
    sys.exit("no columns")
print(",\n".join(cols))
PY
}

# describe_csv <table> <out csv>: DuckDB DESCRIBE of the table's Parquet (S3, or --local DIR)
describe_csv() {
  local t="$1" out="$2" pre="" src
  rm -f "$out"
  if [ -n "$LOCAL" ]; then
    src="$LOCAL/$t/*.parquet"
  else
    src="$PARQUET_BASE/$t/*.parquet"
    pre="INSTALL httpfs; LOAD httpfs; CREATE OR REPLACE SECRET lab_s3 (TYPE S3, PROVIDER credential_chain, REGION '$AWS_REGION');"
  fi
  printf "%s COPY (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('%s'))) TO '%s' (FORMAT csv, HEADER false);\n" "$pre" "$src" "$out" \
    | duckdb -bail -noheader -list >/dev/null || die "duckdb could not read the schema of $src"
  [ -s "$out" ] || die "duckdb wrote no schema for $src"
}

ddl_parquet() { # ddl_parquet <table> <columns>
  printf 'CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s_sf%s (\n%s\n)\nSTORED AS PARQUET\nLOCATION '"'"'%s/%s/'"'"'' \
    "$GLUE_PARQUET_DB" "$1" "$SF" "$2" "$PARQUET_BASE" "$1"
}
ddl_ctas() { # ddl_ctas <table>
  printf "CREATE TABLE %s.%s_sf%s WITH (table_type='ICEBERG', is_external=false, location='%s/%s/', format='PARQUET', write_compression='ZSTD') AS SELECT * FROM %s.%s_sf%s" \
    "$GLUE_ICEBERG_DB" "$1" "$SF" "$ICEBERG_BASE" "$1" "$GLUE_PARQUET_DB" "$1" "$SF"
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/iceberg.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

if [ "$DDLONLY" = 1 ]; then
  N=0
  for t in $TPCDS_TABLES; do
    [ -d "$LOCAL/$t" ] || continue
    describe_csv "$t" "$TMPD/$t.csv"
    COLS=$(columns_ddl "$TMPD/$t.csv") || die "table $t: see above"
    ddl_parquet "$t" "$COLS"; echo ";"
    ddl_ctas "$t"; echo ";"
    N=$((N + 1))
  done
  [ "$N" -gt 0 ] || die "no <table>/ directory of the 24 TPC-DS tables under $LOCAL"
  exit 0
fi

# ---- Athena ------------------------------------------------------------------------------------------
# athena_run <sql>: start, poll, die with the reason on FAILED / CANCELLED. Sets QID, SCANNED (bytes).
athena_run() {
  local sql="$1" state scanned reason waited=0 line
  QID=$(aws athena start-query-execution --work-group "$ATHENA_WORKGROUP" --region "$AWS_REGION" \
    --query-string "$sql" --query QueryExecutionId --output text "${AWS_NET[@]}") \
    || die "athena start-query-execution failed for: $(echo "$sql" | head -1)"
  log "athena $QID: $(echo "$sql" | head -1 | cut -c1-110)"
  while :; do
    line=$(aws athena get-query-execution --query-execution-id "$QID" --region "$AWS_REGION" \
      --query '[QueryExecution.Status.State, QueryExecution.Statistics.DataScannedInBytes, QueryExecution.Status.StateChangeReason]' \
      --output text "${AWS_NET[@]}") || die "athena get-query-execution failed for $QID"
    IFS=$'\t' read -r state scanned reason <<<"$line"
    case "$state" in
      SUCCEEDED) SCANNED="${scanned:-0}"; [ "$SCANNED" != None ] || SCANNED=0; return 0 ;;
      FAILED|CANCELLED) die "athena $QID $state: ${reason:-no reason given}"$'\n'"SQL: $sql" ;;
    esac
    if [ "$waited" -ge "$ATHENA_TIMEOUT" ]; then
      aws athena stop-query-execution --query-execution-id "$QID" --region "$AWS_REGION" "${AWS_NET[@]}" >/dev/null || true
      die "athena $QID still $state after ${ATHENA_TIMEOUT}s, stop requested"
    fi
    sleep "$ATHENA_POLL"; waited=$((waited + ATHENA_POLL))
  done
}

athena_count() { # athena_count <db.table>: rows in $COUNT
  athena_run "SELECT count(*) FROM $1"
  COUNT=$(aws athena get-query-results --query-execution-id "$QID" --region "$AWS_REGION" \
    --query 'ResultSet.Rows[1].Data[0].VarCharValue' --output text "${AWS_NET[@]}") || die "athena get-query-results failed for $QID"
}

LOG_FILE="$OUT_DIR/iceberg-sf$SF.log"
mkdir -p "$OUT_DIR"
: > "$LOG_FILE"

if [ "$DROP" = 1 ]; then
  for t in $TPCDS_TABLES; do
    athena_run "DROP TABLE IF EXISTS $GLUE_ICEBERG_DB.${t}_sf$SF"
    athena_run "DROP TABLE IF EXISTS $GLUE_PARQUET_DB.${t}_sf$SF"
  done
  # the Iceberg data and metadata files; the Parquet under $S3_PREFIX is not touched
  aws s3 rm "$ICEBERG_BASE/" --recursive --only-show-errors "${AWS_NET[@]}" || die "could not delete $ICEBERG_BASE/"
  log "dropped both sets of tables for sf$SF and deleted $ICEBERG_BASE/"
  exit 0
fi

CSV="$OUT_DIR/iceberg-sf$SF.csv"
DATAGEN="$OUT_DIR/datagen-sf$SF.csv"
expected_rows() {
  [ -f "$DATAGEN" ] || return 0
  awk -F, -v t="$1" '$1 == t { print $2 }' "$DATAGEN"
}
[ -f "$DATAGEN" ] || log "WARNING: $DATAGEN not found, row counts will not be compared with the generator"
echo "table,rows,expected_rows,seconds,data_scanned_bytes,status" > "$CSV"
FAILED=0
for t in $TPCDS_TABLES; do
  describe_csv "$t" "$TMPD/$t.csv"
  COLS=$(columns_ddl "$TMPD/$t.csv") || die "table $t: see above"
  athena_run "$(ddl_parquet "$t" "$COLS")"
  SECS=0; SCAN=0; STATUS=ok
  if aws glue get-table --database-name "$GLUE_ICEBERG_DB" --name "${t}_sf$SF" --region "$AWS_REGION" \
       --query Table.Name --output text "${AWS_NET[@]}" >/dev/null 2>&1; then
    STATUS=exists
    log "$t: Iceberg table exists, kept"
  else
    T0=$(now)
    athena_run "$(ddl_ctas "$t")"
    SECS=$(elapsed "$T0" "$(now)"); SCAN=$SCANNED
  fi
  athena_count "$GLUE_ICEBERG_DB.${t}_sf$SF"
  EXP=$(expected_rows "$t")
  if [ -n "$EXP" ] && [ "$COUNT" != "$EXP" ]; then STATUS=rows_differ; FAILED=1; fi
  echo "$t,$COUNT,$EXP,$SECS,$SCAN,$STATUS" >> "$CSV"
  log "$t rows=$COUNT expected=${EXP:-?} ${SECS}s scanned=$SCAN $STATUS"
done
[ "$FAILED" = 0 ] || { echo "row counts differ from the generator, see $CSV" >&2; exit 1; }
log "wrote $CSV"
