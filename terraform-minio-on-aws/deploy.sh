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
echo "   MinIO on AWS EC2 - Deployment Script"
echo "=========================================="
echo ""

# Check prerequisites
print_info "Checking prerequisites..."

if ! command_exists terraform; then
    print_error "Terraform is not installed. Please install Terraform first."
    exit 1
fi

if ! command_exists aws; then
    print_warning "AWS CLI is not installed. You'll need to set AWS credentials via environment variables."
else
    print_success "AWS CLI found"
fi

print_success "Terraform found: $(terraform version | head -n 1)"

# Check AWS credentials
print_info "Checking AWS credentials..."

if [ -z "$AWS_ACCESS_KEY_ID" ] && [ -z "$AWS_PROFILE" ]; then
    print_warning "AWS credentials not found in environment variables"
    print_info "Checking AWS CLI configuration..."

    if command_exists aws && aws sts get-caller-identity >/dev/null 2>&1; then
        print_success "AWS credentials found via AWS CLI configuration"
    else
        print_error "No AWS credentials found. Please configure AWS credentials:"
        echo ""
        echo "  Option 1: Using environment variables"
        echo "    export AWS_ACCESS_KEY_ID=\"your-access-key\""
        echo "    export AWS_SECRET_ACCESS_KEY=\"your-secret-key\""
        echo "    export AWS_REGION=\"us-east-1\"  # optional"
        echo ""
        echo "  Option 2: Using AWS CLI"
        echo "    aws configure"
        echo ""
        exit 1
    fi
else
    print_success "AWS credentials found in environment variables"
fi

# Check AWS region
if [ -z "$AWS_REGION" ] && [ -z "$AWS_DEFAULT_REGION" ]; then
    print_warning "AWS_REGION not set. Will use us-east-1 as default"
else
    REGION="${AWS_REGION:-$AWS_DEFAULT_REGION}"
    print_success "AWS Region: $REGION"
fi

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    print_warning "terraform.tfvars not found"
    print_info "Creating terraform.tfvars from example..."

    if [ -f "terraform.tfvars.example" ]; then
        cp terraform.tfvars.example terraform.tfvars
        print_success "Created terraform.tfvars"
        echo ""
        print_warning "IMPORTANT: Please edit terraform.tfvars and set the following:"
        echo "  - key_pair_name: Your EC2 key pair name"
        echo "  - instance_type: EC2 instance type (default: c5.xlarge)"
        echo "  - ebs_volume_size: EBS volume size in GB (default: 250)"
        echo "  - minio_root_user: MinIO username (default: admin)"
        echo "  - minio_root_password: MinIO password (default: admin)"
        echo ""
        read -p "Press Enter after editing terraform.tfvars to continue, or Ctrl+C to exit..."
    else
        print_error "terraform.tfvars.example not found"
        exit 1
    fi
else
    print_success "Found terraform.tfvars"
fi

# Check key_pair_name (optional but recommended)
if grep -q "YOUR_KEY_PAIR_NAME" terraform.tfvars 2>/dev/null || grep -q "# key_pair_name" terraform.tfvars 2>/dev/null; then
    print_warning "key_pair_name is not configured in terraform.tfvars"
    print_warning "SSH access to the instance will not be available"
    echo ""
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
print_warning "Review the plan above. The following resources will be created:"
echo "  - EC2 Instance (MinIO server)"
echo "  - Security Group (ports 9000, 9001, 22)"
echo "  - Elastic IP (if enabled)"
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
print_success "MinIO Server Deployment Complete!"
echo "=========================================="
echo ""

# Show outputs
print_info "Getting deployment information..."
echo ""

CONSOLE_URL=$(terraform output -raw minio_console_url 2>/dev/null || echo "N/A")
API_ENDPOINT=$(terraform output -raw minio_api_endpoint 2>/dev/null || echo "N/A")
PUBLIC_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "N/A")
SSH_COMMAND=$(terraform output -raw ssh_connection_command 2>/dev/null || echo "N/A")

echo "=========================================="
echo "  Deployment Information"
echo "=========================================="
echo ""
echo "MinIO Console URL: $CONSOLE_URL"
echo "MinIO API Endpoint: $API_ENDPOINT"
echo "Public IP: $PUBLIC_IP"
echo ""
echo "SSH Command:"
echo "  $SSH_COMMAND"
echo ""

# Get credentials (sensitive output)
print_info "MinIO Credentials:"
terraform output -json minio_credentials 2>/dev/null | grep -E '"username"|"password"' | sed 's/^/  /'

echo ""
echo "=========================================="
print_warning "Post-Deployment Notes:"
echo "=========================================="
echo ""
echo "1. MinIO installation may take 2-3 minutes to complete"
echo "2. Access the MinIO Console at: $CONSOLE_URL"
echo "3. Default credentials: admin / admin (change in production!)"
echo "4. Security group allows access from 0.0.0.0/0 (public)"
echo "5. For production, consider:"
echo "   - Change MinIO credentials"
echo "   - Restrict allowed_cidr_blocks"
echo "   - Enable HTTPS/TLS"
echo ""
print_success "Deployment script completed!"
echo ""
