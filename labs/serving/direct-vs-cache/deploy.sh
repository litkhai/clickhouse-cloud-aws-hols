#!/bin/bash
# Deploy the AWS side of labs/serving/direct-vs-cache.
#   ./deploy.sh
# Read-only preflight (credentials, Valkey version offered, instance types offered in the AZ),
# then terraform init + apply (Terraform asks for confirmation), then config.env.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
cd "$LAB_DIR"

command -v terraform >/dev/null || die "terraform is not installed"
command -v aws >/dev/null || die "aws CLI is not installed"
[ -f terraform.tfvars ] || die "terraform.tfvars not found. Run: cp terraform.tfvars.example terraform.tfvars  and fill it in"

tfvar() {  # value of `name = "value"` in terraform.tfvars, or the default given
  local v
  v=$(sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?[[:space:]]*(#.*)?$/\1/p" terraform.tfvars | tail -1)
  echo "${v:-$2}"
}
REGION=$(tfvar aws_region ap-northeast-2)
AZ=$(tfvar az ap-northeast-2a)
CLIENT=$(tfvar client_instance_type c7g.2xlarge)
NODE=$(tfvar valkey_node_type cache.r7g.large)
VK_VER=$(tfvar valkey_engine_version 8.1)

echo "== preflight (read-only)"
aws sts get-caller-identity --query Account --output text >/dev/null 2>&1 || die "no valid AWS credentials"
N=$(aws elasticache describe-cache-engine-versions --region "$REGION" --engine valkey \
      --engine-version "$VK_VER" --query 'length(CacheEngineVersions)' --output text)
[ "$N" != "0" ] || die "ElastiCache does not offer valkey $VK_VER in $REGION"
echo "   valkey $VK_VER offered in $REGION"
N=$(aws ec2 describe-instance-type-offerings --region "$REGION" --location-type availability-zone \
      --filters "Name=location,Values=$AZ" "Name=instance-type,Values=$CLIENT" \
      --query 'length(InstanceTypeOfferings)' --output text)
[ "$N" != "0" ] || die "$CLIENT is not offered in $AZ"
echo "   $CLIENT offered in $AZ; Valkey node $NODE"

terraform init -input=false
terraform apply

cat > config.env <<EOF
# written by deploy.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) — gitignored
REGION=$(terraform output -raw region)
INSTANCE_ID=$(terraform output -raw instance_id)
CLIENT_PUBLIC_IP=$(terraform output -raw client_public_ip)
VK_ADDR=$(terraform output -raw valkey_endpoint):6379
BUCKET=$(terraform output -raw bucket)
DDB_KV_TABLE=$(terraform output -raw ddb_kv_table)
DDB_ASIDE_TABLE=$(terraform output -raw ddb_aside_table)
EOF
chmod 600 config.env
echo
echo "config.env written. Next:"
echo "  1. add $(terraform output -raw client_public_ip)/32 to the ClickHouse Cloud service's IP access list"
echo "  2. ./10-ch-setup.sh   (schema + data on the ClickHouse Cloud service)"
echo "  3. ./20-push.sh       (binary + connection env to the client)"
