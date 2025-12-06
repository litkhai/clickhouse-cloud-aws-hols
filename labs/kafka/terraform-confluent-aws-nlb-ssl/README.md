# Confluent Platform with NLB SSL Termination

## ✅ **SOLUTION: Advertised Listener Fix**

This Terraform configuration demonstrates **NLB SSL termination with Kafka** using the **advertised listener pattern**.

**TL;DR**: By configuring Kafka to advertise the NLB DNS instead of EC2 DNS, clients maintain protocol consistency throughout their connection lifecycle.

See [NLB_ADVERTISED_LISTENER_FIX.md](NLB_ADVERTISED_LISTENER_FIX.md) for detailed explanation of the solution.

## Architecture (Working Solution)

```
External Client (SASL_SSL)
        ↓
    NLB:9094 (SSL/TLS Termination)  ← Initial connection with SSL
        ↓
    Kafka Broker:9092 (SASL_PLAINTEXT - No TLS)
        ↓
    Kafka advertises: "I'm at NLB:9094"  ← Key fix!
        ↓
    Client → NLB:9094 (SASL_SSL)  ← ✅ Works! Stays at NLB
```

**Solution**: Kafka advertises NLB:9094 instead of EC2:9092, keeping clients at the NLB where SSL is handled.

### Key Features (What Was Tested)

1. **Kafka Broker**: Configured with SASL_PLAINTEXT (NO TLS encryption)
2. **NLB**: Provides SSL/TLS termination on port 9094
3. **Expected Behavior**: Clients connect to NLB with SSL, NLB forwards to Kafka without encryption
4. **Actual Behavior**: ❌ Clients fail after metadata fetch due to protocol mismatch

### Why This Architecture Was Tested

This setup was meant to test:
- SSL/TLS termination at the load balancer layer
- Reduced CPU load on Kafka brokers (no SSL processing)
- Centralized certificate management at NLB
- Testing scenarios where SSL is handled by network infrastructure

**Result**: ❌ This approach is incompatible with Kafka's advertised listener mechanism

## Prerequisites

1. AWS CLI configured with credentials
2. Terraform >= 1.0
3. An AWS EC2 key pair (optional, for SSH access)
4. Understanding of Kafka and NLB concepts

## Quick Start

### Option A: Automated Deployment (Recommended)

```bash
# 1. Configure variables first
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings

# 2. Run automated deployment script
./deploy-with-cert.sh
```

This script handles everything automatically:
- Generates initial certificate
- Deploys infrastructure
- Updates certificate with NLB DNS
- Updates ACM certificate

### Option B: Manual Step-by-Step

#### 1. Generate Initial Certificate

```bash
cd certs
./generate-nlb-cert.sh
cd ..
```

This creates placeholder certificates that will be replaced with the correct NLB DNS.

#### 2. Configure Variables

Copy and edit the variables file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region           = "us-east-1"
instance_name        = "confluent-nlb-ssl"
instance_type        = "r5.xlarge"
key_pair_name        = "your-key-pair-name"
kafka_sasl_username  = "admin"
kafka_sasl_password  = "your-secure-password"
```

#### 3. Initial Deployment

```bash
terraform init
terraform plan
terraform apply
```

This creates the infrastructure with a placeholder certificate.

#### 4. Update Certificate with NLB DNS

After the initial deployment, update the certificate:

```bash
terraform apply -replace='aws_acm_certificate.nlb_cert'
```

**Automated Process**:
1. First `terraform apply`: Creates NLB, generates correct certificate in background
2. Second `terraform apply -replace`: Updates ACM with the new certificate
3. Certificate now matches NLB DNS perfectly!

#### 5. Get Connection Information

```bash
terraform output connection_info
terraform output nlb_endpoint
```

## Connection Examples

### Python Client (via NLB with SSL)

```python
from confluent_kafka import Producer

config = {
    'bootstrap.servers': '<NLB_ENDPOINT>:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'your-password',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
}

producer = Producer(config)
producer.produce('test-topic', key='key', value='value')
producer.flush()
```

### Python Client (Direct to EC2, No SSL)

```python
from confluent_kafka import Producer

