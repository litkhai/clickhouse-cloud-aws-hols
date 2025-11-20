# NLB SSL Termination - Solution Summary

## Problem & Solution

### ❌ Original Problem
Kafka advertised EC2 DNS → Clients tried to connect to EC2:9092 with SSL → Protocol mismatch

### ✅ Solution
Kafka advertises NLB DNS → Clients always connect to NLB:9094 with SSL → NLB terminates SSL → Works!

## Key Configuration Change

```yaml
# Before (BROKEN):
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_PLAINTEXT://$EC2_DNS:9092

# After (WORKING):
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_PLAINTEXT://$NLB_DNS:9094
```

## How To Apply

### Option 1: Automated (Recommended)

```bash
# Deploy infrastructure
terraform apply

# Get outputs
NLB_DNS=$(terraform output -raw nlb_endpoint)
EC2_DNS=$(terraform output -raw instance_public_dns)

# Update advertised listener
SSH_KEY=~/.ssh/your-key.pem ./update-advertised-listener.sh
```

### Option 2: Manual

```bash
# 1. Deploy
terraform apply

# 2. SSH to EC2
ssh -i your-key.pem ubuntu@$(terraform output -raw instance_public_dns)

# 3. Update config
NLB_DNS=$(terraform output -raw nlb_endpoint)
sudo sed -i "s/NLB_DNS_PLACEHOLDER/$NLB_DNS/g" /opt/confluent/docker-compose.yml

# 4. Restart Kafka
cd /opt/confluent && sudo docker-compose restart broker && sleep 30
```

## Verification

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
print(f"Brokers: {metadata.brokers}")

# Expected output:
# Brokers: {1: BrokerMetadata(1, <NLB_DNS>:9094)}  ← NLB DNS!
# NOT: ec2-xxx.amazonaws.com:9092
```

## Reference
- Full solution: [NLB_ADVERTISED_LISTENER_FIX.md](NLB_ADVERTISED_LISTENER_FIX.md)
- Test results: [TESTING_RESULTS.md](TESTING_RESULTS.md)
- Confluent blog: https://www.confluent.io/blog/kafka-listeners-explained/
