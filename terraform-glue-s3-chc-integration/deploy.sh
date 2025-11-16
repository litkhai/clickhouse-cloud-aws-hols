#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Header
echo ""
echo "=========================================="
echo "   ClickHouse-Glue Integration Setup"
echo "=========================================="
echo ""

# Check prerequisites
print_info "Checking prerequisites..."

if ! command_exists terraform; then
    print_error "Terraform is not installed. Please install Terraform first."
    exit 1
fi

print_success "Terraform found: $(terraform version | head -n 1)"

if ! command_exists aws; then
    print_warning "AWS CLI is not installed"
    print_info "You can install it from: https://aws.amazon.com/cli/"
    echo ""
else
    print_success "AWS CLI found"
fi

echo ""
echo "=========================================="
echo "  Step 1: AWS Credentials Configuration"
echo "=========================================="
echo ""

# Check AWS credentials
print_info "Checking AWS credentials..."

AWS_CONFIGURED=false

if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
    print_success "AWS credentials found in environment variables"
    AWS_CONFIGURED=true
elif command_exists aws && aws sts get-caller-identity >/dev/null 2>&1; then
    print_success "AWS credentials found via AWS CLI configuration"
    AWS_CONFIGURED=true
else
    print_warning "No AWS credentials found"
fi

# If not configured, prompt user
if [ "$AWS_CONFIGURED" = false ]; then
    echo ""
    print_error "AWS credentials are not configured!"
    echo ""
    echo "Please choose an option to configure AWS credentials:"
    echo ""
    echo "  1. Run 'aws configure' now (recommended)"
    echo "  2. Set environment variables manually"
    echo "  3. Exit and configure later"
    echo ""
    read -p "Enter your choice (1-3): " aws_choice

    case $aws_choice in
        1)
            if ! command_exists aws; then
                print_error "AWS CLI is not installed. Please install it first."
                exit 1
            fi

            echo ""
            print_info "Starting AWS configuration..."
            echo ""
            echo "You will need:"
            echo "  - AWS Access Key ID"
            echo "  - AWS Secret Access Key"
            echo "  - Default region (must match ClickHouse Cloud region)"
            echo "  - Output format (just press Enter for default)"
            echo ""

            aws configure

            # Verify configuration
            if aws sts get-caller-identity >/dev/null 2>&1; then
                print_success "AWS credentials configured successfully!"
                AWS_CONFIGURED=true
            else
                print_error "AWS configuration failed. Please try again."
                exit 1
            fi
            ;;
        2)
            echo ""
            print_info "Please set the following environment variables in your shell:"
            echo ""
            echo "  export AWS_ACCESS_KEY_ID=\"your-access-key\""
            echo "  export AWS_SECRET_ACCESS_KEY=\"your-secret-key\""
            echo "  export AWS_REGION=\"us-east-1\"  # Must match ClickHouse Cloud region"
            echo ""
            print_warning "After setting environment variables, please run this script again."
            exit 0
            ;;
        3)
            print_info "Exiting. Please configure AWS credentials and run again."
            exit 0
            ;;
        *)
            print_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac
fi

# Determine deployment region
DEPLOY_REGION=""
if [ -n "$AWS_REGION" ]; then
    DEPLOY_REGION="$AWS_REGION"
elif [ -n "$AWS_DEFAULT_REGION" ]; then
    DEPLOY_REGION="$AWS_DEFAULT_REGION"
elif command_exists aws; then
    DEPLOY_REGION=$(aws configure get region 2>/dev/null || echo "")
fi

if [ -n "$DEPLOY_REGION" ]; then
    print_success "Deployment Region: $DEPLOY_REGION"
else
    print_warning "AWS region not configured. Will use defaults."
    DEPLOY_REGION="default"
fi

# Display AWS identity
echo ""
print_info "Verifying AWS identity..."
if command_exists aws && aws sts get-caller-identity >/dev/null 2>&1; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
    USER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "unknown")
    echo "  Account ID: $ACCOUNT_ID"
    echo "  User/Role: $USER_ARN"
    print_success "AWS identity verified"
else
    print_warning "Could not verify AWS identity, but will proceed with deployment"
fi

echo ""
echo "=========================================="
echo "  Step 2: ClickHouse Cloud Region Check"
echo "=========================================="
echo ""

print_warning "IMPORTANT: AWS region MUST match your ClickHouse Cloud region!"
echo ""
echo "If your ClickHouse Cloud instance is in a different region,"
echo "data access will fail due to cross-region restrictions."
echo ""

if [ -n "$DEPLOY_REGION" ] && [ "$DEPLOY_REGION" != "default" ]; then
    echo "Current AWS Region: $DEPLOY_REGION"
    echo ""
    read -p "Does this match your ClickHouse Cloud region? (yes/no): " region_match

    if [ "$region_match" != "yes" ]; then
        print_error "Region mismatch detected!"
        echo ""
        print_info "Please either:"
        echo "  1. Change AWS region: export AWS_REGION=<clickhouse-region>"
        echo "  2. Update terraform.tfvars with correct aws_region"
        echo "  3. Run 'aws configure' and set correct region"
        echo ""
        read -p "Do you want to continue anyway? (yes/no): " continue_anyway
        if [ "$continue_anyway" != "yes" ]; then
            print_info "Exiting. Please configure correct region."
            exit 0
        fi
    fi
