# Confluent Platform on AWS with Terraform

> **Last verified: 2025-11-20** — date of the last commit made while running the lab (there is no separate run log). AWS provider `~> 5.0`.
> Changed since without a full re-run:
> - 2026-07-28 — the Kafka SASL username/password moved from a hard-coded default to required variables (not run)
> - 2026-08-10 — `allowed_cidr_blocks` is required and rejects `0.0.0.0/0` (checked with `terraform plan` on 1.15.8, not applied)
>
> Not checked — adjust before `apply` (recorded 2026-10-04 from reading the code; nothing was run):
> - AWS provider: `~> 5.0` resolves to 5.100.0, the last 5.x release; never run on 6.x (6.67.0 is the newest, Terraform Registry API read 2026-10-04).
> - SASL: `user-data.sh` puts the username and password unescaped into the JAAS config and `docker-compose.yml`; every run so far used `admin` / `admin-secret`. Use letters and digits only — `"` breaks the quoting and `$` is expanded by the shell.
> - `user-data.sh` prints the SASL password to the instance's cloud-init log.
> - Not pinned: the AMI (newest Canonical Ubuntu 22.04 at `apply` time). Confluent images are pinned by `confluent_version` (default `7.5.0`).
> - Run path: `./deploy.sh` → `./destroy.sh`.
> - A re-run should show: a SASL client inside `allowed_cidr_blocks` produces and consumes on the sample topic, and the same client from an address outside it cannot connect.
>
> **마지막 검증: 2025-11-20** — 실습을 실행하며 남긴 마지막 커밋 날짜 (별도 실행 기록은 없음). AWS provider `~> 5.0`.
> 그 뒤 전체 재실행 없이 바뀐 것:
> - 2026-07-28 — Kafka SASL 사용자명·비밀번호가 하드코딩 기본값에서 필수 변수로 바뀜 (실행 안 함)
> - 2026-08-10 — `allowed_cidr_blocks` 필수화, `0.0.0.0/0` 거부 (terraform 1.15.8에서 `plan`까지만 확인, apply 안 함)
>
> 확인 안 된 것 — `apply` 전에 맞출 것 (2026-10-04 코드를 읽고 기록, 실행 안 함):
> - AWS provider: `~> 5.0`은 마지막 5.x인 5.100.0으로 잡힘. 6.x에서는 실행한 적 없음 (최신 6.67.0, 2026-10-04 Terraform Registry API로 확인).
> - SASL: `user-data.sh`가 사용자명·비밀번호를 이스케이프 없이 JAAS 설정과 `docker-compose.yml`에 넣음. 지금까지 실행은 모두 `admin` / `admin-secret`. 영문자와 숫자만 쓸 것 — `"`는 따옴표를 깨고 `$`는 셸이 치환함.
> - `user-data.sh`가 SASL 비밀번호를 인스턴스의 cloud-init 로그에 출력함.
> - 고정 안 된 것: AMI (`apply` 시점의 최신 Canonical Ubuntu 22.04). Confluent 이미지는 `confluent_version`(기본 `7.5.0`)으로 고정.
> - 실행 경로: `./deploy.sh` → `./destroy.sh`.
> - 재실행에서 보여야 할 것: `allowed_cidr_blocks` 안의 SASL 클라이언트가 샘플 토픽에 produce·consume 하고, 범위 밖 주소의 같은 클라이언트는 연결되지 않음.

This Terraform configuration deploys a complete Confluent Platform stack on AWS EC2, including Kafka, Schema Registry, Kafka Connect, ksqlDB, Control Center, and REST Proxy.

## Features

- **Complete Confluent Platform**: All core components (Kafka, ZooKeeper, Schema Registry, Connect, ksqlDB, Control Center, REST Proxy)
- **Automated Setup**: One-command deployment with Docker Compose
- **Sample Data Producer**: Automatically generates sample data to a Kafka topic
- **Production-Ready**: Configurable instance types, EBS volumes, and security groups
- **Easy Management**: Scripts for start, stop, and status checking

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- (Optional) SSH key pair for remote access

## AWS Credentials Setup

