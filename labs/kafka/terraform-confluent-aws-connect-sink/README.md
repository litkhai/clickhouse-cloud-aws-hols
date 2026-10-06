# Confluent Platform with ClickHouse Sink Connector on AWS

> **Last verified: 2025-11-24** — date of the last commit made while running the lab (there is no separate run log). AWS provider `~> 5.0`.
> Changed since without a full re-run:
> - 2026-07-28 — the Kafka SASL password moved from a hard-coded default to a required variable; the username still defaults to `admin` (not run)
> - 2026-08-10 — `allowed_cidr_blocks` is required and rejects `0.0.0.0/0` (checked with `terraform plan` on 1.15.8, not applied)
> - 2026-10-06 — `user-data.sh` no longer prints the SASL password to the cloud-init log ([#30](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/30); not run)
>
> Not checked — adjust before `apply` (recorded 2026-10-04 from reading the code; nothing was run):
> - AWS provider: `~> 5.0` resolves to 5.100.0, the last 5.x release; never run on 6.x (6.67.0 is the newest, Terraform Registry API read 2026-10-04).
> - SASL: `user-data.sh` puts the username and password unescaped into the JAAS config and `docker-compose.yml`; every run so far used `admin` / `admin-secret`. Use letters and digits only — `"` breaks the quoting and `$` is expanded by the shell.
> - The SASL password is still in the instance's user data (`main.tf` passes it to `templatefile`).
> - Not pinned: the AMI (newest Canonical Ubuntu 22.04 at `apply` time), `clickhouse/clickhouse-kafka-connect:latest` and `confluent-hub-client-latest` (both in `user-data.sh`). Confluent images are pinned by `confluent_version` (default `7.5.0`).
> - Run path: there is no `deploy.sh` / `destroy.sh` — `terraform apply` → `terraform destroy`.
> - A re-run should show: rows from the sample producer arrive in the ClickHouse Cloud table, and a SASL client from an address outside `allowed_cidr_blocks` cannot connect.
>
> **마지막 검증: 2025-11-24** — 실습을 실행하며 남긴 마지막 커밋 날짜 (별도 실행 기록은 없음). AWS provider `~> 5.0`.
> 그 뒤 전체 재실행 없이 바뀐 것:
> - 2026-07-28 — Kafka SASL 비밀번호가 하드코딩 기본값에서 필수 변수로 바뀜. 사용자명은 여전히 기본값 `admin` (실행 안 함)
> - 2026-08-10 — `allowed_cidr_blocks` 필수화, `0.0.0.0/0` 거부 (terraform 1.15.8에서 `plan`까지만 확인, apply 안 함)
> - 2026-10-06 — `user-data.sh`가 SASL 비밀번호를 cloud-init 로그에 더 이상 출력하지 않음 ([#30](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/30), 실행 안 함)
>
> 확인 안 된 것 — `apply` 전에 맞출 것 (2026-10-04 코드를 읽고 기록, 실행 안 함):
> - AWS provider: `~> 5.0`은 마지막 5.x인 5.100.0으로 잡힘. 6.x에서는 실행한 적 없음 (최신 6.67.0, 2026-10-04 Terraform Registry API로 확인).
> - SASL: `user-data.sh`가 사용자명·비밀번호를 이스케이프 없이 JAAS 설정과 `docker-compose.yml`에 넣음. 지금까지 실행은 모두 `admin` / `admin-secret`. 영문자와 숫자만 쓸 것 — `"`는 따옴표를 깨고 `$`는 셸이 치환함.
> - SASL 비밀번호는 여전히 인스턴스 user data에 들어 있음 (`main.tf`가 `templatefile`에 넘김).
> - 고정 안 된 것: AMI (`apply` 시점의 최신 Canonical Ubuntu 22.04), `clickhouse/clickhouse-kafka-connect:latest`, `confluent-hub-client-latest` (둘 다 `user-data.sh`). Confluent 이미지는 `confluent_version`(기본 `7.5.0`)으로 고정.
> - 실행 경로: `deploy.sh` / `destroy.sh`가 없음 — `terraform apply` → `terraform destroy`.
> - 재실행에서 보여야 할 것: 샘플 producer의 행이 ClickHouse Cloud 테이블에 들어오고, `allowed_cidr_blocks` 밖 주소의 SASL 클라이언트는 연결되지 않음.

[English](#english) | [한국어](#한국어)

## English

This Terraform configuration deploys a complete Confluent Platform stack on AWS EC2 with ClickHouse Sink Connector pre-installed, enabling automatic data streaming from Kafka topics to ClickHouse Cloud.

### Features

- **Complete Confluent Platform**: All core components (Kafka, ZooKeeper, Schema Registry, Connect, ksqlDB, Control Center, REST Proxy)
- **ClickHouse Sink Connector**: Pre-installed and ready to stream data to ClickHouse Cloud
- **Automated Setup**: One-command deployment with Docker Compose
- **Sample Data Producer**: Automatically generates sample data to demonstrate the pipeline
- **SASL Authentication**: SASL/PLAIN on the external broker listeners, `SASL_SSL` on 9092 and `SASL_PLAINTEXT` on 9093 (like Confluent Cloud)
- **Easy Management**: Scripts for start, stop, and status checking

### Architecture

```
Sample Data Producer → Kafka Topic → ClickHouse Sink Connector → ClickHouse Cloud
                          ↓
                   Control Center (Monitoring)
```

### Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- ClickHouse Cloud account (optional - can be configured later)
- SSH key pair for remote access (optional)

### Quick Start

#### 1. Clone and Navigate

```bash
git clone https://github.com/litkhai/clickhouse-cloud-aws-hols.git
cd clickhouse-cloud-aws-hols/labs/kafka/terraform-confluent-aws-connect-sink
```

#### 2. Configure Variables

Copy the example configuration:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to customize your deployment:

```hcl
# AWS Configuration
aws_region = "us-east-1"
instance_name = "confluent-clickhouse-demo"
instance_type = "r5.xlarge"
key_pair_name = "my-key-pair"  # Optional: for SSH access

# Network Configuration (required; 0.0.0.0/0 is rejected)
allowed_cidr_blocks = ["203.0.113.4/32"]  # replace with yours

# Kafka SASL Authentication (the password is required, no default)
kafka_sasl_password = "admin-secret"

# ClickHouse Cloud Configuration (optional - can be added later)
clickhouse_host     = "your-instance.clickhouse.cloud"
clickhouse_port     = 8443
clickhouse_database = "default"
clickhouse_username = "default"
clickhouse_password = "your-password"
clickhouse_table    = "kafka_events"
clickhouse_use_ssl  = true
```

#### 3. Deploy

```bash
# Set AWS credentials
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"

# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply
```

The deployment takes about 10-15 minutes. Terraform will output all important URLs and connection information.

#### 4. Access Confluent Control Center

After deployment completes:

```bash
# Get the Control Center URL
terraform output control_center_url
```

Open the URL in your browser to access the Confluent Control Center Web UI, where you can:
- Monitor Kafka topics and messages
- View connector status
- Manage ClickHouse Sink Connector
- Track data flow from Kafka to ClickHouse

### ClickHouse Cloud Setup

#### Option 1: Configure During Deployment

Add ClickHouse Cloud credentials to `terraform.tfvars` before running `terraform apply`. The ClickHouse Sink Connector will be automatically created and started.

#### Option 2: Configure After Deployment

If you didn't configure ClickHouse during deployment, you can add it later:

1. SSH into the instance:
```bash
ssh -i /path/to/your-key.pem ubuntu@<instance-dns>
```

2. Edit the connector creation script:
```bash
sudo nano /opt/confluent/create-clickhouse-sink.sh
```

3. Update the ClickHouse connection details and run:
```bash
sudo /opt/confluent/create-clickhouse-sink.sh
```

#### Create ClickHouse Table

Before the connector can write data, create a table in ClickHouse Cloud:

```sql
CREATE TABLE default.kafka_events
(
    event_id UInt64,
    timestamp DateTime64(3),
    user_id UInt32,
    event_type String,
    value UInt32,
    metadata Tuple(source String, version String)
)
ENGINE = MergeTree()
ORDER BY (timestamp, event_id);
```

### Connector Management

#### Check Connector Status

```bash
# Get the status command from Terraform outputs
terraform output clickhouse_connector_status

# Or directly
curl http://<instance-dns>:8083/connectors/clickhouse-sink-connector/status | jq '.'
```

#### List All Connectors

```bash
curl http://<instance-dns>:8083/connectors | jq '.'
```

#### View Connector Configuration

```bash
curl http://<instance-dns>:8083/connectors/clickhouse-sink-connector | jq '.'
```

#### Delete and Recreate Connector

```bash
# Delete
curl -X DELETE http://<instance-dns>:8083/connectors/clickhouse-sink-connector

# Recreate
ssh -i /path/to/your-key.pem ubuntu@<instance-dns> 'sudo /opt/confluent/create-clickhouse-sink.sh'
```

### Monitoring Data Flow

#### 1. Watch Kafka Producer Logs

```bash
ssh -i /path/to/your-key.pem ubuntu@<instance-dns> 'sudo journalctl -u confluent-producer -f'
```

#### 2. Check Kafka Topic Messages

```bash
# From the EC2 instance
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic sample-data-topic \
  --from-beginning
```

#### 3. Verify Data in ClickHouse Cloud

```sql
-- Check record count
SELECT count() FROM default.kafka_events;

-- View recent events
SELECT * FROM default.kafka_events ORDER BY timestamp DESC LIMIT 10;

-- Analyze by event type
SELECT event_type, count() as count FROM default.kafka_events GROUP BY event_type;
```

### Sample Data Format

The data producer generates JSON messages with this structure:

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

### Configuration

#### Terraform Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `aws_region` | AWS region for deployment | null (uses env var) | No |
| `instance_name` | Name tag for EC2 instance | "confluent-server" | No |
| `instance_type` | EC2 instance type | "r5.xlarge" | No |
| `ebs_volume_size` | Size of the EBS volume in GB | 100 | No |
| `key_pair_name` | SSH key pair name | null | No |
| `allowed_cidr_blocks` | Who may reach SSH and every service port. `0.0.0.0/0` is rejected | - | **Yes** |
| `use_elastic_ip` | Allocate and associate an Elastic IP | false | No |
| `confluent_version` | Confluent Platform version tag | "7.5.0" | No |
| `sample_topic_name` | Name of the sample topic | "sample-data-topic" | No |
| `data_producer_interval` | Seconds between sample messages (must be > 0) | 5 | No |
| `kafka_sasl_username` | Kafka SASL username | "admin" | No |
| `kafka_sasl_password` | Kafka SASL password | - | **Yes** |
| `clickhouse_host` | ClickHouse Cloud host | null | No |
| `clickhouse_port` | ClickHouse Cloud port | 8443 | No |
| `clickhouse_database` | ClickHouse database | "default" | No |
| `clickhouse_username` | ClickHouse username | "default" | No |
| `clickhouse_password` | ClickHouse password | null | No |
| `clickhouse_table` | Target table name | "kafka_events" | No |
| `clickhouse_use_ssl` | Use SSL for ClickHouse | true | No |

#### Instance Type Recommendations

- **Development**: `t3.xlarge` (4 vCPU, 16 GB RAM)
- **Testing**: `r5.xlarge` (4 vCPU, 32 GB RAM) - **Default**
- **Production**: `r5.2xlarge` or larger (8+ vCPU, 64+ GB RAM)

### Service Endpoints

After deployment, access these services:

| Service | Port | Description |
|---------|------|-------------|
| Control Center | 9021 | Web UI for management |
| Kafka Connect | 8083 | Connector management API |
| Schema Registry | 8081 | Schema management |
| ksqlDB Server | 8088 | Stream processing |
| Kafka Broker (SASL_SSL) | 9092 | Secure Kafka access |
| Kafka Broker (SASL_PLAINTEXT) | 9093 | Kafka access (fallback) |

### Kafka Authentication

The deployment uses SASL/PLAIN authentication (like Confluent Cloud):

```bash
# Get credentials
terraform output kafka_sasl_username
terraform output -raw kafka_sasl_password
```

Credentials:
- **Username**: `kafka_sasl_username`, default `admin`
- **Password**: `kafka_sasl_password`, required with no default (`terraform.tfvars.example` sets `admin-secret`)

### Management Scripts

Once SSH connected, use these scripts:

```bash
# Check status of all services
sudo /opt/confluent/status.sh

# Stop Confluent Platform
sudo /opt/confluent/stop.sh

# Start Confluent Platform
sudo /opt/confluent/start.sh

# Create/recreate ClickHouse Sink Connector
sudo /opt/confluent/create-clickhouse-sink.sh
```

### Troubleshooting

#### Connector Not Creating

1. Check Kafka Connect logs:
```bash
docker logs connect -f
```

2. Verify ClickHouse connectivity:
```bash
# From the EC2 instance
curl -v https://<clickhouse-host>:8443/
```

3. Check connector plugins:
```bash
curl http://localhost:8083/connector-plugins | jq '.'
```

#### No Data Flowing to ClickHouse

1. Check connector status:
```bash
curl http://localhost:8083/connectors/clickhouse-sink-connector/status | jq '.'
```

2. Look for errors in connector tasks:
```bash
curl http://localhost:8083/connectors/clickhouse-sink-connector/status | jq '.tasks[].trace'
```

3. Verify the ClickHouse table exists and schema matches

4. Check Kafka topic has data:
```bash
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic sample-data-topic \
  --max-messages 10
```

#### Connector Shows FAILED Status

Common issues:
- **Authentication failed**: Check ClickHouse username/password
- **Table not found**: Create the table in ClickHouse
- **Network issues**: Verify security groups allow outbound HTTPS
- **SSL/TLS errors**: Ensure `clickhouse_use_ssl` matches your ClickHouse setup

View detailed error:
```bash
curl http://localhost:8083/connectors/clickhouse-sink-connector/status | jq '.tasks[0].trace'
```

### Demo Walkthrough

#### Complete End-to-End Test

1. **Deploy the infrastructure**:
```bash
terraform apply
```

2. **Access Control Center**:
```bash
open $(terraform output -raw control_center_url)
```

3. **Verify Kafka topic exists**:
   - Navigate to "Topics" in Control Center
   - Find `sample-data-topic`
   - View messages flowing in

4. **Check connector status**:
   - Navigate to "Connect" → "connect-default"
   - View `clickhouse-sink-connector`
   - Verify status is "Running"

5. **Query ClickHouse Cloud**:
```sql
SELECT count() FROM default.kafka_events;
SELECT event_type, count(*) FROM default.kafka_events GROUP BY event_type;
```

6. **Watch real-time data flow**:
```bash
# Terminal 1: Watch Kafka producer
ssh -i key.pem ubuntu@<dns> 'sudo journalctl -u confluent-producer -f'

# Terminal 2: Query ClickHouse every few seconds
watch -n 5 "clickhouse-client --host <host> --query 'SELECT count() FROM default.kafka_events'"
```

### Cost Considerations

Estimated AWS costs (us-east-1 region):

- **r5.xlarge instance**: ~$0.25/hour (~$180/month)
- **EBS gp3 volume (100 GB)**: ~$8/month
- **Data transfer**: Variable based on usage
- **Total estimated cost**: ~$190-200/month for 24/7 operation

These are estimates from when the lab was written, not measured; check current AWS pricing for your region.

#### Cost Optimization

1. **Stop when not in use**: `terraform destroy` when done
2. **Use smaller instance**: Change to `t3.xlarge` for development
3. **Reduce EBS volume**: Adjust `ebs_volume_size` if less storage needed

### Security Best Practices

#### For Production Use

1. **Restrict CIDR blocks**: Limit `allowed_cidr_blocks` to your IP ranges
2. **Use strong passwords**: Replace the example `kafka_sasl_password` (`admin-secret` in `terraform.tfvars.example`) and set a strong `clickhouse_password`
3. **Enable CloudWatch**: Add monitoring and alerting
4. **Use private subnets**: Deploy in private subnet with bastion host
5. **Secrets management**: Store credentials in AWS Secrets Manager
6. **Regular updates**: Keep Confluent Platform version updated

#### Current Security Posture

⚠️ **Warning**: Default configuration is for development/testing only

- Every broker port open to whatever `allowed_cidr_blocks` is set to (`0.0.0.0/0` is rejected)
- SASL username defaults to `admin`; the password is the one you set (`admin-secret` in `terraform.tfvars.example`)
- Public IP with direct access

### Outputs

After deployment, Terraform provides:

- `control_center_url`: Control Center web UI URL
- `kafka_connect_url`: Kafka Connect API URL
- `kafka_bootstrap_servers`: Kafka bootstrap servers
- `clickhouse_host`: Configured ClickHouse host
- `clickhouse_connector_status`: Command to check connector status
- `clickhouse_connector_commands`: Useful connector management commands

View all outputs:
```bash
terraform output
```

### Cleanup

To destroy all resources:

```bash
terraform destroy
```

This will:
- Terminate the EC2 instance
- Delete the security group
- Remove all associated resources

**Note**: This is irreversible and will delete all data on the instance.

### Advanced Configuration

#### Custom Connector Configuration

Edit `/opt/confluent/create-clickhouse-sink.sh` on the EC2 instance to customize:

- Batch size
- Flush interval
- Error handling
- Data transformation
- Multiple topics

Example custom configuration:

```json
{
  "name": "clickhouse-sink-connector",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "2",
    "topics": "sample-data-topic,another-topic",
    "hostname": "your-instance.clickhouse.cloud",
    "port": "8443",
    "database": "default",
    "batch.size": "10000",
    "buffer.flush.time": "1000"
  }
}
```

#### Multiple Connectors

Create additional connectors for different topics:

```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "another-clickhouse-sink",
    "config": {
      "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
      "topics": "another-topic",
      ...
    }
  }'
```

### Related Projects

- [terraform-confluent-aws](../terraform-confluent-aws): Base Confluent Platform without ClickHouse
- [ClickHouse Cloud](https://clickhouse.com/cloud): Managed ClickHouse service

### Support

For issues or questions:

- Confluent Documentation: https://docs.confluent.io/
- ClickHouse Documentation: https://clickhouse.com/docs
- ClickHouse Kafka Connect: https://github.com/ClickHouse/clickhouse-kafka-connect

### License

[MIT](../../../LICENSE), like the rest of the repository — the earlier wording granted nothing.
It is still educational material: it provisions real cloud resources that cost money, and
carries no warranty. The providers and services it calls have their own terms.

---

## 한국어

이 Terraform 구성은 ClickHouse Sink Connector가 미리 설치된 Confluent Platform 스택 전체를 AWS EC2에 배포해, Kafka 토픽의 데이터가 ClickHouse Cloud로 자동으로 스트리밍되게 합니다.

### 기능

- **완전한 Confluent Platform**: 모든 핵심 구성 요소 (Kafka, ZooKeeper, Schema Registry, Connect, ksqlDB, Control Center, REST Proxy)
- **ClickHouse Sink Connector**: 미리 설치되어 있어 ClickHouse Cloud로 바로 데이터를 스트리밍할 수 있음
- **자동 설정**: Docker Compose로 명령 하나에 배포
- **샘플 데이터 프로듀서**: 파이프라인을 보여 주는 샘플 데이터를 자동으로 생성
- **SASL 인증**: 외부 브로커 리스너에서 SASL/PLAIN 사용, 9092는 `SASL_SSL`, 9093은 `SASL_PLAINTEXT` (Confluent Cloud와 같은 방식)
- **쉬운 관리**: 시작, 중지, 상태 확인용 스크립트

### 아키텍처

```
Sample Data Producer → Kafka Topic → ClickHouse Sink Connector → ClickHouse Cloud
                          ↓
                   Control Center (Monitoring)
```

### 사전 준비

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- 적절한 권한이 있는 AWS 계정
- 자격 증명이 설정된 AWS CLI
- ClickHouse Cloud 계정 (선택 사항 - 나중에 설정할 수 있음)
- 원격 접속용 SSH 키 페어 (선택 사항)

### 빠른 시작

#### 1. 클론하고 디렉터리로 이동

```bash
git clone https://github.com/litkhai/clickhouse-cloud-aws-hols.git
cd clickhouse-cloud-aws-hols/labs/kafka/terraform-confluent-aws-connect-sink
```

#### 2. 변수 설정

예제 구성을 복사합니다.

```bash
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`를 편집해 배포를 원하는 대로 바꿉니다.

```hcl
# AWS 설정
aws_region = "us-east-1"
instance_name = "confluent-clickhouse-demo"
instance_type = "r5.xlarge"
key_pair_name = "my-key-pair"  # 선택 사항: SSH 접속용

# 네트워크 설정 (필수, 0.0.0.0/0은 거부됨)
allowed_cidr_blocks = ["203.0.113.4/32"]  # 자신의 주소로 바꿀 것

# Kafka SASL 인증 (비밀번호는 필수, 기본값 없음)
kafka_sasl_password = "admin-secret"

# ClickHouse Cloud 설정 (선택 사항 - 나중에 추가할 수 있음)
clickhouse_host     = "your-instance.clickhouse.cloud"
clickhouse_port     = 8443
clickhouse_database = "default"
clickhouse_username = "default"
clickhouse_password = "your-password"
clickhouse_table    = "kafka_events"
clickhouse_use_ssl  = true
```

#### 3. 배포

```bash
# AWS 자격 증명 설정
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"

# Terraform 초기화
terraform init

# 배포 계획 검토
terraform plan

# 인프라 배포
terraform apply
```

배포에는 10-15분쯤 걸립니다. Terraform이 중요한 URL과 연결 정보를 모두 출력합니다.

#### 4. Confluent Control Center 접속

배포가 끝나면 다음을 실행합니다.

```bash
# Control Center URL 확인
terraform output control_center_url
```

브라우저에서 이 URL을 열면 Confluent Control Center 웹 UI에 접속합니다. 여기서 할 수 있는 일은 다음과 같습니다.
- Kafka 토픽과 메시지 모니터링
- 커넥터 상태 보기
- ClickHouse Sink Connector 관리
- Kafka에서 ClickHouse로 가는 데이터 흐름 추적

### ClickHouse Cloud 설정

#### 방법 1: 배포할 때 설정

`terraform apply`를 실행하기 전에 ClickHouse Cloud 자격 증명을 `terraform.tfvars`에 넣습니다. ClickHouse Sink Connector가 자동으로 만들어지고 시작됩니다.

#### 방법 2: 배포한 뒤 설정

배포할 때 ClickHouse를 설정하지 않았다면 나중에 추가할 수 있습니다.

1. 인스턴스에 SSH로 접속합니다.
```bash
ssh -i /path/to/your-key.pem ubuntu@<instance-dns>
```

2. 커넥터 생성 스크립트를 편집합니다.
```bash
sudo nano /opt/confluent/create-clickhouse-sink.sh
```

3. ClickHouse 연결 정보를 고친 뒤 실행합니다.
```bash
sudo /opt/confluent/create-clickhouse-sink.sh
```

#### ClickHouse 테이블 만들기

커넥터가 데이터를 쓰려면 먼저 ClickHouse Cloud에 테이블을 만들어야 합니다.

```sql
CREATE TABLE default.kafka_events
(
    event_id UInt64,
    timestamp DateTime64(3),
    user_id UInt32,
    event_type String,
    value UInt32,
    metadata Tuple(source String, version String)
)
ENGINE = MergeTree()
ORDER BY (timestamp, event_id);
```

### 커넥터 관리

#### 커넥터 상태 확인

```bash
# Terraform 출력값에서 상태 확인 명령 얻기
terraform output clickhouse_connector_status

# 또는 직접
curl http://<instance-dns>:8083/connectors/clickhouse-sink-connector/status | jq '.'
```

#### 모든 커넥터 목록 보기

```bash
curl http://<instance-dns>:8083/connectors | jq '.'
```

#### 커넥터 설정 보기

```bash
curl http://<instance-dns>:8083/connectors/clickhouse-sink-connector | jq '.'
```

#### 커넥터 삭제 후 다시 만들기

```bash
# 삭제
curl -X DELETE http://<instance-dns>:8083/connectors/clickhouse-sink-connector

# 다시 만들기
ssh -i /path/to/your-key.pem ubuntu@<instance-dns> 'sudo /opt/confluent/create-clickhouse-sink.sh'
```

### 데이터 흐름 모니터링

#### 1. Kafka 프로듀서 로그 보기

```bash
ssh -i /path/to/your-key.pem ubuntu@<instance-dns> 'sudo journalctl -u confluent-producer -f'
```

#### 2. Kafka 토픽 메시지 확인

```bash
# EC2 인스턴스에서
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic sample-data-topic \
  --from-beginning
```

#### 3. ClickHouse Cloud에서 데이터 확인

```sql
-- 레코드 수 확인
SELECT count() FROM default.kafka_events;

-- 최근 이벤트 보기
SELECT * FROM default.kafka_events ORDER BY timestamp DESC LIMIT 10;

-- 이벤트 유형별 분석
SELECT event_type, count() as count FROM default.kafka_events GROUP BY event_type;
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

이벤트 유형에는 `page_view`, `click`, `purchase`, `signup`, `logout`이 있습니다.

### 설정

#### Terraform 변수

| 변수 | 설명 | 기본값 | 필수 |
|----------|-------------|---------|----------|
| `aws_region` | 배포할 AWS 리전 | null (환경 변수 사용) | 아니요 |
| `instance_name` | EC2 인스턴스의 Name 태그 | "confluent-server" | 아니요 |
| `instance_type` | EC2 인스턴스 유형 | "r5.xlarge" | 아니요 |
| `ebs_volume_size` | EBS 볼륨 크기 (GB) | 100 | 아니요 |
| `key_pair_name` | SSH 키 페어 이름 | null | 아니요 |
| `allowed_cidr_blocks` | SSH와 모든 서비스 포트에 접근할 수 있는 대상. `0.0.0.0/0`은 거부됨 | - | **예** |
| `use_elastic_ip` | Elastic IP를 할당해 연결할지 여부 | false | 아니요 |
| `confluent_version` | Confluent Platform 버전 태그 | "7.5.0" | 아니요 |
| `sample_topic_name` | 샘플 토픽 이름 | "sample-data-topic" | 아니요 |
| `data_producer_interval` | 샘플 메시지 사이의 간격(초, 0보다 커야 함) | 5 | 아니요 |
| `kafka_sasl_username` | Kafka SASL 사용자명 | "admin" | 아니요 |
| `kafka_sasl_password` | Kafka SASL 비밀번호 | - | **예** |
| `clickhouse_host` | ClickHouse Cloud 호스트 | null | 아니요 |
| `clickhouse_port` | ClickHouse Cloud 포트 | 8443 | 아니요 |
| `clickhouse_database` | ClickHouse 데이터베이스 | "default" | 아니요 |
| `clickhouse_username` | ClickHouse 사용자명 | "default" | 아니요 |
| `clickhouse_password` | ClickHouse 비밀번호 | null | 아니요 |
| `clickhouse_table` | 대상 테이블 이름 | "kafka_events" | 아니요 |
| `clickhouse_use_ssl` | ClickHouse에 SSL 사용 | true | 아니요 |

#### 인스턴스 유형 권장

- **개발**: `t3.xlarge` (4 vCPU, 16 GB RAM)
- **테스트**: `r5.xlarge` (4 vCPU, 32 GB RAM) - **기본값**
- **프로덕션**: `r5.2xlarge` 이상 (8+ vCPU, 64+ GB RAM)

### 서비스 엔드포인트

배포한 뒤 다음 서비스에 접속할 수 있습니다.

| 서비스 | 포트 | 설명 |
|---------|------|-------------|
| Control Center | 9021 | 관리용 웹 UI |
| Kafka Connect | 8083 | 커넥터 관리 API |
| Schema Registry | 8081 | 스키마 관리 |
| ksqlDB Server | 8088 | 스트림 처리 |
| Kafka 브로커 (SASL_SSL) | 9092 | 보안 Kafka 접속 |
| Kafka 브로커 (SASL_PLAINTEXT) | 9093 | Kafka 접속 (대체 경로) |

### Kafka 인증

이 배포는 SASL/PLAIN 인증을 씁니다 (Confluent Cloud와 같은 방식).

```bash
# 자격 증명 확인
terraform output kafka_sasl_username
terraform output -raw kafka_sasl_password
```

자격 증명:
- **사용자명**: `kafka_sasl_username`, 기본값 `admin`
- **비밀번호**: `kafka_sasl_password`, 기본값 없는 필수 변수 (`terraform.tfvars.example`은 `admin-secret`으로 설정)

### 관리 스크립트

SSH로 접속한 뒤 다음 스크립트를 씁니다.

```bash
# 모든 서비스의 상태 확인
sudo /opt/confluent/status.sh

# Confluent Platform 중지
sudo /opt/confluent/stop.sh

# Confluent Platform 시작
sudo /opt/confluent/start.sh

# ClickHouse Sink Connector 생성/재생성
sudo /opt/confluent/create-clickhouse-sink.sh
```

### 문제 해결

#### 커넥터가 만들어지지 않을 때

1. Kafka Connect 로그를 확인합니다.
```bash
docker logs connect -f
```

2. ClickHouse에 연결되는지 확인합니다.
```bash
# EC2 인스턴스에서
curl -v https://<clickhouse-host>:8443/
```

3. 커넥터 플러그인을 확인합니다.
```bash
curl http://localhost:8083/connector-plugins | jq '.'
```

#### ClickHouse로 데이터가 흐르지 않을 때

1. 커넥터 상태를 확인합니다.
```bash
curl http://localhost:8083/connectors/clickhouse-sink-connector/status | jq '.'
```

2. 커넥터 태스크에서 오류를 찾습니다.
```bash
curl http://localhost:8083/connectors/clickhouse-sink-connector/status | jq '.tasks[].trace'
```

3. ClickHouse 테이블이 있고 스키마가 맞는지 확인합니다.

4. Kafka 토픽에 데이터가 있는지 확인합니다.
```bash
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic sample-data-topic \
  --max-messages 10
```

#### 커넥터 상태가 FAILED일 때

자주 있는 문제:
- **인증 실패**: ClickHouse 사용자명/비밀번호를 확인합니다
- **테이블 없음**: ClickHouse에 테이블을 만듭니다
- **네트워크 문제**: 보안 그룹이 아웃바운드 HTTPS를 허용하는지 확인합니다
- **SSL/TLS 오류**: `clickhouse_use_ssl`이 ClickHouse 설정과 맞는지 확인합니다

자세한 오류 보기:
```bash
curl http://localhost:8083/connectors/clickhouse-sink-connector/status | jq '.tasks[0].trace'
```

### 데모 따라 하기

#### 엔드투엔드 전체 테스트

1. **인프라 배포**:
```bash
terraform apply
```

2. **Control Center 접속**:
```bash
open $(terraform output -raw control_center_url)
```

3. **Kafka 토픽이 있는지 확인**:
   - Control Center에서 "Topics"로 이동
   - `sample-data-topic` 찾기
   - 들어오는 메시지 보기

4. **커넥터 상태 확인**:
   - "Connect" → "connect-default"로 이동
   - `clickhouse-sink-connector` 보기
   - 상태가 "Running"인지 확인

5. **ClickHouse Cloud 쿼리**:
```sql
SELECT count() FROM default.kafka_events;
SELECT event_type, count(*) FROM default.kafka_events GROUP BY event_type;
```

6. **실시간 데이터 흐름 보기**:
```bash
# 터미널 1: Kafka 프로듀서 보기
ssh -i key.pem ubuntu@<dns> 'sudo journalctl -u confluent-producer -f'

# 터미널 2: 몇 초마다 ClickHouse 쿼리
watch -n 5 "clickhouse-client --host <host> --query 'SELECT count() FROM default.kafka_events'"
```

### 비용 고려 사항

예상 AWS 비용 (us-east-1 리전):

- **r5.xlarge 인스턴스**: ~$0.25/시간 (~$180/월)
- **EBS gp3 볼륨 (100 GB)**: ~$8/월
- **데이터 전송**: 사용량에 따라 다름
- **총 예상 비용**: 24/7 운영 시 ~$190-200/월

실습을 작성할 때의 추정치이며 측정한 값이 아닙니다. 사용하는 리전의 현재 AWS 요금을 확인하세요.

#### 비용 최적화

1. **쓰지 않을 때는 중지**: 다 쓰면 `terraform destroy`
2. **더 작은 인스턴스 사용**: 개발용으로는 `t3.xlarge`로 변경
3. **EBS 볼륨 줄이기**: 스토리지가 덜 필요하면 `ebs_volume_size` 조정

### 보안 모범 사례

#### 프로덕션에서 쓸 때

1. **CIDR 블록 제한**: `allowed_cidr_blocks`를 자신의 IP 범위로 제한
2. **강한 비밀번호 사용**: 예제의 `kafka_sasl_password`(`terraform.tfvars.example`의 `admin-secret`)를 바꾸고 `clickhouse_password`도 강한 값으로 설정
3. **CloudWatch 활성화**: 모니터링과 알림 추가
4. **프라이빗 서브넷 사용**: 배스천 호스트와 함께 프라이빗 서브넷에 배포
5. **시크릿 관리**: 자격 증명을 AWS Secrets Manager에 저장
6. **정기 업데이트**: Confluent Platform 버전을 최신으로 유지

#### 현재 보안 상태

⚠️ **경고**: 기본 구성은 개발/테스트 전용입니다

- 모든 브로커 포트가 `allowed_cidr_blocks`에 설정한 범위에 열려 있음 (`0.0.0.0/0`은 거부됨)
- SASL 사용자명은 기본값 `admin`, 비밀번호는 직접 설정한 값 (`terraform.tfvars.example`은 `admin-secret`)
- 직접 접속할 수 있는 퍼블릭 IP

### 출력값 (`outputs`)

배포가 끝나면 Terraform이 다음을 제공합니다.

- `control_center_url`: Control Center 웹 UI URL
- `kafka_connect_url`: Kafka Connect API URL
- `kafka_bootstrap_servers`: Kafka 부트스트랩 서버
- `clickhouse_host`: 설정한 ClickHouse 호스트
- `clickhouse_connector_status`: 커넥터 상태를 확인하는 명령
- `clickhouse_connector_commands`: 유용한 커넥터 관리 명령

출력값 전체 보기:
```bash
terraform output
```

### 정리

모든 리소스를 삭제하려면 다음을 실행합니다.

```bash
terraform destroy
```

이 명령은 다음을 합니다.
- EC2 인스턴스 종료
- 보안 그룹 삭제
- 관련 리소스 모두 제거

**참고**: 되돌릴 수 없으며, 인스턴스의 데이터가 모두 삭제됩니다.

### 고급 설정

#### 커넥터 설정 바꾸기

EC2 인스턴스에서 `/opt/confluent/create-clickhouse-sink.sh`를 편집해 다음을 바꿀 수 있습니다.

- 배치 크기
- 플러시 간격
- 오류 처리
- 데이터 변환
- 여러 토픽

사용자 정의 설정 예:

```json
{
  "name": "clickhouse-sink-connector",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "2",
    "topics": "sample-data-topic,another-topic",
    "hostname": "your-instance.clickhouse.cloud",
    "port": "8443",
    "database": "default",
    "batch.size": "10000",
    "buffer.flush.time": "1000"
  }
}
```

#### 여러 커넥터

다른 토픽용 커넥터를 추가로 만듭니다.

```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "another-clickhouse-sink",
    "config": {
      "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
      "topics": "another-topic",
      ...
    }
  }'
```

### 관련 프로젝트

- [terraform-confluent-aws](../terraform-confluent-aws): ClickHouse 없는 기본 Confluent Platform
- [ClickHouse Cloud](https://clickhouse.com/cloud): 관리형 ClickHouse 서비스

### 지원

문제나 질문이 있으면 다음을 참고하세요.

- Confluent 문서: https://docs.confluent.io/
- ClickHouse 문서: https://clickhouse.com/docs
- ClickHouse Kafka Connect: https://github.com/ClickHouse/clickhouse-kafka-connect

### 라이선스

저장소의 나머지와 마찬가지로 [MIT](../../../LICENSE)입니다 — 예전 문구는 아무 권리도 부여하지 않았습니다.
그래도 여전히 교육용 자료입니다. 비용이 드는 실제 클라우드 리소스를 만들며, 어떤 보증도 하지 않습니다.
이 자료가 호출하는 provider와 서비스에는 각자의 약관이 적용됩니다.
