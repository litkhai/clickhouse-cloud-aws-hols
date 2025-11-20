#!/bin/bash
set -e

# Check if NLB DNS is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <NLB_DNS_NAME>"
    echo ""
    echo "Example:"
    echo "  $0 confluent-server-nlb-abc123.elb.ap-northeast-2.amazonaws.com"
    echo ""
    echo "You can get the NLB DNS after terraform apply:"
    echo "  terraform output -raw nlb_endpoint"
    exit 1
fi

NLB_DNS="$1"

echo "Generating self-signed certificate for NLB..."
echo "  NLB DNS: $NLB_DNS"

cd certs

# Generate private key
openssl genrsa -out nlb-private-key.pem 2048

# Generate self-signed certificate with proper CN and SAN
openssl req -new -x509 \
  -key nlb-private-key.pem \
  -out nlb-certificate.pem \
  -days 365 \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=${NLB_DNS}" \
  -addext "subjectAltName=DNS:${NLB_DNS}"

echo ""
echo "Certificate generated successfully!"
echo "  Private Key: certs/nlb-private-key.pem"
echo "  Certificate: certs/nlb-certificate.pem"
echo "  Valid for: ${NLB_DNS}"
echo ""
echo "Next steps:"
echo "  1. Update ACM certificate:"
echo "     terraform apply -replace='aws_acm_certificate.nlb_cert'"
echo "  2. Download certificate for clients:"
echo "     cp certs/nlb-certificate.pem /path/to/your/client/"