Set your AWS credentials as environment variables:

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # If using temporary credentials
export AWS_REGION="us-east-1"  # Optional: Set default region
```

## Quick Start

### 1. Clone and Navigate

```bash
cd terraform-confluent-aws
```

### 2. Configure Variables

Copy the example configuration:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to customize your deployment:

```hcl
aws_region = "us-east-1"
instance_name = "my-confluent-server"
instance_type = "r5.xlarge"
key_pair_name = "my-key-pair"  # Optional: for SSH access
use_elastic_ip = false
```

### 3. Deploy

```bash
# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply
```

The deployment takes about 5-10 minutes. Terraform will output all important URLs and connection information.

### 4. Access Confluent Platform

After deployment completes, access the Control Center:

```bash
# Get the Control Center URL from outputs
terraform output control_center_url
```

Open the URL in your browser to access the Confluent Control Center Web UI.

## Architecture

### Components Deployed

1. **EC2 Instance**: Ubuntu 22.04 LTS with Docker
2. **ZooKeeper**: Cluster coordination (port 2181)
3. **Kafka Broker**: Message streaming (port 9092)
4. **Schema Registry**: Schema management (port 8081)
5. **Kafka Connect**: Data integration (port 8083)
6. **ksqlDB**: Stream processing (port 8088)
7. **Control Center**: Web UI for management (port 9021)
8. **REST Proxy**: HTTP REST API (port 8082)
9. **Data Producer**: Systemd service generating sample data

### Network Configuration

The deployment creates a security group with the following ingress rules:

| Port | Service | Description |
|------|---------|-------------|
| 2181 | ZooKeeper | Cluster coordination |
| 9092 | Kafka | Broker access (internal and external) |
| 8081 | Schema Registry | Schema management API |
| 8083 | Kafka Connect | Connect API |
| 8088 | ksqlDB | ksqlDB API |
| 8082 | REST Proxy | Kafka REST API |
| 9021 | Control Center | Web UI |
| 22 | SSH | Remote access (if key configured) |

### SASL Authentication

The Kafka broker is configured with **SASL/PLAIN authentication** on port **9092** for external clients.

**Authentication Details:**
- **Security Protocol**: `SASL_PLAINTEXT`
- **SASL Mechanism**: `PLAIN`
- **Default Credentials**: Configured via `kafka_sasl_username` and `kafka_sasl_password` variables

**Listener Architecture:**
- **Internal (PLAINTEXT)**: `broker:29092` - Used by Control Center, Schema Registry, Connect (no authentication)
- **External (SASL_PLAINTEXT)**: `<PUBLIC_IP>:9092` - Used by external clients (requires SASL authentication)

This architecture mirrors **Confluent Cloud's authentication model**, making it ideal for ClickHouse integration workshops and hands-on labs.

#### Testing SASL Connection

After deployment, a Python test script is automatically generated on the EC2 instance with the correct IP address:

```bash
# Get the test command from Terraform outputs
terraform output -raw test_sasl_connection

# Download the test script (already configured with correct IP and credentials)
scp -i /path/to/key.pem ubuntu@<instance-ip>:/opt/confluent/test_kafka_sasl.py .

# Install Python package
pip3 install confluent-kafka

# Run the test
python3 test_kafka_sasl.py
```

The test script automatically verifies:
- ✓ Admin client connectivity and topic listing
- ✓ Producer sending messages with SASL authentication
- ✓ Consumer reading messages with SASL authentication

For detailed connection examples in Python, Java, Go, Node.js, and ClickHouse, see [SASL_CONNECTION_GUIDE.md](SASL_CONNECTION_GUIDE.md).

## Configuration

### Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `aws_region` | AWS region for deployment | null (uses env var) | No |
| `instance_name` | Name tag for EC2 instance | "confluent-server" | No |
| `instance_type` | EC2 instance type | "r5.xlarge" | No |
| `ebs_volume_size` | EBS volume size in GB | 100 | No |
| `key_pair_name` | SSH key pair name | null | No |
| `allowed_cidr_blocks` | Who may reach SSH and the broker ports. `0.0.0.0/0` is rejected | - | **Yes** |
| `use_elastic_ip` | Allocate Elastic IP | false | No |
| `confluent_version` | Confluent Platform version | "7.5.0" | No |
| `sample_topic_name` | Sample topic name | "sample-data-topic" | No |
| `data_producer_interval` | Data production interval (seconds) | 5 | No |
| `kafka_sasl_username` | Kafka SASL username | "admin" | No |
| `kafka_sasl_password` | Kafka SASL password | "admin-secret" | No |

### Instance Type Recommendations

- **Development**: `t3.xlarge` (4 vCPU, 16 GB RAM)
- **Testing**: `r5.xlarge` (4 vCPU, 32 GB RAM) - **Default**
- **Production**: `r5.2xlarge` or larger (8+ vCPU, 64+ GB RAM)

## Management

### SSH Access

If you configured a key pair:

```bash
# Get SSH command from outputs
terraform output ssh_command

# Or manually connect
ssh -i /path/to/your-key.pem ubuntu@<instance-ip>
```

### Management Scripts

Once connected via SSH, use these scripts:

```bash
# Check status of all services
sudo /opt/confluent/status.sh

