# Quick Start Guide - NLB SSL Termination

## Prerequisites

1. AWS CLI configured
2. Terraform installed
3. EC2 key pair created
4. SSH key file available

## One-Command Deployment

### Method 1: Configure in terraform.tfvars (Recommended)

```bash
# 1. Copy example config
cp terraform.tfvars.example terraform.tfvars

# 2. Edit terraform.tfvars - uncomment and set:
#    key_pair_name = "your-key-pair"
#    ssh_private_key = "~/.ssh/your-key.pem"

# 3. Deploy (fully automated)
./deploy-complete.sh
```

### Method 2: Use Environment Variable

```bash
# Set SSH key and deploy
SSH_KEY=~/.ssh/your-key.pem ./deploy-complete.sh
```

Both methods will:
- ✅ Generate certificates
- ✅ Deploy all infrastructure
- ✅ Update Kafka advertised listener with NLB DNS
- ✅ Restart Kafka automatically
- ✅ Ready to use!

### Method 3: Manual Configuration

```bash
# Deploy infrastructure only (no SSH key)
./deploy-complete.sh

# Follow the manual configuration instructions shown
```

You'll need to SSH manually and update the advertised listener.

## Alternative: Step-by-Step

```bash
# 1. Generate initial certificate
cd certs && ./generate-nlb-cert.sh && cd ..

# 2. Deploy infrastructure
terraform init
terraform apply

# 3. Update certificate with NLB DNS
terraform apply -replace='aws_acm_certificate.nlb_cert'

# 4. Update advertised listener
SSH_KEY=~/.ssh/your-key.pem ./update-advertised-listener.sh
```

## Test Connection

```bash
# Get NLB DNS
NLB_DNS=$(terraform output -raw nlb_endpoint)

# Test with Python
cat > test.py << 'EOF'
from confluent_kafka.admin import AdminClient

config = {
    'bootstrap.servers': '${NLB_DNS}:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
}

admin = AdminClient(config)
metadata = admin.list_topics(timeout=10)
print(f"✓ Connected! Topics: {len(metadata.topics)}")
print(f"Brokers: {metadata.brokers}")
EOF

python3 test.py
```

## Expected Result

```
✓ Connected! Topics: 59
Brokers: {1: BrokerMetadata(1, confluent-server-nlb-xxx.elb.ap-northeast-2.amazonaws.com:9094)}
```

**Key Point**: Broker metadata shows **NLB DNS**, not EC2 DNS! This means advertised listener is working correctly.

## Configuration Variables

Edit `terraform.tfvars`:

```hcl
aws_region           = "ap-northeast-2"
instance_name        = "confluent-server"
key_pair_name        = "your-key-pair"
ssh_private_key      = "~/.ssh/your-key.pem"  # For automated setup
kafka_sasl_username  = "admin"
kafka_sasl_password  = "admin-secret"
```

**Important**: `ssh_private_key` enables automatic advertised listener configuration!

## Troubleshooting

### Check advertised listener

```bash
ssh -i your-key.pem ubuntu@$(terraform output -raw instance_public_dns)
docker logs broker | grep advertised.listeners
```

Should show NLB DNS, not EC2 DNS.

### Manual update if needed

```bash
NLB_DNS=$(terraform output -raw nlb_endpoint)
ssh -i your-key.pem ubuntu@$(terraform output -raw instance_public_dns)

sudo sed -i "s/NLB_DNS_PLACEHOLDER/$NLB_DNS/g" /opt/confluent/docker-compose.yml
cd /opt/confluent && sudo docker-compose restart broker
```

## Cleanup

```bash
terraform destroy
```

## More Information

- Complete solution guide: [NLB_ADVERTISED_LISTENER_FIX.md](NLB_ADVERTISED_LISTENER_FIX.md)
- Test results: [TESTING_RESULTS.md](TESTING_RESULTS.md)
- Full README: [README.md](README.md)
