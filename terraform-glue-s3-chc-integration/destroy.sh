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
NC='\033[0m'

echo "=========================================="
echo "ClickHouse Glue Catalog - Destroy"
echo "=========================================="
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