# Stop Confluent Platform
sudo /opt/confluent/stop.sh

# Start Confluent Platform
sudo /opt/confluent/start.sh

# View data producer logs
sudo journalctl -u confluent-producer -f
```

### Using Kafka

#### Understanding Kafka Listeners

Kafka is configured with **two listeners**:

- **PLAINTEXT (port 29092)**: Internal Docker network communication
- **EXTERNAL (port 9092)**: External client access (from anywhere, including localhost)

#### List Topics (from SSH)

```bash
# From inside the instance
docker exec broker kafka-topics --list --bootstrap-server localhost:9092
```

#### Consume Messages (from SSH)

```bash
# From inside the instance
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic sample-data-topic \
  --from-beginning
```

#### Produce Messages (from SSH)

```bash
# From inside the instance
docker exec -i broker kafka-console-producer \
  --broker-list localhost:9092 \
  --topic sample-data-topic
```

### Connecting from External Applications

External clients connect using port **9092** (same as Confluent Cloud):

```bash
# Get the external bootstrap server
terraform output kafka_bootstrap_servers

# Example output: 203.0.113.13:9092
```

#### Test External Connection

```bash
# Test connectivity
nc -zv <public-ip> 9092

# Test Kafka API from local machine (requires kafka tools)
kafka-broker-api-versions --bootstrap-server <public-ip>:9092
```

#### Example: External Python Client (with SASL Authentication)

```python
from kafka import KafkaProducer, KafkaConsumer

# Get credentials from Terraform outputs
# terraform output kafka_sasl_username
# terraform output -raw kafka_sasl_password

# Producer
producer = KafkaProducer(
    bootstrap_servers=['<public-ip>:9092'],
    security_protocol='SASL_PLAINTEXT',
    sasl_mechanism='PLAIN',
    sasl_plain_username='admin',  # Your kafka_sasl_username
    sasl_plain_password='admin-secret'  # Your kafka_sasl_password
)
producer.send('sample-data-topic', b'Hello from external client')
producer.flush()

# Consumer
consumer = KafkaConsumer(
    'sample-data-topic',
    bootstrap_servers=['<public-ip>:9092'],
    security_protocol='SASL_PLAINTEXT',
    sasl_mechanism='PLAIN',
    sasl_plain_username='admin',  # Your kafka_sasl_username
    sasl_plain_password='admin-secret',  # Your kafka_sasl_password
    auto_offset_reset='earliest'
)
for message in consumer:
    print(message.value)
```

#### Port Summary

| Port | Listener | Access From | Use Case |
|------|----------|-------------|----------|
| 29092 | PLAINTEXT | Docker containers | Internal service communication |
| **9092** | **SASL_PLAINTEXT** | **Anywhere (including SSH)** | **External clients with SASL auth** |

### SASL Authentication

The Kafka broker is configured with **SASL/PLAIN authentication** (like Confluent Cloud's API Key/Secret model).

#### Get Credentials

```bash
# Get username (API Key)
terraform output kafka_sasl_username

# Get password (API Secret)
terraform output -raw kafka_sasl_password
```

Default credentials:
- **Username (API Key)**: `admin`
- **Password (API Secret)**: `admin-secret`

⚠️ **Security Warning**: Change these default credentials in production! Edit `terraform.tfvars`:
```hcl
kafka_sasl_username = "your-api-key"
kafka_sasl_password = "your-secret-key"
```

#### Command-line Tools with SASL

```bash
# List topics (from inside instance)
docker exec broker kafka-topics --list \
  --bootstrap-server localhost:9092 \
  --command-config /opt/confluent/client.properties

# Consume messages (from inside instance)
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic sample-data-topic \
  --from-beginning \
  --consumer.config /opt/confluent/client.properties

# Produce messages (from inside instance)
docker exec -i broker kafka-console-producer \
  --broker-list localhost:9092 \
  --topic sample-data-topic \
  --producer.config /opt/confluent/client.properties
```

#### Java Client Configuration

```java
Properties props = new Properties();
props.put("bootstrap.servers", "<public-ip>:9092");
props.put("security.protocol", "SASL_PLAINTEXT");
props.put("sasl.mechanism", "PLAIN");
props.put("sasl.jaas.config",
  "org.apache.kafka.common.security.plain.PlainLoginModule required " +
  "username=\"admin\" password=\"admin-secret\";");

KafkaProducer<String, String> producer = new KafkaProducer<>(props);
```

#### Node.js Client Configuration

```javascript
const { Kafka } = require('kafkajs');

