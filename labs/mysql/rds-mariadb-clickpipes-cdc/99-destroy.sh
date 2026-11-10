#!/usr/bin/env bash
# Removes what the lab created: the pipes in out/pipes.txt, the destination database, the RDS
# instance (no final snapshot), its parameter group and security group. The ClickHouse Cloud
# service is not touched. Run `terraform -chdir=terraform destroy` first if you applied it.
set -euo pipefail
cd "$(dirname "$0")"; . ./.env; . out/rds.env
export AWS_REGION
API="https://api.clickhouse.cloud/v1/organizations/$ORG_ID/services/$SERVICE_ID/clickpipes"
if [ -s out/pipes.txt ]; then
  while read -r id; do
    curl -s -o /dev/null -w "pipe $id %{http_code}\n" -u "$CHC_KEY:$CHC_SECRET" -X DELETE "$API/$id"
  done < out/pipes.txt
  rm out/pipes.txt
fi
if [ -n "${CH_HOST:-}" ]; then
  clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" -q "DROP DATABASE IF EXISTS mariadb_cdc_lab"
fi
aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot --delete-automated-backups >/dev/null
aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID"
aws rds delete-db-parameter-group --db-parameter-group-name "$DB_ID"
aws ec2 delete-security-group --group-id "$SG"
echo "removed $DB_ID, its parameter group and $SG"
