#!/bin/bash
set -e

echo "Generating initial self-signed certificate for NLB..."
echo "Note: This will be replaced with correct NLB DNS during terraform apply"

# Generate private key
openssl genrsa -out nlb-private-key.pem 2048

# Generate initial certificate with short CN and placeholder SAN
openssl req -new -x509 \
  -key nlb-private-key.pem \
  -out nlb-certificate.pem \
  -days 365 \
  -subj "/C=US/ST=State/L=City/O=Confluent/CN=kafka-nlb" \
  -addext "subjectAltName=DNS:kafka-nlb.placeholder.local"

echo ""
echo "Initial certificate generated successfully!"
echo "  Private Key: nlb-private-key.pem"
echo "  Certificate: nlb-certificate.pem"
echo "  CN: kafka-nlb"
echo "  SAN: kafka-nlb.placeholder.local"
echo ""
echo "This certificate will be automatically replaced with the correct"
echo "NLB DNS name during 'terraform apply'."
