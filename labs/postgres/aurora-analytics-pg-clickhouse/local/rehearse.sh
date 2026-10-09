#!/bin/bash
# Local rehearsal of the lab's scripts against Docker only (no AWS, no ClickHouse Cloud).
#   ./local/rehearse.sh --sf N [--keep] [--timeout S]   run everything, write local/REHEARSAL.md, clean up
#   ./local/rehearse.sh cleanup                         remove the containers and volumes
# Steps: 02-queries -> 01-generate (Parquet + DuckDB file) -> docker compose up (pg_clickhouse 18-0.11.0,
# ClickHouse server) -> 20-clickhouse-load (file() instead of s3()) -> 21-pgfront-setup (no TLS) ->
# plain PostgreSQL loaded by COPY (database "plain", same container) -> run.py correctness for R, P, PG (all
# queries, P and PG in parallel) and P-s3 (5 queries, a smoke check of the table-function tables)
# -> compare.py -> local/report.py.
# Everything lands in out/rehearsal/ and work/rehearsal/ (gitignored). --keep leaves the containers running.
# --timeout is the per-query timeout of run.py in seconds (default 60; the real run uses 600).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
cd "$LAB"

export LAB_OUT="$LAB/out/rehearsal" LAB_WORK="$LAB/work/rehearsal"
export PARQUET_DIR="$LAB_WORK/parquet" CSV_DIR="$LAB_WORK/csv"
export CH_NATIVE_PORT=19000 PG_PORT=55432
# throwaway password of the two local containers, random per run, never written outside out/rehearsal/config.env
REHEARSAL_PASSWORD="${REHEARSAL_PASSWORD:-$(python3 -c 'import secrets; print(secrets.token_hex(8))')}"
export REHEARSAL_PASSWORD
COMPOSE=(docker compose -f "$HERE/compose.yaml")

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans; }

SF=""; KEEP=0; TIMEOUT=60
case "${1:-}" in
  cleanup) cleanup; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --sf) SF="${2:?--sf needs a value}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$SF" in *[!0-9]*|'') echo "--sf N is required" >&2; exit 2 ;; esac
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v duckdb >/dev/null || { echo "duckdb CLI is required" >&2; exit 1; }
command -v clickhouse >/dev/null || { echo "the clickhouse binary (client) is required" >&2; exit 1; }
command -v uv >/dev/null || { echo "uv is required" >&2; exit 1; }

step() { echo; echo "== $*"; }
runpy() { uv run --quiet --with 'psycopg[binary]' --with duckdb==1.5.6 "$LAB/run.py" "$@"; }

[ "$KEEP" = 1 ] || trap cleanup EXIT
mkdir -p "$LAB_OUT" "$LAB_WORK" "$CSV_DIR"
# run.py appends: start every rehearsal from empty result files
find "$LAB_OUT" -name 'sf*-correctness.csv' -delete
START=$(date -u +%FT%TZ)

step "queries (pinned tpcds-scripts commit)"
"$LAB/02-queries.sh"

step "generate SF$SF (DuckDB tpcds extension) into $PARQUET_DIR/sf$SF"
"$LAB/01-generate.sh" --sf "$SF" --dest "$PARQUET_DIR/sf$SF"

step "export CSV for the plain-PostgreSQL check"
{
  for t in $(awk -F, 'NR > 1 { print $1 }' "$LAB_OUT/datagen-sf$SF.csv"); do
    echo "COPY $t TO '$CSV_DIR/$t.csv' (FORMAT csv, HEADER false);"
  done
} | duckdb -noheader -list "$LAB_WORK/tpcds-sf$SF.duckdb" -readonly > /dev/null

step "containers"
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --wait

# The front-end database uses the binary ("C") collation, like DuckDB and ClickHouse. With the image's
# default en_US.utf8, queries 18 (ORDER BY ... LIMIT picks other rows) and 57 (mergejoin input data is out of
# order) differ from R (measured 2026-10-09, see REHEARSAL.md).
docker exec aa-rehearsal-pg psql -U postgres -q -c "CREATE DATABASE pgc TEMPLATE template0 LOCALE_PROVIDER libc LOCALE 'C'"

