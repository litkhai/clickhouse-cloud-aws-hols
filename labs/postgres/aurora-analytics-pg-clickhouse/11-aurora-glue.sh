#!/bin/bash
# Aurora side of the Glue variant: the 24 Iceberg tables of the Glue catalog as foreign tables in schema ice_sf<N>.
#   ./11-aurora-glue.sh --sf N [--dry-run]
# Run on the generator after 30-iceberg.sh (needs enable_glue = true: GLUE_ICEBERG_DB, GLUE_CATALOG_ARN in config.env).
#   CREATE SCHEMA ice_sf<N>;
#   IMPORT FOREIGN SCHEMA <iceberg_db> LIMIT TO (<t>_sf<N>, ...) FROM SERVER aurora_analytics_server INTO ice_sf<N>
#     OPTIONS (location '<GLUE_CATALOG_ARN>');
#   ALTER FOREIGN TABLE ice_sf<N>.<t>_sf<N> RENAME TO <t>;     -- the query text uses plain names
# then \d of every table and a count per table. Syntax: Aurora User Guide, "Working with foreign tables" (Bulk table
# creation, Modifying foreign tables), read 2026-10-09:
#   https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-analytics-foreign-tables.html
# Only catalog-based sources can be imported; the import is one transaction (one failing table rolls all back).
# Run against the writer (config.env AURORA_HOST is the cluster endpoint); a reader sees the catalog through
# the replicated metadata. Needs the Glue interface endpoint of the Terraform (private DNS) and glue:GetTable / GetTables.
# --dry-run prints the SQL only.
# Out: out/<target>/schema-ice-sf<N>.txt (\d of each table), counts-ice-sf<N>.csv (table,rows,expected_rows,seconds,status),
#      11-aurora-glue-sf<N>.log. Exit 1 when a count differs from out/datagen-sf<N>.csv.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SF=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sf) SF="${2:?--sf needs a value}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$SF" in *[!0-9]*|'') die "--sf N is required (integer)" ;; esac

if [ "$DRY" = 1 ]; then
  GLUE_ICEBERG_DB=ICEBERG_DB; GLUE_CATALOG_ARN=arn:aws:glue:REGION:ACCOUNT:catalog; TARGET=${TARGET:-X}
  aurora_psql() { echo "-- aurora_psql $*" >&2; if [ "${1:-}" != "-c" ]; then cat >&2; fi; }
else
  load_config
  require_keys AURORA_CLASS GLUE_ICEBERG_DB GLUE_CATALOG_ARN
  TARGET=$(target_letter)
  set_log "$TARGET" "11-aurora-glue-sf$SF"
fi
R="$OUT_DIR/$TARGET"
SCHEMA="ice_sf$SF"
DATAGEN="$OUT_DIR/datagen-sf$SF.csv"

LIMIT=""
for t in $TPCDS_TABLES; do LIMIT="${LIMIT:+$LIMIT, }${t}_sf$SF"; done

{
  echo "DROP SCHEMA IF EXISTS $SCHEMA CASCADE;"
  echo "CREATE SCHEMA $SCHEMA;"
  echo "IMPORT FOREIGN SCHEMA $GLUE_ICEBERG_DB LIMIT TO ($LIMIT) FROM SERVER aurora_analytics_server INTO $SCHEMA OPTIONS (location '$GLUE_CATALOG_ARN');"
  for t in $TPCDS_TABLES; do echo "ALTER FOREIGN TABLE $SCHEMA.${t}_sf$SF RENAME TO $t;"; done
} | aurora_psql -q > /dev/null
SCHEMA_OUT="$R/schema-ice-sf$SF.txt"
if [ "$DRY" = 1 ]; then SCHEMA_OUT=/dev/null; else mkdir -p "$R"; fi

{ for t in $TPCDS_TABLES; do echo "\\d $SCHEMA.$t"; done; } | aurora_psql > "$SCHEMA_OUT"
if [ "$DRY" = 1 ]; then exit 0; fi
log "wrote $SCHEMA_OUT"
CSV="$R/counts-ice-sf$SF.csv"
echo "table,rows,expected_rows,seconds,status" > "$CSV"
FAILED=0
for t in $TPCDS_TABLES; do
  T0=$(now)
  STATUS=ok
  ROWS=$(aurora_psql -At -c "SELECT count(*) FROM $SCHEMA.$t" 2>/dev/null | tail -1) || STATUS=count_failed
  SECS=$(elapsed "$T0" "$(now)")
  EXP=""
  [ ! -f "$DATAGEN" ] || EXP=$(awk -F, -v t="$t" '$1 == t { print $2 }' "$DATAGEN")
  if [ "$STATUS" = ok ] && [ -n "$EXP" ] && [ "$ROWS" != "$EXP" ]; then STATUS=rows_differ; fi
  [ "$STATUS" = ok ] || FAILED=1
  echo "$t,$ROWS,$EXP,$SECS,$STATUS" >> "$CSV"
  log "$t rows=$ROWS expected=${EXP:-?} ${SECS}s $STATUS"
done
[ -f "$DATAGEN" ] || log "WARNING: $DATAGEN not found, row counts were not compared with the generator"
[ "$FAILED" = 0 ] || { echo "count FAILED, see $CSV" >&2; exit 1; }
log "done: $R/schema-ice-sf$SF.txt  $CSV"
