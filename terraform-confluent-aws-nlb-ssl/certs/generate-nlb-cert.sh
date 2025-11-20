#!/bin/bash
set -e

# Check if NLB_DNS is provided
if [ -z "$NLB_DNS" ]; then
    echo "Generating initial placeholder certificate..."
    echo "Note: This will be replaced with correct NLB DNS during terraform apply"
    SAN_DNS="kafka-nlb.placeholder.local"
else
    echo "Generating certificate with NLB DNS: $NLB_DNS"
    SAN_DNS="$NLB_DNS"
fi

# Generate private key if it doesn't exist
if [ ! -f "nlb-private-key.pem" ]; then
    openssl genrsa -out nlb-private-key.pem 2048
fi

# Generate certificate with proper CA extensions
openssl req -new -x509 \
  -key nlb-private-key.pem \
  -out nlb-certificate.pem \
  -days 365 \
  -subj "/C=US/ST=State/L=City/O=Confluent/CN=Confluent-CA" \
  -addext "subjectAltName=DNS:${SAN_DNS}" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign"

echo ""
echo "Certificate generated successfully!"
echo "  Private Key: nlb-private-key.pem"
echo "  Certificate: nlb-certificate.pem"
echo "  CN: Confluent-CA"
echo "  SAN: ${SAN_DNS}"
echo ""

if [ -z "$NLB_DNS" ]; then
    echo "This is a placeholder certificate."
    echo "It will be automatically replaced with the correct NLB DNS during 'terraform apply'."
fi
