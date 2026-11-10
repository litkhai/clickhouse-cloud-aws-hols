#!/usr/bin/env bash
# Usage: 03-try-pipe.sh <type> <retention-hours|NULL|keep> [replicationMode]
#   type: rdsmariadb | mariadb | rdsmysql | auroramysql | mysql
# Sets 'binlog retention hours' on the source (unless "keep"), then POSTs a MySQL CDC ClickPipe
# and prints the HTTP status, the error and the requestId. A created pipe's id goes to out/pipes.txt
# so 99-destroy.sh can remove it. Results are appended to out/results.log.
set -euo pipefail
cd "$(dirname "$0")"; . ./.env; . out/rds.env
TYPE=${1:?type}; HOURS=${2:?hours}; MODE=${3:-cdc}
RDS_HOST=${HOST_OVERRIDE:-$RDS_HOST}
M=(mysql -h "$RDS_HOST" -u admin -p"$MASTER_PW" --ssl-mode=REQUIRED -N -B)
[ "$HOURS" = keep ] || "${M[@]}" -e "CALL mysql.rds_set_configuration('binlog retention hours', $HOURS);" 2>/dev/null
NOW=$("${M[@]}" -e "CALL mysql.rds_show_configuration;" 2>/dev/null | awk -F'\t' '$1=="binlog retention hours"{print $2}')
NAME="lab-$TYPE-$MODE-$NOW-$(date +%H%M%S)"
BODY=$(jq -n --arg t "$TYPE" --arg h "$RDS_HOST" --arg pw "$CP_PW" --arg n "$NAME" --arg m "$MODE" '{
  name: $n,
  source: { mysql: {
    type: $t, host: $h, port: 3306, authentication: "basic",
    credentials: { username: "clickpipes_user", password: $pw },
    settings: { replicationMode: $m },
    tableMappings: [{ sourceSchemaName: "shop", sourceTable: "orders",
                      targetTable: ("orders_" + ($n | gsub("-"; "_"))) }] } },
  destination: { database: "mariadb_cdc_lab" } }')
OUT=$(curl -s -w '\n%{http_code}' -u "$CHC_KEY:$CHC_SECRET" -H 'Content-Type: application/json' -X POST \
  "https://api.clickhouse.cloud/v1/organizations/$ORG_ID/services/$SERVICE_ID/clickpipes" -d "$BODY")
CODE=$(tail -n1 <<<"$OUT"); RESP=$(sed '$d' <<<"$OUT")
LINE="$(date -u +%FT%TZ) type=$TYPE mode=$MODE retention=$NOW http=$CODE $(jq -c '{error, requestId, id: .result.id}' <<<"$RESP")"
echo "$LINE" | tee -a out/results.log
ID=$(jq -r '.result.id // empty' <<<"$RESP"); [ -z "$ID" ] || echo "$ID" >> out/pipes.txt
