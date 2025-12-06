#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo "Manual Advertised Listener Update"
echo -e "==========================================${NC}"
echo ""

# Get values from terraform
if ! NLB_DNS=$(terraform output -raw nlb_endpoint 2>/dev/null); then
    echo -e "${RED}[ERROR]${NC} Could not get NLB DNS from terraform"
    exit 1
fi

if ! EC2_DNS=$(terraform output -raw instance_public_dns 2>/dev/null); then
    echo -e "${RED}[ERROR]${NC} Could not get EC2 DNS from terraform"
    exit 1
fi

echo -e "${BLUE}[INFO]${NC} NLB DNS: $NLB_DNS"
echo -e "${BLUE}[INFO]${NC} EC2 DNS: $EC2_DNS"
echo ""

# Check if SSH key is provided
if [ -z "$1" ]; then
    echo -e "${YELLOW}[WARNING]${NC} No SSH key provided"
    echo ""
    echo "Usage:"
    echo "  $0 /path/to/your-key.pem"
    echo ""
    echo "Or use SSH agent:"
    echo "  ssh-add /path/to/your-key.pem"
    echo "  $0"
    echo ""
    exit 1
fi

SSH_KEY="$1"

if [ ! -f "$SSH_KEY" ]; then
    echo -e "${RED}[ERROR]${NC} SSH key not found: $SSH_KEY"
    exit 1
fi

echo -e "${GREEN}[SUCCESS]${NC} SSH key found: $SSH_KEY"
echo ""

# Test SSH connection
echo -e "${BLUE}[INFO]${NC} Testing SSH connection..."
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${EC2_DNS} "echo 'Connection successful'" 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${NC} SSH connection working"
else
    echo -e "${RED}[ERROR]${NC} Cannot connect to EC2 instance"
    exit 1
fi

echo ""

# Wait for docker-compose.yml
echo -e "${BLUE}[INFO]${NC} Waiting for docker-compose.yml..."
if timeout 600 bash -c "until ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@${EC2_DNS} 'test -f /opt/confluent/docker-compose.yml' 2>/dev/null; do sleep 10; done" 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${NC} docker-compose.yml is ready"
else
    echo -e "${RED}[ERROR]${NC} Timeout waiting for docker-compose.yml"
    exit 1
fi

echo ""

# Check current advertised listener
echo -e "${BLUE}[INFO]${NC} Checking current advertised listener..."
CURRENT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${EC2_DNS} "grep 'KAFKA_ADVERTISED_LISTENERS' /opt/confluent/docker-compose.yml | grep SASL_PLAINTEXT" 2>/dev/null || echo "")

if [[ "$CURRENT" == *"$NLB_DNS"* ]]; then
    echo -e "${GREEN}[SUCCESS]${NC} Already configured with NLB DNS"
    echo "$CURRENT"
    exit 0
fi

echo "Current: $CURRENT"
echo ""

# Update advertised listener
echo -e "${BLUE}[INFO]${NC} Updating advertised listener to: $NLB_DNS:9094"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${EC2_DNS} << EOF
    echo "Updating docker-compose.yml..."
    sudo sed -i 's/NLB_DNS_PLACEHOLDER/${NLB_DNS}/g' /opt/confluent/docker-compose.yml

    echo "Verifying update..."
    grep 'KAFKA_ADVERTISED_LISTENERS' /opt/confluent/docker-compose.yml | grep SASL_PLAINTEXT

    echo "Restarting Kafka broker..."
    cd /opt/confluent
    sudo docker-compose restart broker

    echo "Waiting for Kafka to be ready..."
    sleep 30

    echo "Checking Kafka logs..."
    docker logs broker 2>&1 | grep -i "advertised.listeners" | tail -3 || true
EOF

echo ""
echo -e "${GREEN}=========================================="
echo "Update Complete!"
echo -e "==========================================${NC}"
echo ""
echo "Kafka should now advertise: $NLB_DNS:9094"
echo ""
echo "Test connection:"
echo "  python3 test_nlb_connection.py"
