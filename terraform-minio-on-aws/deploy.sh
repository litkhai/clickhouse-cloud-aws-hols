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
            echo "  - Default region (e.g., us-east-1)"
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
            echo "  export AWS_REGION=\"us-east-1\"  # optional"
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

# Check AWS region
if [ -z "$AWS_REGION" ] && [ -z "$AWS_DEFAULT_REGION" ]; then
    if command_exists aws; then
        CONFIGURED_REGION=$(aws configure get region 2>/dev/null || echo "")
        if [ -n "$CONFIGURED_REGION" ]; then
            print_success "AWS Region from config: $CONFIGURED_REGION"
        else
            print_warning "AWS_REGION not set. Will use us-east-1 as default"
        fi
    else
        print_warning "AWS_REGION not set. Will use us-east-1 as default"
    fi
else
    REGION="${AWS_REGION:-$AWS_DEFAULT_REGION}"
    print_success "AWS Region: $REGION"
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
echo "  Step 2: EC2 Key Pair Configuration"
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

# Check for key pair configuration
KEY_PAIR_CONFIGURED=false

if grep -q "^key_pair_name\s*=\s*\".\+\"" terraform.tfvars 2>/dev/null; then
    CONFIGURED_KEY=$(grep "^key_pair_name" terraform.tfvars | cut -d'"' -f2)
    if [ "$CONFIGURED_KEY" != "YOUR_KEY_PAIR_NAME" ] && [ -n "$CONFIGURED_KEY" ]; then
        print_success "EC2 Key Pair already configured: $CONFIGURED_KEY"
        KEY_PAIR_CONFIGURED=true
    fi
fi

if [ "$KEY_PAIR_CONFIGURED" = false ]; then
    print_warning "EC2 Key Pair is not configured"
    echo ""
    echo "SSH Key Pair allows you to access the EC2 instance via SSH."
    echo ""

    # List available key pairs if AWS CLI is available
    if command_exists aws && aws ec2 describe-key-pairs >/dev/null 2>&1; then
        echo "Available key pairs in your AWS account:"
        aws ec2 describe-key-pairs --query 'KeyPairs[*].KeyName' --output table 2>/dev/null || echo "  (Could not list key pairs)"
        echo ""
    fi

    echo "Options:"
    echo "  1. Enter an existing EC2 key pair name"
    echo "  2. Skip SSH configuration (MinIO will still be accessible via web)"
    echo ""
    read -p "Enter your choice (1-2): " key_choice

    case $key_choice in
        1)
            echo ""
            read -p "Enter your EC2 key pair name: " key_pair_name

            if [ -z "$key_pair_name" ]; then
                print_error "Key pair name cannot be empty"
                exit 1
            fi

            # Verify key pair exists (if AWS CLI is available)
            if command_exists aws; then
                if aws ec2 describe-key-pairs --key-names "$key_pair_name" >/dev/null 2>&1; then
                    print_success "Key pair '$key_pair_name' verified"
                else
                    print_warning "Key pair '$key_pair_name' not found in AWS account"
                    read -p "Continue anyway? (yes/no): " continue_choice
                    if [ "$continue_choice" != "yes" ]; then
                        print_info "Exiting. Please check your key pair name."
                        exit 0
                    fi
                fi
            fi

            # Update terraform.tfvars
            if grep -q "^# key_pair_name" terraform.tfvars; then
                sed -i.bak "s|^# key_pair_name.*|key_pair_name = \"$key_pair_name\"|" terraform.tfvars
            elif grep -q "^key_pair_name" terraform.tfvars; then
                sed -i.bak "s|^key_pair_name.*|key_pair_name = \"$key_pair_name\"|" terraform.tfvars
            else
                echo "key_pair_name = \"$key_pair_name\"" >> terraform.tfvars
            fi
            rm -f terraform.tfvars.bak

            print_success "Key pair configured: $key_pair_name"
            ;;
        2)
            print_warning "Skipping SSH key pair configuration"
            print_info "You will not be able to SSH into the instance"
            print_info "MinIO will still be accessible via web console and API"
            echo ""
            ;;
        *)
            print_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac
fi

echo ""
echo "=========================================="
echo "  Step 3: Deployment Configuration"
echo "=========================================="
echo ""

print_info "Current configuration:"
echo ""

# Show instance configuration
INSTANCE_TYPE=$(grep "^instance_type" terraform.tfvars | cut -d'"' -f2 2>/dev/null || echo "c5.xlarge")
EBS_SIZE=$(grep "^ebs_volume_size" terraform.tfvars | awk '{print $3}' 2>/dev/null || echo "250")
MINIO_USER=$(grep "^minio_root_user" terraform.tfvars | cut -d'"' -f2 2>/dev/null || echo "admin")

echo "  Instance Type: $INSTANCE_TYPE"
echo "  EBS Volume: ${EBS_SIZE}GB"
echo "  MinIO User: $MINIO_USER"
echo "  Network Access: Public (0.0.0.0/0)"
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
terraform output -json minio_credentials 2>/dev/null | grep -E '"username"|"password"' | sed 's/^/  /' || echo "  (credentials not available)"

echo ""
echo "=========================================="
print_warning "Post-Deployment Notes:"
echo "=========================================="
echo ""
echo "1. MinIO installation may take 2-3 minutes to complete"
echo "2. Access the MinIO Console at: $CONSOLE_URL"
echo "3. Default credentials: admin / admin"
echo "   ⚠️  IMPORTANT: Change credentials for production use!"
echo "4. Security group allows access from 0.0.0.0/0 (public)"
echo "5. For production, consider:"
echo "   - Change MinIO credentials"
echo "   - Restrict allowed_cidr_blocks to specific IPs"
echo "   - Enable HTTPS/TLS"
echo ""
print_success "Deployment script completed!"
echo ""
