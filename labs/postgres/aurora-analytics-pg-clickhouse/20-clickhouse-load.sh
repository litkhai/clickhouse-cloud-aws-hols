#!/bin/bash
# Load the TPC-DS Parquet files into ClickHouse Cloud MergeTree tables (target P), from the generator.
#   ./20-clickhouse-load.sh --sf N [--s3-tables] [--dry-run]
# Database sf<N>: tables from tpcds-scripts engines/clickhouse/ddl/schema.sql (work/ddl/, pinned commit
# in _lib.sh; type adaptations, see SCHEMA below; no tuning), then per table
#   INSERT INTO sf<N>.<t> SELECT * FROM <source>
# --s3-tables  also database sf<N>_s3: CREATE TABLE sf<N>_s3.<t> AS <source> (the S3 table function as a
#              table: ClickHouse keeps the source and reads the same files on every query; target P-s3)
# --dry-run    print the SQL, run nothing
#
# <source> is a template (env CH_SOURCE_TEMPLATE, placeholders {SF} and {TABLE}); the default is
#   s3('https://$BUCKET.s3.$AWS_REGION.amazonaws.com/$S3_PREFIX/sf{SF}/{TABLE}/*.parquet', 'Parquet',
#      extra_credentials(role_arn = '$CHC_S3_ROLE_ARN'))
# extra_credentials(role_arn = ...): ClickHouse docs, table function s3 ("Parameters", "Using S3 credentials
# (ClickHouse Cloud)") and "Secure S3" (clickhouse.com/docs/cloud/data-sources/secure-s3), read 2026-10-09.
# The local rehearsal sets it to file('tpcds/sf{SF}/{TABLE}/*.parquet', 'Parquet').
# Out: out/P/load-sf<N>.csv (table,rows,expected_rows,seconds,status), out/P/clickhouse-version.txt,
#      out/P/20-clickhouse-load-sf<N>.log. Exit 1 when a table fails or a row count differs from
#      out/datagen-sf<N>.csv.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SF=""; S3T=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sf) SF="${2:?--sf needs a value}"; shift 2 ;;
    --s3-tables) S3T=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$SF" in *[!0-9]*|'') die "--sf N is required (integer)" ;; esac

load_config
require_keys CH_HOST CH_USER CH_PASSWORD
if [ -z "${CH_SOURCE_TEMPLATE:-}" ]; then
  require_keys BUCKET S3_PREFIX AWS_REGION CHC_S3_ROLE_ARN
  CH_SOURCE_TEMPLATE="s3('https://$BUCKET.s3.$AWS_REGION.amazonaws.com/$S3_PREFIX/sf{SF}/{TABLE}/*.parquet', 'Parquet', extra_credentials(role_arn = '$CHC_S3_ROLE_ARN'))"
fi
source_for() { local s="${CH_SOURCE_TEMPLATE//\{SF\}/$SF}"; echo "${s//\{TABLE\}/$1}"; }

SCHEMA_SRC="$WORK_DIR/ddl/clickhouse-schema.sql"
[ -f "$SCHEMA_SRC" ] || die "$SCHEMA_SRC not found (run ./02-queries.sh)"
# Adaptations of the pinned DDL (measured on the local rehearsal, ClickHouse 26.9.13.15, 2026-10-09). The
# Parquet files hold what DuckDB dsdgen wrote; these keep it intact in ClickHouse:
#  1. date_dim.d_date Date -> Date32: date_dim starts at 1900-01-02, ClickHouse Date covers 1970-2149 only
#     (INSERT fails: "Input value -25566 is out of allowed Date range").
#  2. columns without NOT NULL -> Nullable(T): a plain ClickHouse column turns NULL into 0 / '' / 1970-01-01
#     on INSERT. With only (1) applied, 36 of 103 queries returned another answer than the DuckDB reference
#     (screening run, 8 s timeout); with all three adaptations 6 (local/REHEARSAL.md).
#  3. FixedString(N) -> String: the Parquet columns are variable-length strings, and pg_clickhouse pushes
#     substr() down as substringUTF8, which rejects FixedString (queries 08, 15, 19, 45, 85).
# CH_DDL=pinned applies only (1) (what the pinned DDL needs to load at all).
SCHEMA="$WORK_DIR/ddl/clickhouse-schema.lab.sql"
CH_DDL_MODE="${CH_DDL:-adapted}"
python3 - "$SCHEMA_SRC" "$SCHEMA" "$CH_DDL_MODE" <<'PY'
import re, sys
src, dst, mode = sys.argv[1:4]
out, in_table, table, changed = [], False, "", {"d_date": 0, "nullable": 0, "fixedstring": 0}
col = re.compile(r"^(\s+)([A-Za-z_0-9]+)(\s+)([A-Za-z0-9]+(?:\([0-9, ]+\))?)(,?\s*)$")
for line in open(src).read().split("\n"):
    m = re.match(r"^CREATE TABLE (\w+)", line)
    if m:
        in_table, table = True, m.group(1)
    elif in_table and line.startswith(")"):
        in_table = False
    elif in_table:
        if table == "date_dim" and re.match(r"^\s+d_date\s+Date\b", line):
            line = re.sub(r"^(\s+d_date\s+)Date\b", r"\1Date32", line)
            changed["d_date"] += 1
        elif mode == "adapted":
            line2 = re.sub(r"FixedString\(\d+\)", "String", line)
            changed["fixedstring"] += line2 != line
            line = line2
            m2 = col.match(line)
            if m2 and "NOT NULL" not in line and not line.lstrip().startswith("PRIMARY"):
                line = "%s%s%sNullable(%s)%s" % (m2.group(1), m2.group(2), m2.group(3), m2.group(4), m2.group(5))
                changed["nullable"] += 1
    out.append(line)
