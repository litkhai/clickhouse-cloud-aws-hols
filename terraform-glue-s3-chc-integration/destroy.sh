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
echo "   ClickHouse-Glue Integration Cleanup"
echo "=========================================="
echo ""

# Check if Terraform is installed
if ! command_exists terraform; then
    print_error "Terraform is not installed."
    exit 1
fi

# Check if terraform.tfstate exists
if [ ! -f "terraform.tfstate" ]; then
    print_error "No terraform.tfstate found. Nothing to destroy."
    echo ""
    print_info "If you want to clean up local files, run:"
    echo "  rm -rf .terraform terraform.tfstate.backup terraform.tfvars sample-data/"
    exit 1
fi

echo ""
print_warning "⚠️  WARNING: This will permanently delete the following resources:"
echo ""

# Try to show current resources
print_info "Current deployment:"
echo ""

S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "unknown")
GLUE_DB=$(terraform output -raw glue_database_name 2>/dev/null || echo "unknown")
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "unknown")
IAM_USER=$(terraform output -raw clickhouse_user_name 2>/dev/null || echo "unknown")

echo "  Region:        $AWS_REGION"
echo "  S3 Bucket:     $S3_BUCKET"
echo "  Glue Database: $GLUE_DB"
echo "  IAM User:      $IAM_USER"
echo ""

echo "Resources to be deleted:"
echo "  • S3 bucket and ALL data inside it"
echo "  • AWS Glue database and all tables"
echo "  • AWS Glue crawlers (3x)"
echo "  • IAM user and credentials"
echo "  • All IAM policies and roles"
echo ""

print_error "⚠️  THIS ACTION CANNOT BE UNDONE!"
echo ""

# First confirmation
read -p "Are you sure you want to destroy these resources? (yes/no): " confirm1

if [ "$confirm1" != "yes" ]; then
    print_info "Destruction cancelled. No changes made."
    exit 0
fi

echo ""
print_warning "Second confirmation required."
echo ""
echo "Type 'destroy' to confirm resource destruction:"
read -p "> " confirm2

if [ "$confirm2" != "destroy" ]; then
    print_info "Destruction cancelled. No changes made."
    exit 0
fi

echo ""
print_info "Starting resource destruction..."
echo ""

# Check for S3 bucket contents
if [ "$S3_BUCKET" != "unknown" ] && command_exists aws; then
    print_info "Checking S3 bucket contents..."

    OBJECT_COUNT=$(aws s3 ls "s3://$S3_BUCKET" --recursive 2>/dev/null | wc -l || echo "0")

    if [ "$OBJECT_COUNT" -gt 0 ]; then
        echo ""
        print_warning "S3 bucket contains $OBJECT_COUNT object(s)"
        echo ""
        read -p "Empty S3 bucket before destroying? (recommended: yes/no): " empty_bucket

        if [ "$empty_bucket" == "yes" ]; then
            print_info "Emptying S3 bucket: $S3_BUCKET"

            # Remove all versions and delete markers
            aws s3api list-object-versions \
                --bucket "$S3_BUCKET" \
                --output json \
                --query 'Versions[].{Key:Key,VersionId:VersionId}' 2>/dev/null | \
                jq -r '.[] | "--key \"\(.Key)\" --version-id \"\(.VersionId)\""' | \
                xargs -I {} aws s3api delete-object --bucket "$S3_BUCKET" {} 2>/dev/null || true

            # Remove delete markers
            aws s3api list-object-versions \
                --bucket "$S3_BUCKET" \
                --output json \
                --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' 2>/dev/null | \
                jq -r '.[] | "--key \"\(.Key)\" --version-id \"\(.VersionId)\""' | \
                xargs -I {} aws s3api delete-object --bucket "$S3_BUCKET" {} 2>/dev/null || true

            # Final cleanup
            aws s3 rm "s3://$S3_BUCKET" --recursive 2>/dev/null || true

            print_success "S3 bucket emptied"
        else
            print_warning "S3 bucket will be force-deleted (may fail if not empty)"
        fi
    fi
fi

echo ""
print_info "Running Terraform destroy..."
echo ""

# Run terraform destroy
if terraform destroy -auto-approve; then
    print_success "All resources destroyed successfully!"
else
    print_error "Terraform destroy encountered errors."
    echo ""
    print_info "You may need to manually delete remaining resources:"
    echo "  - S3 bucket: $S3_BUCKET"
    echo "  - Glue database: $GLUE_DB"
    echo "  - IAM user: $IAM_USER"
    exit 1
fi

echo ""
echo "=========================================="
print_success "Cleanup Complete!"
echo "=========================================="
echo ""

# Ask about local files
read -p "Remove local Terraform files? (terraform.tfvars, .terraform/, etc.) (yes/no): " clean_local

if [ "$clean_local" == "yes" ]; then
    print_info "Cleaning up local files..."

    rm -rf .terraform/
    rm -f terraform.tfstate terraform.tfstate.backup
    rm -f .terraform.lock.hcl
    rm -f tfplan

    print_success "Local Terraform files removed"

    echo ""
    read -p "Remove terraform.tfvars? (yes/no): " remove_tfvars

    if [ "$remove_tfvars" == "yes" ]; then
        rm -f terraform.tfvars
        print_success "terraform.tfvars removed"
    fi

    echo ""
    read -p "Remove sample-data directory? (yes/no): " remove_samples

    if [ "$remove_samples" == "yes" ]; then
        rm -rf sample-data/
        print_success "sample-data directory removed"
    fi
fi

echo ""
print_success "Destroy script completed!"
echo ""
print_info "To redeploy, run: ./deploy.sh"
echo ""
