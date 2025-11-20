# Automated Certificate Generation

## Overview

This Terraform configuration **automatically generates** SSL certificates with the correct NLB DNS name during deployment. No manual certificate generation is required!

## How It Works

### Deployment Flow

```
1. terraform apply
   ↓
2. Create NLB
   ↓ (get DNS: confluent-server-nlb-abc123.elb.region.amazonaws.com)
3. Generate certificate with NLB DNS
   ↓
4. Import certificate to ACM
   ↓
5. Configure NLB listener with certificate
   ↓
6. ✅ Certificate CN matches NLB DNS perfectly!
```

### Technical Implementation

The automation uses three Terraform resources:

1. **aws_lb.kafka_nlb** - Creates NLB first to get DNS name
2. **null_resource.generate_nlb_cert** - Generates certificate with actual NLB DNS
3. **aws_acm_certificate.nlb_cert** - Imports certificate to ACM

```hcl
# 1. Create NLB
resource "aws_lb" "kafka_nlb" {
  name = "${var.instance_name}-nlb"
  # ... configuration
}

# 2. Auto-generate certificate with NLB DNS
resource "null_resource" "generate_nlb_cert" {
  depends_on = [aws_lb.kafka_nlb]

  provisioner "local-exec" {
    command = <<-EOT
      openssl req -new -x509 \
        -subj "/CN=${aws_lb.kafka_nlb.dns_name}" \
        -addext "subjectAltName=DNS:${aws_lb.kafka_nlb.dns_name}"
    EOT
  }
}

# 3. Import to ACM
resource "aws_acm_certificate" "nlb_cert" {
  depends_on = [null_resource.generate_nlb_cert]
  private_key      = file("certs/nlb-private-key.pem")
  certificate_body = file("certs/nlb-certificate.pem")
}
```

## Usage

### Simple Deployment (All Automatic)

```bash
# 1. Configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars

# 2. Deploy everything
terraform init
terraform apply
```

That's it! The certificate is automatically generated with the correct NLB DNS.

### What Gets Generated

After `terraform apply`, you'll have:

```
certs/
├── nlb-private-key.pem     # Auto-generated private key
└── nlb-certificate.pem     # Auto-generated certificate with NLB DNS
```

The certificate will have:
- **CN (Common Name)**: `confluent-server-nlb-abc123.elb.ap-northeast-2.amazonaws.com`
- **SAN (Subject Alternative Name)**: Same as CN
- **Valid**: Matches actual NLB DNS perfectly

## Verification

### Check Generated Certificate

```bash
# View certificate details
openssl x509 -in certs/nlb-certificate.pem -text -noout | grep -A1 "Subject:"
openssl x509 -in certs/nlb-certificate.pem -text -noout | grep -A1 "Subject Alternative Name"

# Should show your actual NLB DNS:
# Subject: CN = confluent-server-nlb-abc123.elb.ap-northeast-2.amazonaws.com
# X509v3 Subject Alternative Name:
#     DNS:confluent-server-nlb-abc123.elb.ap-northeast-2.amazonaws.com
```

### Test SSL Connection

```bash
# Get NLB endpoint
NLB_DNS=$(terraform output -raw nlb_endpoint)

# Test TLS connection
openssl s_client -connect ${NLB_DNS}:9094 -CAfile certs/nlb-certificate.pem
# Should show: "Verify return code: 0 (ok)"
```

### Test Kafka Connection

```python
from confluent_kafka import Producer
from confluent_kafka.admin import AdminClient

config = {
    'bootstrap.servers': '<NLB_ENDPOINT>:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'your-password',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
}

# Should connect without certificate errors
admin = AdminClient(config)
topics = admin.list_topics(timeout=10)
print(f"✅ Connected! Found {len(topics.topics)} topics")
```

## Updating Infrastructure

### Change Instance Name

If you change `instance_name` in `terraform.tfvars`, the NLB DNS changes, and the certificate is automatically regenerated:

```bash
# Edit terraform.tfvars
instance_name = "new-name"

# Apply changes
terraform apply
# Certificate is automatically regenerated with new NLB DNS!
```

### Force Certificate Regeneration

To force regenerate the certificate:

```bash
terraform apply -replace='null_resource.generate_nlb_cert'
```

## Advantages

### ✅ Automatic
- No manual certificate generation
- No NLB DNS lookup required
- Works on first deployment

### ✅ Correct
- Certificate CN always matches NLB DNS
- No "certificate is not valid for any names" errors
- Proper SAN (Subject Alternative Name)

### ✅ Consistent
- Certificate regenerated when NLB changes
- Always up-to-date with infrastructure
- No stale certificates

### ✅ Simple
- One command: `terraform apply`
- No additional scripts to run
- No manual steps

## Troubleshooting

### Certificate Not Generated

If certificate generation fails:

```bash
# Check Terraform output
terraform apply

# Manually generate if needed
cd certs
rm -f nlb-*.pem
NLB_DNS=$(terraform output -raw nlb_endpoint)
openssl genrsa -out nlb-private-key.pem 2048
openssl req -new -x509 \
  -key nlb-private-key.pem \
  -out nlb-certificate.pem \
  -days 365 \
  -subj "/CN=${NLB_DNS}" \
  -addext "subjectAltName=DNS:${NLB_DNS}"

# Update ACM
cd ..
terraform apply -replace='aws_acm_certificate.nlb_cert'
```

### Certificate Mismatch After Changes

If you made changes and certificate doesn't match:

```bash
# Regenerate certificate
terraform apply -replace='null_resource.generate_nlb_cert'
terraform apply -replace='aws_acm_certificate.nlb_cert'
```

## Comparison: Before vs After

### ❌ Before (Manual)

```bash
# 1. Generate dummy certificate
cd certs
./generate-nlb-cert.sh  # Creates cert with "kafka-nlb.example.com"

# 2. Deploy
terraform apply

# 3. Get NLB DNS
NLB_DNS=$(terraform output -raw nlb_endpoint)
# Result: confluent-server-nlb-abc123.elb.region.amazonaws.com

# 4. Realize certificate is wrong! ❌
# Certificate CN: kafka-nlb.example.com
# Actual NLB DNS: confluent-server-nlb-abc123.elb.region.amazonaws.com

# 5. Regenerate certificate manually
./generate-nlb-cert.sh ${NLB_DNS}

# 6. Update ACM
terraform apply -replace='aws_acm_certificate.nlb_cert'

# Result: Works, but requires 6 manual steps
```

### ✅ After (Automatic)

```bash
# 1. Deploy
terraform apply

# Result: Certificate automatically matches NLB DNS! ✅
# Certificate CN: confluent-server-nlb-abc123.elb.region.amazonaws.com
# Actual NLB DNS: confluent-server-nlb-abc123.elb.region.amazonaws.com
```

## For Production

While this automated approach works great for testing, for production you should:

1. **Use Route53 with custom domain**:
   ```
   kafka.yourdomain.com → NLB DNS (CNAME)
   ```

2. **Use CA-signed certificate**:
   - AWS Certificate Manager (ACM) with domain validation
   - Let's Encrypt with certbot
   - Commercial CA

3. **Update certificate CN**:
   ```bash
   CN=kafka.yourdomain.com  # Your custom domain
   ```

But for testing and development, the automated self-signed certificate works perfectly!
