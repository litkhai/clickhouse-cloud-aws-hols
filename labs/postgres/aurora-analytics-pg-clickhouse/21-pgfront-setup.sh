#!/bin/bash
# PostgreSQL front end for target P / P-s3: pg_clickhouse + the ClickHouse foreign tables.
#   ./21-pgfront-setup.sh --sf N [--s3-tables] [--dry-run]
# Works with a ClickHouse Managed Postgres service (PGFRONT_SSLMODE=require) or the Terraform EC2 front
# end (disable): the connection is only the PGFRONT_* keys. Run on the generator after 20-clickhouse-load.sh.
#  1. CREATE EXTENSION pg_clickhouse; record installed and available version (pg_available_extensions);
#     ALTER EXTENSION pg_clickhouse UPDATE when the installed one is older.
#  2. CREATE SERVER ch_sf<N> (driver 'binary', host CH_HOST, dbname sf<N>) + USER MAPPING for the CH_* user.
#     The ClickHouse Cloud host gets TLS on port 9440 by default.
#  3. IMPORT FOREIGN SCHEMA sf<N> INTO schema sf<N> (and sf<N>_s3 -> sf<N>_s3 with --s3-tables); \d dump.
# The query text is unqualified; run.py sets search_path = sf<N> (P) or sf<N>_s3 (P-s3), as for Aurora.
# Option names: pg_clickhouse v0.11.0 reference, "CREATE SERVER" / "CREATE USER MAPPING" / "IMPORT FOREIGN
# SCHEMA": https://github.com/ClickHouse/pg_clickhouse/blob/v0.11.0/doc/pg_clickhouse.md (read 2026-10-09).
# Rehearsal-only overrides: PGCH_HOST / PGCH_PORT (where the front end reaches ClickHouse), CH_SECURE=0.
# Out: out/P/pg_clickhouse-version.txt, out/P/schema-sf<N>.txt, out/P/21-pgfront-setup-sf<N>.log.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SF=""; S3T=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sf) SF="${2:?--sf needs a value}"; shift 2 ;;
    --s3-tables) S3T=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$SF" in *[!0-9]*|'') die "--sf N is required (integer)" ;; esac

load_config
require_keys CH_HOST CH_USER CH_PASSWORD
sqlq() { printf "%s" "$1" | sed "s/'/''/g"; }   # SQL string literal body
if [ "$DRY" = 1 ]; then
  pgfront_psql() { echo "-- pgfront_psql $*" >&2; if [ "${1:-}" != "-c" ]; then cat >&2; fi; }
else
  set_log P "21-pgfront-setup-sf$SF"
fi
mkdir -p "$OUT_DIR/P"
VERFILE="$OUT_DIR/P/pg_clickhouse-version.txt"

SERVER_HOST="${PGCH_HOST:-$CH_HOST}"
OPTS="driver 'binary', host '$(sqlq "$SERVER_HOST")'"
[ -z "${PGCH_PORT:-}" ] || OPTS="$OPTS, port '$PGCH_PORT'"
if [ "${CH_SECURE:-1}" = 1 ]; then OPTS="$OPTS, secure 'on'"; else OPTS="$OPTS, secure 'off'"; fi

# ---- 1. extension and version ------------------------------------------------------------------------
pgfront_psql >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_clickhouse;
SQL
VER=$(pgfront_psql -At -F ' ' 2>/dev/null <<'SQL' || true
SELECT installed_version, default_version,
       (string_to_array(installed_version, '.')::int[] < string_to_array(default_version, '.')::int[])
FROM pg_available_extensions WHERE name = 'pg_clickhouse';
SQL
)
[ "$DRY" = 1 ] || [ -n "$VER" ] || die "pg_clickhouse is not in pg_available_extensions on the front end"
read -r INSTALLED AVAILABLE OLDER <<<"$VER"
if [ "${OLDER:-f}" = t ]; then
  log "pg_clickhouse $INSTALLED installed, $AVAILABLE available: ALTER EXTENSION UPDATE"
  pgfront_psql >/dev/null <<'SQL'
ALTER EXTENSION pg_clickhouse UPDATE;
SQL
fi
AFTER=$(pgfront_psql -At -c "SELECT extversion FROM pg_extension WHERE extname = 'pg_clickhouse'" 2>/dev/null || true)
{
  echo "installed_before=${INSTALLED:-}"
  echo "available=${AVAILABLE:-}"
  echo "installed_after=${AFTER:-}"
  pgfront_psql -At -c "SELECT 'postgres=' || split_part(version(), ' (', 1)" 2>/dev/null || true
} > "$VERFILE"
log "pg_clickhouse installed_before=${INSTALLED:-?} available=${AVAILABLE:-?} installed_after=${AFTER:-?}"

# ---- 2 + 3. servers, user mappings, foreign tables ----------------------------------------------------
setup_db() { # setup_db <clickhouse database = pg schema>
  local db="$1" srv
  srv="ch_$db"
  pgfront_psql >/dev/null <<SQL
SET client_min_messages = warning;
DROP SERVER IF EXISTS $srv CASCADE;
CREATE SERVER $srv FOREIGN DATA WRAPPER clickhouse_fdw OPTIONS ($OPTS, dbname '$db');
CREATE USER MAPPING FOR CURRENT_USER SERVER $srv OPTIONS (user '$(sqlq "$CH_USER")', password '$(sqlq "$CH_PASSWORD")');
DROP SCHEMA IF EXISTS $db CASCADE;
CREATE SCHEMA $db;
IMPORT FOREIGN SCHEMA $db FROM SERVER $srv INTO $db;
SQL
  # run.py's cold step calls clickhouse_perform('SYSTEM DROP ... CACHE'); no role has EXECUTE by default
  pgfront_psql -c "GRANT EXECUTE ON PROCEDURE clickhouse_perform(text, text) TO CURRENT_USER" >/dev/null \
    || log "WARNING: could not GRANT EXECUTE on clickhouse_perform; the cold step of run.py will record it as refused"
  {
    echo "-- schema $db: foreign tables"
    pgfront_psql -At -c "SELECT count(*) || ' foreign tables in schema $db' FROM information_schema.foreign_tables WHERE foreign_table_schema = '$db'"
    for t in $TPCDS_TABLES; do echo "\\d $db.$t"; done | pgfront_psql
    pgfront_psql -At -c "SELECT 'clickhouse_server_version=' || clickhouse_server_version('$srv')"
  } >> "$OUT_DIR/P/schema-sf$SF.txt"
}
: > "$OUT_DIR/P/schema-sf$SF.txt"
setup_db "sf$SF"
[ "$S3T" = 0 ] || setup_db "sf${SF}_s3"
# the parameter exists once the extension is loaded in the session: call one of its functions first
pgfront_psql -At >> "$VERFILE" <<SQL
SELECT 'clickhouse_server_version=' || clickhouse_server_version('ch_sf$SF');
SELECT 'pg_clickhouse.session_settings=' || current_setting('pg_clickhouse.session_settings');
SQL
echo "done: $VERFILE  $OUT_DIR/P/schema-sf$SF.txt"
