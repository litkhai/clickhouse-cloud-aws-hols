#!/bin/bash
# Drop the cachelab database from the ClickHouse Cloud service. Run after the console captures.
#   ./90-ch-cleanup.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
load_ch

ch -q "SELECT table, sum(rows) AS rows FROM system.parts WHERE database = 'cachelab' AND active GROUP BY table ORDER BY table"
read -r -p "Type cachelab to drop the database: " TYPED
[ "$TYPED" = "cachelab" ] || die "name does not match, nothing dropped"
ch -q "DROP DATABASE IF EXISTS cachelab SYNC"
echo "dropped cachelab"
