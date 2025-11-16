#!/bin/bash
# Deploy ClickHouse Glue Catalog Integration
# This script: prompts for AWS credentials → deploys infrastructure → creates sample data → runs crawler

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
echo "ClickHouse Glue Catalog - Deploy"
echo "=========================================="
echo ""

# ==================== Step 1: Get AWS Credentials ====================
echo -e "${BLUE}Step 1/5: AWS Credentials Setup${NC}"
echo ""

# Check if credentials are already in environment
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Please enter your AWS credentials:"
    echo ""

    read -p "AWS Access Key ID (AKIA...): " AWS_ACCESS_KEY_ID
    read -sp "AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
    echo ""
    read -p "AWS Region [ap-northeast-2]: " AWS_REGION
    AWS_REGION=${AWS_REGION:-ap-northeast-2}

    # Export for this session
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_REGION

    echo ""
    echo -e "${GREEN}✓ Credentials set for this session${NC}"
else
    echo -e "${GREEN}✓ Using existing environment credentials${NC}"
    AWS_REGION=${AWS_REGION:-ap-northeast-2}
fi

echo ""

# ==================== Step 2: Check Prerequisites ====================
echo -e "${BLUE}Step 2/5: Checking prerequisites...${NC}"

if ! command -v terraform &> /dev/null; then
    echo -e "${RED}Error: Terraform not found. Please install: https://www.terraform.io/downloads${NC}"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not found. Please install: https://aws.amazon.com/cli/${NC}"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 not found. Please install Python 3${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All prerequisites met${NC}"
echo ""

# ==================== Step 3: Deploy Infrastructure ====================
echo -e "${BLUE}Step 3/5: Deploying AWS infrastructure (S3 + Glue)...${NC}"

if [ ! -f "terraform.tfstate" ]; then
    terraform init
fi

terraform apply -auto-approve

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Terraform deployment failed${NC}"
    echo -e "${YELLOW}Note: If IAM role creation failed due to AWS SCP restrictions,${NC}"
    echo -e "${YELLOW}      you may need to use an existing role or contact your administrator.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Infrastructure deployed${NC}"
echo ""

# ==================== Step 4: Create and Upload Iceberg Data ====================
echo -e "${BLUE}Step 4/5: Creating and uploading Iceberg table...${NC}"

# Install required Python packages
pip3 install -q pyiceberg pandas pyarrow

# Run Python script to create Iceberg table
python3 ./scripts/create-iceberg-table.py

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to create Iceberg table${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Iceberg table created and uploaded to S3${NC}"
echo ""

# ==================== Step 5: Run Glue Crawler ====================
echo -e "${BLUE}Step 5/5: Running Glue Crawler...${NC}"

CRAWLER_NAME=$(terraform output -raw glue_crawler_name)
AWS_REGION=$(terraform output -raw aws_region)

# Start the crawler
aws glue start-crawler --name "$CRAWLER_NAME" --region "$AWS_REGION"

echo -e "${YELLOW}Crawler started. Waiting for completion (this takes ~2 minutes)...${NC}"

# Wait for crawler to complete
TIMEOUT=300  # 5 minutes
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $TIMEOUT ]; do
    STATUS=$(aws glue get-crawler --name "$CRAWLER_NAME" --region "$AWS_REGION" --query 'Crawler.State' --output text)

    if [ "$STATUS" == "READY" ]; then
        echo -e "${GREEN}✓ Crawler completed successfully${NC}"
        break
    elif [ "$STATUS" == "RUNNING" ]; then
        echo -e "  Crawler status: RUNNING... (${ELAPSED}s elapsed)"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    else
        echo -e "${YELLOW}Warning: Crawler status: $STATUS${NC}"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    fi
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo -e "${YELLOW}Warning: Crawler did not complete within timeout. Check status manually:${NC}"
    echo "  aws glue get-crawler --name $CRAWLER_NAME --region $AWS_REGION"
fi

echo ""

# ==================== Display Connection Info ====================
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""

# Get the connection info and replace placeholders with actual values
CONNECTION_INFO=$(terraform output -raw clickhouse_connection_info)
CONNECTION_INFO=${CONNECTION_INFO//\$AWS_ACCESS_KEY_ID/$AWS_ACCESS_KEY_ID}
CONNECTION_INFO=${CONNECTION_INFO//\$AWS_SECRET_ACCESS_KEY/$AWS_SECRET_ACCESS_KEY}

echo "$CONNECTION_INFO"

echo ""
echo -e "${GREEN}Next Steps:${NC}"
echo "  1. Copy the SQL commands above"
echo "  2. Paste them into your ClickHouse Cloud SQL console"
echo "  3. Start querying your Iceberg data!"
echo ""
echo -e "${YELLOW}Important:${NC}"
echo "  - AWS credentials are stored in environment variables for this session only"
echo "  - They are NOT saved in any Terraform files"
echo "  - If AWS SCP restricts IAM operations, some features may be limited"
echo ""
