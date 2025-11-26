#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${BLUE}========================================================${NC}"
echo -e "${BLUE}  ClickHouse Cloud Secure S3 - Deployment Script${NC}"
echo -e "${BLUE}========================================================${NC}"
echo ""

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if terraform is installed
if ! command -v terraform &> /dev/null; then
    print_error "Terraform is not installed. Please install Terraform first."
    print_info "Visit: https://www.terraform.io/downloads.html"
    exit 1
fi

print_success "Terraform is installed: $(terraform version -json | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4)"
echo ""

# Check AWS credentials
print_info "Checking AWS credentials..."

# Function to check if AWS credentials are valid
check_aws_credentials() {
    local has_valid_creds=false

    # Check environment variables
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
        print_success "AWS credentials found in environment variables"
        has_valid_creds=true
    fi

    # Check AWS CLI configuration
    if command -v aws &> /dev/null; then
        if aws sts get-caller-identity &> /dev/null; then
            print_success "AWS CLI is configured with valid credentials"
            CALLER_IDENTITY=$(aws sts get-caller-identity 2>/dev/null)
            ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
            USER_ARN=$(echo "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)
            print_info "AWS Account: $ACCOUNT_ID"
            print_info "Identity: $USER_ARN"
            has_valid_creds=true
        fi
    fi

    if [ "$has_valid_creds" = false ]; then
        print_error "AWS credentials not found or invalid!"
        print_info "Please configure AWS credentials:"
        print_info "  1. Set environment variables:"
        print_info "     export AWS_ACCESS_KEY_ID=\"your-key\""
        print_info "     export AWS_SECRET_ACCESS_KEY=\"your-secret\""
        print_info "     export AWS_SESSION_TOKEN=\"your-token\"  # if using temporary credentials"
        print_info "  2. Or configure AWS CLI: aws configure"
        exit 1
    fi
}

check_aws_credentials
echo ""

# Check AWS region
print_info "Checking AWS region configuration..."
DETECTED_REGION=""

# Check environment variables first
if [ -n "$AWS_REGION" ]; then
    DETECTED_REGION="$AWS_REGION"
    print_success "AWS region from environment: $AWS_REGION"
elif [ -n "$AWS_DEFAULT_REGION" ]; then
    DETECTED_REGION="$AWS_DEFAULT_REGION"
    print_success "AWS region from environment: $AWS_DEFAULT_REGION"
# Check terraform.tfvars (only uncommented lines)
elif [ -f terraform.tfvars ] && grep -q "^[^#]*aws_region\s*=\s*\".\+\"" terraform.tfvars 2>/dev/null; then
    DETECTED_REGION=$(grep "^[^#]*aws_region" terraform.tfvars | cut -d'"' -f2 | head -1)
    if [ -n "$DETECTED_REGION" ]; then
        print_success "AWS region from terraform.tfvars: $DETECTED_REGION"
    fi
fi

# Check AWS CLI configuration if no region found yet
if [ -z "$DETECTED_REGION" ] && command -v aws &> /dev/null; then
    AWS_CLI_REGION=$(aws configure get region 2>/dev/null)
    if [ -n "$AWS_CLI_REGION" ]; then
        DETECTED_REGION="$AWS_CLI_REGION"
        print_success "AWS region from AWS CLI configuration: $AWS_CLI_REGION"
    fi
fi

# If no region detected, show warning
if [ -z "$DETECTED_REGION" ]; then
    print_warning "AWS region not detected"
    print_info "Will use Terraform provider default or prompt during apply"
else
    print_info "Terraform will use region: $DETECTED_REGION"
fi
echo ""

# Configuration Setup
echo "=========================================="
echo "  Configuration Setup"
echo "=========================================="
echo ""

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    print_info "terraform.tfvars not found, creating from template..."

    if [ -f "terraform.tfvars.example" ]; then
        cp terraform.tfvars.example terraform.tfvars
        print_success "Created terraform.tfvars"
    else
        print_error "terraform.tfvars.example not found"
        exit 1
    fi
fi

# Auto-configuration for S3 bucket name and ClickHouse IAM role
BUCKET_CONFIGURED=false
IAM_ROLE_CONFIGURED=false

# Check if bucket_name is already configured
if grep -q "^bucket_name\s*=\s*\".\+\"" terraform.tfvars 2>/dev/null; then
    CONFIGURED_BUCKET=$(grep "^bucket_name" terraform.tfvars | cut -d'"' -f2)
    if [ "$CONFIGURED_BUCKET" != "my-clickhouse-data-bucket-unique-name" ] && [ -n "$CONFIGURED_BUCKET" ]; then
        print_success "S3 bucket name already configured: $CONFIGURED_BUCKET"
        BUCKET_CONFIGURED=true
    fi
fi

# Auto-generate bucket name if not configured
if [ "$BUCKET_CONFIGURED" = false ]; then
    print_info "Auto-configuring S3 bucket name..."

    # Generate unique bucket name using AWS account ID and timestamp
    if [ -n "$ACCOUNT_ID" ]; then
        GENERATED_BUCKET="clickhouse-s3-${ACCOUNT_ID}-$(date +%Y%m%d-%H%M%S)"
    else
        # Fallback if account ID not available
        GENERATED_BUCKET="clickhouse-s3-$(whoami)-$(date +%Y%m%d-%H%M%S)"
    fi

    # Convert to lowercase and remove invalid characters
    GENERATED_BUCKET=$(echo "$GENERATED_BUCKET" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

    print_success "Generated bucket name: $GENERATED_BUCKET"

    echo ""
    read -p "Use this bucket name? (y/n) or enter custom name: " bucket_choice

    if [[ $bucket_choice =~ ^[Yy]$ ]]; then
        CONFIGURED_BUCKET="$GENERATED_BUCKET"
    elif [[ $bucket_choice =~ ^[Nn]$ ]]; then
        read -p "Enter your custom S3 bucket name: " custom_bucket
        if [ -n "$custom_bucket" ]; then
            # Validate and sanitize bucket name
            CONFIGURED_BUCKET=$(echo "$custom_bucket" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g')
            if [ "$CONFIGURED_BUCKET" != "$custom_bucket" ]; then
                print_warning "Bucket name sanitized to: $CONFIGURED_BUCKET"
            fi
        else
            print_error "Bucket name cannot be empty"
            exit 1
        fi
    else
        # User entered a custom name directly
        CONFIGURED_BUCKET=$(echo "$bucket_choice" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g')
        if [ "$CONFIGURED_BUCKET" != "$bucket_choice" ]; then
            print_warning "Bucket name sanitized to: $CONFIGURED_BUCKET"
        fi
    fi

    # Update terraform.tfvars
    if grep -q "^bucket_name" terraform.tfvars; then
        sed -i.bak "s|^bucket_name.*|bucket_name = \"$CONFIGURED_BUCKET\"|" terraform.tfvars
    elif grep -q "^# bucket_name" terraform.tfvars; then
        sed -i.bak "s|^# bucket_name.*|bucket_name = \"$CONFIGURED_BUCKET\"|" terraform.tfvars
    else
        # Add to file if not present
        echo "" >> terraform.tfvars
        echo "bucket_name = \"$CONFIGURED_BUCKET\"" >> terraform.tfvars
    fi
    rm -f terraform.tfvars.bak

    print_success "Bucket name configured: $CONFIGURED_BUCKET"
    BUCKET_CONFIGURED=true
    echo ""
fi

# Check if ClickHouse IAM role is already configured
if grep -q "^clickhouse_iam_role_arns\s*=\s*\[" terraform.tfvars 2>/dev/null; then
    if ! grep -q "123456789012:role/ClickHouseInstanceRole-xxxxx" terraform.tfvars; then
        print_success "ClickHouse IAM role ARN(s) already configured"
        IAM_ROLE_CONFIGURED=true
    fi
fi

# Prompt for ClickHouse IAM role if not configured
if [ "$IAM_ROLE_CONFIGURED" = false ]; then
    print_warning "ClickHouse IAM role ARN not configured"
    echo ""
    echo "To get your ClickHouse IAM role ARN:"
    echo -e "  ${BLUE}1.${NC} Log into ClickHouse Cloud Console: ${GREEN}https://clickhouse.cloud/${NC}"
    echo -e "  ${BLUE}2.${NC} Select your service"
    echo -e "  ${BLUE}3.${NC} Navigate to: ${YELLOW}Settings → Network security information${NC}"
    echo -e "  ${BLUE}4.${NC} Copy the ${YELLOW}'Service role ID (IAM)'${NC} value"
    echo -e "     Format: ${GREEN}arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx${NC}"
    echo ""

    read -p "Do you have your ClickHouse IAM role ARN? (y/n) " has_arn

    if [[ ! $has_arn =~ ^[Yy]$ ]]; then
        print_error "ClickHouse IAM role ARN is required to continue"
        print_info "Please get your IAM role ARN from ClickHouse Cloud Console and run this script again"
        exit 1
    fi

    echo ""
    read -p "Enter your ClickHouse IAM role ARN: " clickhouse_arn

    # Validate ARN format
    if [[ ! $clickhouse_arn =~ ^arn:aws:iam::[0-9]{12}:role/.+ ]]; then
        print_error "Invalid IAM role ARN format"
        print_info "Expected format: arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx"
        echo ""
        read -p "Continue anyway? (yes/no) " continue_anyway
        if [[ ! $continue_anyway =~ ^[Yy][Ee][Ss]$ ]]; then
            exit 1
        fi
    fi

    # Update terraform.tfvars
    # Remove old clickhouse_iam_role_arns lines (including array contents)
    if grep -q "^clickhouse_iam_role_arns" terraform.tfvars || grep -q "^# clickhouse_iam_role_arns" terraform.tfvars; then
        # Create temp file without clickhouse_iam_role_arns section
        awk '
        /^clickhouse_iam_role_arns/ { skip=1; next }
        /^# clickhouse_iam_role_arns/ { skip=1; next }
        skip && /^\]/ { skip=0; next }
        skip && /^  "arn:/ { next }
        !skip { print }
        ' terraform.tfvars > terraform.tfvars.tmp
        mv terraform.tfvars.tmp terraform.tfvars
    fi

    # Add new clickhouse_iam_role_arns configuration
    echo "" >> terraform.tfvars
    echo "clickhouse_iam_role_arns = [" >> terraform.tfvars
    echo "  \"$clickhouse_arn\"" >> terraform.tfvars
    echo "]" >> terraform.tfvars

    print_success "ClickHouse IAM role ARN configured"
    IAM_ROLE_CONFIGURED=true
    echo ""
fi

echo ""
print_success "Configuration is complete!"
print_info "Configuration saved to terraform.tfvars"
echo ""

# Validate bucket name with AWS if possible
if [ "$BUCKET_CONFIGURED" = true ] && command -v aws &> /dev/null && [ -n "$DETECTED_REGION" ]; then
    print_info "Checking if S3 bucket name is available..."

    # Check if bucket already exists
    if aws s3 ls "s3://${CONFIGURED_BUCKET}" --region "$DETECTED_REGION" 2>/dev/null; then
        print_warning "S3 bucket '$CONFIGURED_BUCKET' already exists"
        print_info "Terraform will use the existing bucket if it's in this account"
    else
        print_success "S3 bucket name appears to be available"
    fi
    echo ""
fi

# Initialize Terraform
print_info "Initializing Terraform..."
if terraform init; then
    print_success "Terraform initialized successfully"
else
    print_error "Terraform initialization failed"
    exit 1
fi
echo ""

# Validate Terraform configuration
print_info "Validating Terraform configuration..."
if terraform validate; then
    print_success "Terraform configuration is valid"
else
    print_error "Terraform configuration validation failed"
    exit 1
fi
echo ""

# Format check
print_info "Checking Terraform formatting..."
if terraform fmt -check -recursive; then
    print_success "Terraform files are properly formatted"
else
    print_warning "Some Terraform files need formatting"
    read -p "Do you want to auto-format the files? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        terraform fmt -recursive
        print_success "Files formatted"
    fi
fi
echo ""

# Run terraform plan
print_info "Running Terraform plan..."
echo ""
if terraform plan -out=tfplan; then
    print_success "Terraform plan completed successfully"
else
    print_error "Terraform plan failed"
    exit 1
fi
echo ""

# Ask for confirmation
echo -e "${YELLOW}========================================================${NC}"
echo -e "${YELLOW}Review the plan above carefully!${NC}"
echo -e "${YELLOW}========================================================${NC}"
echo ""
echo "This will create:"
echo "  • 1 S3 bucket (with encryption and versioning)"
echo "  • 1 IAM role (for ClickHouse Cloud access)"
echo "  • 1 IAM policy (with read and write permissions)"
echo ""
echo -e "${GREEN}Estimated cost: ~\$3-5/month for moderate usage${NC}"
echo "  - S3 storage: ~\$0.023/GB per month"
echo "  - S3 requests: ~\$0.0004/1000 GET requests"
echo "  - Data transfer: Free within same region"
echo ""

read -p "Do you want to apply this plan? (yes/no) " -r
echo
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    print_info "Deployment cancelled"
    rm -f tfplan
    exit 0
fi

# Apply the plan
print_info "Applying Terraform configuration..."
echo ""
if terraform apply tfplan; then
    print_success "Deployment completed successfully!"
else
    print_error "Terraform apply failed"
    rm -f tfplan
    exit 1
fi

# Clean up plan file
rm -f tfplan

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""

# Display outputs
print_info "Retrieving deployment information..."
echo ""

# Get outputs
BUCKET_NAME=$(terraform output -raw bucket_name 2>/dev/null || echo "N/A")
BUCKET_REGION=$(terraform output -raw bucket_region 2>/dev/null || echo "N/A")
IAM_ROLE_ARN=$(terraform output -raw iam_role_arn 2>/dev/null || echo "N/A")
S3_URL=$(terraform output -raw s3_url_prefix 2>/dev/null || echo "N/A")

echo -e "${BLUE}S3 Configuration:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${GREEN}S3 Bucket:${NC}"
echo "  Name: $BUCKET_NAME"
echo "  Region: $BUCKET_REGION"
echo "  URL: $S3_URL"
echo ""
echo -e "${GREEN}IAM Role:${NC}"
echo "  ARN: $IAM_ROLE_ARN"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_info "Next Steps:"
echo ""
echo -e "1. ${GREEN}Test the S3 integration:${NC}"
echo "   ./test-s3-integration.sh"
echo ""
echo -e "2. ${GREEN}Connect to ClickHouse Cloud and run SQL:${NC}"
echo "   terraform output clickhouse_sql_examples"
echo ""
echo -e "3. ${GREEN}View complete connection information:${NC}"
echo "   terraform output connection_info"
echo ""
echo -e "4. ${GREEN}View setup checklist:${NC}"
echo "   terraform output setup_checklist"
echo ""

# Save deployment information
OUTPUT_FILE="deployment-info.txt"
cat > "$OUTPUT_FILE" <<EOF
ClickHouse Cloud Secure S3 Deployment Information
==================================================
Deployment Date: $(date)
AWS Region: $BUCKET_REGION

S3 Bucket:
----------
Name: $BUCKET_NAME
Region: $BUCKET_REGION
URL: $S3_URL

IAM Role:
---------
ARN: $IAM_ROLE_ARN

Quick Test:
-----------
Run the test script:
  ./test-s3-integration.sh

View SQL examples:
  terraform output clickhouse_sql_examples

Example ClickHouse SQL:
-----------------------
-- Create S3-backed table
CREATE TABLE test_s3
(
    id UInt64,
    name String,
    timestamp DateTime
)
ENGINE = S3(
    '$S3_URL/data/test.parquet',
    'Parquet',
    extra_credentials(role_arn = '$IAM_ROLE_ARN')
);

-- Insert data
INSERT INTO test_s3 VALUES (1, 'example', now());

-- Query data
SELECT * FROM test_s3;

Cleanup:
--------
To destroy all resources:
  ./destroy.sh
  or
  terraform destroy
EOF

print_success "Deployment information saved to: $OUTPUT_FILE"
echo ""

print_info "To view all outputs:"
echo "  terraform output"
echo ""
print_info "To destroy the deployment:"
echo "  ./destroy.sh"
echo ""

print_success "Happy querying with ClickHouse and S3! 🚀"