config = {
    'bootstrap.servers': '<EC2_DNS>:9092',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'your-password',
}

producer = Producer(config)
```

### ClickHouse Kafka Engine (via NLB)

```sql
CREATE TABLE kafka_queue_nlb
ENGINE = Kafka()
SETTINGS
    kafka_broker_list = '<NLB_ENDPOINT>:9094',
    kafka_topic_list = 'sample-data-topic',
    kafka_group_name = 'clickhouse_group',
    kafka_format = 'JSONEachRow',
    kafka_sasl_mechanism = 'PLAIN',
    kafka_sasl_username = 'admin',
    kafka_sasl_password = 'your-password',
    kafka_security_protocol = 'SASL_SSL';
```

## Testing

### 1. Test Direct Connection (No SSL)

SSH into the EC2 instance and run the test script:

```bash
ssh -i your-key.pem ubuntu@<EC2_DNS>
python3 /opt/confluent/test_kafka_sasl.py
```

### 2. Test via NLB (with SSL)

From your local machine:

```bash
# Copy the NLB certificate
cp certs/nlb-certificate.pem /path/to/your/test/directory/

# Create a test script
cat > test_nlb.py << 'EOF'
from confluent_kafka import Producer, Consumer
from confluent_kafka.admin import AdminClient

config = {
    'bootstrap.servers': '<NLB_ENDPOINT>:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'your-password',
    'ssl.ca.location': 'nlb-certificate.pem',
}

# Test connection
admin = AdminClient(config)
metadata = admin.list_topics(timeout=10)
print(f"Connected! Found {len(metadata.topics)} topics")
EOF

python3 test_nlb.py
```

## Architecture Details

### Kafka Configuration

- **Port 9092**: SASL_PLAINTEXT listener (no TLS)
- **Port 29092**: Internal PLAINTEXT listener (for Confluent components)
- **SASL Mechanism**: PLAIN
- **Broker Advertised Listener**: Uses EC2 public DNS

### NLB Configuration

- **Port 9094**: TLS listener with SSL termination
- **Protocol**: TLS (TCP with SSL/TLS)
- **Target**: EC2 instance port 9092
- **SSL Policy**: ELBSecurityPolicy-TLS13-1-2-2021-06
- **Certificate**: Self-signed certificate with NLB DNS (auto-generated during deployment)
- **Certificate CN**: Matches actual NLB DNS name (e.g., `confluent-server-nlb-xxx.elb.region.amazonaws.com`)

### Security Group Rules

- **Port 9092**: Kafka SASL_PLAINTEXT (from allowed CIDR blocks)
- **Port 2181**: ZooKeeper (from allowed CIDR blocks)
- **Port 9021**: Control Center (from allowed CIDR blocks)
- **Port 22**: SSH (from allowed CIDR blocks)

## Deployed Services

| Service | Port | URL |
|---------|------|-----|
| Kafka (Direct) | 9092 | `<EC2_DNS>:9092` |
| Kafka (via NLB) | 9094 | `<NLB_ENDPOINT>:9094` |
| Control Center | 9021 | `http://<EC2_DNS>:9021` |
| Schema Registry | 8081 | `http://<EC2_DNS>:8081` |
| Kafka Connect | 8083 | `http://<EC2_DNS>:8083` |
| ksqlDB Server | 8088 | `http://<EC2_DNS>:8088` |
| REST Proxy | 8082 | `http://<EC2_DNS>:8082` |

## Useful Commands

```bash
# Show all outputs
terraform output

# Show connection info
terraform output connection_info

# Show NLB endpoint
terraform output nlb_endpoint

# Show Kafka bootstrap servers
terraform output kafka_bootstrap_servers_nlb

# SSH to instance
ssh -i your-key.pem ubuntu@$(terraform output -raw instance_public_dns)

# Check Kafka status on instance
ssh -i your-key.pem ubuntu@<EC2_DNS> 'sudo /opt/confluent/status.sh'

# View producer logs
ssh -i your-key.pem ubuntu@<EC2_DNS> 'sudo journalctl -u confluent-producer -f'
```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

## Troubleshooting

### NLB Health Check Failing

