#!/bin/bash
# Deploy the aurora_analytics / pg_clickhouse lab.
#   ./deploy.sh [--class <db.instance.class>]
# Read-only preflight (is the class orderable?), then terraform init + apply (Terraform asks for
# confirmation), then config.env. --class overrides aurora_instance_class for this run only
# (-var); it is not written to terraform.tfvars.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLASS_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --class) CLASS_OVERRIDE="${2:?--class needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1 (usage: ./deploy.sh [--class <db.instance.class>])" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

command -v terraform >/dev/null || die "terraform is not installed"
command -v aws >/dev/null || die "aws CLI is not installed"
[ -f terraform.tfvars ] || die "terraform.tfvars not found. Run: cp terraform.tfvars.example terraform.tfvars  and fill it in"

# Value of `name = "value"` in terraform.tfvars, or the default from variables.tf
tfvar() {
  local v
  v=$(sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?[[:space:]]*(#.*)?$/\1/p" terraform.tfvars | tail -1)
  echo "${v:-$2}"
}

REGION=$(tfvar aws_region ap-northeast-2)
ENGINE_VERSION=$(tfvar aurora_engine_version 17.11)
CLASS=${CLASS_OVERRIDE:-$(tfvar aurora_instance_class db.t4g.large)}
STORAGE=$(tfvar aurora_storage_type "")
KEY_NAME=$(tfvar key_name "<your-key>")
CREATE_AURORA=$(tfvar create_aurora true)
CREATE_PGFRONT=$(tfvar create_pgfront false)
[ -n "$STORAGE" ] || STORAGE=aurora   # the orderable-options API calls Aurora Standard "aurora"

# ---------------------------------------------------------------- preflight (read-only)
if [ "$CREATE_AURORA" = "true" ]; then
  echo "== preflight: is $CLASS orderable for aurora-postgresql $ENGINE_VERSION in $REGION ($STORAGE)?"
  aws sts get-caller-identity >/dev/null 2>&1 || die "no valid AWS credentials (aws sts get-caller-identity failed)"
  mkdir -p out
  OUT="out/orderable-${CLASS}.json"
  aws rds describe-orderable-db-instance-options \
    --engine aurora-postgresql --engine-version "$ENGINE_VERSION" \
    --db-instance-class "$CLASS" --region "$REGION" --output json > "$OUT"
  N=$(aws rds describe-orderable-db-instance-options \
    --engine aurora-postgresql --engine-version "$ENGINE_VERSION" \
    --db-instance-class "$CLASS" --region "$REGION" \
    --query 'length(OrderableDBInstanceOptions)' --output text)
  if [ "$N" = "0" ]; then
    die "$CLASS is not orderable for aurora-postgresql $ENGINE_VERSION in $REGION (empty list, saved in $OUT). Pick another class or version."
  fi
  M=$(aws rds describe-orderable-db-instance-options \
    --engine aurora-postgresql --engine-version "$ENGINE_VERSION" \
    --db-instance-class "$CLASS" --region "$REGION" \
    --query "length(OrderableDBInstanceOptions[?StorageType=='$STORAGE'])" --output text)
  if [ "$M" = "0" ]; then
    die "$CLASS is orderable, but not with storage type '$STORAGE' (see $OUT). Change aurora_storage_type."
  fi
  echo "   orderable: $N option(s), $M with storage type '$STORAGE' (details: $OUT)"
else
  echo "== preflight skipped: create_aurora = false"
fi

# ---------------------------------------------------------------- apply
TF_ARGS=()
[ -z "$CLASS_OVERRIDE" ] || TF_ARGS+=(-var "aurora_instance_class=$CLASS_OVERRIDE")

terraform init -input=false
# Terraform's own confirmation: no -auto-approve, no saved plan file
terraform apply ${TF_ARGS[@]+"${TF_ARGS[@]}"}

# ---------------------------------------------------------------- config.env
# Keep the hand-filled CH_* lines of an existing config.env; rewrite only the Terraform ones.
PREV=""
if [ -f config.env ]; then
  PREV=$(mktemp)
  cp config.env "$PREV"
fi
keep() { # keep <KEY> <default>: value from the previous config.env, else the default
  local v=""
  [ -z "$PREV" ] || v=$(grep -E "^$1=" "$PREV" | head -1 | cut -d= -f2- || true)
  echo "${v:-$2}"
}
out() { terraform output -raw "$1"; }
# Read every output first: a failing `terraform output` must stop the script, not write a blank value
o_aws_region=$(out aws_region)
o_bucket=$(out bucket)
o_aurora_cluster_id=$(out aurora_cluster_id)
o_aurora_instance_id=$(out aurora_instance_id)
o_aurora_class=$(out aurora_class)
o_aurora_host=$(out aurora_host)
o_aurora_secret_arn=$(out aurora_secret_arn)
o_pgfront_host=$(out pgfront_host)
o_pgfront_password=$(out pgfront_password)
o_pgfront_instance_id=$(out pgfront_instance_id)
o_pgfront_public_ip=$(out pgfront_public_ip)
o_generator_public_ip=$(out generator_public_ip)
o_chc_s3_role_arn=$(out chc_s3_role_arn)
o_glue_parquet_db=$(out glue_parquet_db)
o_glue_iceberg_db=$(out glue_iceberg_db)
o_athena_workgroup=$(out athena_workgroup)
o_glue_catalog_arn=$(out glue_catalog_arn)

# TLS to the front end: the EC2 one (create_pgfront = true) listens without it; a Managed Postgres service
# (hand-filled PGFRONT_*) needs it. A value already in config.env is kept.
PGFRONT_SSLMODE_DEFAULT=require
[ "$CREATE_PGFRONT" != "true" ] || PGFRONT_SSLMODE_DEFAULT=disable

umask 077
cat > config.env.new <<ENV
AWS_REGION=$o_aws_region
BUCKET=$o_bucket
S3_PREFIX=tpcds
AURORA_CLUSTER_ID=$o_aurora_cluster_id
AURORA_INSTANCE_ID=$o_aurora_instance_id
AURORA_CLASS=$o_aurora_class
AURORA_HOST=$o_aurora_host
AURORA_PORT=5432
AURORA_USER=postgres
AURORA_DB=postgres
AURORA_SECRET_ARN=$o_aurora_secret_arn
PGFRONT_HOST=$o_pgfront_host
PGFRONT_PORT=5432
PGFRONT_USER=postgres
PGFRONT_PASSWORD=$o_pgfront_password
PGFRONT_DB=postgres
PGFRONT_SSLMODE=$(keep PGFRONT_SSLMODE "$PGFRONT_SSLMODE_DEFAULT")
PGFRONT_INSTANCE_ID=$o_pgfront_instance_id
PGFRONT_PUBLIC_IP=$o_pgfront_public_ip
GENERATOR_PUBLIC_IP=$o_generator_public_ip
CHC_S3_ROLE_ARN=$o_chc_s3_role_arn
GLUE_PARQUET_DB=$o_glue_parquet_db
GLUE_ICEBERG_DB=$o_glue_iceberg_db
ATHENA_WORKGROUP=$o_athena_workgroup
GLUE_CATALOG_ARN=$o_glue_catalog_arn
# filled by hand after creating the ClickHouse Cloud service
CH_HOST=$(keep CH_HOST "")
CH_USER=$(keep CH_USER default)
CH_PASSWORD=$(keep CH_PASSWORD "")
CH_SERVICE_ID=$(keep CH_SERVICE_ID "")
CH_REPLICA_MEMORY_GB=$(keep CH_REPLICA_MEMORY_GB 8)
CH_REPLICAS=$(keep CH_REPLICAS "")
ENV
mv config.env.new config.env
chmod 600 config.env
[ -z "$PREV" ] || rm -f "$PREV"

GEN_IP=$o_generator_public_ip
PGF_IP=$o_pgfront_public_ip
echo
echo "== config.env written (mode 600)."
echo "   Note: --class is not saved; the next ./deploy.sh without --class uses aurora_instance_class from terraform.tfvars."
echo
echo "Copy it to the generator and log in (the user data needs a few minutes; wait for /var/log/lab-ready):"
echo "  scp -i ~/.ssh/${KEY_NAME}.pem config.env ec2-user@${GEN_IP}:~/"
echo "  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${GEN_IP}"
echo "  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PGF_IP}    # PG front end"
echo
echo "Add GENERATOR_PUBLIC_IP (${GEN_IP}) and PGFRONT_PUBLIC_IP (${PGF_IP}) to the ClickHouse Cloud IP access list."
