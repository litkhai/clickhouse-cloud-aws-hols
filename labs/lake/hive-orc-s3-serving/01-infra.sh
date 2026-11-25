#!/usr/bin/env bash
# Bucket, Glue database (the Hive catalog), the role ClickHouse Cloud assumes, the EMR roles.
# Needs AWS credentials in the environment and CHC_IAM_ROLE_ARN in .env.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
set -a; source .env; set +a
cd terraform
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve -var "chc_iam_role_arn=${CHC_IAM_ROLE_ARN}" -var "region=${AWS_REGION}"
terraform output
