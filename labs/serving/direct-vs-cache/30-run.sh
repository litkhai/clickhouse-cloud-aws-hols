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
# A transient systemd unit: SSM kills a nohup'd child when its command ends or times out.
ssm_run 60 "mkdir -p /opt/cachebench/results/$STAMP && \
systemd-run --unit cachelab-$PHASE-$STAMP --collect --working-directory=/opt/cachebench \
  -p StandardOutput=append:/opt/cachebench/results/$STAMP/unit-$PHASE.log -p StandardError=inherit \
  /opt/cachebench/matrix.sh $PHASE $STAMP && echo started cachelab-$PHASE-$STAMP"
echo "follow: ./31-fetch.sh $STAMP"
