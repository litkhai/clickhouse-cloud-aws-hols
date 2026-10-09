#!/bin/bash
# Fetch the single query set: tpcds-scripts engines/duckdb/queries at TPCDS_SCRIPTS_SHA (see _lib.sh),
# plus engines/clickhouse/ddl/schema.sql and engines/postgres/ddl/schema.sql from the same commit.
#   ./02-queries.sh
# Result: work/queries/*.sql (patches/*.diff applied), work/ddl/*.sql, out/queries.sha256.
# patches/queryNN.diff (unified diff against work/, first line a comment saying why) are applied to
# every target including R; there are none unless the rehearsal found a query that fails.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

command -v git >/dev/null || die "git is not installed"
SRC="$WORK_DIR/tpcds-scripts"
mkdir -p "$SRC" "$OUT_DIR"
cd "$SRC"
[ -d .git ] || git init -q .
git fetch -q --depth 1 "$TPCDS_SCRIPTS_URL" "$TPCDS_SCRIPTS_SHA"
git -c advice.detachedHead=false checkout -q -f FETCH_HEAD
[ "$(git rev-parse HEAD)" = "$TPCDS_SCRIPTS_SHA" ] || die "fetched $(git rev-parse HEAD), expected $TPCDS_SCRIPTS_SHA"

cd "$LAB_DIR"
rm -rf "$WORK_DIR/queries" "$WORK_DIR/ddl"
mkdir -p "$WORK_DIR/queries" "$WORK_DIR/ddl"
cp "$SRC"/engines/duckdb/queries/*.sql "$WORK_DIR/queries/"
cp "$SRC/engines/clickhouse/ddl/schema.sql" "$WORK_DIR/ddl/clickhouse-schema.sql"
cp "$SRC/engines/postgres/ddl/schema.sql" "$WORK_DIR/ddl/postgres-schema.sql"
N=$(ls "$WORK_DIR/queries"/*.sql | wc -l | tr -d ' ')
[ "$N" = 103 ] || die "expected 103 query files, found $N"

if ls "$LAB_DIR"/patches/*.diff >/dev/null 2>&1; then
  for p in "$LAB_DIR"/patches/*.diff; do
    echo "patch: $(basename "$p"): $(head -1 "$p")"
    patch -s -p0 -d "$WORK_DIR" < "$p"
  done
else
  echo "no patches: the query text is the commit's, unchanged"
fi

( cd "$WORK_DIR" && sha256_files queries/*.sql ddl/*.sql ) > "$OUT_DIR/queries.sha256"
echo "tpcds-scripts $TPCDS_SCRIPTS_SHA: $N queries -> $WORK_DIR/queries, hashes in $OUT_DIR/queries.sha256"