cat > "$LAB_OUT/config.env" <<ENV
PGFRONT_HOST=127.0.0.1
PGFRONT_PORT=$PG_PORT
PGFRONT_USER=postgres
PGFRONT_PASSWORD=$REHEARSAL_PASSWORD
PGFRONT_DB=pgc
PGFRONT_SSLMODE=disable
CH_HOST=127.0.0.1
CH_USER=default
CH_PASSWORD=$REHEARSAL_PASSWORD
CH_SECURE=0
CH_PORT=$CH_NATIVE_PORT
PGCH_HOST=ch
PGCH_PORT=9000
CH_SOURCE_TEMPLATE=file('tpcds/sf{SF}/{TABLE}/*.parquet', 'Parquet')
ENV
chmod 600 "$LAB_OUT/config.env"
export CONFIG_ENV="$LAB_OUT/config.env" LAB_PSQL_DOCKER=aa-rehearsal-pg

step "20-clickhouse-load (file() source)"
"$LAB/20-clickhouse-load.sh" --sf "$SF" --s3-tables

step "21-pgfront-setup (no TLS)"
"$LAB/21-pgfront-setup.sh" --sf "$SF" --s3-tables

step "plain PostgreSQL: schema + COPY (database plain)"
source "$LAB/_lib.sh"
load_config
set_log PG "load-sf$SF"
# Binary ("C") collation, like DuckDB and ClickHouse: with en_US.utf8 the ORDER BY ... LIMIT 100 queries
# pick other rows at the boundary (measured, see the notes); here every remaining difference is semantics.
# The tpcds-scripts PostgreSQL DDL has customer.c_last_review_date char(10); dsdgen writes c_last_review_date_sk
# (an integer), so the column is renamed for this check.
pgfront_psql -q <<'SQL'
DROP DATABASE IF EXISTS plain;
CREATE DATABASE plain TEMPLATE template0 LOCALE_PROVIDER libc LOCALE 'C';
SQL
{
  echo "CREATE SCHEMA sf$SF; SET search_path = sf$SF;"
  sed -E 's/^([[:space:]]*)c_last_review_date([[:space:]]+)char\(10\)/\1c_last_review_date_sk\2integer  /' "$WORK_DIR/ddl/postgres-schema.sql"
  for t in $TPCDS_TABLES; do echo "COPY $t FROM '/csv/$t.csv' (FORMAT csv);"; done
  echo "ANALYZE;"
} | PGFRONT_DB_OVERRIDE=plain pgfront_psql -q > /dev/null
PGFRONT_DB_OVERRIDE=plain pgfront_psql -At -c "SELECT 'plain PostgreSQL store_sales rows: ' || count(*) FROM sf$SF.store_sales"

step "run.py correctness: R, then P and PG in parallel (timeout ${TIMEOUT}s), then P-s3 on 5 queries"
runpy --target R --sf "$SF" --phase correctness --pause 0
runpy --target P --sf "$SF" --phase correctness --pause 0 --timeout "$TIMEOUT" > "$LAB_OUT/P-run.out" 2>&1 &
PID_P=$!
runpy --target PG --sf "$SF" --phase correctness --pause 0 --timeout "$TIMEOUT" > "$LAB_OUT/PG-run.out" 2>&1 &
PID_PG=$!
RC=0
wait "$PID_P" || RC=1
wait "$PID_PG" || RC=1
tail -n 3 "$LAB_OUT/P-run.out" "$LAB_OUT/PG-run.out"
[ "$RC" = 0 ] || { echo "run.py failed for P or PG (see $LAB_OUT/P-run.out, PG-run.out)" >&2; exit 1; }
runpy --target P-s3 --sf "$SF" --phase correctness --pause 0 --timeout "$TIMEOUT" --queries 3,7,42,52,55

step "compare.py"
python3 "$LAB/compare.py" --sf "$SF" --targets P,P-s3,PG

step "local/REHEARSAL.md"
{
  echo "start=$START"
  echo "end=$(date -u +%FT%TZ)"
  echo "timeout=$TIMEOUT"
  echo "pg_image=$(docker inspect aa-rehearsal-pg --format '{{.Config.Image}}')"
  echo "ch_image=$(docker inspect aa-rehearsal-ch --format '{{.Config.Image}}')"
  echo "docker_mem=$(docker info --format '{{.MemTotal}}')"
  echo "docker_cpus=$(docker info --format '{{.NCPU}}')"
  echo "host_arch=$(uname -m)"
  echo "host_os=$(uname -sr)"
  echo "host_cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
  echo "host_mem=$(sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/ { print $2 * 1024 }' /proc/meminfo)"
} > "$LAB_OUT/facts.env"
python3 "$HERE/report.py" --sf "$SF" > "$HERE/REHEARSAL.md"
echo "wrote $HERE/REHEARSAL.md"
[ "$KEEP" = 1 ] || echo "containers and volumes are removed on exit"
