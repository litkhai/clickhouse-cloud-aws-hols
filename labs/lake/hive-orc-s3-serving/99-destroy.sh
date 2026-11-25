#!/usr/bin/env bash
# Terminate the EMR cluster, drop the ClickHouse objects, destroy the Terraform stack (bucket included).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
set -a; source .env; set +a
if [ -f .cluster-id ]; then
  aws emr terminate-clusters --region "$AWS_REGION" --cluster-ids "$(cat .cluster-id)"
  aws emr wait cluster-terminated --region "$AWS_REGION" --cluster-id "$(cat .cluster-id)"
fi
for q in "DROP DATABASE IF EXISTS hive_orc_glue" "DROP DATABASE IF EXISTS hive_orc_lab"; do
  clickhouse client --secure --host "$CH_HOST" --user "$CH_USER" --password "$CH_PASSWORD" -q "$q"
done
# Glue tables Spark and Athena created live in the database Terraform owns; drop them so destroy succeeds.
for t in events_raw item_events events_iceberg; do
  aws glue delete-table --region "$AWS_REGION" --database-name game_lake --name "$t" 2>/dev/null || true
done
# The first Hive client on EMR creates a Glue `default` database (location hdfs://<primary>…) when the
# region has none. Drop it only when it is that one: empty and pointing at HDFS.
loc=$(aws glue get-database --region "$AWS_REGION" --name default --query Database.LocationUri --output text 2>/dev/null)
n=$(aws glue get-tables --region "$AWS_REGION" --database-name default --query 'length(TableList)' --output text 2>/dev/null)
if [[ "$loc" == hdfs://* && "$n" == 0 ]]; then
  aws glue delete-database --region "$AWS_REGION" --name default
fi
terraform -chdir=terraform destroy -input=false -auto-approve -var "chc_iam_role_arn=${CHC_IAM_ROLE_ARN}" -var "region=${AWS_REGION}"
rm -f .cluster-id .steps
