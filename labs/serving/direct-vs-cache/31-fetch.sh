#!/bin/bash
# Copy the results of one stamp from the lab bucket to results/<stamp>/ and show the matrix log tail.
#   ./31-fetch.sh <stamp>
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
load_config

STAMP=${1:?usage: ./31-fetch.sh <stamp>}
mkdir -p "$LAB_DIR/results/$STAMP"
aws s3 sync --quiet "s3://$BUCKET/results/$STAMP/" "$LAB_DIR/results/$STAMP/"
echo "== results/$STAMP"
wc -l "$LAB_DIR"/results/"$STAMP"/*.jsonl 2>/dev/null || echo "(no result lines yet)"
echo "== matrix.log (last 5)"
tail -5 "$LAB_DIR/results/$STAMP/matrix.log" 2>/dev/null || true
