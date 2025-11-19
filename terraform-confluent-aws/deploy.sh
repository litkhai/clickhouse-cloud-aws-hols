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

echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}  Confluent Platform on AWS - Deployment Script${NC}"
echo -e "${BLUE}=================================================${NC}"
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
# Check terraform.tfvars
elif grep -q "aws_region" terraform.tfvars 2>/dev/null; then
    DETECTED_REGION=$(grep "aws_region" terraform.tfvars | cut -d'"' -f2)
    print_success "AWS region from terraform.tfvars: $DETECTED_REGION"
# Check AWS CLI configuration
elif command -v aws &> /dev/null; then
    AWS_CLI_REGION=$(aws configure get region 2>/dev/null)
    if [ -n "$AWS_CLI_REGION" ]; then
        DETECTED_REGION="$AWS_CLI_REGION"
        print_success "AWS region from AWS CLI configuration: $AWS_CLI_REGION"
    fi
fi

# If no region detected, show warning and try to get from AWS CLI config file
if [ -z "$DETECTED_REGION" ]; then
    if [ -f "$HOME/.aws/config" ]; then
        CLI_CONFIG_REGION=$(grep -A 5 "^\[default\]" "$HOME/.aws/config" | grep "^region" | cut -d'=' -f2 | tr -d ' ' | head -1)
        if [ -n "$CLI_CONFIG_REGION" ]; then
            DETECTED_REGION="$CLI_CONFIG_REGION"
            print_success "AWS region from AWS config file: $CLI_CONFIG_REGION"
        fi
    fi
fi

# Final check
if [ -z "$DETECTED_REGION" ]; then
    print_warning "AWS region not detected"
    print_info "Will use Terraform provider default or prompt during apply"
else
    print_info "Terraform will use region: $DETECTED_REGION"
fi
echo ""

