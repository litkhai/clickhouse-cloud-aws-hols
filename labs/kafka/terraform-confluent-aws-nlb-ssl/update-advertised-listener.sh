#!/bin/bash
set -e

echo "==========================================="
echo "Update Kafka Advertised Listener with NLB DNS"
echo "==========================================="
echo ""

# Get NLB DNS from terraform
if ! NLB_DNS=$(terraform output -raw nlb_endpoint 2>/dev/null); then
    echo "❌ Error: Could not get NLB endpoint from terraform"
    echo "Make sure you've run 'terraform apply' first"
    exit 1
fi

# Get EC2 DNS from terraform
if ! EC2_DNS=$(terraform output -raw instance_public_dns 2>/dev/null); then
    echo "❌ Error: Could not get EC2 DNS from terraform"
    exit 1
fi

echo "Configuration:"
echo "  NLB DNS: ${NLB_DNS}"
echo "  EC2 DNS: ${EC2_DNS}"
echo ""

# Check if SSH key is configured
if [ -z "${SSH_KEY}" ]; then
    echo "⚠ SSH_KEY environment variable not set"
    echo "Usage: SSH_KEY=/path/to/key.pem $0"
    echo ""
    echo "Manual steps:"
    echo "1. SSH to instance:"
    echo "   ssh -i your-key.pem ubuntu@${EC2_DNS}"
    echo ""
    echo "2. Update advertised listener:"
    echo "   sudo sed -i 's/NLB_DNS_PLACEHOLDER/${NLB_DNS}/g' /opt/confluent/docker-compose.yml"
    echo ""
    echo "3. Restart Kafka:"
    echo "   cd /opt/confluent && sudo docker-compose restart broker"
    echo ""
    echo "4. Wait and verify:"
    echo "   sleep 30"
    echo "   docker logs broker | grep 'advertised.listeners'"
    exit 0
fi

echo "Step 1: Waiting for instance to be ready..."
timeout 300 bash -c "until nc -z ${EC2_DNS} 22 2>/dev/null; do echo -n '.'; sleep 5; done" || {
    echo ""
    echo "❌ Timeout waiting for SSH access"
    exit 1
}
echo " ✓"

echo ""
echo "Step 2: Waiting for docker-compose.yml..."
timeout 600 bash -c "until ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${EC2_DNS} 'test -f /opt/confluent/docker-compose.yml' 2>/dev/null; do echo -n '.'; sleep 10; done" || {
    echo ""
    echo "❌ Timeout waiting for docker-compose.yml"
    exit 1
}
echo " ✓"

echo ""
echo "Step 3: Checking current advertised listener..."
CURRENT_LISTENER=$(ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ubuntu@${EC2_DNS} \
    "grep 'KAFKA_ADVERTISED_LISTENERS' /opt/confluent/docker-compose.yml | grep -o 'SASL_PLAINTEXT://[^,]*' | tail -1")
echo "  Current: ${CURRENT_LISTENER}"

if [[ "$CURRENT_LISTENER" == *"${NLB_DNS}"* ]]; then
    echo "  ✓ Already configured with NLB DNS"
    exit 0
fi

echo ""
echo "Step 4: Updating advertised listener to ${NLB_DNS}:9094..."
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

    echo ""
    echo "✓ Kafka broker restarted"
EOF

echo ""
echo "Step 5: Verifying broker metadata..."
sleep 5

ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ubuntu@${EC2_DNS} \
    "docker exec broker kafka-broker-api-versions --bootstrap-server localhost:29092 2>&1 | head -5" || true

echo ""
echo "==========================================="
echo "✓ Update Complete!"
echo "==========================================="
echo ""
echo "Kafka should now advertise: ${NLB_DNS}:9094"
echo ""
echo "Test connection:"
echo "  python3 test_nlb_connection.py"
echo ""
echo "Or manually:"
echo "  bootstrap.servers: ${NLB_DNS}:9094"
echo "  security.protocol: SASL_SSL"
echo "  ssl.ca.location: certs/nlb-certificate.pem"
