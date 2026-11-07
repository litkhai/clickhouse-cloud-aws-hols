#!/bin/bash
# Build cachebench for linux/arm64, send it, matrix.sh and the connection env to the client,
# then check that the client reaches all three systems (cachebench floor, 5 s each).
#   ./20-push.sh
# The env file goes through the lab bucket (encrypted at rest) and is deleted from it at once.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
load_config
load_ch
command -v go >/dev/null || die "go is not installed"

echo "== build"
( cd "$LAB_DIR/cachebench" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o bin/cachebench-linux-arm64 . )

ENVF=$(mktemp); chmod 600 "$ENVF"; trap 'rm -f "$ENVF"' EXIT
cat > "$ENVF" <<EOF
CH_URL=https://$CH_HOST:8443
CH_USER=$CH_USER
CH_PASSWORD=$CH_PASSWORD
CH_DB=cachelab
VK_ADDR=$VK_ADDR
VK_TLS=1
AWS_REGION=$REGION
DDB_KV_TABLE=$DDB_KV_TABLE
DDB_ASIDE_TABLE=$DDB_ASIDE_TABLE
EOF

echo "== upload"
aws s3 cp --quiet "$LAB_DIR/cachebench/bin/cachebench-linux-arm64" "s3://$BUCKET/bin/cachebench"
aws s3 cp --quiet "$LAB_DIR/matrix.sh" "s3://$BUCKET/bin/matrix.sh"
aws s3 cp --quiet "$ENVF" "s3://$BUCKET/secret/env"

echo "== install on $INSTANCE_ID"
ssm_run 120 "set -e
cd /opt/cachebench
aws s3 cp --quiet s3://$BUCKET/bin/cachebench ./cachebench && chmod 755 cachebench
aws s3 cp --quiet s3://$BUCKET/bin/matrix.sh ./matrix.sh && chmod 755 matrix.sh
umask 077; aws s3 cp --quiet s3://$BUCKET/secret/env ./env
aws s3 rm --quiet s3://$BUCKET/secret/env
echo BUCKET=$BUCKET >> ./env
echo installed: \$(ls -l cachebench matrix.sh env | awk '{print \$1, \$NF}' | tr '\n' ' ')"

echo "== floor check (5 s per system)"
ssm_run 120 "set -e; cd /opt/cachebench; set -a; . ./env; set +a; ulimit -n 65536
./cachebench floor --conc 1 --duration 5s --out results/push-check.jsonl --run-id push-check >/dev/null
python3 -c 'import json,sys
for l in open(\"results/push-check.jsonl\"):
    r=json.loads(l); print(r[\"arm\"], \"ok\", r[\"ok\"], \"errors\", r[\"errors\"], \"p50_ms\", r[\"lat_ms\"][\"p50\"])'"
