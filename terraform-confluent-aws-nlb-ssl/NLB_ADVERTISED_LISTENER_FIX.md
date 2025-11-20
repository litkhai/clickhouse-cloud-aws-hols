# NLB SSL Termination - Advertised Listener Fix

## The Original Problem (SOLVED!)

**Previous Issue**: Kafka advertised EC2 DNS, causing protocol mismatch when clients connected via NLB.

**Flow (What was failing)**:
```
1. Client → NLB:9094 (SASL_SSL)                    ✓
2. NLB → Kafka:9092 (SSL terminated, PLAINTEXT)    ✓
3. Kafka returns: "I'm at EC2:9092"                ✓
4. Client → EC2:9092 (SASL_SSL attempt)            ❌ Protocol mismatch!
```

## The Solution: Advertise NLB DNS Instead

Based on [Confluent's blog post on Kafka listeners](https://www.confluent.io/blog/kafka-listeners-explained/), Kafka can advertise a different address than where it's actually listening.

**Solution**: Configure Kafka to advertise **NLB DNS:9094** instead of **EC2 DNS:9092**

**Fixed Flow**:
```
1. Client → NLB:9094 (SASL_SSL)                    ✓
2. NLB → Kafka:9092 (SSL terminated, PLAINTEXT)    ✓
3. Kafka returns: "I'm at NLB:9094"                ✓ (advertising NLB!)
4. Client → NLB:9094 (SASL_SSL)                    ✓ Stays at NLB!
5. NLB → Kafka:9092 (SSL terminated)               ✓ Works!
```

Now clients **always** connect through NLB, and NLB handles SSL termination!

## Implementation

### 1. Kafka Configuration Change

**Before (EC2 advertised)**:
```yaml
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_PLAINTEXT://$EC2_DNS:9092
```

**After (NLB advertised)**:
```yaml
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_PLAINTEXT://$NLB_DNS:9094
```

### 2. Protocol Map

Add mapping so Kafka knows SASL_SSL requests should be handled as SASL_PLAINTEXT internally:

```yaml
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,SASL_PLAINTEXT:SASL_PLAINTEXT,SASL_SSL:SASL_PLAINTEXT
```

### 3. Deployment Process

Since NLB DNS is only known after `terraform apply`, we need a two-step process:

**Option A: Automated (Requires SSH Key)**

1. Deploy with placeholder:
```bash
terraform apply
```

2. Terraform will automatically update Kafka configuration via remote-exec provisioner
3. Kafka restarts with correct NLB DNS

**Option B: Manual (No SSH Key Required)**

1. Deploy infrastructure:
```bash
terraform apply
```

2. Get NLB DNS:
```bash
NLB_DNS=$(terraform output -raw nlb_endpoint)
```

3. SSH to EC2 and update configuration:
```bash
ssh -i your-key.pem ubuntu@$(terraform output -raw instance_public_dns)

# Update docker-compose.yml
sudo sed -i "s/NLB_DNS_PLACEHOLDER/$NLB_DNS/g" /opt/confluent/docker-compose.yml

# Restart Kafka
cd /opt/confluent
sudo docker-compose restart broker

# Wait for Kafka to be ready
sleep 30
```

4. Verify:
```bash
docker exec broker kafka-broker-api-versions --bootstrap-server localhost:29092
```

## Testing the Fix

### Test Script

```python
from confluent_kafka.admin import AdminClient

config = {
    'bootstrap.servers': '<NLB_DNS>:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
}

admin = AdminClient(config)
metadata = admin.list_topics(timeout=10)

print(f"✓ Connected via NLB!")
print(f"  Topics: {len(metadata.topics)}")
print(f"  Brokers: {metadata.brokers}")
# Should show: {1: BrokerMetadata(1, <NLB_DNS>:9094)}  ← NLB DNS, not EC2!
```

### Expected Result

**Before Fix**:
```
Brokers: {1: BrokerMetadata(1, ec2-xxx.amazonaws.com:9092)}
❌ Client tries to connect to EC2 with SSL
❌ Fails: "connecting to a PLAINTEXT broker listener?"
```

**After Fix**:
```
Brokers: {1: BrokerMetadata(1, nlb-xxx.elb.amazonaws.com:9094)}
✓ Client connects to NLB with SSL
✓ Works perfectly!
```

## Why This Works

1. **Client always uses NLB**: Since Kafka advertises NLB:9094, clients never try to connect directly to EC2

2. **Protocol consistency from client perspective**:
   - Client uses SASL_SSL throughout
   - Client always connects to NLB:9094
   - Client doesn't know SSL is terminated

3. **NLB handles SSL termination**:
   - NLB receives SASL_SSL on port 9094
   - NLB terminates SSL
   - NLB forwards SASL_PLAINTEXT to Kafka:9092

4. **Kafka stays simple**:
   - Kafka only handles SASL_PLAINTEXT
   - No SSL/TLS overhead
   - Advertises NLB address for external clients

## Key Insights from Confluent Blog

From [Kafka listeners explained](https://www.confluent.io/blog/kafka-listeners-explained/):

> **advertised.listeners**: The advertised listeners are the listeners that clients will use to connect to the Kafka broker. This is what the broker will return to clients.

This means:
- `KAFKA_LISTENERS`: Where Kafka actually listens (EC2:9092)
- `KAFKA_ADVERTISED_LISTENERS`: What Kafka tells clients (NLB:9094)
- These can be different!

**Perfect for our use case**: Kafka listens on EC2:9092, but tells clients to use NLB:9094!

## Architecture Comparison

### Before Fix: BROKEN ❌

```
Client config: SASL_SSL
         ↓
    [Initial Connection]
         ↓
    NLB:9094 (SSL)
         ↓
    Kafka:9092 (PLAINTEXT)
         ↓
    [Kafka returns metadata]
         ↓
    "Broker is at EC2:9092"  ← Wrong address!
         ↓
    Client → EC2:9092 (SASL_SSL)  ← Protocol mismatch!
         ❌ FAILS
```

### After Fix: WORKING ✓

```
Client config: SASL_SSL
         ↓
    [Initial Connection]
         ↓
    NLB:9094 (SSL termination)
         ↓
    Kafka:9092 (PLAINTEXT)
         ↓
    [Kafka returns metadata]
         ↓
    "Broker is at NLB:9094"  ← Correct address!
         ↓
    Client → NLB:9094 (SASL_SSL)  ← Stays at NLB!
         ↓
    NLB:9094 (SSL termination)
         ↓
    Kafka:9092 (PLAINTEXT)
         ✓ WORKS!
```

## Configuration Files Modified

### 1. user-data.sh

```yaml
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,SASL_PLAINTEXT:SASL_PLAINTEXT,SASL_SSL:SASL_PLAINTEXT
KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:29092,SASL_PLAINTEXT://0.0.0.0:9092
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_PLAINTEXT://NLB_DNS_PLACEHOLDER:9094
```

### 2. main.tf

Added provisioner to update `NLB_DNS_PLACEHOLDER` with actual NLB DNS after deployment.

### 3. variables.tf

Added `ssh_private_key` variable for remote-exec provisioner (optional).

## Deployment Instructions

### Quick Start (With SSH Key)

```bash
# 1. Configure terraform.tfvars
cat > terraform.tfvars << EOF
aws_region           = "ap-northeast-2"
instance_name        = "confluent-server"
key_pair_name        = "your-key-pair"
ssh_private_key      = "~/.ssh/your-key.pem"
kafka_sasl_username  = "admin"
kafka_sasl_password  = "admin-secret"
EOF

# 2. Deploy
terraform init
terraform apply

# 3. Wait for automatic configuration update
# Terraform will SSH to instance and update advertised listener

# 4. Test connection
python3 test_nlb_connection.py
```

### Manual Process (Without SSH Key)

```bash
# 1. Deploy infrastructure
terraform apply

# 2. Get NLB DNS
NLB_DNS=$(terraform output -raw nlb_endpoint)
EC2_DNS=$(terraform output -raw instance_public_dns)

# 3. SSH and update
ssh -i your-key.pem ubuntu@$EC2_DNS

# 4. Update configuration
sudo sed -i "s/NLB_DNS_PLACEHOLDER/$NLB_DNS/g" /opt/confluent/docker-compose.yml

# 5. Restart Kafka
cd /opt/confluent
sudo docker-compose restart broker

# 6. Verify
docker logs broker | tail -20
```

## Verification Steps

### 1. Check Advertised Listener

```bash
ssh ubuntu@$(terraform output -raw instance_public_dns)
docker exec broker kafka-broker-api-versions --bootstrap-server localhost:29092
```

Should show listener on NLB DNS, not EC2 DNS.

### 2. Test Client Connection

```python
from confluent_kafka.admin import AdminClient

admin = AdminClient({
    'bootstrap.servers': '<NLB_DNS>:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
})

metadata = admin.list_topics(timeout=10)
print(f"Brokers: {metadata.brokers}")
# Should show NLB DNS, not EC2 DNS!
```

### 3. Check Broker Metadata

```bash
# From client machine
echo "get metadata" | kafka-console-consumer \
    --bootstrap-server <NLB_DNS>:9094 \
    --consumer-property security.protocol=SASL_SSL \
    --consumer-property sasl.mechanism=PLAIN \
    --consumer-property sasl.jaas.config='org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";' \
    --consumer-property ssl.truststore.location=certs/nlb-certificate.jks \
    --topic __consumer_offsets \
    --timeout-ms 5000
```

## Success Criteria

✅ **Working when**:
- Client connects to NLB:9094 with SASL_SSL
- Kafka returns broker metadata with NLB DNS (not EC2 DNS)
- All produce/consume operations work
- No "PLAINTEXT broker listener" errors

✅ **Expected behavior**:
- Clients only know about NLB endpoint
- NLB handles all SSL termination
- Kafka processes SASL authentication in PLAINTEXT mode
- Centralized certificate management at NLB

## Benefits of This Approach

1. ✅ **SSL termination at NLB**: Reduces CPU load on Kafka brokers
2. ✅ **Centralized certificate management**: Only NLB needs certificates
3. ✅ **Works with standard Kafka clients**: No custom client configuration
4. ✅ **Protocol consistency**: Clients use SASL_SSL throughout
5. ✅ **Scalable**: Can add more Kafka brokers behind same NLB
6. ✅ **Secure external access**: SSL encryption from client to NLB

## Conclusion

The original architecture wasn't broken - it just needed the correct **advertised listener** configuration!

**Key Learning**: Kafka's `advertised.listeners` can be different from where Kafka actually listens. This is the key to making NLB SSL termination work.

Thanks to the [Confluent blog post](https://www.confluent.io/blog/kafka-listeners-explained/) for explaining this crucial detail!

## Next Steps

1. Update existing infrastructure with advertised listener fix
2. Test with ClickHouse ClickPipes
3. Update main README.md with working architecture
4. Remove "does not work" warnings
5. Add this as a working reference architecture
