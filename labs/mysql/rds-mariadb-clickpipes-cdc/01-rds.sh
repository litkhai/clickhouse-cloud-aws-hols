#!/usr/bin/env bash
# Creates the source: a parameter group with the CDC binlog settings, a security group that admits
# the ClickPipes egress IPs of CLICKPIPES_REGIONS (from api.clickhouse.cloud/static-ips.json) and
# this machine, and an RDS MariaDB db.t4g.micro instance (public, 20 GiB gp3, backups 1 day).
# Writes the generated passwords and the endpoint to out/rds.env (mode 600).
set -euo pipefail
cd "$(dirname "$0")"; . ./.env
: "${DB_ID:?}" "${ENGINE:?}" "${ENGINE_VERSION:?}" "${PG_FAMILY:?}" "${CLICKPIPES_REGIONS:?}"
export AWS_REGION
mkdir -p out; umask 077
TAGS=(Key=purpose,Value=clickpipes-mariadb-cdc-lab)
pw() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24; }
[ -s out/rds.env ] || printf 'MASTER_PW=%s\nCP_PW=%s\n' "$(pw)" "$(pw)" > out/rds.env
. out/rds.env

# binlog_row_image is static on RDS MariaDB, so all three go in before the instance boots.
aws rds create-db-parameter-group --db-parameter-group-name "$DB_ID" --db-parameter-group-family "$PG_FAMILY" \
  --description "ClickPipes MySQL CDC source" --tags "${TAGS[@]}" >/dev/null
aws rds modify-db-parameter-group --db-parameter-group-name "$DB_ID" --parameters \
  ParameterName=binlog_format,ParameterValue=ROW,ApplyMethod=pending-reboot \
  ParameterName=binlog_row_image,ParameterValue=FULL,ApplyMethod=pending-reboot \
  ParameterName=binlog_row_metadata,ParameterValue=FULL,ApplyMethod=pending-reboot >/dev/null

VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 create-security-group --group-name "$DB_ID" --description "ClickPipes MySQL CDC source" \
  --vpc-id "$VPC" --query GroupId --output text)
aws ec2 create-tags --resources "$SG" --tags "${TAGS[@]}"
RANGES="{CidrIp=$(curl -s https://checkip.amazonaws.com)/32,Description=operator}"
for r in $CLICKPIPES_REGIONS; do
  for ip in $(curl -s https://api.clickhouse.cloud/static-ips.json | jq -r --arg r "$r" '.aws[] | select(.region==$r) | .clickpipes_egress_ips[]'); do
    RANGES="$RANGES,{CidrIp=$ip/32,Description=clickpipes-$r}"
  done
done
aws ec2 authorize-security-group-ingress --group-id "$SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=3306,ToPort=3306,IpRanges=[$RANGES]" >/dev/null
echo "SG=$SG" >> out/rds.env

aws rds create-db-instance --db-instance-identifier "$DB_ID" --engine "$ENGINE" --engine-version "$ENGINE_VERSION" \
  --db-instance-class db.t4g.micro --allocated-storage 20 --storage-type gp3 \
  --master-username admin --master-user-password "$MASTER_PW" \
  --db-parameter-group-name "$DB_ID" --vpc-security-group-ids "$SG" --publicly-accessible \
  --backup-retention-period 1 --no-multi-az --no-deletion-protection --tags "${TAGS[@]}" >/dev/null
echo "waiting for $DB_ID (about 9 minutes in our run)"
aws rds wait db-instance-available --db-instance-identifier "$DB_ID" || aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
HOST=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].Endpoint.Address' --output text)
echo "RDS_HOST=$HOST" >> out/rds.env
echo "ready: $HOST"
