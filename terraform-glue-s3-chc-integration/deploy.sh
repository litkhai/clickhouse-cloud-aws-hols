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

    read -p "AWS Access Key ID (AKIA...): " INPUT_KEY_ID
    read -sp "AWS Secret Access Key: " INPUT_SECRET_KEY
    echo ""  # New line after secret input
    read -p "AWS Region [ap-northeast-2]: " INPUT_REGION
    INPUT_REGION=${INPUT_REGION:-ap-northeast-2}

    # Export for this session
    export AWS_ACCESS_KEY_ID="$INPUT_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$INPUT_SECRET_KEY"
    export AWS_REGION="$INPUT_REGION"

    echo ""
    echo -e "${GREEN}✓ Credentials set for this session${NC}"
else
    echo -e "${GREEN}✓ Using existing environment credentials${NC}"
    export AWS_REGION=${AWS_REGION:-ap-northeast-2}
fi

# Verify credentials
echo ""
echo "Verifying AWS credentials..."
if aws sts get-caller-identity &>/dev/null; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
    echo -e "${GREEN}✓ Credentials valid${NC}"
    echo "  Account: $ACCOUNT_ID"
    echo "  User: $USER_ARN"
else
    echo -e "${RED}✗ Invalid AWS credentials${NC}"
    echo "  Please check your Access Key ID and Secret Access Key"
    exit 1
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

if [ ! -d ".terraform" ]; then
    echo "Initializing Terraform..."
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
echo "Installing Python dependencies..."
pip3 install -q pyiceberg pandas pyarrow 2>&1 | grep -v "already satisfied" || true

# Run Python script to create Iceberg table
echo "Creating Iceberg table..."
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
CRAWLER_REGION=$(terraform output -raw aws_region)

# Start the crawler
echo "Starting Glue Crawler: $CRAWLER_NAME"
aws glue start-crawler --name "$CRAWLER_NAME" --region "$CRAWLER_REGION"

echo -e "${YELLOW}Crawler started. Waiting for completion (this takes ~2 minutes)...${NC}"

# Wait for crawler to complete
TIMEOUT=300  # 5 minutes
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $TIMEOUT ]; do
    STATUS=$(aws glue get-crawler --name "$CRAWLER_NAME" --region "$CRAWLER_REGION" --query 'Crawler.State' --output text)

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
    echo "  aws glue get-crawler --name $CRAWLER_NAME --region $CRAWLER_REGION"
fi

echo ""

# Verify table was created
echo "Verifying Glue table..."
GLUE_DB=$(terraform output -raw glue_database_name)
TABLES=$(aws glue get-tables --database-name "$GLUE_DB" --region "$CRAWLER_REGION" --query 'TableList[*].Name' --output text)

if [ -n "$TABLES" ]; then
    echo -e "${GREEN}✓ Tables found in Glue Catalog:${NC} $TABLES"
else
    echo -e "${YELLOW}⚠ No tables found in Glue Catalog${NC}"
    echo "  Run: aws glue get-tables --database-name $GLUE_DB --region $CRAWLER_REGION"
fi

echo ""

# ==================== Display Connection Info ====================
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
echo "Infrastructure Created:"
echo "-----------------------"
echo "✓ S3 Bucket:      $(terraform output -raw s3_bucket_name)"
echo "✓ Glue Database:  $(terraform output -raw glue_database_name)"
echo "✓ Glue Crawler:   $(terraform output -raw glue_crawler_name)"
echo "✓ AWS Region:     $(terraform output -raw aws_region)"
if [ -n "$TABLES" ]; then
    echo "✓ Glue Tables:    $TABLES"
fi
echo ""
echo "ClickHouse DataLakeCatalog SQL:"
echo "-------------------------------"
echo "CREATE DATABASE glue_db"
echo "ENGINE = DataLakeCatalog"
echo "SETTINGS"
echo "    catalog_type = 'glue',"
echo "    region = '$(terraform output -raw aws_region)',"
echo "    glue_database = '$(terraform output -raw glue_database_name)',"
echo "    aws_access_key_id = '$AWS_ACCESS_KEY_ID',"
echo "    aws_secret_access_key = '$AWS_SECRET_ACCESS_KEY';"
echo ""
echo "-- List all tables"
echo "SHOW TABLES FROM glue_db;"
echo ""
echo "-- Query Iceberg table"
echo "SELECT * FROM glue_db.\`sales_orders\` LIMIT 10;"
echo ""
echo "=========================================="
echo ""
echo -e "${GREEN}Next Steps:${NC}"
echo "  1. Copy the SQL commands above"
echo "  2. Paste them into your ClickHouse Cloud SQL console"
echo "  3. Start querying your Iceberg data!"
echo ""
echo -e "${YELLOW}Important:${NC}"
echo "  - AWS credentials are stored in environment variables for this session only"
echo "  - They are NOT saved in any Terraform files"
echo "  - To destroy resources later, run: ./destroy.sh"
echo ""