open(dst, "w").write("\n".join(out))
sys.stderr.write("DDL %s: %s\n" % (mode, changed))
if changed["d_date"] != 1:
    sys.exit("expected exactly one d_date line, changed %d" % changed["d_date"])
PY
if [ "$DRY" = 1 ]; then
  ch_client() { echo "-- ch_client $*" >&2; }
else
  set_log P "20-clickhouse-load-sf$SF"
fi
mkdir -p "$OUT_DIR/P"
CSV="$OUT_DIR/P/load-sf$SF.csv"
DATAGEN="$OUT_DIR/datagen-sf$SF.csv"

ch_client --query "SELECT version()" > "$OUT_DIR/P/clickhouse-version.txt" || die "cannot reach ClickHouse at $CH_HOST"
log "ClickHouse $(cat "$OUT_DIR/P/clickhouse-version.txt")"

echo "table,rows,expected_rows,seconds,status" > "$CSV"
FAILED=0
expected_rows() { # rows of table $1 in datagen-sf<N>.csv, or empty
  [ -f "$DATAGEN" ] || return 0
  awk -F, -v t="$1" '$1 == t { print $2 }' "$DATAGEN"
}

ch_client --query "DROP DATABASE IF EXISTS sf$SF SYNC"
ch_client --query "CREATE DATABASE sf$SF"
ch_client --database "sf$SF" --multiquery < "$SCHEMA"

for t in $TPCDS_TABLES; do
  SRC=$(source_for "$t")
  T0=$(now)
  STATUS=ok
  ch_client --query "INSERT INTO sf$SF.$t SELECT * FROM $SRC" || STATUS=insert_failed
  SECS=$(elapsed "$T0" "$(now)")
  # select_sequential_consistency: on a 2-replica ClickHouse Cloud service the count right after the
  # INSERT can land on the other replica and see fewer rows (web_sales SF10: 6,525,695 of 7,197,566, 2026-10-09).
  ROWS=$(ch_client --query "SELECT count() FROM sf$SF.$t SETTINGS select_sequential_consistency = 1" 2>/dev/null || echo "")
  EXP=$(expected_rows "$t")
  if [ "$STATUS" = ok ] && [ -n "$EXP" ] && [ "$ROWS" != "$EXP" ]; then STATUS="rows_differ"; fi
  [ "$STATUS" = ok ] || FAILED=1
  echo "$t,$ROWS,$EXP,$SECS,$STATUS" >> "$CSV"
  log "$t rows=$ROWS expected=${EXP:-?} ${SECS}s $STATUS"
done
[ -n "$(expected_rows store_sales)" ] || log "WARNING: $DATAGEN not found, row counts were not compared with the generator"

if [ "$S3T" = 1 ]; then
  ch_client --query "DROP DATABASE IF EXISTS sf${SF}_s3 SYNC"
  ch_client --query "CREATE DATABASE sf${SF}_s3"
  for t in $TPCDS_TABLES; do
    ch_client --query "CREATE TABLE sf${SF}_s3.$t AS $(source_for "$t")" || FAILED=1
  done
  ch_client --query "SELECT name, engine FROM system.tables WHERE database = 'sf${SF}_s3' ORDER BY name LIMIT 3"
fi

[ "$FAILED" = 0 ] || { echo "load FAILED, see $CSV" >&2; exit 1; }
log "load ok: $CSV"
