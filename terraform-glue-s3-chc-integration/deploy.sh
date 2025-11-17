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

# Check if environment variables are already set
if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Found AWS credentials in environment variables"
    echo "  Key ID prefix: ${AWS_ACCESS_KEY_ID:0:10}..."
    echo "Verifying credentials..."

    if aws sts get-caller-identity >/dev/null 2>&1; then
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
        echo -e "${GREEN}✓ Using environment variable credentials${NC}"
        echo "  Account: $ACCOUNT_ID"
        echo "  User: $USER_ARN"

        # Set default region if not set
        if [ -z "$AWS_REGION" ]; then
            export AWS_REGION="ap-northeast-2"
            echo "  Region: $AWS_REGION (default)"
        else
            echo "  Region: $AWS_REGION"
        fi
    else
        echo -e "${RED}✗ Environment variables set but credentials are invalid${NC}"
        echo "  This usually means the exported credentials are incorrect or expired."
        echo "  Falling back to AWS CLI configured credentials..."
        echo ""

        # Unset invalid environment variables and try AWS CLI config
        unset AWS_ACCESS_KEY_ID
        unset AWS_SECRET_ACCESS_KEY
        unset AWS_SESSION_TOKEN

        if aws sts get-caller-identity >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Using AWS CLI configured credentials${NC}"
            ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
            USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
            echo "  Account: $ACCOUNT_ID"
            echo "  User: $USER_ARN"

            # Extract credentials from AWS CLI for Terraform
            export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
            export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
            export AWS_REGION=$(aws configure get region || echo "ap-northeast-2")
            echo "  Region: $AWS_REGION"
        else
            echo -e "${RED}✗ No valid AWS credentials found${NC}"
            exit 1
        fi
    fi
# Try AWS CLI configured credentials
elif aws sts get-caller-identity >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Using AWS CLI configured credentials${NC}"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
    echo "  Account: $ACCOUNT_ID"
    echo "  User: $USER_ARN"

    # Extract credentials from AWS CLI for Terraform
    export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
    export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
    export AWS_REGION=$(aws configure get region || echo "ap-northeast-2")
    echo "  Region: $AWS_REGION"
else
    # No valid credentials found, prompt user
    echo "No valid AWS credentials found. Please enter your credentials:"
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
    echo "Verifying credentials..."
    if aws sts get-caller-identity >/dev/null 2>&1; then
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
    LAST_CRAWL=$(aws glue get-crawler --name "$CRAWLER_NAME" --region "$CRAWLER_REGION" --query 'Crawler.LastCrawl' --output json 2>/dev/null || echo '{}')

    if [ "$STATUS" == "READY" ]; then
        echo -e "${GREEN}✓ Crawler completed (status: READY)${NC}"

        # Check last crawl result
        CRAWL_STATUS=$(echo "$LAST_CRAWL" | grep -o '"Status": *"[^"]*"' | cut -d'"' -f4)
        if [ "$CRAWL_STATUS" == "SUCCEEDED" ]; then
            echo -e "${GREEN}✓ Last crawl succeeded${NC}"
        elif [ "$CRAWL_STATUS" == "FAILED" ]; then
            echo -e "${RED}✗ Last crawl failed${NC}"
            ERROR_MSG=$(echo "$LAST_CRAWL" | grep -o '"ErrorMessage": *"[^"]*"' | cut -d'"' -f4)
            if [ -n "$ERROR_MSG" ]; then
                echo -e "${RED}  Error: $ERROR_MSG${NC}"
            fi
        fi
        break
    elif [ "$STATUS" == "RUNNING" ]; then
        echo -e "  Crawler status: RUNNING... (${ELAPSED}s elapsed)"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    elif [ "$STATUS" == "STOPPING" ]; then
        echo -e "  Crawler status: STOPPING... (${ELAPSED}s elapsed)"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    else
        echo -e "${YELLOW}  Crawler status: $STATUS (${ELAPSED}s elapsed)${NC}"
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
