# Custom Domain Setup with Valid SSL Certificate

This guide explains how to use a **custom domain with a valid CA-signed certificate** instead of self-signed certificates.

## Why You Need a Custom Domain

The NLB DNS (`confluent-server-nlb-xxx.elb.amazonaws.com`) is:
- Owned by AWS
- Cannot be used to obtain a valid CA certificate (you can't prove domain ownership)
- Results in certificate verification errors with self-signed certificates

**Solution**: Use your own domain (e.g., `kafka.yourcompany.com`) with a valid certificate.

## Prerequisites

1. **Own a domain name** (e.g., `yourcompany.com`)
2. **Access to DNS management** for your domain
3. **AWS Route 53** (recommended) or another DNS provider

## Option 1: Using AWS Certificate Manager (ACM) with Route 53

This is the easiest method if you use Route 53 for DNS.

### Step 1: Request a Certificate in ACM

```bash
# Request a certificate for your Kafka subdomain
aws acm request-certificate \
  --domain-name kafka.yourcompany.com \
  --validation-method DNS \
  --region ap-northeast-2
```

### Step 2: Validate Domain Ownership

1. Go to **AWS Certificate Manager Console**
2. Find your certificate request
3. Click "Create records in Route 53" (if using Route 53)
4. Wait for validation to complete (~5-10 minutes)

### Step 3: Create DNS CNAME Record

Point your custom domain to the NLB:

```bash
# Get your NLB DNS
NLB_DNS=$(terraform output -raw nlb_endpoint)

# Create CNAME record in Route 53
aws route53 change-resource-record-sets \
  --hosted-zone-id YOUR_HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "kafka.yourcompany.com",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "'$NLB_DNS'"}]
      }
    }]
  }'
```

### Step 4: Update Terraform Configuration

Modify `main.tf` to use your ACM certificate:

```hcl
# Comment out the existing aws_acm_certificate.nlb_cert resource

# Add data source to reference your ACM certificate
data "aws_acm_certificate" "custom_domain" {
  domain   = "kafka.yourcompany.com"
  statuses = ["ISSUED"]
  region   = var.aws_region
}

# Update the listener to use your certificate
resource "aws_lb_listener" "kafka_ssl" {
  load_balancer_arn = aws_lb.kafka_nlb.arn
  port              = "9094"
  protocol          = "TLS"
  certificate_arn   = data.aws_acm_certificate.custom_domain.arn  # Changed
  alpn_policy       = "None"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kafka.arn
  }
}
```

### Step 5: Update Kafka Advertised Listener

Update your docker-compose.yml to advertise your custom domain:

```yaml
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_PLAINTEXT://kafka.yourcompany.com:9094
```

### Step 6: Apply Changes

```bash
terraform apply
```

### Step 7: Test Connection

Now clients can connect without disabling certificate verification:

```python
from confluent_kafka.admin import AdminClient

config = {
    'bootstrap.servers': 'kafka.yourcompany.com:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    # No ssl.ca.location needed - uses system trust store
    # No certificate verification bypass needed
}

admin = AdminClient(config)
metadata = admin.list_topics(timeout=10)
print(f"✓ Connected! Topics: {len(metadata.topics)}")
```

## Option 2: Using Let's Encrypt with DNS-01 Challenge

If you manage your own DNS (not Route 53), use certbot:

### Step 1: Install Certbot

```bash
# macOS
brew install certbot

# Ubuntu
sudo apt-get install certbot
```

### Step 2: Request Certificate

```bash
# Using DNS-01 challenge (manual)
sudo certbot certonly --manual \
  --preferred-challenges dns \
  -d kafka.yourcompany.com
```

Follow the instructions to add TXT records to your DNS.

### Step 3: Upload Certificate to ACM

```bash
# Upload to ACM
aws acm import-certificate \
  --certificate fileb:///etc/letsencrypt/live/kafka.yourcompany.com/cert.pem \
  --private-key fileb:///etc/letsencrypt/live/kafka.yourcompany.com/privkey.pem \
  --certificate-chain fileb:///etc/letsencrypt/live/kafka.yourcompany.com/chain.pem \
  --region ap-northeast-2
```

### Step 4: Follow Steps 3-7 from Option 1

## Option 3: Using Your Organization's Certificate

If you have an existing certificate from your organization:

### Step 1: Prepare Certificate Files

You need:
- `certificate.pem` - Your domain certificate
- `private-key.pem` - Private key
- `ca-bundle.pem` - Certificate chain (intermediate + root CA)

### Step 2: Import to ACM

```bash
aws acm import-certificate \
  --certificate fileb://certificate.pem \
  --private-key fileb://private-key.pem \
  --certificate-chain fileb://ca-bundle.pem \
  --region ap-northeast-2
```

### Step 3: Follow Steps 3-7 from Option 1

## Automated Terraform Configuration

Create a new variables file for custom domain:

```hcl
# variables.tf additions
variable "use_custom_domain" {
  description = "Use custom domain instead of NLB DNS"
  type        = bool
  default     = false
}

variable "custom_domain" {
  description = "Custom domain for Kafka (e.g., kafka.yourcompany.com)"
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ARN of ACM certificate for custom domain"
  type        = string
  default     = ""
}
```

```hcl
# main.tf modifications
locals {
  kafka_endpoint = var.use_custom_domain ? var.custom_domain : aws_lb.kafka_nlb.dns_name
  certificate_arn = var.use_custom_domain ? var.acm_certificate_arn : aws_acm_certificate.nlb_cert[0].arn
}

resource "aws_acm_certificate" "nlb_cert" {
  count = var.use_custom_domain ? 0 : 1  # Only create if not using custom domain
  # ... existing configuration
}

resource "aws_lb_listener" "kafka_ssl" {
  load_balancer_arn = aws_lb.kafka_nlb.arn
  port              = "9094"
  protocol          = "TLS"
  certificate_arn   = local.certificate_arn
  # ... rest of configuration
}
```

## Testing Your Setup

### Verify DNS Resolution

```bash
dig kafka.yourcompany.com
# Should return your NLB DNS as CNAME
```

### Verify SSL Certificate

```bash
openssl s_client -connect kafka.yourcompany.com:9094 -showcerts
# Should show your CA-signed certificate
```

### Test with Client

```bash
# kcat/kafkacat
kcat -b kafka.yourcompany.com:9094 \
  -X security.protocol=SASL_SSL \
  -X sasl.mechanism=PLAIN \
  -X sasl.username=admin \
  -X sasl.password=admin-secret \
  -L
```

## Cost Considerations

- **ACM Certificates**: Free for AWS services
- **Route 53 Hosted Zone**: ~$0.50/month
- **Route 53 Queries**: $0.40 per million queries
- **Let's Encrypt**: Free
- **Domain Registration**: Varies by TLD (~$10-15/year)

## Renewal

- **ACM**: Automatically renews certificates
- **Let's Encrypt**: Renew every 90 days (can be automated with certbot)

## Troubleshooting

### Certificate Not Trusted

```bash
# Check certificate chain
openssl s_client -connect kafka.yourcompany.com:9094 -showcerts | openssl x509 -text -noout
```

### DNS Not Resolving

```bash
# Check CNAME record
dig kafka.yourcompany.com CNAME
# Flush DNS cache
sudo dscacheutil -flushcache  # macOS
```

### Certificate ARN Not Found

```bash
# List all certificates in region
aws acm list-certificates --region ap-northeast-2
```

## Benefits of Using Custom Domain

1. ✅ **Valid SSL Certificate**: No certificate verification errors
2. ✅ **No Client Configuration**: Works with default trust stores
3. ✅ **Production Ready**: Meets security best practices
4. ✅ **Branded**: Use your organization's domain
5. ✅ **Portable**: Can move to different infrastructure without changing client configs

## Next Steps

After setting up your custom domain:

1. Update all client applications to use `kafka.yourcompany.com:9094`
2. Remove `enable.ssl.certificate.verification=False` from all configs
3. Remove `ssl.ca.location` (uses system trust store)
4. Document the new endpoint for your team
