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

echo -e "${RED}=================================================${NC}"
echo -e "${RED}  Confluent Platform on AWS - Destroy Script${NC}"
echo -e "${RED}=================================================${NC}"
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
INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null || echo "")
PUBLIC_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "")

if [ -n "$INSTANCE_ID" ]; then
    print_info "Current deployment:"
    echo "  Instance ID: $INSTANCE_ID"
    echo "  Public IP: $PUBLIC_IP"
    echo ""
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
echo -e "${RED}=================================================${NC}"
echo -e "${RED}             ⚠️  WARNING  ⚠️${NC}"
echo -e "${RED}=================================================${NC}"
echo ""
echo -e "${RED}This action will PERMANENTLY DELETE:${NC}"
echo ""
echo "  • EC2 Instance (and all Confluent Platform data)"
echo "  • Security Group"
echo "  • EBS Volume (all Kafka data will be lost)"
echo "  • Elastic IP (if allocated)"
echo ""
echo -e "${RED}This action is IRREVERSIBLE!${NC}"
echo -e "${RED}All data will be permanently lost!${NC}"
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

# Second confirmation
echo ""
echo -e "${YELLOW}Second confirmation required${NC}"
read -p "Type 'destroy' to confirm: " -r
echo
if [[ ! $REPLY == "destroy" ]]; then
    print_info "Destroy cancelled"
    rm -f tfplan-destroy
    print_success "Your infrastructure is safe!"
    exit 0
fi

# Optional: Try to backup data before destroying
if [ -n "$PUBLIC_IP" ]; then
    echo ""
    print_warning "Do you want to create a backup before destroying? (recommended)"
    read -p "Create backup? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Creating backup..."

        BACKUP_DIR="backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"

        print_info "Saving deployment information..."
        terraform output > "$BACKUP_DIR/outputs.txt" 2>/dev/null || true
        terraform show > "$BACKUP_DIR/state.txt" 2>/dev/null || true

        # Try to backup Kafka topics list
        if command -v ssh &> /dev/null; then
            print_info "Attempting to backup Kafka topics list..."
            timeout 30 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                ubuntu@$PUBLIC_IP 'docker exec broker kafka-topics --list --bootstrap-server localhost:9092' \
                > "$BACKUP_DIR/kafka-topics.txt" 2>/dev/null || \
                print_warning "Could not connect to instance to backup topics"
        fi

        print_success "Backup saved to: $BACKUP_DIR"
        echo ""
    fi
fi

# Destroy infrastructure
print_info "Destroying infrastructure..."
echo ""

if terraform apply tfplan-destroy; then
    print_success "Infrastructure destroyed successfully!"
else
    print_error "Destroy operation failed"
    print_info "You may need to manually clean up some resources"
    rm -f tfplan-destroy
    exit 1
fi

# Clean up plan file
rm -f tfplan-destroy

echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}  Destroy Complete!${NC}"
echo -e "${GREEN}=================================================${NC}"
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