Check if Kafka is listening on port 9092:

```bash
ssh -i your-key.pem ubuntu@<EC2_DNS>
docker exec broker kafka-broker-api-versions --bootstrap-server localhost:29092
```

### SSL Connection Issues

1. Verify the NLB certificate is correctly copied to client machine
2. Check NLB listener is active: `aws elbv2 describe-listeners --load-balancer-arn <ARN>`
3. Verify target group health: `aws elbv2 describe-target-health --target-group-arn <ARN>`

### Cannot Connect via NLB

1. Check security group allows traffic on port 9092
2. Verify NLB target group has healthy targets
3. Test direct connection to EC2:9092 first
4. Check Kafka logs: `docker logs broker`

## Architecture Limitations & Test Results

### ⚠️ **IMPORTANT: This Architecture Has Fundamental Limitations**

This project was created to **test NLB SSL termination with Kafka**, but testing revealed a **critical architectural flaw** that prevents it from working correctly with most Kafka clients.

### Test Objective

The goal was to test whether we could:
1. Use AWS Network Load Balancer (NLB) to handle SSL/TLS termination
2. Keep Kafka broker without TLS (SASL_PLAINTEXT only)
3. Allow external clients to connect securely via NLB with SASL_SSL

### Why It Fails

**The Problem**: Kafka's advertised listener mechanism is incompatible with this SSL termination approach.

**Failure Flow**:
```
1. Client → NLB:9094 (SASL_SSL connection)           ✓ Success
2. NLB → Kafka:9092 (SSL terminated, forwards plain) ✓ Success
3. Kafka returns metadata: "I'm at EC2:9092"         ✓ Success
4. Client → EC2:9092 (attempts SASL_SSL connection)  ❌ FAILURE
   - Kafka:9092 only speaks SASL_PLAINTEXT
   - Client expects SASL_SSL
   - SSL handshake fails: "connecting to a PLAINTEXT broker listener?"
```

**Root Cause**:
- Kafka advertises its listener as `EC2_DNS:9092`
- When clients fetch metadata through the NLB, they get redirected to connect directly to EC2:9092
- Clients try to connect to EC2:9092 with SASL_SSL (since they initially connected via SSL)
- But Kafka:9092 only supports SASL_PLAINTEXT
- Result: Protocol mismatch and connection failure

### Test Results

**Direct EC2 Connection (SASL_PLAINTEXT)**: ✅ **Works perfectly**
```bash
bootstrap.servers: ec2-xxx.amazonaws.com:9092
security.protocol: SASL_PLAINTEXT
# Successfully connects and produces/consumes
```

**NLB Connection (SASL_SSL)**: ❌ **Fails**
```bash
bootstrap.servers: nlb-xxx.elb.amazonaws.com:9094
security.protocol: SASL_SSL
# Initial connection succeeds, but metadata fetch redirects to EC2:9092
# SSL handshake fails when trying to reconnect to EC2:9092
# Error: "SSL handshake failed: connecting to a PLAINTEXT broker listener?"
```

### Why This Architecture Doesn't Work

Kafka's design requires that:
1. The advertised listener protocol must match what clients use to connect
2. Clients will be redirected to the advertised listener address after initial connection
3. All subsequent connections must use the same security protocol

With NLB SSL termination:
- NLB terminates SSL and forwards PLAINTEXT to Kafka ✓
- Kafka advertises PLAINTEXT listener (EC2:9092) ✓
- Client connects with SASL_SSL via NLB ✓
- Client gets redirected to EC2:9092 with SASL_SSL ❌ (protocol mismatch!)

### Correct Architectures for SSL with Kafka

#### Option 1: End-to-End Encryption (Recommended)
```
Client (SASL_SSL) → Kafka (SASL_SSL on 9092)
```
- Kafka handles SSL directly
- No load balancer SSL termination
- See: terraform-confluent-aws (our other project)

#### Option 2: NLB TCP Passthrough
```
Client (SASL_SSL) → NLB:9094 (TCP passthrough) → Kafka:9092 (SASL_SSL)
```
- NLB in TCP mode (not TLS mode)
- Kafka still does SSL/TLS encryption
- NLB just forwards encrypted traffic

