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
echo "   MinIO on AWS EC2 - Destroy Script"
echo "=========================================="
echo ""

# Check prerequisites
print_info "Checking prerequisites..."

if ! command_exists terraform; then
    print_error "Terraform is not installed."
    exit 1
fi

print_success "Terraform found: $(terraform version | head -n 1)"

# Check if terraform state exists
if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
    print_warning "No Terraform state found. Nothing to destroy."
    exit 0
fi

# Show current resources
print_info "Checking existing resources..."
echo ""

if terraform show >/dev/null 2>&1; then
    print_info "Current deployment information:"
    echo ""

    CONSOLE_URL=$(terraform output -raw minio_console_url 2>/dev/null || echo "N/A")
    PUBLIC_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "N/A")
    INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null || echo "N/A")

    echo "  MinIO Console: $CONSOLE_URL"
    echo "  Public IP: $PUBLIC_IP"
    echo "  Instance ID: $INSTANCE_ID"
    echo ""
fi

# Warning
print_warning "=========================================="
print_warning "           DESTRUCTIVE OPERATION"
print_warning "=========================================="
echo ""
print_warning "This will destroy the following resources:"
echo "  - EC2 Instance (MinIO server)"
echo "  - All data stored in MinIO"
echo "  - Security Group"
echo "  - Elastic IP (if allocated)"
echo ""
print_error "This action CANNOT be undone!"
echo ""

# Confirmation
read -p "Are you sure you want to destroy all resources? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    print_info "Destroy operation cancelled"
    exit 0
fi

echo ""
read -p "Type 'destroy' to confirm: " confirm2

if [ "$confirm2" != "destroy" ]; then
    print_info "Destroy operation cancelled"
    exit 0
fi

echo ""
print_info "Starting resource destruction..."
echo ""

# Run terraform destroy
if terraform destroy -auto-approve; then
    print_success "All resources destroyed successfully!"
else
    print_error "Terraform destroy failed"
    print_info "You may need to manually clean up resources in AWS Console"
    exit 1
fi

echo ""
echo "=========================================="
print_success "Cleanup Complete!"
echo "=========================================="
echo ""
print_info "All AWS resources have been destroyed"
print_info "Local Terraform state has been updated"
echo ""

# Optional: Clean up local files
read -p "Do you want to remove local Terraform files? (yes/no): " cleanup

if [ "$cleanup" = "yes" ]; then
    print_info "Cleaning up local files..."

    rm -rf .terraform/
    rm -f .terraform.lock.hcl
    rm -f terraform.tfstate*
    rm -f tfplan

    print_success "Local Terraform files removed"
fi

echo ""
print_success "Destroy script completed!"
echo ""
