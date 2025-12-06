# Certificate Validation Fix for NLB

## Problem

When connecting to Kafka via NLB, you may encounter:

```
tls: failed to verify certificate: x509: certificate is not valid for any names,
but wanted to match confluent-server-nlb-31fb841812c887f0.elb.ap-northeast-2.amazonaws.com
```

This happens because the certificate CN doesn't match the NLB DNS name.

## Root Cause

- **Certificate CN**: `kafka-nlb.example.com` (fixed before deployment)
- **Actual NLB DNS**: `<instance-name>-nlb-<random>.elb.<region>.amazonaws.com` (unknown until after deployment)

## Solutions

### Solution 1: Recreate Certificate with NLB DNS (Recommended)

After first deployment, regenerate the certificate with the actual NLB DNS:

```bash
# 1. Get NLB DNS name
terraform output -raw nlb_endpoint

# 2. Regenerate certificate with correct DNS
./generate-nlb-cert.sh confluent-server-nlb-abc123.elb.ap-northeast-2.amazonaws.com

# 3. Update ACM certificate in AWS
terraform apply -replace='aws_acm_certificate.nlb_cert'

# 4. Distribute new certificate to clients
cp certs/nlb-certificate.pem /path/to/clients/
```

### Solution 2: Disable Certificate Verification (Testing Only)

⚠️ **For testing/development only - NOT for production!**

#### Python (confluent-kafka)

```python
config = {
    'bootstrap.servers': '<NLB_ENDPOINT>:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'your-password',
    # Disable certificate verification
    'enable.ssl.certificate.verification': False,
}
```

#### ClickHouse ClickPipes

In ClickPipes configuration, if available:
- Enable "Skip SSL Verification" option
- Or use `verify_ssl=false` in connection string

#### Java

```java
Properties props = new Properties();
props.put("bootstrap.servers", "<NLB_ENDPOINT>:9094");
props.put("security.protocol", "SASL_SSL");
props.put("sasl.mechanism", "PLAIN");
props.put("sasl.jaas.config", "...");
// Disable certificate verification (testing only)
props.put("ssl.endpoint.identification.algorithm", "");
```

### Solution 3: Use Direct EC2 Connection (No SSL)

If SSL is not required, connect directly to EC2 without NLB:

```python
config = {
    'bootstrap.servers': '<EC2_DNS>:9092',
    'security.protocol': 'SASL_PLAINTEXT',  # No SSL
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'your-password',
}
```

### Solution 4: Use Custom Domain with Route53 (Production)

For production use:

1. **Create Route53 CNAME**:
   ```
   kafka.yourdomain.com -> confluent-server-nlb-abc123.elb.ap-northeast-2.amazonaws.com
   ```

2. **Generate certificate for your domain**:
   ```bash
   ./generate-nlb-cert.sh kafka.yourdomain.com
   ```

3. **Clients connect to**:
   ```python
   'bootstrap.servers': 'kafka.yourdomain.com:9094'
   ```

## Recommended Workflow

### For Testing/Development:
1. Deploy with default certificate
2. Use **Solution 2** (disable verification) or **Solution 3** (direct connection)

### For Production:
1. Set up custom domain with Route53 (**Solution 4**)
2. Generate certificate for your domain
3. Deploy infrastructure
4. Clients use custom domain with proper certificate validation

## Automation Option

Add to terraform to automatically recreate certificate after NLB creation:

```hcl
# Note: This requires a two-step deployment
# Step 1: Create NLB without certificate
# Step 2: Recreate certificate with NLB DNS and update

resource "null_resource" "regenerate_cert" {
  depends_on = [aws_lb.kafka_nlb]

  triggers = {
    nlb_dns = aws_lb.kafka_nlb.dns_name
  }

  provisioner "local-exec" {
    command = "./generate-nlb-cert.sh ${aws_lb.kafka_nlb.dns_name}"
  }
}
```

## Verification

After updating the certificate, verify it matches:

```bash
# Check certificate CN/SAN
openssl x509 -in certs/nlb-certificate.pem -text -noout | grep -A1 "Subject:"
openssl x509 -in certs/nlb-certificate.pem -text -noout | grep -A1 "Subject Alternative Name"

# Test connection
openssl s_client -connect <NLB_ENDPOINT>:9094 -CAfile certs/nlb-certificate.pem
```
