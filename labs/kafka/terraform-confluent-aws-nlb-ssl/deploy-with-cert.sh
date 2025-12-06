#!/bin/bash
set -e

echo "=========================================="
echo "Confluent Platform NLB SSL Deployment"
echo "=========================================="
echo ""

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
echo "NLB DNS: ${NLB_DNS}"
echo ""

# Wait a bit for certificate generation
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
echo "=========================================="
echo "✓ Deployment Complete!"
echo "=========================================="
echo ""

# Show connection info
terraform output connection_info

echo ""
echo "Certificate details:"
openssl x509 -in certs/nlb-certificate.pem -text -noout | grep -A1 "Subject Alternative Name"
