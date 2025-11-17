#!/bin/bash
# Destroy ClickHouse Glue Catalog Integration
# This script removes all AWS resources created by Terraform

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=========================================="
echo "ClickHouse Glue Catalog - Destroy"
echo "=========================================="
echo ""

# Check AWS credentials
echo "Checking AWS credentials..."

# If environment variables are set, check if they're valid
if [ -n "$AWS_ACCESS_KEY_ID" ] || [ -n "$AWS_SECRET_ACCESS_KEY" ] || [ -n "$AWS_SESSION_TOKEN" ]; then
    echo "Detected AWS environment variables. Checking validity..."
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Environment variables are set but credentials are invalid/expired${NC}"
        echo "  Clearing invalid environment variables and trying AWS CLI config..."
        unset AWS_ACCESS_KEY_ID
        unset AWS_SECRET_ACCESS_KEY
        unset AWS_SESSION_TOKEN
    fi
fi

# Final credential check
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo -e "${RED}✗ AWS credentials are invalid or expired${NC}"
    echo ""
    echo "Please ensure valid AWS credentials are configured:"
    echo "  1. Run 'aws configure' to set credentials, OR"
    echo "  2. Export valid environment variables:"
    echo "     export AWS_ACCESS_KEY_ID=\"your-key\""
    echo "     export AWS_SECRET_ACCESS_KEY=\"your-secret\""
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}✓ Using AWS Account: $ACCOUNT_ID${NC}"
echo ""

# Check if terraform state exists
if [ ! -f "terraform.tfstate" ]; then
    echo -e "${YELLOW}No terraform.tfstate found. Nothing to destroy.${NC}"
    exit 0
fi

# Show what will be destroyed
echo -e "${YELLOW}The following resources will be destroyed:${NC}"
echo ""
terraform show -no-color | grep -E "^resource|identifier|bucket|database" | head -20
echo ""

# Confirm destruction
read -p "Are you sure you want to destroy all resources? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Destruction cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}Destroying AWS infrastructure...${NC}"

# Destroy resources
terraform destroy -auto-approve

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Terraform destroy failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ All resources destroyed successfully${NC}"
echo ""

# Offer to clean up local files
read -p "Do you want to clean up local Terraform files? (.terraform, *.tfstate) (yes/no): " CLEANUP

if [ "$CLEANUP" == "yes" ]; then
    rm -rf .terraform
    rm -f terraform.tfstate*
    rm -f .terraform.lock.hcl
    echo -e "${GREEN}✓ Local Terraform files cleaned up${NC}"
fi

echo ""
echo "=========================================="
echo "Cleanup Complete!"
echo "=========================================="
