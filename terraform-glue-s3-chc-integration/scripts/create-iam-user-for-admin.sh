#!/bin/bash
# Script to create IAM User for ClickHouse Glue Catalog integration
# This script must be run by an AWS administrator with iam:CreateUser permission

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Create IAM User for ClickHouse Glue Catalog"
echo "=========================================="
echo ""

# Get values from Terraform
cd "$PROJECT_DIR"

if [ ! -f "terraform.tfstate" ]; then
    echo -e "${RED}Error: terraform.tfstate not found. Please run 'terraform apply' first.${NC}"
    exit 1
fi

S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null)
GLUE_DATABASE=$(terraform output -raw glue_database_name 2>/dev/null)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [ -z "$S3_BUCKET" ] || [ -z "$GLUE_DATABASE" ] || [ -z "$AWS_REGION" ]; then
    echo -e "${RED}Error: Could not get required values from Terraform outputs${NC}"
    exit 1
fi

echo "Configuration:"
echo "  S3 Bucket:      $S3_BUCKET"
echo "  Glue Database:  $GLUE_DATABASE"
echo "  AWS Region:     $AWS_REGION"
echo "  AWS Account:    $ACCOUNT_ID"
echo ""

USER_NAME="chc-glue-integration-glue-user"
POLICY_NAME="chc-glue-integration-glue-catalog-policy"

# Check if user already exists
if aws iam get-user --user-name "$USER_NAME" &>/dev/null; then
    echo -e "${YELLOW}Warning: User '$USER_NAME' already exists${NC}"
    read -p "Do you want to update the policy and create new access keys? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
else
    # Create IAM User
    echo "Creating IAM User: $USER_NAME"
    aws iam create-user \
        --user-name "$USER_NAME" \
        --tags Key=Project,Value=ClickHouse-Glue-Integration Key=ManagedBy,Value=Manual \
        || {
            echo -e "${RED}Error: Failed to create IAM User${NC}"
            echo -e "${YELLOW}You may not have permission to create IAM Users.${NC}"
            echo -e "${YELLOW}Please ask your AWS administrator to run this script.${NC}"
            exit 1
        }
    echo -e "${GREEN}✓ IAM User created${NC}"
fi

# Create policy document
POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}",
        "arn:aws:s3:::${S3_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase",
        "glue:GetDatabases",
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetPartition",
        "glue:GetPartitions",
        "glue:BatchGetPartition"
      ],
      "Resource": [
        "arn:aws:glue:${AWS_REGION}:${ACCOUNT_ID}:catalog",
        "arn:aws:glue:${AWS_REGION}:${ACCOUNT_ID}:database/${GLUE_DATABASE}",
        "arn:aws:glue:${AWS_REGION}:${ACCOUNT_ID}:table/${GLUE_DATABASE}/*"
      ]
    }
  ]
}
EOF
)

# Attach policy
echo "Attaching IAM policy: $POLICY_NAME"
aws iam put-user-policy \
    --user-name "$USER_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document "$POLICY_DOC" \
    || {
        echo -e "${RED}Error: Failed to attach policy${NC}"
        exit 1
    }
echo -e "${GREEN}✓ IAM Policy attached${NC}"

# List existing access keys
EXISTING_KEYS=$(aws iam list-access-keys --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text)

if [ -n "$EXISTING_KEYS" ]; then
    echo -e "${YELLOW}Warning: User already has access keys:${NC}"
    for key in $EXISTING_KEYS; do
        echo "  - $key"
    done
    read -p "Do you want to create a new access key? (existing keys will remain active) (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping access key creation."
        echo ""
        echo -e "${GREEN}✓ Setup complete${NC}"
        echo ""
        echo "Use existing access keys with ClickHouse Cloud."
        exit 0
    fi
fi

# Create access keys
echo "Creating access keys..."
ACCESS_KEY_OUTPUT=$(aws iam create-access-key --user-name "$USER_NAME" --output json)

ACCESS_KEY_ID=$(echo "$ACCESS_KEY_OUTPUT" | jq -r '.AccessKey.AccessKeyId')
SECRET_ACCESS_KEY=$(echo "$ACCESS_KEY_OUTPUT" | jq -r '.AccessKey.SecretAccessKey')

if [ -z "$ACCESS_KEY_ID" ] || [ -z "$SECRET_ACCESS_KEY" ]; then
    echo -e "${RED}Error: Failed to create access keys${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Access keys created${NC}"
echo ""
echo "=========================================="
echo "IMPORTANT: Save these credentials securely"
echo "=========================================="
echo ""
echo "AWS Access Key ID:     $ACCESS_KEY_ID"
echo "AWS Secret Access Key: $SECRET_ACCESS_KEY"
echo ""
echo "These credentials will not be shown again!"
echo ""
echo "=========================================="
echo "Next Steps"
echo "=========================================="
echo ""
echo "1. Use these credentials in ClickHouse Cloud:"
echo ""
echo "   CREATE DATABASE glue_db"
echo "   ENGINE = DataLakeCatalog"
echo "   SETTINGS"
echo "       catalog_type = 'glue',"
echo "       region = '$AWS_REGION',"
echo "       glue_database = '$GLUE_DATABASE',"
echo "       aws_access_key_id = '$ACCESS_KEY_ID',"
echo "       aws_secret_access_key = '$SECRET_ACCESS_KEY';"
echo ""
echo "2. List tables:"
echo "   SHOW TABLES FROM glue_db;"
echo ""
echo "3. Query Iceberg tables:"
echo "   SELECT * FROM glue_db.\`sales_orders\` LIMIT 10;"
echo ""
echo "=========================================="
