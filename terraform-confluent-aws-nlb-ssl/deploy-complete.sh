#!/bin/bash
set -e

echo "=========================================="
echo "Complete NLB SSL Deployment with Advertised Listener Fix"
echo "=========================================="
echo ""

# Check if SSH key is provided
if [ -z "$SSH_KEY" ]; then
    echo "⚠️  SSH_KEY environment variable not set"
    echo ""
    echo "You have two options:"
    echo ""
    echo "Option 1: Provide SSH key for automatic configuration"
    echo "  SSH_KEY=~/.ssh/your-key.pem $0"
    echo ""
    echo "Option 2: Continue without SSH key (manual configuration required)"
    read -p "Continue without SSH key? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    MANUAL_MODE=true
else
    MANUAL_MODE=false
    echo "✓ SSH key configured: $SSH_KEY"
    echo ""
fi

# Check if initial cert exists
if [ ! -f "certs/nlb-certificate.pem" ]; then
    echo "Step 1: Generating initial certificate..."
    cd certs
    ./generate-nlb-cert.sh
    cd ..
    echo ""
fi

# Initial deployment
echo "Step 2: Initial deployment (creating infrastructure)..."
terraform init
terraform apply -auto-approve

echo ""
echo "✓ Infrastructure created!"
echo ""

# Get NLB DNS
NLB_DNS=$(terraform output -raw nlb_endpoint)
EC2_DNS=$(terraform output -raw instance_public_dns)
echo "NLB DNS: ${NLB_DNS}"
echo "EC2 DNS: ${EC2_DNS}"
echo ""

# Wait for certificate generation
echo "Step 3: Waiting for certificate generation..."
sleep 5

# Check if certificate was updated
if grep -q "${NLB_DNS}" certs/nlb-certificate.pem 2>/dev/null; then
    echo "✓ Certificate already updated with NLB DNS"
else
    echo "⚠ Certificate needs manual update"
    echo "Run: terraform apply -replace='aws_acm_certificate.nlb_cert'"
fi

echo ""
echo "Step 4: Updating ACM certificate..."
terraform apply -replace='aws_acm_certificate.nlb_cert' -auto-approve

echo ""
echo "Step 5: Updating Kafka advertised listener..."
if [ "$MANUAL_MODE" = true ]; then
    echo ""
    echo "⚠️  Manual configuration required!"
    echo ""
    echo "SSH to your instance and run these commands:"
    echo ""
    echo "  ssh -i your-key.pem ubuntu@${EC2_DNS}"
    echo ""
    echo "  # Wait for docker-compose to be ready"
    echo "  while [ ! -f /opt/confluent/docker-compose.yml ]; do sleep 5; done"
    echo ""
    echo "  # Update advertised listener"
    echo "  sudo sed -i 's/NLB_DNS_PLACEHOLDER/${NLB_DNS}/g' /opt/confluent/docker-compose.yml"
    echo ""
    echo "  # Restart Kafka"
    echo "  cd /opt/confluent"
    echo "  sudo docker-compose restart broker"
    echo ""
    echo "  # Wait for Kafka to be ready"
    echo "  sleep 30"
    echo ""
    echo "  # Verify"
    echo "  docker logs broker | grep advertised.listeners"
    echo ""
else
    echo "Waiting for instance to be SSH-ready..."
    timeout 300 bash -c "until nc -z ${EC2_DNS} 22 2>/dev/null; do echo -n '.'; sleep 5; done" && echo " ✓"

    echo ""
    echo "Waiting for docker-compose.yml to be created..."
    timeout 600 bash -c "until ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${EC2_DNS} 'test -f /opt/confluent/docker-compose.yml' 2>/dev/null; do echo -n '.'; sleep 10; done" && echo " ✓"

    echo ""
    echo "Updating advertised listener with NLB DNS..."
    ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ubuntu@${EC2_DNS} << EOF
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

    echo ""
    echo "✓ Advertised listener updated!"
fi

echo ""
echo "=========================================="
echo "✓ Deployment Complete!"
echo "=========================================="
echo ""

# Show connection info
terraform output connection_info

echo ""
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
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
    echo "⚠️  IMPORTANT: Don't forget to complete the manual configuration steps above!"
    echo ""
fi