else
    print_warning "Could not determine AWS region automatically."
    echo ""
    read -p "Enter your ClickHouse Cloud region (e.g., us-east-1): " ch_region
    if [ -n "$ch_region" ]; then
        export AWS_REGION="$ch_region"
        DEPLOY_REGION="$ch_region"
        print_success "Region set to: $DEPLOY_REGION"
    fi
fi

echo ""
echo "=========================================="
echo "  Step 3: Terraform Configuration"
echo "=========================================="
echo ""

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    print_info "terraform.tfvars not found, creating from template..."

    if [ -f "terraform.tfvars.example" ]; then
        cp terraform.tfvars.example terraform.tfvars
        print_success "Created terraform.tfvars"

        # Update region in terraform.tfvars if we have one
        if [ -n "$DEPLOY_REGION" ] && [ "$DEPLOY_REGION" != "default" ]; then
            sed -i.bak "s|aws_region = \".*\"|aws_region = \"$DEPLOY_REGION\"|" terraform.tfvars
            sed -i.bak "s|clickhouse_cloud_region = \".*\"|clickhouse_cloud_region = \"$DEPLOY_REGION\"|" terraform.tfvars
            rm -f terraform.tfvars.bak
            print_success "Updated terraform.tfvars with region: $DEPLOY_REGION"
        fi
    else
        print_error "terraform.tfvars.example not found"
        exit 1
    fi
else
    print_success "terraform.tfvars already exists"
fi

echo ""
print_info "Current configuration:"
echo ""

# Show configuration
PROJECT_NAME=$(grep "^project_name" terraform.tfvars | cut -d'"' -f2 2>/dev/null || echo "chc-glue-integration")
GLUE_DB=$(grep "^glue_database_name" terraform.tfvars | cut -d'"' -f2 2>/dev/null || echo "clickhouse_iceberg_db")
CRAWLER_ENABLED=$(grep "^enable_glue_crawler" terraform.tfvars | awk '{print $3}' 2>/dev/null || echo "true")

echo "  Project Name: $PROJECT_NAME"
echo "  Glue Database: $GLUE_DB"
echo "  Glue Crawlers: $CRAWLER_ENABLED"
echo "  AWS Region: $DEPLOY_REGION"
echo ""

read -p "Proceed with this configuration? (yes/no): " proceed_choice

if [ "$proceed_choice" != "yes" ]; then
    print_info "You can edit terraform.tfvars to customize the configuration"
    print_info "Run this script again when ready"
    exit 0
fi

echo ""
print_info "Starting Terraform deployment..."
echo ""

# Initialize Terraform
print_info "Step 1/3: Initializing Terraform..."
if terraform init; then
    print_success "Terraform initialized"
else
    print_error "Terraform initialization failed"
    exit 1
fi

echo ""

# Terraform plan
print_info "Step 2/3: Creating execution plan..."
if terraform plan -out=tfplan; then
    print_success "Execution plan created"
else
    print_error "Terraform plan failed"
    exit 1
fi

echo ""

# Confirm before apply
print_warning "=========================================="
print_warning "           READY TO DEPLOY"
print_warning "=========================================="
echo ""
print_info "Resources to be created:"
echo "  - S3 Bucket (encrypted, versioned)"
echo "  - AWS Glue Database"
echo "  - AWS Glue Crawlers (3x)"
echo "  - IAM User for ClickHouse"
echo "  - IAM Policies and Roles"
echo ""
read -p "Do you want to proceed with the deployment? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    print_info "Deployment cancelled"
    rm -f tfplan
    exit 0
fi

# Apply Terraform
print_info "Step 3/3: Applying Terraform configuration..."
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
echo "=========================================="
print_success "Infrastructure Deployment Complete!"
echo "=========================================="
echo ""

# Show outputs
print_info "Getting deployment information..."
echo ""

S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "N/A")
GLUE_DB=$(terraform output -raw glue_database_name 2>/dev/null || echo "N/A")
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "N/A")
ACCESS_KEY=$(terraform output -raw clickhouse_access_key_id 2>/dev/null || echo "N/A")

echo "=========================================="
echo "  Deployment Information"
echo "=========================================="
echo ""
echo "S3 Bucket:        $S3_BUCKET"
echo "Glue Database:    $GLUE_DB"
echo "AWS Region:       $AWS_REGION"
echo "Access Key ID:    $ACCESS_KEY"
echo ""

echo "=========================================="
print_warning "Next Steps:"
echo "=========================================="
echo ""
echo "1. Upload sample data:"
echo "   ./scripts/upload-sample-data.sh"
echo ""
echo "2. View ClickHouse integration details:"
echo "   terraform output clickhouse_integration_info"
echo ""
echo "3. Get AWS secret key:"
echo "   terraform output -raw clickhouse_secret_access_key"
echo ""
echo "4. Configure ClickHouse Cloud with the credentials above"
echo ""
print_success "Deployment script completed!"
echo ""
