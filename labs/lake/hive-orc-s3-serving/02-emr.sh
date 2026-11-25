#!/usr/bin/env bash
# One EMR cluster: Spark + Hive with Glue as the Hive metastore. 1 x m7g.xlarge primary,
# 4 x m7g.2xlarge core (override with PRIMARY_TYPE / CORE_TYPE / CORE_COUNT). It terminates
# itself after 1 hour idle; 99-destroy.sh terminates it at once.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
set -a; source .env; set +a
BUCKET=$(terraform -chdir=terraform output -raw bucket)
SVC=$(terraform -chdir=terraform output -raw emr_service_role)
PROFILE=$(terraform -chdir=terraform output -raw emr_instance_profile)
RELEASE=${EMR_RELEASE:-$(aws emr list-release-labels --region "$AWS_REGION" --filters Prefix=emr-7 \
  --query 'ReleaseLabels[0]' --output text)}
SUBNET=${SUBNET_ID:-$(aws ec2 describe-subnets --region "$AWS_REGION" --filters Name=default-for-az,Values=true \
  --query 'sort_by(Subnets,&AvailabilityZone)[0].SubnetId' --output text)}
aws s3 cp --recursive spark/ "s3://$BUCKET/scripts/" --exclude '*' --include '*.py' --region "$AWS_REGION"
echo "release=$RELEASE subnet=$SUBNET"
aws emr create-cluster --region "$AWS_REGION" --name hive-orc-s3-serving \
  --release-label "$RELEASE" --applications Name=Spark Name=Hive \
  --instance-groups \
    "InstanceGroupType=MASTER,InstanceCount=1,InstanceType=${PRIMARY_TYPE:-m7g.xlarge}" \
    "InstanceGroupType=CORE,InstanceCount=${CORE_COUNT:-4},InstanceType=${CORE_TYPE:-m7g.2xlarge}" \
  --service-role "$SVC" --ec2-attributes "InstanceProfile=$PROFILE,SubnetId=$SUBNET" \
  --configurations file://emr-config.json --log-uri "s3://$BUCKET/emr-logs/" \
  --auto-termination-policy IdleTimeout=3600 --tags lab=hive-orc-s3-serving \
  --query ClusterId --output text | tee .cluster-id
aws emr wait cluster-running --region "$AWS_REGION" --cluster-id "$(cat .cluster-id)"
aws emr describe-cluster --region "$AWS_REGION" --cluster-id "$(cat .cluster-id)" \
  --query 'Cluster.{state:Status.State,created:Status.Timeline.CreationDateTime,ready:Status.Timeline.ReadyDateTime,release:ReleaseLabel}'
