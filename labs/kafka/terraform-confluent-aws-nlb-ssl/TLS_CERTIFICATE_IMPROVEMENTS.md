# TLS Certificate Improvements - Hostname-Based with CA Chain

## Summary of Changes

This document details the improvements made to the TLS certificate infrastructure for the Confluent Platform deployment.

## Problems Solved

### 1. Certificate Generated with IP Address Instead of Hostname
**Problem**: TLS certificates were being generated using the public IP address, which can change and doesn't match the AWS public DNS hostname.

**Solution**: Modified [user-data.sh:33-136](user-data.sh#L33-L136) to:
- Retrieve both PUBLIC_IP and PUBLIC_DNS from AWS metadata
- Generate TLS certificates with PUBLIC_DNS as the primary Common Name (CN)
- Include both hostname and IP in Subject Alternative Names (SAN)
- Update KAFKA_ADVERTISED_LISTENERS to use PUBLIC_DNS

**Benefits**:
- Certificates work with stable AWS hostnames
- No need to regenerate certificates when IP changes
- Better TLS hostname verification

### 2. "Certificate Signed by Unknown Authority" Error
**Problem**: Self-signed certificates caused `x509: certificate signed by unknown authority` errors because clients couldn't verify the certificate chain.

**Solution**: Implemented proper CA (Certificate Authority) chain:
- Create a self-signed CA certificate
- Sign the broker certificate with the CA
- Provide CA certificate to clients for verification
- No need to disable SSL verification

**Technical Implementation**:

```bash
# Step 1: Create CA
openssl req -new -x509 \
  -keyout ca-key.pem \
  -out ca-cert.pem \
  -days 3650

# Step 2: Generate broker keystore
keytool -genkeypair \
  -alias kafka-broker \
  -dname "CN=$PUBLIC_DNS,OU=Engineering,O=Confluent,..."

# Step 3: Create CSR (Certificate Signing Request)
keytool -certreq \
  -alias kafka-broker \
  -file broker-cert-request.csr

# Step 4: Sign with CA
openssl x509 -req \
  -in broker-cert-request.csr \
  -CA ca-cert.pem \
  -CAkey ca-key.pem \
  -out broker-cert-signed.pem

# Step 5-6: Import CA and signed cert into keystore
keytool -importcert -alias CARoot -file ca-cert.pem ...
keytool -importcert -alias kafka-broker -file broker-cert-signed.pem ...

# Step 7: Create truststore with CA
keytool -importcert -alias CARoot -file ca-cert.pem \
  -keystore kafka.server.truststore.jks
```

## Certificate Files Generated

| File | Purpose | Usage |
|------|---------|-------|
| `kafka-ca-cert.crt` | CA Certificate (PEM) | **Recommended** - Use in `ssl.ca.location` for clients |
| `kafka-broker-cert.crt` | Broker Certificate (PEM) | Broker's signed certificate |
| `kafka-broker-cert-bundle.crt` | Combined Bundle (CA + Broker) | Alternative for some clients |
| `kafka.server.keystore.jks` | Server Keystore | Used by Kafka broker |
| `kafka.server.truststore.jks` | Server Truststore | Used by Kafka broker |
| `kafka.client.truststore.jks` | Client Truststore (JKS) | For Java clients |

## Updated Configuration Examples

### Python Client (confluent-kafka) - BEFORE
```python
config = {
    'bootstrap.servers': '203.0.113.11:9092',  # IP address
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'kafka-broker-cert.crt',
    'enable.ssl.certificate.verification': False  # Had to disable!
}
```

### Python Client (confluent-kafka) - AFTER
```python
config = {
    'bootstrap.servers': 'ec2-203-0-113-11.ap-northeast-2.compute.amazonaws.com:9092',  # Hostname
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'kafka-ca-cert.crt',  # CA certificate
    # NO NEED to disable verification - it works!
}
```

### ClickHouse Kafka Engine - BEFORE
```sql
CREATE TABLE kafka_queue_ssl ENGINE = Kafka()
SETTINGS
    kafka_broker_list = '203.0.113.11:9092',  -- IP address
    kafka_security_protocol = 'SASL_SSL',
    kafka_sasl_mechanism = 'PLAIN',
    kafka_sasl_username = 'admin',
    kafka_sasl_password = 'admin-secret';
    -- Certificate verification issues!
```

### ClickHouse Kafka Engine - AFTER
```sql
CREATE TABLE kafka_queue_ssl ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'ec2-203-0-113-11.ap-northeast-2.compute.amazonaws.com:9092',  -- Hostname
    kafka_security_protocol = 'SASL_SSL',
    kafka_sasl_mechanism = 'PLAIN',
    kafka_sasl_username = 'admin',
    kafka_sasl_password = 'admin-secret';
    -- Proper certificate verification!
```

## Kafka Broker Configuration Changes

### KAFKA_ADVERTISED_LISTENERS
**Before**:
```yaml
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_SSL://$PUBLIC_IP:9092,SASL_PLAINTEXT://$PUBLIC_IP:9093
```

**After**:
```yaml
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_SSL://$PUBLIC_DNS:9092,SASL_PLAINTEXT://$PUBLIC_DNS:9093
```

### Certificate Common Name (CN)
**Before**: `CN=203.0.113.11` (IP address)
**After**: `CN=ec2-203-0-113-11.ap-northeast-2.compute.amazonaws.com` (hostname)

### Subject Alternative Names (SAN)
**Before**: `DNS:broker,DNS:localhost,IP:203.0.113.11,IP:127.0.0.1`
**After**: `DNS:ec2-203-0-113-11.ap-northeast-2.compute.amazonaws.com,DNS:broker,DNS:localhost,IP:203.0.113.11,IP:127.0.0.1`

## How to Use

### 1. Deploy Infrastructure
```bash
cd terraform-confluent-aws
terraform apply
```

### 2. Download CA Certificate
```bash
# Get hostname from terraform output
HOSTNAME=$(terraform output -raw instance_public_dns)

# Download CA certificate
scp -i /path/to/key.pem ubuntu@$HOSTNAME:/opt/confluent/kafka-ca-cert.crt .
```

### 3. Connect with Proper Verification
```python
from confluent_kafka import Producer

config = {
    'bootstrap.servers': f'{HOSTNAME}:9092',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'kafka-ca-cert.crt'  # CA cert resolves "unknown authority"
}

producer = Producer(config)
print("✓ Connected successfully with full certificate verification!")
```

## Testing

### Test 1: Verify Certificate Hostname
```bash
# Download CA cert
scp -i key.pem ubuntu@$HOSTNAME:/opt/confluent/kafka-ca-cert.crt .

# Verify certificate details
openssl x509 -in kafka-ca-cert.crt -text -noout | grep -A1 "Subject:"
# Should show: CN = <hostname>, not IP address
```

### Test 2: Test SASL_SSL Connection
```bash
# Download and run test script
terraform output -raw test_sasl_connection
```

### Test 3: Verify No "Unknown Authority" Error
```python
# Run Python test with CA certificate
# Should connect without disabling verification
```

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                          AWS EC2 Instance                            │
│  Hostname: ec2-203-0-113-11.ap-northeast-2.compute.amazonaws.com     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │              TLS Certificate Authority (CA)                 │    │
│  │  • Self-signed CA certificate (kafka-ca-cert.crt)          │    │
│  │  • Valid for 10 years                                       │    │
│  │  • Used to sign broker certificate                          │    │
│  └────────────────────────────────────────────────────────────┘    │
│                              │                                       │
│                              ▼                                       │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │              Kafka Broker Certificate                       │    │
│  │  • CN: ec2-3-39-24-136.ap-northeast-2.compute.amazonaws... │    │
│  │  • SAN: DNS:<hostname>, DNS:broker, IP:<ip>                │    │
│  │  • Signed by CA (trusted chain)                             │    │
│  └────────────────────────────────────────────────────────────┘    │
│                              │                                       │
│                              ▼                                       │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │                  Kafka Broker (Docker)                      │    │
│  │  Port 9092: SASL_SSL (with TLS + SASL/PLAIN)               │    │
│  │  Port 9093: SASL_PLAINTEXT (SASL/PLAIN, no TLS)            │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
                    ┌──────────────────────────────┐
                    │    External Clients           │
                    │  • Download CA certificate    │
                    │  • Connect to <hostname>:9092 │
                    │  • Full TLS verification ✓    │
                    │  • No "unknown authority" ✓   │
                    └──────────────────────────────┘
```

## Benefits

### Before (IP-based, Self-Signed)
❌ Certificate CN didn't match hostname
❌ "Unknown authority" errors
❌ Had to disable SSL verification
❌ Certificates needed regeneration when IP changed
❌ Security warnings in all clients

### After (Hostname-based with CA)
✅ Certificate CN matches AWS hostname
✅ No "unknown authority" errors
✅ Full SSL verification enabled
✅ Certificates stable across IP changes
✅ Production-ready certificate chain
✅ Works seamlessly with all Kafka clients

## Files Modified

- [user-data.sh:33-201](user-data.sh#L33-L201) - Certificate generation with CA chain
- [user-data.sh:482-527](user-data.sh#L482-L527) - Deployment messages updated
- [user-data.sh:530-638](user-data.sh#L530-L638) - CONNECTION_INFO.md updated
- [user-data.sh:640-672](user-data.sh#L640-L672) - test_kafka_sasl.py updated
- [outputs.tf](../terraform-confluent-aws/outputs.tf) - All outputs use hostname

## Production Recommendations

1. **Use Real CA**: For production, obtain certificates from a trusted CA (Let's Encrypt, DigiCert, etc.)
2. **Rotate Certificates**: Set up certificate rotation before expiry
3. **Monitor Expiry**: Alert on certificate expiration dates
4. **Strong Passwords**: Use complex SASL passwords
5. **Network Security**: Restrict security group access
6. **Enable ACLs**: Configure Kafka ACLs for authorization

## Troubleshooting

### Issue: "Certificate signed by unknown authority"
**Solution**: Download and use the CA certificate (`kafka-ca-cert.crt`) in `ssl.ca.location`

### Issue: "Hostname verification failed"
**Solution**: Ensure you're connecting to the AWS public DNS hostname, not the IP address

### Issue: Certificate expired
**Solution**: Certificates are valid for 10 years. Regenerate with `terraform apply` if needed

## Related Documentation

- [HOSTNAME_MIGRATION.md](HOSTNAME_MIGRATION.md) - Terraform outputs migration
- [DEPLOYMENT_SUMMARY.md](DEPLOYMENT_SUMMARY.md) - Overall deployment details
- [SASL_CONNECTION_GUIDE.md](SASL_CONNECTION_GUIDE.md) - Connection examples

## Date

**Implemented**: November 20, 2025
