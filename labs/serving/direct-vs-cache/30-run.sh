#!/bin/bash
# Start one phase of the run matrix on the client, in the background, and return.
#   ./30-run.sh floor|s1|kv|s2|s3|all [stamp]
# Follow it with ./31-fetch.sh <stamp>. Full matrix ≈ 2 floor + 36 s1 + 2 kv + 24 s2 + 16 s3 runs,
# about 70 s each (10 s warm-up + 60 s) plus 10 s for the server stats: roughly 1 h 40 min.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
load_config

PHASE=${1:?usage: ./30-run.sh floor|s1|kv|s2|s3|all [stamp]}
STAMP=${2:-$(date -u +%Y%m%dT%H%M%SZ)}
ssm_run 60 "cd /opt/cachebench && mkdir -p results/$STAMP && \
nohup ./matrix.sh $PHASE $STAMP > results/$STAMP/nohup-$PHASE.log 2>&1 < /dev/null & echo started $PHASE $STAMP pid \$!"
echo "follow: ./31-fetch.sh $STAMP"
