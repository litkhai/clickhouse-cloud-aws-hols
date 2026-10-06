# Confluent Platform on AWS with Terraform

> **Last verified: 2025-11-20** — date of the last commit made while running the lab (there is no separate run log). AWS provider `~> 5.0`.
> Changed since without a full re-run:
> - 2026-07-28 — the Kafka SASL password moved from a hard-coded default to a required variable; the username still defaults to `admin` (not run)
> - 2026-08-10 — `allowed_cidr_blocks` is required and rejects `0.0.0.0/0` (checked with `terraform plan` on 1.15.8, not applied)
> - 2026-10-06 — `user-data.sh` no longer prints the SASL password to the cloud-init log ([#30](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/30); not run)
>
> Not checked — adjust before `apply` (recorded 2026-10-04 from reading the code; nothing was run):
> - AWS provider: `~> 5.0` resolves to 5.100.0, the last 5.x release; never run on 6.x (6.67.0 is the newest, Terraform Registry API read 2026-10-04).
> - SASL: `user-data.sh` puts the username and password unescaped into the JAAS config and `docker-compose.yml`; every run so far used `admin` / `admin-secret`. Use letters and digits only — `"` breaks the quoting and `$` is expanded by the shell.
> - The SASL password is still in the instance's user data (`main.tf` passes it to `templatefile`) and in files `user-data.sh` writes under `/opt/confluent` (`CONNECTION_INFO.md`, `test_kafka_sasl.py`).
> - Not pinned: the AMI (newest Canonical Ubuntu 22.04 at `apply` time). Confluent images are pinned by `confluent_version` (default `7.5.0`).
> - Run path: `./deploy.sh` → `./destroy.sh`.
> - A re-run should show: a SASL client inside `allowed_cidr_blocks` produces and consumes on the sample topic, and the same client from an address outside it cannot connect.
>
> **마지막 검증: 2025-11-20** — 실습을 실행하며 남긴 마지막 커밋 날짜 (별도 실행 기록은 없음). AWS provider `~> 5.0`.
> 그 뒤 전체 재실행 없이 바뀐 것:
> - 2026-07-28 — Kafka SASL 비밀번호가 하드코딩 기본값에서 필수 변수로 바뀜. 사용자명은 여전히 기본값 `admin` (실행 안 함)
> - 2026-08-10 — `allowed_cidr_blocks` 필수화, `0.0.0.0/0` 거부 (terraform 1.15.8에서 `plan`까지만 확인, apply 안 함)
> - 2026-10-06 — `user-data.sh`가 SASL 비밀번호를 cloud-init 로그에 더 이상 출력하지 않음 ([#30](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/30), 실행 안 함)
>
> 확인 안 된 것 — `apply` 전에 맞출 것 (2026-10-04 코드를 읽고 기록, 실행 안 함):
> - AWS provider: `~> 5.0`은 마지막 5.x인 5.100.0으로 잡힘. 6.x에서는 실행한 적 없음 (최신 6.67.0, 2026-10-04 Terraform Registry API로 확인).
> - SASL: `user-data.sh`가 사용자명·비밀번호를 이스케이프 없이 JAAS 설정과 `docker-compose.yml`에 넣음. 지금까지 실행은 모두 `admin` / `admin-secret`. 영문자와 숫자만 쓸 것 — `"`는 따옴표를 깨고 `$`는 셸이 치환함.
> - SASL 비밀번호는 여전히 인스턴스 user data(`main.tf`가 `templatefile`에 넘김)와 `user-data.sh`가 `/opt/confluent` 아래에 쓰는 파일(`CONNECTION_INFO.md`, `test_kafka_sasl.py`)에 들어 있음.
> - 고정 안 된 것: AMI (`apply` 시점의 최신 Canonical Ubuntu 22.04). Confluent 이미지는 `confluent_version`(기본 `7.5.0`)으로 고정.
> - 실행 경로: `./deploy.sh` → `./destroy.sh`.
> - 재실행에서 보여야 할 것: `allowed_cidr_blocks` 안의 SASL 클라이언트가 샘플 토픽에 produce·consume 하고, 범위 밖 주소의 같은 클라이언트는 연결되지 않음.

[English](#english) | [한국어](#한국어)

## English

This Terraform configuration deploys a complete Confluent Platform stack on AWS EC2, including Kafka, Schema Registry, Kafka Connect, ksqlDB, Control Center, and REST Proxy.

### Features

- **Complete Confluent Platform**: All core components (Kafka, ZooKeeper, Schema Registry, Connect, ksqlDB, Control Center, REST Proxy)
- **Automated Setup**: One-command deployment with Docker Compose
- **Sample Data Producer**: Automatically generates sample data to a Kafka topic
- **Configurable**: instance types, EBS volumes, and the CIDR blocks the security group allows
- **Easy Management**: Scripts for start, stop, and status checking

### Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- (Optional) SSH key pair for remote access

### AWS Credentials Setup

Set your AWS credentials as environment variables:

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # If using temporary credentials
export AWS_REGION="us-east-1"  # Optional: Set default region
```

### Quick Start

#### 1. Clone and Navigate

```bash
git clone https://github.com/litkhai/clickhouse-cloud-aws-hols.git
cd clickhouse-cloud-aws-hols/labs/kafka/terraform-confluent-aws
```

#### 2. Configure Variables

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

#### 3. Deploy

```bash
# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply
```

The deployment takes about 5-10 minutes. Terraform will output all important URLs and connection information.

#### 4. Access Confluent Platform

After deployment completes, access the Control Center:

```bash
# Get the Control Center URL from outputs
terraform output control_center_url
```

Open the URL in your browser to access the Confluent Control Center Web UI.

### Architecture

#### Components Deployed

1. **EC2 Instance**: Ubuntu 22.04 LTS with Docker
2. **ZooKeeper**: Cluster coordination (port 2181)
3. **Kafka Broker**: Message streaming (ports 9092 and 9093)
4. **Schema Registry**: Schema management (port 8081)
5. **Kafka Connect**: Data integration (port 8083)
6. **ksqlDB**: Stream processing (port 8088)
7. **Control Center**: Web UI for management (port 9021)
8. **REST Proxy**: HTTP REST API (port 8082)
9. **Data Producer**: Systemd service generating sample data

#### Network Configuration

The deployment creates a security group with the following ingress rules, each open to `allowed_cidr_blocks` only:

| Port | Service | Description |
|------|---------|-------------|
| 2181 | ZooKeeper | Cluster coordination |
| 9092 | Kafka | `SASL_SSL` broker access (external) |
| 9093 | Kafka | `SASL_PLAINTEXT` broker access (external) |
| 8081 | Schema Registry | Schema management API |
| 8083 | Kafka Connect | Connect API |
| 8088 | ksqlDB | ksqlDB API |
| 8082 | REST Proxy | Kafka REST API |
| 9021 | Control Center | Web UI |
| 22 | SSH | Remote access (if key configured) |

#### SASL Authentication

The Kafka broker is configured with **SASL/PLAIN authentication** on ports **9092** (`SASL_SSL`) and **9093** (`SASL_PLAINTEXT`) for external clients.

**Authentication Details:**
- **Security Protocol**: `SASL_SSL` (port 9092, TLS) or `SASL_PLAINTEXT` (port 9093, no encryption)
- **SASL Mechanism**: `PLAIN`
- **Credentials**: `kafka_sasl_username` (default `admin`) and `kafka_sasl_password` (required, no default)

**Listener Architecture:**
- **Internal (PLAINTEXT)**: `broker:29092` - Used by Control Center, Schema Registry, Connect (no authentication)
- **External (SASL_SSL)**: `<PUBLIC_DNS>:9092` - Used by external clients (requires SASL authentication, TLS)
- **External (SASL_PLAINTEXT)**: `<PUBLIC_DNS>:9093` - Used by external clients (requires SASL authentication, no encryption)

This architecture mirrors **Confluent Cloud's authentication model**, making it ideal for ClickHouse integration workshops and hands-on labs.

##### Testing SASL Connection

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

### Configuration

#### Variables

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
| `kafka_sasl_password` | Kafka SASL password (sensitive) | - | **Yes** |

#### Instance Type Recommendations

- **Development**: `t3.xlarge` (4 vCPU, 16 GB RAM)
- **Testing**: `r5.xlarge` (4 vCPU, 32 GB RAM) - **Default**
- **Production**: `r5.2xlarge` or larger (8+ vCPU, 64+ GB RAM)

### Management

#### SSH Access

If you configured a key pair:

```bash
# Get SSH command from outputs
terraform output ssh_command

# Or manually connect
ssh -i /path/to/your-key.pem ubuntu@<instance-ip>
```

#### Management Scripts

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

#### Using Kafka

##### Understanding Kafka Listeners

Kafka is configured with **three listeners**:

- **PLAINTEXT (port 29092)**: Internal Docker network communication, no authentication (not published to the host)
- **SASL_SSL (port 9092)**: External client access with SASL/PLAIN over TLS (from `allowed_cidr_blocks`)
- **SASL_PLAINTEXT (port 9093)**: External client access with SASL/PLAIN, no encryption (from `allowed_cidr_blocks`)

The commands below run inside the broker container and use the internal listener `localhost:29092`, which needs no client settings.

##### List Topics (from SSH)

```bash
# From inside the instance
docker exec broker kafka-topics --list --bootstrap-server localhost:29092
```

##### Consume Messages (from SSH)

```bash
# From inside the instance
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic sample-data-topic \
  --from-beginning
```

##### Produce Messages (from SSH)

```bash
# From inside the instance
docker exec -i broker kafka-console-producer \
  --broker-list localhost:29092 \
  --topic sample-data-topic
```

#### Connecting from External Applications

External clients connect on port **9092** (`SASL_SSL`, same as Confluent Cloud) or **9093** (`SASL_PLAINTEXT`):

```bash
# Get the external bootstrap servers
terraform output kafka_bootstrap_servers             # SASL_SSL, port 9092
terraform output kafka_bootstrap_servers_plaintext   # SASL_PLAINTEXT, port 9093

# Example output: <public-dns>:9092
```

##### Test External Connection

```bash
# Test connectivity
nc -zv <public-ip> 9092
nc -zv <public-ip> 9093

# Test Kafka API from local machine (requires kafka tools and a client.properties with the settings from Command-line Tools with SASL)
kafka-broker-api-versions --bootstrap-server <public-ip>:9093 --command-config client.properties
```

##### Example: External Python Client (with SASL Authentication)

```python
from kafka import KafkaProducer, KafkaConsumer

# Get credentials from Terraform outputs
# terraform output kafka_sasl_username
# terraform output -raw kafka_sasl_password

# Producer
producer = KafkaProducer(
    bootstrap_servers=['<public-ip>:9093'],
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
    bootstrap_servers=['<public-ip>:9093'],
    security_protocol='SASL_PLAINTEXT',
    sasl_mechanism='PLAIN',
    sasl_plain_username='admin',  # Your kafka_sasl_username
    sasl_plain_password='admin-secret',  # Your kafka_sasl_password
    auto_offset_reset='earliest'
)
for message in consumer:
    print(message.value)
```

##### Port Summary

| Port | Listener | Access From | Use Case |
|------|----------|-------------|----------|
| 29092 | PLAINTEXT | Docker containers | Internal service communication |
| **9092** | **SASL_SSL** | **`allowed_cidr_blocks`** | **External clients with SASL auth over TLS** |
| **9093** | **SASL_PLAINTEXT** | **`allowed_cidr_blocks`** | **External clients with SASL auth, no encryption** |

#### SASL Authentication

The Kafka broker is configured with **SASL/PLAIN authentication** (like Confluent Cloud's API Key/Secret model).

##### Get Credentials

```bash
# Get username (API Key)
terraform output kafka_sasl_username

# Get password (API Secret)
terraform output -raw kafka_sasl_password
```

Credentials:
- **Username (API Key)**: `kafka_sasl_username`, default `admin`
- **Password (API Secret)**: `kafka_sasl_password`, required with no default; `terraform.tfvars.example` sets `admin-secret`

⚠️ **Security Warning**: Replace the example values from `terraform.tfvars.example` with your own. Edit `terraform.tfvars`:
```hcl
kafka_sasl_username = "your-api-key"
kafka_sasl_password = "your-secret-key"
```

##### Command-line Tools with SASL

```bash
# Create the client settings inside the broker container (use your kafka_sasl_username and kafka_sasl_password)
docker exec broker bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";
EOF'

# List topics (from inside instance)
docker exec broker kafka-topics --list \
  --bootstrap-server localhost:9093 \
  --command-config /tmp/client.properties

# Consume messages (from inside instance)
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:9093 \
  --topic sample-data-topic \
  --from-beginning \
  --consumer.config /tmp/client.properties

# Produce messages (from inside instance)
docker exec -i broker kafka-console-producer \
  --broker-list localhost:9093 \
  --topic sample-data-topic \
  --producer.config /tmp/client.properties
```

##### Java Client Configuration

```java
Properties props = new Properties();
props.put("bootstrap.servers", "<public-ip>:9093");
props.put("security.protocol", "SASL_PLAINTEXT");
props.put("sasl.mechanism", "PLAIN");
props.put("sasl.jaas.config",
  "org.apache.kafka.common.security.plain.PlainLoginModule required " +
  "username=\"admin\" password=\"admin-secret\";");

KafkaProducer<String, String> producer = new KafkaProducer<>(props);
```

##### Node.js Client Configuration

```javascript
const { Kafka } = require('kafkajs');

const kafka = new Kafka({
  brokers: ['<public-ip>:9093'],
  sasl: {
    mechanism: 'plain',
    username: 'admin',
    password: 'admin-secret'
  }
});

const producer = kafka.producer();
const consumer = kafka.consumer({ groupId: 'my-group' });
```

### Sample Data Format

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

### Monitoring

#### Control Center

Access the Confluent Control Center at port 9021:

- View cluster health
- Monitor topics and consumers
- Manage connectors
- Execute ksqlDB queries
- View metrics and alerts

#### Docker Compose

```bash
# View all container status
docker compose ps

# View specific container logs
docker logs broker -f
docker logs control-center -f

# View resource usage
docker stats
```

### Outputs

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

### Troubleshooting

#### Services Not Starting

Check Docker container status:

```bash
docker compose ps
docker compose logs
```

#### Cannot Access Control Center

1. Verify security group allows access from your IP
2. Check if Docker containers are running
3. Wait 2-3 minutes after deployment for services to fully start

#### Data Producer Not Running

```bash
# Check service status
sudo systemctl status confluent-producer

# Restart service
sudo systemctl restart confluent-producer

# View logs
sudo journalctl -u confluent-producer -f
```

#### Kafka Connection Issues

Check that the external `SASL_PLAINTEXT` listener answers, with the client settings from Command-line Tools with SASL:

```bash
docker exec broker kafka-broker-api-versions --bootstrap-server localhost:9093 --command-config /tmp/client.properties
```

### Cost Considerations

Estimated AWS costs (us-east-1 region):

- **r5.xlarge instance**: ~$0.25/hour (~$180/month)
- **EBS gp3 volume (100 GB)**: ~$8/month
- **Data transfer**: Variable based on usage
- **Elastic IP** (if enabled): $0.005/hour when instance stopped

**Total estimated cost**: ~$190-200/month for 24/7 operation

These are estimates from when the lab was written, not measured; check current AWS pricing for your region.

#### Cost Optimization

1. **Stop when not in use**: `terraform destroy` when done
2. **Use smaller instance**: Change to `t3.xlarge` for development
3. **Reduce EBS volume**: Adjust `ebs_volume_size` if less storage needed
4. **Disable Elastic IP**: Set `use_elastic_ip = false`

### Security Best Practices

#### For Production Use

1. **Restrict CIDR blocks**: Limit `allowed_cidr_blocks` to your IP ranges
2. **Encryption**: Use `SASL_SSL` on 9092 rather than `SASL_PLAINTEXT` on 9093; add TLS to the HTTP services
3. **Authentication**: SASL/PLAIN covers the Kafka listeners only; add authentication to ZooKeeper and the HTTP services
4. **Use private subnets**: Deploy in private subnet with bastion host
5. **Enable CloudWatch**: Add monitoring and alerting
6. **Backup data**: Configure EBS snapshots
7. **Use secrets manager**: Store credentials in AWS Secrets Manager

#### Current Security Posture

⚠️ **Warning**: Default configuration is for development/testing only

- Every broker port open to whatever `allowed_cidr_blocks` is set to (`0.0.0.0/0` is rejected)
- SASL/PLAIN on the external Kafka listeners 9092 and 9093; the internal `PLAINTEXT` listener 29092 (Docker network only), ZooKeeper and the HTTP services (8081, 8082, 8083, 8088, 9021) have no authentication
- TLS only on 9092 (`SASL_SSL`, certificate signed by a CA generated on the instance); 9093, 29092, ZooKeeper and the HTTP services are unencrypted
- Public IP with direct access

### Cleanup

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

### Integration with ClickHouse

This Confluent Platform deployment can be integrated with ClickHouse using Kafka Connect:

1. Access the Connect API:
```bash
terraform output kafka_connect_url
```

2. Install the ClickHouse Sink Connector (if not already included)

3. Configure the connector to stream data from Kafka topics to ClickHouse tables

See the main repository for ClickHouse integration examples.

### Support

For issues or questions:

- Confluent Documentation: https://docs.confluent.io/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/
- Apache Kafka Documentation: https://kafka.apache.org/documentation/

### License

[MIT](../../../LICENSE), like the rest of the repository — the earlier wording granted nothing.
It is still educational material: it provisions real cloud resources that cost money, and
carries no warranty. The providers and services it calls have their own terms.

---

## 한국어

이 Terraform 구성은 Kafka, Schema Registry, Kafka Connect, ksqlDB, Control Center, REST Proxy를 포함한 완전한 Confluent Platform 스택을 AWS EC2에 배포합니다.

### 기능

- **완전한 Confluent Platform**: 모든 핵심 구성 요소(Kafka, ZooKeeper, Schema Registry, Connect, ksqlDB, Control Center, REST Proxy)
- **자동 설정**: Docker Compose로 명령 하나에 배포
- **샘플 데이터 프로듀서**: Kafka 토픽에 샘플 데이터를 자동으로 생성
- **설정 가능**: 인스턴스 유형, EBS 볼륨, 보안 그룹이 허용할 CIDR 블록
- **쉬운 관리**: 시작, 중지, 상태 확인용 스크립트

### 사전 준비

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- 적절한 권한이 있는 AWS 계정
- 자격 증명이 설정된 AWS CLI
- (선택) 원격 접속용 SSH 키 페어

### AWS 자격 증명 설정

AWS 자격 증명을 환경 변수로 설정합니다.

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # 임시 자격 증명을 쓰는 경우
export AWS_REGION="us-east-1"  # 선택: 기본 리전 설정
```

### 빠른 시작

#### 1. 클론 후 디렉터리로 이동

```bash
git clone https://github.com/litkhai/clickhouse-cloud-aws-hols.git
cd clickhouse-cloud-aws-hols/labs/kafka/terraform-confluent-aws
```

#### 2. 변수 설정

예시 구성을 복사합니다.

```bash
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`를 편집해 배포를 원하는 대로 바꿉니다.

```hcl
aws_region = "us-east-1"
instance_name = "my-confluent-server"
instance_type = "r5.xlarge"
key_pair_name = "my-key-pair"  # 선택: SSH 접속용
use_elastic_ip = false
```

#### 3. 배포

```bash
# Terraform 초기화
terraform init

# 배포 계획 검토
terraform plan

# 인프라 배포
terraform apply
```

배포에는 약 5-10분이 걸립니다. Terraform이 중요한 URL과 연결 정보를 모두 출력합니다.

#### 4. Confluent Platform 접속

배포가 끝나면 Control Center에 접속합니다.

```bash
# 출력값에서 Control Center URL 가져오기
terraform output control_center_url
```

브라우저에서 이 URL을 열어 Confluent Control Center Web UI에 접속합니다.

### 아키텍처

#### 배포되는 구성 요소

1. **EC2 인스턴스**: Docker가 설치된 Ubuntu 22.04 LTS
2. **ZooKeeper**: 클러스터 조정 (포트 2181)
3. **Kafka 브로커**: 메시지 스트리밍 (포트 9092, 9093)
4. **Schema Registry**: 스키마 관리 (포트 8081)
5. **Kafka Connect**: 데이터 통합 (포트 8083)
6. **ksqlDB**: 스트림 처리 (포트 8088)
7. **Control Center**: 관리용 Web UI (포트 9021)
8. **REST Proxy**: HTTP REST API (포트 8082)
9. **데이터 프로듀서**: 샘플 데이터를 생성하는 Systemd 서비스

#### 네트워크 구성

배포는 다음 인그레스 규칙을 가진 보안 그룹을 만듭니다. 모든 규칙은 `allowed_cidr_blocks`에만 열려 있습니다.

| 포트 | 서비스 | 설명 |
|------|---------|-------------|
| 2181 | ZooKeeper | 클러스터 조정 |
| 9092 | Kafka | `SASL_SSL` 브로커 접속 (외부) |
| 9093 | Kafka | `SASL_PLAINTEXT` 브로커 접속 (외부) |
| 8081 | Schema Registry | 스키마 관리 API |
| 8083 | Kafka Connect | Connect API |
| 8088 | ksqlDB | ksqlDB API |
| 8082 | REST Proxy | Kafka REST API |
| 9021 | Control Center | Web UI |
| 22 | SSH | 원격 접속 (키를 설정한 경우) |

#### SASL 인증

Kafka 브로커는 외부 클라이언트용으로 포트 **9092**(`SASL_SSL`)와 **9093**(`SASL_PLAINTEXT`)에 **SASL/PLAIN 인증**이 설정됩니다.

**인증 세부 정보:**
- **보안 프로토콜**: `SASL_SSL` (포트 9092, TLS) 또는 `SASL_PLAINTEXT` (포트 9093, 암호화 없음)
- **SASL 메커니즘**: `PLAIN`
- **자격 증명**: `kafka_sasl_username`(기본값 `admin`)과 `kafka_sasl_password`(필수, 기본값 없음)

**리스너 아키텍처:**
- **내부 (PLAINTEXT)**: `broker:29092` - Control Center, Schema Registry, Connect가 사용 (인증 없음)
- **외부 (SASL_SSL)**: `<PUBLIC_DNS>:9092` - 외부 클라이언트가 사용 (SASL 인증 필요, TLS)
- **외부 (SASL_PLAINTEXT)**: `<PUBLIC_DNS>:9093` - 외부 클라이언트가 사용 (SASL 인증 필요, 암호화 없음)

이 아키텍처는 **Confluent Cloud의 인증 모델**을 그대로 따르므로 ClickHouse 연동 워크숍과 실습에 이상적입니다.

##### SASL 연결 테스트

배포가 끝나면 올바른 IP 주소가 들어간 Python 테스트 스크립트가 EC2 인스턴스에 자동으로 생성됩니다.

```bash
# Terraform 출력값에서 테스트 명령 가져오기
terraform output -raw test_sasl_connection

# 테스트 스크립트 내려받기 (올바른 IP와 자격 증명이 이미 설정되어 있음)
scp -i /path/to/key.pem ubuntu@<instance-ip>:/opt/confluent/test_kafka_sasl.py .

# Python 패키지 설치
pip3 install confluent-kafka

# 테스트 실행
python3 test_kafka_sasl.py
```

테스트 스크립트는 다음을 자동으로 검증합니다.
- ✓ Admin 클라이언트 연결과 토픽 목록 조회
- ✓ 프로듀서가 SASL 인증으로 메시지 전송
- ✓ 컨슈머가 SASL 인증으로 메시지 읽기

Python, Java, Go, Node.js, ClickHouse의 자세한 연결 예시는 [SASL_CONNECTION_GUIDE.md](SASL_CONNECTION_GUIDE.md)를 참고하세요.

### 구성

#### 변수

| 변수 | 설명 | 기본값 | 필수 |
|----------|-------------|---------|----------|
| `aws_region` | 배포할 AWS 리전 | null (환경 변수 사용) | 아니요 |
| `instance_name` | EC2 인스턴스의 Name 태그 | "confluent-server" | 아니요 |
| `instance_type` | EC2 인스턴스 유형 | "r5.xlarge" | 아니요 |
| `ebs_volume_size` | EBS 볼륨 크기(GB) | 100 | 아니요 |
| `key_pair_name` | SSH 키 페어 이름 | null | 아니요 |
| `allowed_cidr_blocks` | SSH와 브로커 포트에 접근할 수 있는 대상. `0.0.0.0/0`은 거부됨 | - | **예** |
| `use_elastic_ip` | Elastic IP 할당 | false | 아니요 |
| `confluent_version` | Confluent Platform 버전 | "7.5.0" | 아니요 |
| `sample_topic_name` | 샘플 토픽 이름 | "sample-data-topic" | 아니요 |
| `data_producer_interval` | 데이터 생성 간격(초) | 5 | 아니요 |
| `kafka_sasl_username` | Kafka SASL 사용자명 | "admin" | 아니요 |
| `kafka_sasl_password` | Kafka SASL 비밀번호 (sensitive) | - | **예** |

#### 인스턴스 유형 권장

- **개발**: `t3.xlarge` (4 vCPU, 16 GB RAM)
- **테스트**: `r5.xlarge` (4 vCPU, 32 GB RAM) - **기본값**
- **프로덕션**: `r5.2xlarge` 이상 (8+ vCPU, 64+ GB RAM)

### 관리

#### SSH 접속

키 페어를 설정했다면:

```bash
# 출력값에서 SSH 명령 가져오기
terraform output ssh_command

# 또는 직접 연결
ssh -i /path/to/your-key.pem ubuntu@<instance-ip>
```

#### 관리 스크립트

SSH로 접속한 뒤 다음 스크립트를 사용합니다.

```bash
# 모든 서비스의 상태 확인
sudo /opt/confluent/status.sh

# Confluent Platform 중지
sudo /opt/confluent/stop.sh

# Confluent Platform 시작
sudo /opt/confluent/start.sh

# 데이터 프로듀서 로그 보기
sudo journalctl -u confluent-producer -f
```

#### Kafka 사용

##### Kafka 리스너 이해하기

Kafka에는 **리스너 세 개**가 설정됩니다.

- **PLAINTEXT (포트 29092)**: 내부 Docker 네트워크 통신, 인증 없음 (호스트에 게시되지 않음)
- **SASL_SSL (포트 9092)**: TLS 위의 SASL/PLAIN으로 외부 클라이언트 접속 (`allowed_cidr_blocks`에서)
- **SASL_PLAINTEXT (포트 9093)**: SASL/PLAIN으로 외부 클라이언트 접속, 암호화 없음 (`allowed_cidr_blocks`에서)

아래 명령은 브로커 컨테이너 안에서 실행되며, 클라이언트 설정이 필요 없는 내부 리스너 `localhost:29092`를 사용합니다.

##### 토픽 목록 보기 (SSH에서)

```bash
# 인스턴스 안에서
docker exec broker kafka-topics --list --bootstrap-server localhost:29092
```

##### 메시지 소비 (SSH에서)

```bash
# 인스턴스 안에서
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic sample-data-topic \
  --from-beginning
```

##### 메시지 생산 (SSH에서)

```bash
# 인스턴스 안에서
docker exec -i broker kafka-console-producer \
  --broker-list localhost:29092 \
  --topic sample-data-topic
```

#### 외부 애플리케이션에서 연결

외부 클라이언트는 포트 **9092**(`SASL_SSL`, Confluent Cloud와 같음) 또는 **9093**(`SASL_PLAINTEXT`)으로 연결합니다.

```bash
# 외부 bootstrap 서버 가져오기
terraform output kafka_bootstrap_servers             # SASL_SSL, 포트 9092
terraform output kafka_bootstrap_servers_plaintext   # SASL_PLAINTEXT, 포트 9093

# 출력 예시: <public-dns>:9092
```

##### 외부 연결 테스트

```bash
# 연결 테스트
nc -zv <public-ip> 9092
nc -zv <public-ip> 9093

# 로컬 머신에서 Kafka API 테스트 (kafka 도구와, SASL을 쓰는 명령줄 도구의 설정을 담은 client.properties 필요)
kafka-broker-api-versions --bootstrap-server <public-ip>:9093 --command-config client.properties
```

##### 예시: 외부 Python 클라이언트 (SASL 인증 사용)

```python
from kafka import KafkaProducer, KafkaConsumer

# Terraform 출력값에서 자격 증명 가져오기
# terraform output kafka_sasl_username
# terraform output -raw kafka_sasl_password

# 프로듀서
producer = KafkaProducer(
    bootstrap_servers=['<public-ip>:9093'],
    security_protocol='SASL_PLAINTEXT',
    sasl_mechanism='PLAIN',
    sasl_plain_username='admin',  # 설정한 kafka_sasl_username
    sasl_plain_password='admin-secret'  # 설정한 kafka_sasl_password
)
producer.send('sample-data-topic', b'Hello from external client')
producer.flush()

# 컨슈머
consumer = KafkaConsumer(
    'sample-data-topic',
    bootstrap_servers=['<public-ip>:9093'],
    security_protocol='SASL_PLAINTEXT',
    sasl_mechanism='PLAIN',
    sasl_plain_username='admin',  # 설정한 kafka_sasl_username
    sasl_plain_password='admin-secret',  # 설정한 kafka_sasl_password
    auto_offset_reset='earliest'
)
for message in consumer:
    print(message.value)
```

##### 포트 요약

| 포트 | 리스너 | 접속 위치 | 용도 |
|------|----------|-------------|----------|
| 29092 | PLAINTEXT | Docker 컨테이너 | 내부 서비스 통신 |
| **9092** | **SASL_SSL** | **`allowed_cidr_blocks`** | **TLS 위에서 SASL 인증을 쓰는 외부 클라이언트** |
| **9093** | **SASL_PLAINTEXT** | **`allowed_cidr_blocks`** | **SASL 인증을 쓰는 외부 클라이언트, 암호화 없음** |

#### SASL 인증

Kafka 브로커에는 **SASL/PLAIN 인증**이 설정됩니다 (Confluent Cloud의 API Key/Secret 모델과 같은 방식).

##### 자격 증명 가져오기

```bash
# 사용자명 가져오기 (API Key)
terraform output kafka_sasl_username

# 비밀번호 가져오기 (API Secret)
terraform output -raw kafka_sasl_password
```

자격 증명:
- **사용자명 (API Key)**: `kafka_sasl_username`, 기본값 `admin`
- **비밀번호 (API Secret)**: `kafka_sasl_password`, 필수이며 기본값 없음. `terraform.tfvars.example`에는 `admin-secret`이 들어 있음

⚠️ **보안 경고**: `terraform.tfvars.example`의 예시 값을 직접 정한 값으로 바꾸세요. `terraform.tfvars`를 편집합니다.
```hcl
kafka_sasl_username = "your-api-key"
kafka_sasl_password = "your-secret-key"
```

##### SASL을 쓰는 명령줄 도구

```bash
# 브로커 컨테이너 안에 클라이언트 설정 만들기 (설정한 kafka_sasl_username과 kafka_sasl_password 사용)
docker exec broker bash -c 'cat > /tmp/client.properties << EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";
EOF'

# 토픽 목록 보기 (인스턴스 안에서)
docker exec broker kafka-topics --list \
  --bootstrap-server localhost:9093 \
  --command-config /tmp/client.properties

# 메시지 소비 (인스턴스 안에서)
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:9093 \
  --topic sample-data-topic \
  --from-beginning \
  --consumer.config /tmp/client.properties

# 메시지 생산 (인스턴스 안에서)
docker exec -i broker kafka-console-producer \
  --broker-list localhost:9093 \
  --topic sample-data-topic \
  --producer.config /tmp/client.properties
```

##### Java 클라이언트 구성

```java
Properties props = new Properties();
props.put("bootstrap.servers", "<public-ip>:9093");
props.put("security.protocol", "SASL_PLAINTEXT");
props.put("sasl.mechanism", "PLAIN");
props.put("sasl.jaas.config",
  "org.apache.kafka.common.security.plain.PlainLoginModule required " +
  "username=\"admin\" password=\"admin-secret\";");

KafkaProducer<String, String> producer = new KafkaProducer<>(props);
```

##### Node.js 클라이언트 구성

```javascript
const { Kafka } = require('kafkajs');

const kafka = new Kafka({
  brokers: ['<public-ip>:9093'],
  sasl: {
    mechanism: 'plain',
    username: 'admin',
    password: 'admin-secret'
  }
});

const producer = kafka.producer();
const consumer = kafka.consumer({ groupId: 'my-group' });
```

### 샘플 데이터 형식

데이터 프로듀서는 다음 구조의 JSON 메시지를 생성합니다.

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

이벤트 유형: `page_view`, `click`, `purchase`, `signup`, `logout`

### 모니터링

#### Control Center

포트 9021에서 Confluent Control Center에 접속합니다.

- 클러스터 상태 보기
- 토픽과 컨슈머 모니터링
- 커넥터 관리
- ksqlDB 쿼리 실행
- 메트릭과 알림 보기

#### Docker Compose

```bash
# 모든 컨테이너 상태 보기
docker compose ps

# 특정 컨테이너 로그 보기
docker logs broker -f
docker logs control-center -f

# 리소스 사용량 보기
docker stats
```

### 출력값 (`outputs`)

배포가 끝나면 Terraform이 다음을 제공합니다.

- `instance_id`: EC2 인스턴스 ID
- `instance_public_ip`: 퍼블릭 IP 주소
- `control_center_url`: Control Center Web UI URL
- `schema_registry_url`: Schema Registry API URL
- `kafka_connect_url`: Kafka Connect API URL
- `ksqldb_url`: ksqlDB Server API URL
- `rest_proxy_url`: REST Proxy API URL
- `kafka_bootstrap_servers`: 외부 연결용 Kafka bootstrap 서버
- `ssh_command`: SSH 연결 명령
- `useful_commands`: 빠른 참조용 명령

### 문제 해결

#### 서비스가 시작되지 않을 때

Docker 컨테이너 상태를 확인합니다.

```bash
docker compose ps
docker compose logs
```

#### Control Center에 접속할 수 없을 때

1. 보안 그룹이 내 IP에서의 접근을 허용하는지 확인합니다
2. Docker 컨테이너가 실행 중인지 확인합니다
3. 배포 후 서비스가 완전히 시작될 때까지 2-3분 기다립니다

#### 데이터 프로듀서가 실행되지 않을 때

```bash
# 서비스 상태 확인
sudo systemctl status confluent-producer

# 서비스 재시작
sudo systemctl restart confluent-producer

# 로그 보기
sudo journalctl -u confluent-producer -f
```

#### Kafka 연결 문제

SASL을 쓰는 명령줄 도구의 클라이언트 설정으로 외부 `SASL_PLAINTEXT` 리스너가 응답하는지 확인합니다.

```bash
docker exec broker kafka-broker-api-versions --bootstrap-server localhost:9093 --command-config /tmp/client.properties
```

### 비용 고려 사항

예상 AWS 비용 (us-east-1 리전):

- **r5.xlarge 인스턴스**: 약 $0.25/시간 (약 $180/월)
- **EBS gp3 볼륨 (100 GB)**: 약 $8/월
- **데이터 전송**: 사용량에 따라 달라짐
- **Elastic IP** (활성화한 경우): 인스턴스가 중지된 동안 $0.005/시간

**총 예상 비용**: 24/7 운영 시 약 $190-200/월

실습을 작성할 때의 추정치이며 측정한 값이 아닙니다. 사용하는 리전의 현재 AWS 요금을 확인하세요.

#### 비용 최적화

1. **사용하지 않을 때는 중지**: 끝나면 `terraform destroy`
2. **더 작은 인스턴스 사용**: 개발용으로는 `t3.xlarge`로 변경
3. **EBS 볼륨 줄이기**: 스토리지가 덜 필요하면 `ebs_volume_size` 조정
4. **Elastic IP 비활성화**: `use_elastic_ip = false` 설정

### 보안 모범 사례

#### 프로덕션 사용 시

1. **CIDR 블록 제한**: `allowed_cidr_blocks`를 내 IP 범위로 제한
2. **암호화**: 9093의 `SASL_PLAINTEXT` 대신 9092의 `SASL_SSL` 사용. HTTP 서비스에 TLS 추가
3. **인증**: SASL/PLAIN은 Kafka 리스너에만 적용됨. ZooKeeper와 HTTP 서비스에 인증 추가
4. **프라이빗 서브넷 사용**: bastion 호스트를 두고 프라이빗 서브넷에 배포
5. **CloudWatch 활성화**: 모니터링과 알림 추가
6. **데이터 백업**: EBS 스냅샷 설정
7. **secrets manager 사용**: 자격 증명을 AWS Secrets Manager에 저장

#### 현재 보안 상태

⚠️ **경고**: 기본 구성은 개발/테스트 전용입니다

- 모든 브로커 포트가 `allowed_cidr_blocks`에 설정한 범위에 열려 있음 (`0.0.0.0/0`은 거부됨)
- 외부 Kafka 리스너 9092와 9093에는 SASL/PLAIN이 있음. 내부 `PLAINTEXT` 리스너 29092 (Docker 네트워크 전용), ZooKeeper, HTTP 서비스(8081, 8082, 8083, 8088, 9021)에는 인증 없음
- TLS는 9092(`SASL_SSL`, 인스턴스에서 만든 CA가 서명한 인증서)에만 있음. 9093, 29092, ZooKeeper, HTTP 서비스는 암호화되지 않음
- 직접 접근할 수 있는 퍼블릭 IP

### 정리

모든 리소스를 삭제하려면:

```bash
terraform destroy
```

이 명령은 다음을 수행합니다.
- EC2 인스턴스 종료
- 보안 그룹 삭제
- Elastic IP 해제 (할당한 경우)
- 연관된 모든 리소스 제거

**참고**: 되돌릴 수 없으며 인스턴스의 모든 데이터가 삭제됩니다.

### ClickHouse 연동

이 Confluent Platform 배포는 Kafka Connect를 사용해 ClickHouse와 연동할 수 있습니다.

1. Connect API에 접속합니다.
```bash
terraform output kafka_connect_url
```

2. ClickHouse 싱크 커넥터를 설치합니다 (아직 포함되어 있지 않다면)

3. Kafka 토픽의 데이터를 ClickHouse 테이블로 스트리밍하도록 커넥터를 설정합니다

ClickHouse 연동 예시는 메인 저장소를 참고하세요.

### 지원

문제나 질문이 있으면:

- Confluent 문서: https://docs.confluent.io/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/
- Apache Kafka 문서: https://kafka.apache.org/documentation/

### 라이선스

저장소의 나머지와 마찬가지로 [MIT](../../../LICENSE)입니다 — 이전 문구는 아무 권리도 부여하지 않았습니다.
그래도 이것은 교육용 자료입니다. 비용이 드는 실제 클라우드 리소스를 만들고,
어떤 보증도 하지 않습니다. 이 자료가 호출하는 provider와 서비스에는 각자의 약관이 있습니다.
