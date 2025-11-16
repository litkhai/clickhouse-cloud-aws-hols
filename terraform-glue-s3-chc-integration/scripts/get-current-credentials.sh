#!/bin/bash
# Script to extract current AWS credentials for ClickHouse Cloud
# Works with SSO, assumed roles, and temporary credentials

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Extract AWS Credentials for ClickHouse"
echo "=========================================="
echo ""

# Get Terraform outputs
cd "$PROJECT_DIR"

if [ ! -f "terraform.tfstate" ]; then
    echo -e "${RED}Error: terraform.tfstate not found. Please run 'terraform apply' first.${NC}"
    exit 1
fi

GLUE_DATABASE=$(terraform output -raw glue_database_name 2>/dev/null)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null)

if [ -z "$GLUE_DATABASE" ] || [ -z "$AWS_REGION" ]; then
    echo -e "${RED}Error: Could not get required values from Terraform outputs${NC}"
    exit 1
fi

# Check current identity
IDENTITY=$(aws sts get-caller-identity 2>/dev/null)
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Unable to get AWS identity. Please configure AWS credentials.${NC}"
    echo ""
    echo "Run: aws configure"
    echo "Or: export AWS_PROFILE=<your-profile>"
    exit 1
fi

ACCOUNT_ID=$(echo "$IDENTITY" | jq -r '.Account')
ARN=$(echo "$IDENTITY" | jq -r '.Arn')

echo -e "${GREEN}Current AWS Identity:${NC}"
echo "  ARN: $ARN"
echo "  Account: $ACCOUNT_ID"
echo ""

# Extract credentials from environment or AWS CLI config
# Try to get credentials from aws configure list
ACCESS_KEY=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
SECRET_KEY=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")
SESSION_TOKEN=$(aws configure get aws_session_token 2>/dev/null || echo "")

# If not in config, try environment variables
if [ -z "$ACCESS_KEY" ]; then
    ACCESS_KEY="${AWS_ACCESS_KEY_ID:-}"
    SECRET_KEY="${AWS_SECRET_ACCESS_KEY:-}"
    SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
fi

# If still empty, try to get from credential process or SSO
if [ -z "$ACCESS_KEY" ]; then
    echo -e "${YELLOW}Attempting to retrieve credentials from AWS CLI session...${NC}"

    # For SSO users, credentials are cached
    CREDS=$(aws sts get-session-token 2>/dev/null || echo "")

    if [ -z "$CREDS" ]; then
        echo -e "${RED}Error: Unable to retrieve credentials.${NC}"
        echo ""
        echo -e "${YELLOW}If you're using AWS SSO, your credentials are temporary and managed by AWS CLI.${NC}"
        echo -e "${YELLOW}You need to manually extract them from:${NC}"
        echo ""
        echo "  1. Check ~/.aws/credentials"
        echo "  2. Or run: aws configure export-credentials --profile <your-profile>"
        echo "  3. Or check environment variables: env | grep AWS"
        echo ""
        exit 1
    fi

    ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
    SECRET_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
    SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')
fi

# Check if we have credentials
if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
    echo -e "${RED}Error: Could not extract AWS credentials.${NC}"
    echo ""
    echo -e "${YELLOW}For SSO/temporary credentials, please manually extract them:${NC}"
    echo ""
    echo "1. Check your environment:"
    echo "   env | grep AWS"
    echo ""
    echo "2. Or check AWS config:"
    echo "   cat ~/.aws/credentials"
    echo ""
    echo "3. Then use the values in ClickHouse:"
    echo ""
    echo "   CREATE DATABASE glue_db"
    echo "   ENGINE = DataLakeCatalog"
    echo "   SETTINGS"
    echo "       catalog_type = 'glue',"
    echo "       region = '$AWS_REGION',"
    echo "       glue_database = '$GLUE_DATABASE',"
    echo "       aws_access_key_id = '<YOUR_ACCESS_KEY>',"
    echo "       aws_secret_access_key = '<YOUR_SECRET_KEY>'"
    if [ -n "$SESSION_TOKEN" ]; then
        echo "       aws_session_token = '<YOUR_SESSION_TOKEN>';"
    else
        echo ";"
    fi
    echo ""
    exit 1
fi

# Display credentials
echo "=========================================="
echo "AWS Credentials Extracted"
echo "=========================================="
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Glue Database: $GLUE_DATABASE"
echo "  AWS Region:    $AWS_REGION"
echo ""
echo -e "${GREEN}Credentials:${NC}"
echo "  Access Key ID:     ${ACCESS_KEY:0:20}..."
echo "  Secret Access Key: ${SECRET_KEY:0:20}..."
if [ -n "$SESSION_TOKEN" ]; then
    echo "  Session Token:     ${SESSION_TOKEN:0:20}... (temporary)"
    echo ""
    echo -e "${YELLOW}⚠️  These are TEMPORARY credentials (session token included)${NC}"
    echo -e "${YELLOW}    They will expire after some time (usually 1-12 hours)${NC}"
fi
echo ""

# Determine if session token is needed
if [ -n "$SESSION_TOKEN" ]; then
    CREDENTIAL_TYPE="temporary (with session token)"
else
    CREDENTIAL_TYPE="long-term"
fi

echo "=========================================="
echo "ClickHouse SQL Commands"
echo "=========================================="
echo ""
echo -e "${GREEN}Copy and paste this into ClickHouse Cloud:${NC}"
echo ""
echo "-- Create database from Glue Catalog ($CREDENTIAL_TYPE)"
echo "CREATE DATABASE glue_db"
echo "ENGINE = DataLakeCatalog"
echo "SETTINGS"
echo "    catalog_type = 'glue',"
echo "    region = '$AWS_REGION',"
echo "    glue_database = '$GLUE_DATABASE',"
echo "    aws_access_key_id = '$ACCESS_KEY',"

if [ -n "$SESSION_TOKEN" ]; then
    echo "    aws_secret_access_key = '$SECRET_KEY',"
    echo "    aws_session_token = '$SESSION_TOKEN';"
else
    echo "    aws_secret_access_key = '$SECRET_KEY';"
fi

echo ""
echo "-- List all tables"
echo "SHOW TABLES FROM glue_db;"
echo ""
echo "-- Query Iceberg table"
echo "SELECT * FROM glue_db.\`sales_orders\` LIMIT 10;"
echo ""
echo "=========================================="

if [ -n "$SESSION_TOKEN" ]; then
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANT: Temporary Credentials${NC}"
    echo ""
    echo "Your credentials include a session token, which means they are temporary."
    echo "They will expire and you'll need to refresh them periodically."
    echo ""
    echo "To refresh, run this script again:"
    echo "  ./scripts/get-current-credentials.sh"
    echo ""
fi