const kafka = new Kafka({
  brokers: ['<public-ip>:9092'],
  sasl: {
    mechanism: 'plain',
    username: 'admin',
    password: 'admin-secret'
  }
});

const producer = kafka.producer();
const consumer = kafka.consumer({ groupId: 'my-group' });
```

## Sample Data Format

The data producer generates JSON messages with the following structure:

```json
{
  "event_id": 1,
  "timestamp": "2025-01-15T10:30:00Z",
  "user_id": 123,
  "event_type": "page_view",
  "value": 456,
  "metadata": {
    "source": "web",
    "version": "1.0"
  }
}
```

Event types include: `page_view`, `click`, `purchase`, `signup`, `logout`

## Monitoring

### Control Center

Access the Confluent Control Center at port 9021:

- View cluster health
- Monitor topics and consumers
- Manage connectors
- Execute ksqlDB queries
- View metrics and alerts

### Docker Compose

```bash
# View all container status
docker compose ps

# View specific container logs
docker logs broker -f
docker logs control-center -f

# View resource usage
docker stats
```

## Outputs

After deployment, Terraform provides:

- `instance_id`: EC2 instance ID
- `instance_public_ip`: Public IP address
- `control_center_url`: Control Center web UI URL
- `schema_registry_url`: Schema Registry API URL
- `kafka_connect_url`: Kafka Connect API URL
- `ksqldb_url`: ksqlDB Server API URL
- `rest_proxy_url`: REST Proxy API URL
- `kafka_bootstrap_servers`: Kafka bootstrap servers for external connections
- `ssh_command`: SSH connection command
- `useful_commands`: Quick reference commands

## Troubleshooting

### Services Not Starting

Check Docker container status:

```bash
docker compose ps
docker compose logs
```

### Cannot Access Control Center

1. Verify security group allows access from your IP
2. Check if Docker containers are running
3. Wait 2-3 minutes after deployment for services to fully start

### Data Producer Not Running

```bash
# Check service status
sudo systemctl status confluent-producer

# Restart service
sudo systemctl restart confluent-producer

# View logs
sudo journalctl -u confluent-producer -f
```

### Kafka Connection Issues

Verify the external listener is properly configured:

```bash
docker exec broker kafka-broker-api-versions --bootstrap-server localhost:9092
```

## Cost Considerations

Estimated AWS costs (us-east-1 region):

- **r5.xlarge instance**: ~$0.25/hour (~$180/month)
- **EBS gp3 volume (100 GB)**: ~$8/month
- **Data transfer**: Variable based on usage
- **Elastic IP** (if enabled): $0.005/hour when instance stopped

**Total estimated cost**: ~$190-200/month for 24/7 operation

### Cost Optimization

1. **Stop when not in use**: `terraform destroy` when done
2. **Use smaller instance**: Change to `t3.xlarge` for development
3. **Reduce EBS volume**: Adjust `ebs_volume_size` if less storage needed
4. **Disable Elastic IP**: Set `use_elastic_ip = false`

## Security Best Practices

### For Production Use

1. **Restrict CIDR blocks**: Limit `allowed_cidr_blocks` to your IP ranges
2. **Enable encryption**: Add SSL/TLS for Kafka listeners
3. **Enable authentication**: Configure SASL for Kafka
4. **Use private subnets**: Deploy in private subnet with bastion host
5. **Enable CloudWatch**: Add monitoring and alerting
6. **Backup data**: Configure EBS snapshots
7. **Use secrets manager**: Store credentials in AWS Secrets Manager

### Current Security Posture

⚠️ **Warning**: Default configuration is for development/testing only

- Every broker port open to whatever `allowed_cidr_blocks` is set to (`0.0.0.0/0` is rejected)
- No authentication enabled
- No encryption in transit
- Public IP with direct access

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

This will:
- Terminate the EC2 instance
- Delete the security group
- Release the Elastic IP (if allocated)
- Remove all associated resources

**Note**: This is irreversible and will delete all data on the instance.

## Integration with ClickHouse

This Confluent Platform deployment can be integrated with ClickHouse using Kafka Connect:

1. Access the Connect API:
```bash
terraform output kafka_connect_url
```

2. Install the ClickHouse Sink Connector (if not already included)

3. Configure the connector to stream data from Kafka topics to ClickHouse tables

See the main repository for ClickHouse integration examples.

## Support

For issues or questions:

- Confluent Documentation: https://docs.confluent.io/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/
- Apache Kafka Documentation: https://kafka.apache.org/documentation/

## License

[MIT](../../../LICENSE), like the rest of the repository — the earlier wording granted nothing.
It is still educational material: it provisions real cloud resources that cost money, and
carries no warranty. The providers and services it calls have their own terms.