#### Option 3: No SSL on External Network (Not Recommended)
```
Client (SASL_PLAINTEXT) → Kafka (SASL_PLAINTEXT on 9092)
```
- Direct connection without any SSL
- Only for trusted networks or testing

### What This Project Demonstrates

✅ **Successfully demonstrates**:
- How to set up AWS NLB with TLS termination
- How to configure ACM certificates for NLB
- Automated certificate generation matching NLB DNS
- Terraform infrastructure for Confluent Platform on AWS

❌ **Does NOT work for**:
- External Kafka clients connecting via NLB with SSL
- Production use cases requiring SSL/TLS encryption
- ClickHouse ClickPipes or other Kafka clients expecting SASL_SSL

### Conclusion

**This architecture is a proof-of-concept that reveals an important limitation**: NLB SSL termination is **incompatible** with Kafka's advertised listener mechanism.

For production Kafka deployments requiring SSL:
- Use end-to-end encryption with Kafka handling SSL directly
- Or use NLB in TCP passthrough mode (not TLS termination mode)
- See our `terraform-confluent-aws` project for a working SSL implementation

This project remains useful as:
- A learning exercise about Kafka networking and SSL
- Infrastructure template for Confluent Platform on AWS
- Documentation of what doesn't work and why

## Important Notes

- ⚠️ **This architecture does NOT work for external Kafka clients** - See "Architecture Limitations" above
- ⚠️ **TLS is disabled on Kafka broker** - Only NLB provides SSL termination
- ⚠️ **Kafka advertised listener uses EC2 DNS** - Clients get redirected to EC2:9092 (PLAINTEXT)
- ⚠️ **Protocol mismatch** - Clients expect SASL_SSL but Kafka only speaks SASL_PLAINTEXT
- ✅ **Direct EC2 connection works** - Use SASL_PLAINTEXT to connect directly to EC2:9092
- ℹ️ **For working SSL setup** - See terraform-confluent-aws project instead
- ℹ️ **Certificate auto-generated** - Matches NLB DNS automatically during deployment
- ℹ️ Self-signed certificate is used - Not suitable for production

## Cost Estimation

Approximate AWS costs (us-east-1):
- EC2 r5.xlarge: ~$0.25/hour
- NLB: ~$0.0225/hour + data processing charges
- EBS gp3 100GB: ~$8/month
- Data transfer: Variable

**Estimated monthly cost**: ~$190-220 (if running 24/7)

## Differences from terraform-confluent-aws

1. **TLS Configuration**: Kafka has NO TLS (vs SASL_SSL on 9092)
2. **NLB Added**: SSL termination at NLB layer
3. **Port Changes**: NLB listens on 9094 (vs direct access on 9092/9093)
4. **Certificate Management**: NLB certificate (vs Kafka broker certificates)
5. **Architecture**: SSL termination at load balancer (vs end-to-end encryption)

## SSL Certificate Configuration

This project uses **self-signed certificates** for testing. For production use:

### Using Self-Signed Certificates (Testing Only)

See [SSL_CERTIFICATE_GUIDE.md](SSL_CERTIFICATE_GUIDE.md) for:
- Python, Go, Java, Node.js configuration examples
- How to disable certificate verification for testing
- Certificate troubleshooting

### Using Valid CA-Signed Certificates (Production)

See [CUSTOM_DOMAIN_SETUP.md](CUSTOM_DOMAIN_SETUP.md) for:
- Setting up custom domain (e.g., `kafka.yourcompany.com`)
- Obtaining valid certificates from Let's Encrypt or ACM
- Configuring Route 53 DNS
- No certificate verification issues!

**Recommended for Production**: Use a custom domain with valid certificates.

## References

- [AWS Network Load Balancer - TLS Termination](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/create-tls-listener.html)
- [Confluent Platform Documentation](https://docs.confluent.io/)
- [Kafka Security Documentation](https://kafka.apache.org/documentation/#security)
- [Kafka Advertised Listeners](https://cwiki.apache.org/confluence/display/KAFKA/KIP-103+-+Separation+of+Internal+and+External+traffic)
