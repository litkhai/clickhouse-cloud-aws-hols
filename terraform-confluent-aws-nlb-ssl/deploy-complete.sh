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
echo -e "${BLUE}  Confluent Platform NLB SSL - Complete Deployment${NC}"
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
    print_error "Terraform is not installed"
    exit 1
fi

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    print_error "terraform.tfvars not found!"
    echo ""
    print_info "Please create terraform.tfvars first:"
    echo "  cp terraform.tfvars.example terraform.tfvars"
    echo "  # Edit terraform.tfvars with your settings"
    exit 1
fi

print_success "terraform.tfvars found"
echo ""

# Check for SSH key configuration
print_info "Checking SSH key configuration..."
SSH_KEY_PATH=""

# Method 1: Check terraform.tfvars (only uncommented lines)
if grep -q "^[^#]*ssh_private_key\s*=\s*\".\+\"" terraform.tfvars 2>/dev/null; then
    SSH_KEY_FROM_TF=$(grep "^[^#]*ssh_private_key" terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/' | head -1)
    if [ -n "$SSH_KEY_FROM_TF" ]; then
        # Expand tilde
        SSH_KEY_PATH="${SSH_KEY_FROM_TF/#\~/$HOME}"
    fi
fi

# Method 2: Check environment variable (backward compatibility)
if [ -z "$SSH_KEY_PATH" ] && [ -n "$SSH_KEY" ]; then
    SSH_KEY_PATH="$SSH_KEY"
fi

# Determine mode
if [ -z "$SSH_KEY_PATH" ]; then
    print_warning "No SSH key configured"
    echo ""
    echo "You have three options:"
    echo ""
    echo "  1. Add to terraform.tfvars (recommended):"
    echo "     ssh_private_key = \"~/.ssh/your-key.pem\""
    echo ""
    echo "  2. Use environment variable:"
    echo "     SSH_KEY=~/.ssh/your-key.pem $0"
    echo ""
    echo "  3. Continue without SSH key (manual configuration required)"
    echo ""
    read -p "Continue without SSH key? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    MANUAL_MODE=true
    print_info "Continuing in manual mode"
else
    # Verify SSH key exists
    if [ ! -f "$SSH_KEY_PATH" ]; then
        print_error "SSH key not found: $SSH_KEY_PATH"
        exit 1
    fi
    MANUAL_MODE=false
    print_success "SSH key configured: $SSH_KEY_PATH"
fi

echo ""

# Check for initial certificate
print_info "Step 1: Checking for initial certificate..."
if [ ! -f "certs/nlb-certificate.pem" ]; then
    print_info "Generating initial certificate..."
    cd certs
    ./generate-nlb-cert.sh
    cd ..
    print_success "Initial certificate generated"
else
    print_success "Initial certificate already exists"
fi

echo ""

# Initial deployment
print_info "Step 2: Deploying infrastructure..."
terraform init
terraform apply -auto-approve

print_success "Infrastructure deployed!"
echo ""

# Get outputs
print_info "Step 3: Getting deployment information..."
NLB_DNS=$(terraform output -raw nlb_endpoint 2>/dev/null)
EC2_DNS=$(terraform output -raw instance_public_dns 2>/dev/null)

if [ -z "$NLB_DNS" ] || [ -z "$EC2_DNS" ]; then
    print_error "Could not get deployment outputs"
    exit 1
fi

print_info "NLB DNS: $NLB_DNS"
print_info "EC2 DNS: $EC2_DNS"
echo ""

# Wait for certificate generation
print_info "Step 4: Waiting for certificate generation..."
sleep 5

# Check if certificate was updated
if grep -q "${NLB_DNS}" certs/nlb-certificate.pem 2>/dev/null; then
    print_success "Certificate already updated with NLB DNS"
else
    print_warning "Certificate needs update"
fi

echo ""

# Update ACM certificate
print_info "Step 5: Updating ACM certificate..."
terraform apply -replace='aws_acm_certificate.nlb_cert' -auto-approve
print_success "ACM certificate updated"
echo ""

# Update Kafka advertised listener
print_info "Step 6: Updating Kafka advertised listener..."

if [ "$MANUAL_MODE" = true ]; then
    echo ""
    print_warning "Manual configuration required!"
    echo ""
    echo "SSH to your instance and run these commands:"
    echo ""
    echo -e "${BLUE}  ssh -i your-key.pem ubuntu@${EC2_DNS}${NC}"
    echo ""
    echo -e "${BLUE}  # Wait for docker-compose to be ready${NC}"
    echo -e "${BLUE}  while [ ! -f /opt/confluent/docker-compose.yml ]; do sleep 5; done${NC}"
    echo ""
    echo -e "${BLUE}  # Update advertised listener${NC}"
    echo -e "${BLUE}  sudo sed -i 's/NLB_DNS_PLACEHOLDER/${NLB_DNS}/g' /opt/confluent/docker-compose.yml${NC}"
    echo ""
    echo -e "${BLUE}  # Restart Kafka${NC}"
    echo -e "${BLUE}  cd /opt/confluent${NC}"
    echo -e "${BLUE}  sudo docker-compose restart broker${NC}"
    echo ""
    echo -e "${BLUE}  # Wait for Kafka to be ready${NC}"
    echo -e "${BLUE}  sleep 30${NC}"
    echo ""
    echo -e "${BLUE}  # Verify${NC}"
    echo -e "${BLUE}  docker logs broker | grep advertised.listeners${NC}"
    echo ""
else
    print_info "Waiting for instance to be SSH-ready..."
    if timeout 300 bash -c "until nc -z ${EC2_DNS} 22 2>/dev/null; do sleep 5; done" 2>/dev/null; then
        print_success "Instance is SSH-ready"
    else
        print_error "Timeout waiting for SSH access"
        exit 1
    fi

    echo ""
    print_info "Waiting for docker-compose.yml to be created..."
    if timeout 600 bash -c "until ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${EC2_DNS} 'test -f /opt/confluent/docker-compose.yml' 2>/dev/null; do sleep 10; done" 2>/dev/null; then
        print_success "docker-compose.yml is ready"
    else
        print_error "Timeout waiting for docker-compose.yml"
        exit 1
    fi

    echo ""
    print_info "Updating advertised listener with NLB DNS..."

    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no ubuntu@${EC2_DNS} << EOF
        echo "Updating docker-compose.yml..."
        sudo sed -i 's/NLB_DNS_PLACEHOLDER/${NLB_DNS}/g' /opt/confluent/docker-compose.yml

        echo "Restarting Kafka broker..."
        cd /opt/confluent
        sudo docker-compose restart broker

        echo "Waiting for Kafka to be ready..."
        sleep 30

        echo "Verifying advertised listener..."
        docker logs broker 2>&1 | grep -i "advertised.listeners" | tail -3 || true
EOF

    print_success "Advertised listener updated!"
fi

echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""

# Show connection info
terraform output connection_info

echo ""
echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}  Next Steps${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""
echo "1. Test connection:"
echo "   python3 test_nlb_connection.py"
echo ""
echo "2. Verify broker metadata shows NLB DNS (not EC2 DNS):"
echo "   Expected: ${NLB_DNS}:9094"
echo ""
echo "3. Certificate location:"
echo "   certs/nlb-certificate.pem"
echo ""
echo "4. Connection details:"
echo "   bootstrap.servers: ${NLB_DNS}:9094"
echo "   security.protocol: SASL_SSL"
echo "   ssl.ca.location: certs/nlb-certificate.pem"
echo ""

if [ "$MANUAL_MODE" = true ]; then
    print_warning "Don't forget to complete the manual configuration steps above!"
    echo ""
fi

print_success "All done! Your Confluent Platform with NLB SSL termination is ready."