# EC2 Key Pair Configuration
echo "=========================================="
echo "  EC2 Key Pair Configuration"
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
    KEY_PAIRS=()
    if command -v aws &> /dev/null && [ -n "$DETECTED_REGION" ]; then
        print_info "Fetching available key pairs from region: $DETECTED_REGION..."

        # Build AWS command with region
        AWS_CMD="aws ec2 describe-key-pairs --query 'KeyPairs[*].KeyName' --output text"
        if [ -n "$DETECTED_REGION" ]; then
            AWS_CMD="$AWS_CMD --region $DETECTED_REGION"
        fi

        # Get key pairs as array (compatible with bash 3.x)
        while IFS= read -r line; do
            [ -n "$line" ] && KEY_PAIRS+=("$line")
        done < <(eval $AWS_CMD 2>/dev/null | tr '\t' '\n')

        if [ ${#KEY_PAIRS[@]} -gt 0 ]; then
            echo ""
            echo "Available key pairs in region $DETECTED_REGION:"
            echo "=========================================="
            for i in "${!KEY_PAIRS[@]}"; do
                printf "  %2d. %s\n" $((i+1)) "${KEY_PAIRS[$i]}"
            done
            echo "=========================================="
            echo ""

            echo "Options:"
            echo "  1-${#KEY_PAIRS[@]}. Select a key pair by number"
            echo "  0. Enter a key pair name manually"
            echo "  s. Skip SSH configuration (Confluent will still be accessible via web)"
            echo ""
            read -p "Enter your choice: " key_choice

            if [ "$key_choice" = "s" ] || [ "$key_choice" = "S" ]; then
                print_warning "Skipping SSH key pair configuration"
                print_info "You will not be able to SSH into the instance"
                print_info "Confluent Platform will still be accessible via web console"
                echo ""
            elif [ "$key_choice" = "0" ]; then
                echo ""
                read -p "Enter your EC2 key pair name: " key_pair_name

                if [ -z "$key_pair_name" ]; then
                    print_error "Key pair name cannot be empty"
                    exit 1
                fi

                # Verify key pair exists
                VERIFY_CMD="aws ec2 describe-key-pairs --key-names \"$key_pair_name\""
                if [ -n "$DETECTED_REGION" ]; then
                    VERIFY_CMD="$VERIFY_CMD --region $DETECTED_REGION"
                fi

                if eval $VERIFY_CMD >/dev/null 2>&1; then
                    print_success "Key pair '$key_pair_name' verified in region $DETECTED_REGION"
                else
                    print_warning "Key pair '$key_pair_name' not found in region $DETECTED_REGION"
                    read -p "Continue anyway? (yes/no): " continue_choice
                    if [ "$continue_choice" != "yes" ]; then
                        print_info "Exiting. Please check your key pair name and region."
                        exit 0
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
            elif [[ "$key_choice" =~ ^[0-9]+$ ]] && [ "$key_choice" -ge 1 ] && [ "$key_choice" -le ${#KEY_PAIRS[@]} ]; then
                # Valid number selection
                selected_index=$((key_choice-1))
                key_pair_name="${KEY_PAIRS[$selected_index]}"

                print_success "Selected key pair: $key_pair_name"

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
            else
                print_error "Invalid choice. Exiting."
                exit 1
            fi
        else
            print_warning "No key pairs found in your AWS account"
            echo ""
            read -p "Would you like to enter a key pair name manually? (yes/no): " manual_choice

            if [ "$manual_choice" = "yes" ]; then
                read -p "Enter your EC2 key pair name: " key_pair_name

                if [ -n "$key_pair_name" ]; then
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
                else
                    print_warning "Skipping SSH key pair configuration"
                fi
            else
                print_warning "Skipping SSH key pair configuration"
            fi
        fi
    else
        print_warning "AWS CLI not available or region not detected"
        echo ""
        read -p "Would you like to enter a key pair name manually? (yes/no): " manual_choice

        if [ "$manual_choice" = "yes" ]; then
            read -p "Enter your EC2 key pair name: " key_pair_name

            if [ -n "$key_pair_name" ]; then
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
            else
                print_warning "Skipping SSH key pair configuration"
            fi
        else
            print_warning "Skipping SSH key pair configuration"
        fi
    fi
fi
echo ""

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
echo -e "${YELLOW}=================================================${NC}"
echo -e "${YELLOW}Review the plan above carefully!${NC}"
echo -e "${YELLOW}=================================================${NC}"
echo ""
echo "This will create:"
echo "  • 1 EC2 instance (with Confluent Platform)"
echo "  • 1 Security group"
echo "  • 1 EBS volume"
echo "  • (Optional) 1 Elastic IP"
echo ""
echo -e "${YELLOW}Estimated cost: ~\$180-200/month for 24/7 operation${NC}"
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
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""

# Display outputs
print_info "Retrieving deployment information..."
echo ""

# Get outputs
CONTROL_CENTER_URL=$(terraform output -raw control_center_url 2>/dev/null || echo "N/A")
PUBLIC_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "N/A")
KAFKA_BOOTSTRAP=$(terraform output -raw kafka_bootstrap_servers 2>/dev/null || echo "N/A")
SSH_COMMAND=$(terraform output -raw ssh_command 2>/dev/null || echo "N/A")

echo -e "${BLUE}Access Information:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${GREEN}Control Center (Web UI):${NC}"
echo "  $CONTROL_CENTER_URL"
echo ""
echo -e "${GREEN}Public IP Address:${NC}"
echo "  $PUBLIC_IP"
echo ""
echo -e "${GREEN}Kafka Bootstrap Servers:${NC}"
echo "  $KAFKA_BOOTSTRAP"
echo ""
echo -e "${GREEN}SSH Access:${NC}"
echo "  $SSH_COMMAND"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_info "The instance is starting up and installing Confluent Platform..."
print_info "This may take 5-10 minutes to complete."
echo ""
print_info "You can monitor the installation progress:"
echo "  ssh ubuntu@$PUBLIC_IP 'tail -f /var/log/cloud-init-output.log'"
echo ""
print_info "Once installation is complete, access the Control Center at:"
echo "  $CONTROL_CENTER_URL"
echo ""

# Save outputs to file
OUTPUT_FILE="deployment-info.txt"
cat > "$OUTPUT_FILE" <<EOF
Confluent Platform Deployment Information
==========================================
Deployment Date: $(date)

Control Center URL: $CONTROL_CENTER_URL
Public IP: $PUBLIC_IP
Kafka Bootstrap Servers: $KAFKA_BOOTSTRAP
SSH Command: $SSH_COMMAND

Management Commands:
-------------------
Check Status:
  ssh ubuntu@$PUBLIC_IP 'sudo /opt/confluent/status.sh'

Stop Services:
  ssh ubuntu@$PUBLIC_IP 'sudo /opt/confluent/stop.sh'

Start Services:
  ssh ubuntu@$PUBLIC_IP 'sudo /opt/confluent/start.sh'

View Producer Logs:
  ssh ubuntu@$PUBLIC_IP 'sudo journalctl -u confluent-producer -f'

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

print_success "Happy Streaming! 🚀"
