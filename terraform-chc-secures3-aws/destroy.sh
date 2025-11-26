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

echo -e "${RED}========================================================${NC}"
echo -e "${RED}  ClickHouse Cloud Secure S3 - Destroy Script${NC}"
echo -e "${RED}========================================================${NC}"
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
    exit 1
fi

# Check if terraform has been initialized
if [ ! -d ".terraform" ]; then
    print_error "Terraform has not been initialized in this directory"
    print_info "Run './deploy.sh' or 'terraform init' first"
    exit 1
fi

# Check if there are any resources to destroy
if [ ! -f "terraform.tfstate" ]; then
    print_warning "No terraform.tfstate file found"
    print_info "There may be no resources to destroy"
    echo ""
    read -p "Do you want to continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Destroy cancelled"
        exit 0
    fi
fi

# Check AWS credentials
print_info "Checking AWS credentials..."

# Function to validate AWS credentials
validate_aws_credentials() {
    local has_valid_creds=false
    local checked_methods=""

    # Method 1: Check environment variables
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
        checked_methods="${checked_methods}environment variables, "

        # Additional validation for environment variables
        if [ ${#AWS_ACCESS_KEY_ID} -lt 16 ]; then
            print_warning "AWS_ACCESS_KEY_ID seems too short (${#AWS_ACCESS_KEY_ID} chars)"
        else
            print_success "Found AWS credentials in environment variables"
            print_info "  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:8}... (${#AWS_ACCESS_KEY_ID} chars)"
            has_valid_creds=true
        fi

        if [ -n "$AWS_SESSION_TOKEN" ]; then
            print_info "  AWS_SESSION_TOKEN is set (temporary credentials)"
        fi
    fi

    # Method 2: Check AWS CLI configuration
    if command -v aws &> /dev/null; then
        checked_methods="${checked_methods}AWS CLI, "

        if aws sts get-caller-identity &> /dev/null 2>&1; then
            print_success "AWS CLI credentials are valid"

            CALLER_IDENTITY=$(aws sts get-caller-identity 2>/dev/null)
            if [ -n "$CALLER_IDENTITY" ]; then
                ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": *"[^"]*"' | sed 's/"Account": *"\([^"]*\)"/\1/')
                USER_ARN=$(echo "$CALLER_IDENTITY" | grep -o '"Arn": *"[^"]*"' | sed 's/"Arn": *"\([^"]*\)"/\1/')

                if [ -n "$ACCOUNT_ID" ]; then
                    print_info "  AWS Account: $ACCOUNT_ID"
                fi
                if [ -n "$USER_ARN" ]; then
                    print_info "  Identity: $USER_ARN"
                fi
            fi
            has_valid_creds=true
        else
            print_warning "AWS CLI is installed but credentials are invalid or expired"
        fi
    fi

    # Method 3: Check AWS credentials file
    if [ -f "$HOME/.aws/credentials" ]; then
        checked_methods="${checked_methods}credentials file, "
        print_info "AWS credentials file exists at ~/.aws/credentials"
    fi

    # Final validation
    if [ "$has_valid_creds" = false ]; then
        print_error "No valid AWS credentials found!"
        print_info "Checked: ${checked_methods%??}"
        echo ""
        print_info "Please configure AWS credentials using one of these methods:"
        print_info "  1. Environment variables:"
        print_info "     export AWS_ACCESS_KEY_ID=\"your-access-key\""
        print_info "     export AWS_SECRET_ACCESS_KEY=\"your-secret-key\""
        print_info "     export AWS_SESSION_TOKEN=\"your-token\"  # if using temporary credentials"
        print_info "  2. AWS CLI configuration:"
        print_info "     aws configure"
        print_info "  3. AWS credentials file at ~/.aws/credentials"
        echo ""

        # Check for common invalid credential patterns
        if [ -n "$AWS_ACCESS_KEY_ID" ]; then
            if [[ "$AWS_ACCESS_KEY_ID" == "your-"* ]] || [[ "$AWS_ACCESS_KEY_ID" == "AKIA"* ]]; then
                print_warning "AWS_ACCESS_KEY_ID appears to be a placeholder or example value"
            fi
        fi

        return 1
    fi

    return 0
}

if ! validate_aws_credentials; then
    exit 1
fi
echo ""

# Show current state
print_info "Checking current infrastructure state..."
echo ""

# Get current resources
BUCKET_NAME=$(terraform output -raw bucket_name 2>/dev/null || echo "")
BUCKET_REGION=$(terraform output -raw bucket_region 2>/dev/null || echo "")
IAM_ROLE_ARN=$(terraform output -raw iam_role_arn 2>/dev/null || echo "")

if [ -n "$BUCKET_NAME" ]; then
    print_info "Current deployment:"
    echo "  S3 Bucket: $BUCKET_NAME"
    echo "  Region: $BUCKET_REGION"
    echo "  IAM Role: $IAM_ROLE_ARN"
    echo ""

    # Check if bucket has objects
    if command -v aws &> /dev/null && [ -n "$BUCKET_REGION" ]; then
        print_info "Checking S3 bucket contents..."
        OBJECT_COUNT=$(aws s3 ls "s3://${BUCKET_NAME}" --recursive --region "$BUCKET_REGION" 2>/dev/null | wc -l | tr -d ' ')

        if [ -n "$OBJECT_COUNT" ] && [ "$OBJECT_COUNT" -gt 0 ]; then
            print_warning "S3 bucket contains $OBJECT_COUNT object(s)"
            echo ""
            echo "Preview of files in bucket:"
            aws s3 ls "s3://${BUCKET_NAME}" --recursive --region "$BUCKET_REGION" 2>/dev/null | head -10 || true
            echo ""

            if [ "$OBJECT_COUNT" -gt 10 ]; then
                echo "... and $((OBJECT_COUNT - 10)) more files"
                echo ""
            fi
        else
            print_success "S3 bucket is empty"
        fi
        echo ""
    fi
fi

# Run terraform plan -destroy to show what will be destroyed
print_info "Generating destroy plan..."
echo ""
if ! terraform plan -destroy -out=tfplan-destroy; then
    print_error "Failed to generate destroy plan"
    exit 1
fi
echo ""

# Show warning
echo -e "${RED}========================================================${NC}"
echo -e "${RED}             ⚠️  WARNING  ⚠️${NC}"
echo -e "${RED}========================================================${NC}"
echo ""
echo -e "${RED}This action will PERMANENTLY DELETE:${NC}"
echo ""
echo "  • S3 Bucket: $BUCKET_NAME"

if [ -n "$OBJECT_COUNT" ] && [ "$OBJECT_COUNT" -gt 0 ]; then
    echo "    └─ Contains $OBJECT_COUNT file(s) that will be LOST"
fi

echo "  • IAM Role: $(basename "$IAM_ROLE_ARN")"
echo "  • IAM Policy attached to the role"
echo ""

if [ -n "$OBJECT_COUNT" ] && [ "$OBJECT_COUNT" -gt 0 ]; then
    echo -e "${RED}⚠️  WARNING: S3 bucket contains data!${NC}"
    echo -e "${RED}All files in the bucket will be permanently deleted!${NC}"
    echo ""
fi

echo -e "${RED}This action is IRREVERSIBLE!${NC}"
echo ""

# Ask for confirmation
read -p "Are you absolutely sure you want to destroy all resources? (yes/no) " -r
echo
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    print_info "Destroy cancelled"
    rm -f tfplan-destroy
    print_success "Your infrastructure is safe!"
    exit 0
fi

# Second confirmation if bucket has data
if [ -n "$OBJECT_COUNT" ] && [ "$OBJECT_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Second confirmation required (bucket contains data)${NC}"
    read -p "Type 'destroy' to confirm deletion of $OBJECT_COUNT file(s): " -r
    echo
    if [[ ! $REPLY == "destroy" ]]; then
        print_info "Destroy cancelled"
        rm -f tfplan-destroy
        print_success "Your infrastructure is safe!"
        exit 0
    fi
fi

# Optional: Backup data before destroying
if [ -n "$BUCKET_NAME" ] && command -v aws &> /dev/null; then
    if [ -n "$OBJECT_COUNT" ] && [ "$OBJECT_COUNT" -gt 0 ]; then
        echo ""
        print_warning "Do you want to create a backup before destroying? (recommended)"
        read -p "Create backup? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Creating backup..."

            BACKUP_DIR="backup-s3-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$BACKUP_DIR"

            print_info "Saving deployment information..."
            terraform output > "$BACKUP_DIR/outputs.txt" 2>/dev/null || true
            terraform show > "$BACKUP_DIR/state.txt" 2>/dev/null || true

            print_info "Downloading S3 objects..."
            if aws s3 sync "s3://${BUCKET_NAME}" "$BACKUP_DIR/s3-data/" --region "$BUCKET_REGION" 2>/dev/null; then
                print_success "Backup saved to: $BACKUP_DIR"
                print_info "S3 data backed up to: $BACKUP_DIR/s3-data/"
            else
                print_warning "Could not backup S3 data completely"
            fi
            echo ""
        fi
    else
        print_info "Saving deployment metadata..."
        BACKUP_DIR="backup-metadata-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        terraform output > "$BACKUP_DIR/outputs.txt" 2>/dev/null || true
        terraform show > "$BACKUP_DIR/state.txt" 2>/dev/null || true
        print_success "Metadata saved to: $BACKUP_DIR"
        echo ""
    fi
fi

# Empty S3 bucket if it has objects (Terraform can't destroy non-empty buckets)
if [ -n "$BUCKET_NAME" ] && [ -n "$OBJECT_COUNT" ] && [ "$OBJECT_COUNT" -gt 0 ]; then
    print_info "Emptying S3 bucket before destroy..."

    if command -v aws &> /dev/null && [ -n "$BUCKET_REGION" ]; then
        # Delete all objects
        if aws s3 rm "s3://${BUCKET_NAME}" --recursive --region "$BUCKET_REGION" 2>/dev/null; then
            print_success "S3 bucket emptied"
        else
            print_warning "Could not empty S3 bucket automatically"
            print_info "You may need to empty the bucket manually"
        fi

        # Delete all versions if versioning is enabled
        print_info "Checking for object versions..."
        aws s3api list-object-versions --bucket "$BUCKET_NAME" --region "$BUCKET_REGION" --output text --query 'Versions[].{Key:Key,VersionId:VersionId}' 2>/dev/null | \
        while read -r key version; do
            if [ -n "$key" ] && [ -n "$version" ]; then
                aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version" --region "$BUCKET_REGION" 2>/dev/null || true
            fi
        done

        # Delete all delete markers
        aws s3api list-object-versions --bucket "$BUCKET_NAME" --region "$BUCKET_REGION" --output text --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' 2>/dev/null | \
        while read -r key version; do
            if [ -n "$key" ] && [ -n "$version" ]; then
                aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version" --region "$BUCKET_REGION" 2>/dev/null || true
            fi
        done
    fi
    echo ""
fi

# Destroy infrastructure
print_info "Destroying infrastructure..."
echo ""

if terraform apply tfplan-destroy; then
    print_success "Infrastructure destroyed successfully!"
else
    print_error "Destroy operation failed"
    print_info "You may need to manually clean up some resources"

    if [ -n "$BUCKET_NAME" ]; then
        echo ""
        print_info "If S3 bucket deletion failed, try:"
        echo "  aws s3 rb s3://${BUCKET_NAME} --force --region ${BUCKET_REGION}"
    fi

    rm -f tfplan-destroy
    exit 1
fi

# Clean up plan file
rm -f tfplan-destroy

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  Destroy Complete!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""

print_success "All AWS resources have been destroyed"
print_info "The following local files remain:"
echo "  • Terraform state files (.tfstate)"
echo "  • Terraform configuration files (.tf)"
echo "  • Configuration files (terraform.tfvars)"
echo ""

# Ask if user wants to clean up local files
read -p "Do you want to clean up local Terraform files? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Cleaning up local files..."

    # Backup state files before deleting
    if [ -f "terraform.tfstate" ]; then
        BACKUP_DIR="backup-state-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp terraform.tfstate* "$BACKUP_DIR/" 2>/dev/null || true
        print_info "State files backed up to: $BACKUP_DIR"
    fi

    rm -rf .terraform .terraform.lock.hcl
    rm -f terraform.tfstate terraform.tfstate.backup
    rm -f tfplan tfplan-destroy
    rm -f deployment-info.txt

    # Clean up generated test files
    rm -f test_s3_queries.sql
    rm -f example_*.sql

    print_success "Local Terraform files cleaned up"
    print_info "Configuration files (.tf, terraform.tfvars) preserved"
else
    print_info "Local files preserved"
    print_info "You can re-deploy using: ./deploy.sh"
fi

echo ""
print_info "To deploy again in the future:"
echo "  ./deploy.sh"
echo ""

print_success "Cleanup complete! 👋"
