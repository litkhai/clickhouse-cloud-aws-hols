#!/bin/bash
set -e

echo "=========================================="
echo "NLB + Kafka Connection Debug Script"
echo "=========================================="
echo ""

# Get NLB DNS
if ! NLB_DNS=$(terraform output -raw nlb_endpoint 2>/dev/null); then
    echo "❌ Error: Could not get NLB endpoint from terraform"
    echo "Make sure you've run 'terraform apply' first"
    exit 1
fi

# Get EC2 DNS
if ! EC2_DNS=$(terraform output -raw instance_public_dns 2>/dev/null); then
    echo "❌ Error: Could not get EC2 DNS from terraform"
    exit 1
fi

echo "Configuration:"
echo "  NLB DNS: ${NLB_DNS}"
echo "  EC2 DNS: ${EC2_DNS}"
echo ""

# Test 1: NLB DNS Resolution
echo "=========================================="
echo "Test 1: NLB DNS Resolution"
echo "=========================================="
if host "${NLB_DNS}" > /dev/null 2>&1; then
    echo "✓ NLB DNS resolves:"
    host "${NLB_DNS}" | head -5
else
    echo "❌ NLB DNS does not resolve"
fi
echo ""

# Test 2: NLB Port 9094 (SSL) Reachability
echo "=========================================="
echo "Test 2: NLB Port 9094 (SSL) Reachability"
echo "=========================================="
echo "Testing TCP connection to ${NLB_DNS}:9094..."
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${NLB_DNS}/9094" 2>/dev/null; then
    echo "✓ Port 9094 is reachable"
else
    echo "❌ Port 9094 is NOT reachable (Connection timeout)"
    echo ""
    echo "Possible causes:"
    echo "  1. NLB listener not configured correctly"
    echo "  2. Security group blocking traffic"
    echo "  3. Target group unhealthy"
fi
echo ""

# Test 3: EC2 Port 9092 (Direct) Reachability
echo "=========================================="
echo "Test 3: EC2 Port 9092 (Direct) Reachability"
echo "=========================================="
echo "Testing TCP connection to ${EC2_DNS}:9092..."
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${EC2_DNS}/9092" 2>/dev/null; then
    echo "✓ Port 9092 is reachable (Kafka is listening)"
else
    echo "❌ Port 9092 is NOT reachable"
    echo ""
    echo "Possible causes:"
    echo "  1. Kafka not started"
    echo "  2. Security group blocking traffic"
fi
echo ""

# Test 4: NLB Target Health
echo "=========================================="
echo "Test 4: NLB Target Health Check"
echo "=========================================="

# Get target group ARN
TG_ARN=$(aws elbv2 describe-target-groups \
    --names "confluent-server-kafka-tg" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || echo "")

if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    echo "Target Group: $TG_ARN"
    echo ""
    echo "Target Health:"
    aws elbv2 describe-target-health \
        --target-group-arn "$TG_ARN" \
        --output table

    HEALTH_STATE=$(aws elbv2 describe-target-health \
        --target-group-arn "$TG_ARN" \
        --query 'TargetHealthDescriptions[0].TargetHealth.State' \
        --output text)

    if [ "$HEALTH_STATE" = "healthy" ]; then
        echo "✓ Target is healthy"
    else
        echo "❌ Target is NOT healthy: $HEALTH_STATE"
        echo ""
        echo "Health check details:"
        aws elbv2 describe-target-health \
            --target-group-arn "$TG_ARN" \
            --query 'TargetHealthDescriptions[0].TargetHealth' \
            --output table
    fi
else
    echo "⚠ Could not find target group"
    echo "Make sure the target group name matches your instance_name"
fi
echo ""

# Test 5: NLB Listener Configuration
echo "=========================================="
echo "Test 5: NLB Listener Configuration"
echo "=========================================="

# Get NLB ARN
NLB_ARN=$(aws elbv2 describe-load-balancers \
    --names "confluent-server-nlb" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || echo "")

if [ -n "$NLB_ARN" ] && [ "$NLB_ARN" != "None" ]; then
    echo "NLB: $NLB_ARN"
    echo ""
    echo "Listeners:"
    aws elbv2 describe-listeners \
        --load-balancer-arn "$NLB_ARN" \
        --output table
else
    echo "⚠ Could not find NLB"
fi
echo ""

# Test 6: Security Group Rules
echo "=========================================="
echo "Test 6: Security Group Rules"
echo "=========================================="

# Get security group ID
SG_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=confluent-server" \
    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")

if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
    echo "Security Group: $SG_ID"
    echo ""
    echo "Ingress Rules for port 9092:"
    aws ec2 describe-security-groups \
        --group-ids "$SG_ID" \
        --query 'SecurityGroups[0].IpPermissions[?FromPort==`9092`]' \
        --output table
else
    echo "⚠ Could not find security group"
fi
echo ""

# Test 7: SSL Handshake with NLB
echo "=========================================="
echo "Test 7: SSL Handshake with NLB"
echo "=========================================="
echo "Attempting SSL handshake with ${NLB_DNS}:9094..."
echo ""
timeout 10 openssl s_client -connect "${NLB_DNS}:9094" -showcerts < /dev/null 2>&1 | head -30
echo ""

# Test 8: Certificate Verification
echo "=========================================="
echo "Test 8: Certificate Verification"
echo "=========================================="
echo "Checking if certificate matches NLB DNS..."
echo ""

if [ -f "certs/nlb-certificate.pem" ]; then
    echo "Certificate SAN:"
    openssl x509 -in certs/nlb-certificate.pem -text -noout | grep -A1 "Subject Alternative Name"
    echo ""

    CERT_DNS=$(openssl x509 -in certs/nlb-certificate.pem -text -noout | grep "DNS:" | sed 's/.*DNS://g' | tr -d ' ')

    if [ "$CERT_DNS" = "$NLB_DNS" ]; then
        echo "✓ Certificate DNS matches NLB DNS"
    else
        echo "❌ Certificate DNS does NOT match"
        echo "   Certificate: $CERT_DNS"
        echo "   NLB DNS:     $NLB_DNS"
        echo ""
        echo "To fix: terraform apply -replace='aws_acm_certificate.nlb_cert'"
    fi
else
    echo "❌ Certificate file not found"
fi
echo ""

# Summary
echo "=========================================="
echo "Summary & Recommendations"
echo "=========================================="
echo ""

# Check if we can connect to EC2 directly
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${EC2_DNS}/9092" 2>/dev/null; then
    echo "✓ Direct EC2 connection works"
    echo "  Use: ${EC2_DNS}:9092 (SASL_PLAINTEXT, no SSL)"
    echo ""
fi

# Check NLB reachability
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${NLB_DNS}/9094" 2>/dev/null; then
    echo "✓ NLB connection works"
    echo "  Use: ${NLB_DNS}:9094 (SASL_SSL via NLB)"
else
    echo "❌ NLB connection FAILED"
    echo ""
    echo "Debug steps:"
    echo "  1. Check target health: aws elbv2 describe-target-health --target-group-arn <ARN>"
    echo "  2. Check security group allows port 9092 from NLB subnets"
    echo "  3. Verify Kafka is running: ssh ... 'docker ps | grep broker'"
    echo "  4. Check Kafka logs: ssh ... 'docker logs broker'"
fi

echo ""
echo "=========================================="
echo "Done!"
echo "=========================================="
