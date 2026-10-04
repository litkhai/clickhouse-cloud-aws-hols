# Confluent Platform with NLB SSL Termination

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
> - Run path: `./deploy-with-cert.sh` → `terraform destroy` (README *Quick Start* and *Cleanup*; `deploy.sh`, `deploy-complete.sh` and `destroy.sh` also exist).
> - A re-run should show: a SASL_SSL client inside `allowed_cidr_blocks` produces and consumes through the NLB on port 9094, and the same client from an address outside it cannot connect.
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
> - 실행 경로: `./deploy-with-cert.sh` → `terraform destroy` (README *Quick Start*·*Cleanup*. `deploy.sh`, `deploy-complete.sh`, `destroy.sh`도 있음).
> - 재실행에서 보여야 할 것: `allowed_cidr_blocks` 안의 SASL_SSL 클라이언트가 NLB 9094 포트로 produce·consume 하고, 범위 밖 주소의 같은 클라이언트는 연결되지 않음.

[English](#english) | [한국어](#한국어)

## English

### ✅ **SOLUTION: Advertised Listener Fix**

This Terraform configuration demonstrates **NLB SSL termination with Kafka** using the **advertised listener pattern**.

**TL;DR**: By configuring Kafka to advertise the NLB DNS instead of EC2 DNS, clients maintain protocol consistency throughout their connection lifecycle.

See [NLB_ADVERTISED_LISTENER_FIX.md](NLB_ADVERTISED_LISTENER_FIX.md) for detailed explanation of the solution.

### Architecture (Working Solution)

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

#### Key Features (What Was Tested)

1. **Kafka Broker**: Configured with SASL_PLAINTEXT (NO TLS encryption)
2. **NLB**: Provides SSL/TLS termination on port 9094
3. **Expected Behavior**: Clients connect to NLB with SSL, NLB forwards to Kafka without encryption
4. **Actual Behavior**: ❌ Clients fail after metadata fetch due to protocol mismatch

#### Why This Architecture Was Tested

This setup was meant to test:
- SSL/TLS termination at the load balancer layer
- Reduced CPU load on Kafka brokers (no SSL processing)
- Centralized certificate management at NLB
- Testing scenarios where SSL is handled by network infrastructure

**Result**: ❌ This approach is incompatible with Kafka's advertised listener mechanism

### Prerequisites

1. AWS CLI configured with credentials
2. Terraform >= 1.0
3. An AWS EC2 key pair (optional, for SSH access)
4. Understanding of Kafka and NLB concepts

### Quick Start

#### Option A: Automated Deployment (Recommended)

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

#### Option B: Manual Step-by-Step

##### 1. Generate Initial Certificate

```bash
cd certs
./generate-nlb-cert.sh
cd ..
```

This creates placeholder certificates that will be replaced with the correct NLB DNS.

##### 2. Configure Variables

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

##### 3. Initial Deployment

```bash
terraform init
terraform plan
terraform apply
```

This creates the infrastructure with a placeholder certificate.

##### 4. Update Certificate with NLB DNS

After the initial deployment, update the certificate:

```bash
terraform apply -replace='aws_acm_certificate.nlb_cert'
```

**Automated Process**:
1. First `terraform apply`: Creates NLB, generates correct certificate in background
2. Second `terraform apply -replace`: Updates ACM with the new certificate
3. Certificate now matches NLB DNS perfectly!

##### 5. Get Connection Information

```bash
terraform output connection_info
terraform output nlb_endpoint
```

### Connection Examples

#### Python Client (via NLB with SSL)

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

#### Python Client (Direct to EC2, No SSL)

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

#### ClickHouse Kafka Engine (via NLB)

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

### Testing

#### 1. Test Direct Connection (No SSL)

SSH into the EC2 instance and run the test script:

```bash
ssh -i your-key.pem ubuntu@<EC2_DNS>
python3 /opt/confluent/test_kafka_sasl.py
```

#### 2. Test via NLB (with SSL)

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

### Architecture Details

#### Kafka Configuration

- **Port 9092**: SASL_PLAINTEXT listener (no TLS)
- **Port 29092**: Internal PLAINTEXT listener (for Confluent components)
- **SASL Mechanism**: PLAIN
- **Broker Advertised Listener**: Uses EC2 public DNS

#### NLB Configuration

- **Port 9094**: TLS listener with SSL termination
- **Protocol**: TLS (TCP with SSL/TLS)
- **Target**: EC2 instance port 9092
- **SSL Policy**: ELBSecurityPolicy-TLS13-1-2-2021-06
- **Certificate**: Self-signed certificate with NLB DNS (auto-generated during deployment)
- **Certificate CN**: Matches actual NLB DNS name (e.g., `confluent-server-nlb-xxx.elb.region.amazonaws.com`)

#### Security Group Rules

- **Port 9092**: Kafka SASL_PLAINTEXT (from allowed CIDR blocks)
- **Port 2181**: ZooKeeper (from allowed CIDR blocks)
- **Port 9021**: Control Center (from allowed CIDR blocks)
- **Port 22**: SSH (from allowed CIDR blocks)

### Deployed Services

| Service | Port | URL |
|---------|------|-----|
| Kafka (Direct) | 9092 | `<EC2_DNS>:9092` |
| Kafka (via NLB) | 9094 | `<NLB_ENDPOINT>:9094` |
| Control Center | 9021 | `http://<EC2_DNS>:9021` |
| Schema Registry | 8081 | `http://<EC2_DNS>:8081` |
| Kafka Connect | 8083 | `http://<EC2_DNS>:8083` |
| ksqlDB Server | 8088 | `http://<EC2_DNS>:8088` |
| REST Proxy | 8082 | `http://<EC2_DNS>:8082` |

### Useful Commands

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

### Cleanup

To destroy all resources:

```bash
terraform destroy
```

### Troubleshooting

#### NLB Health Check Failing

Check if Kafka is listening on port 9092:

```bash
ssh -i your-key.pem ubuntu@<EC2_DNS>
docker exec broker kafka-broker-api-versions --bootstrap-server localhost:29092
```

#### SSL Connection Issues

1. Verify the NLB certificate is correctly copied to client machine
2. Check NLB listener is active: `aws elbv2 describe-listeners --load-balancer-arn <ARN>`
3. Verify target group health: `aws elbv2 describe-target-health --target-group-arn <ARN>`

#### Cannot Connect via NLB

1. Check security group allows traffic on port 9092
2. Verify NLB target group has healthy targets
3. Test direct connection to EC2:9092 first
4. Check Kafka logs: `docker logs broker`

### Architecture Limitations & Test Results

#### ⚠️ **IMPORTANT: This Architecture Has Fundamental Limitations**

This project was created to **test NLB SSL termination with Kafka**, but testing revealed a **critical architectural flaw** that prevents it from working correctly with most Kafka clients.

#### Test Objective

The goal was to test whether we could:
1. Use AWS Network Load Balancer (NLB) to handle SSL/TLS termination
2. Keep Kafka broker without TLS (SASL_PLAINTEXT only)
3. Allow external clients to connect securely via NLB with SASL_SSL

#### Why It Fails

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

#### Test Results

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

#### Why This Architecture Doesn't Work

Kafka's design requires that:
1. The advertised listener protocol must match what clients use to connect
2. Clients will be redirected to the advertised listener address after initial connection
3. All subsequent connections must use the same security protocol

With NLB SSL termination:
- NLB terminates SSL and forwards PLAINTEXT to Kafka ✓
- Kafka advertises PLAINTEXT listener (EC2:9092) ✓
- Client connects with SASL_SSL via NLB ✓
- Client gets redirected to EC2:9092 with SASL_SSL ❌ (protocol mismatch!)

#### Correct Architectures for SSL with Kafka

##### Option 1: End-to-End Encryption (Recommended)
```
Client (SASL_SSL) → Kafka (SASL_SSL on 9092)
```
- Kafka handles SSL directly
- No load balancer SSL termination
- See: terraform-confluent-aws (our other project)

##### Option 2: NLB TCP Passthrough
```
Client (SASL_SSL) → NLB:9094 (TCP passthrough) → Kafka:9092 (SASL_SSL)
```
- NLB in TCP mode (not TLS mode)
- Kafka still does SSL/TLS encryption
- NLB just forwards encrypted traffic

##### Option 3: No SSL on External Network (Not Recommended)
```
Client (SASL_PLAINTEXT) → Kafka (SASL_PLAINTEXT on 9092)
```
- Direct connection without any SSL
- Only for trusted networks or testing

#### What This Project Demonstrates

✅ **Successfully demonstrates**:
- How to set up AWS NLB with TLS termination
- How to configure ACM certificates for NLB
- Automated certificate generation matching NLB DNS
- Terraform infrastructure for Confluent Platform on AWS

❌ **Does NOT work for**:
- External Kafka clients connecting via NLB with SSL
- Production use cases requiring SSL/TLS encryption
- ClickHouse ClickPipes or other Kafka clients expecting SASL_SSL

#### Conclusion

**This architecture is a proof-of-concept that reveals an important limitation**: NLB SSL termination is **incompatible** with Kafka's advertised listener mechanism.

For production Kafka deployments requiring SSL:
- Use end-to-end encryption with Kafka handling SSL directly
- Or use NLB in TCP passthrough mode (not TLS termination mode)
- See our `terraform-confluent-aws` project for a working SSL implementation

This project remains useful as:
- A learning exercise about Kafka networking and SSL
- Infrastructure template for Confluent Platform on AWS
- Documentation of what doesn't work and why

### Important Notes

- ⚠️ **This architecture does NOT work for external Kafka clients** - See "Architecture Limitations" above
- ⚠️ **TLS is disabled on Kafka broker** - Only NLB provides SSL termination
- ⚠️ **Kafka advertised listener uses EC2 DNS** - Clients get redirected to EC2:9092 (PLAINTEXT)
- ⚠️ **Protocol mismatch** - Clients expect SASL_SSL but Kafka only speaks SASL_PLAINTEXT
- ✅ **Direct EC2 connection works** - Use SASL_PLAINTEXT to connect directly to EC2:9092
- ℹ️ **For working SSL setup** - See terraform-confluent-aws project instead
- ℹ️ **Certificate auto-generated** - Matches NLB DNS automatically during deployment
- ℹ️ Self-signed certificate is used - Not suitable for production

### Cost Estimation

Approximate AWS costs (us-east-1):
- EC2 r5.xlarge: ~$0.25/hour
- NLB: ~$0.0225/hour + data processing charges
- EBS gp3 100GB: ~$8/month
- Data transfer: Variable

**Estimated monthly cost**: ~$190-220 (if running 24/7)

### Differences from terraform-confluent-aws

1. **TLS Configuration**: Kafka has NO TLS (vs SASL_SSL on 9092)
2. **NLB Added**: SSL termination at NLB layer
3. **Port Changes**: NLB listens on 9094 (vs direct access on 9092/9093)
4. **Certificate Management**: NLB certificate (vs Kafka broker certificates)
5. **Architecture**: SSL termination at load balancer (vs end-to-end encryption)

### SSL Certificate Configuration

This project uses **self-signed certificates** for testing. For production use:

#### Using Self-Signed Certificates (Testing Only)

See [SSL_CERTIFICATE_GUIDE.md](SSL_CERTIFICATE_GUIDE.md) for:
- Python, Go, Java, Node.js configuration examples
- How to disable certificate verification for testing
- Certificate troubleshooting

#### Using Valid CA-Signed Certificates (Production)

See [CUSTOM_DOMAIN_SETUP.md](CUSTOM_DOMAIN_SETUP.md) for:
- Setting up custom domain (e.g., `kafka.yourcompany.com`)
- Obtaining valid certificates from Let's Encrypt or ACM
- Configuring Route 53 DNS
- No certificate verification issues!

**Recommended for Production**: Use a custom domain with valid certificates.

### References

- [AWS Network Load Balancer - TLS Termination](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/create-tls-listener.html)
- [Confluent Platform Documentation](https://docs.confluent.io/)
- [Kafka Security Documentation](https://kafka.apache.org/documentation/#security)
- [Kafka Advertised Listeners](https://cwiki.apache.org/confluence/display/KAFKA/KIP-103+-+Separation+of+Internal+and+External+traffic)

### License

[MIT](../../../LICENSE) — same as the rest of the repository.

---

## 한국어

### ✅ **해결책: advertised listener 수정**

이 Terraform 구성은 **advertised listener 패턴**으로 **Kafka와 NLB SSL 종료**를 시연합니다.

**TL;DR**: Kafka가 EC2 DNS 대신 NLB DNS를 advertise하도록 구성하면, 클라이언트는 연결의 전체 수명 동안 같은 프로토콜을 유지합니다.

해결책에 대한 자세한 설명은 [NLB_ADVERTISED_LISTENER_FIX.md](NLB_ADVERTISED_LISTENER_FIX.md)를 참고하세요.

### 아키텍처 (동작하는 해결책)

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

**해결책**: Kafka가 EC2:9092 대신 NLB:9094를 advertise하므로, 클라이언트는 SSL을 처리하는 NLB에 머뭅니다.

#### 주요 기능 (테스트한 것)

1. **Kafka 브로커**: SASL_PLAINTEXT로 구성 (TLS 암호화 없음)
2. **NLB**: 9094 포트에서 SSL/TLS 종료를 제공
3. **기대한 동작**: 클라이언트가 SSL로 NLB에 연결하고, NLB는 암호화 없이 Kafka로 전달
4. **실제 동작**: ❌ 프로토콜 불일치 때문에 클라이언트가 메타데이터를 가져온 뒤 실패

#### 이 아키텍처를 테스트한 이유

이 구성은 다음을 테스트하려는 것이었습니다.
- 로드 밸런서 계층에서의 SSL/TLS 종료
- Kafka 브로커의 CPU 부하 감소 (SSL 처리 없음)
- NLB에서의 중앙 집중식 인증서 관리
- 네트워크 인프라가 SSL을 처리하는 시나리오 테스트

**결과**: ❌ 이 방식은 Kafka의 advertised listener 메커니즘과 호환되지 않습니다

### 사전 준비

1. 자격 증명이 구성된 AWS CLI
2. Terraform >= 1.0
3. AWS EC2 키 페어 (선택 사항, SSH 접속용)
4. Kafka와 NLB 개념에 대한 이해

### 빠른 시작

#### 옵션 A: 자동 배포 (권장)

```bash
# 1. 먼저 변수를 구성합니다
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars를 자신의 설정으로 편집합니다

# 2. 자동 배포 스크립트를 실행합니다
./deploy-with-cert.sh
```

이 스크립트가 모든 것을 자동으로 처리합니다.
- 초기 인증서 생성
- 인프라 배포
- NLB DNS로 인증서 갱신
- ACM 인증서 갱신

#### 옵션 B: 수동 단계별 진행

##### 1. 초기 인증서 생성

```bash
cd certs
./generate-nlb-cert.sh
cd ..
```

이 단계는 나중에 올바른 NLB DNS로 교체될 임시(placeholder) 인증서를 만듭니다.

##### 2. 변수 구성

변수 파일을 복사해 편집합니다.

```bash
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`를 편집합니다.

```hcl
aws_region           = "us-east-1"
instance_name        = "confluent-nlb-ssl"
instance_type        = "r5.xlarge"
key_pair_name        = "your-key-pair-name"
kafka_sasl_username  = "admin"
kafka_sasl_password  = "your-secure-password"
```

##### 3. 초기 배포

```bash
terraform init
terraform plan
terraform apply
```

이 단계는 임시 인증서로 인프라를 만듭니다.

##### 4. NLB DNS로 인증서 갱신

초기 배포가 끝나면 인증서를 갱신합니다.

```bash
terraform apply -replace='aws_acm_certificate.nlb_cert'
```

**자동화된 과정**:
1. 첫 번째 `terraform apply`: NLB를 만들고, 백그라운드에서 올바른 인증서를 생성
2. 두 번째 `terraform apply -replace`: 새 인증서로 ACM을 갱신
3. 이제 인증서가 NLB DNS와 정확히 일치합니다!

##### 5. 연결 정보 확인

```bash
terraform output connection_info
terraform output nlb_endpoint
```

### 연결 예시

#### Python 클라이언트 (NLB 경유, SSL 사용)

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

#### Python 클라이언트 (EC2에 직접 연결, SSL 없음)

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

#### ClickHouse Kafka 엔진 (NLB 경유)

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

### 테스트

#### 1. 직접 연결 테스트 (SSL 없음)

EC2 인스턴스에 SSH로 접속해 테스트 스크립트를 실행합니다.

```bash
ssh -i your-key.pem ubuntu@<EC2_DNS>
python3 /opt/confluent/test_kafka_sasl.py
```

#### 2. NLB 경유 테스트 (SSL 사용)

로컬 머신에서 실행합니다.

```bash
# NLB 인증서를 복사합니다
cp certs/nlb-certificate.pem /path/to/your/test/directory/

# 테스트 스크립트를 만듭니다
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

# 연결 테스트
admin = AdminClient(config)
metadata = admin.list_topics(timeout=10)
print(f"Connected! Found {len(metadata.topics)} topics")
EOF

python3 test_nlb.py
```

### 아키텍처 상세

#### Kafka 구성

- **포트 9092**: SASL_PLAINTEXT 리스너 (TLS 없음)
- **포트 29092**: 내부 PLAINTEXT 리스너 (Confluent 구성 요소용)
- **SASL 메커니즘**: PLAIN
- **브로커 advertised listener**: EC2 퍼블릭 DNS 사용

#### NLB 구성

- **포트 9094**: SSL 종료를 하는 TLS 리스너
- **프로토콜**: TLS (SSL/TLS를 쓰는 TCP)
- **대상**: EC2 인스턴스의 9092 포트
- **SSL 정책**: ELBSecurityPolicy-TLS13-1-2-2021-06
- **인증서**: NLB DNS를 담은 자체 서명 인증서 (배포 중 자동 생성)
- **인증서 CN**: 실제 NLB DNS 이름과 일치 (예: `confluent-server-nlb-xxx.elb.region.amazonaws.com`)

#### 보안 그룹 규칙

- **포트 9092**: Kafka SASL_PLAINTEXT (허용된 CIDR 블록에서)
- **포트 2181**: ZooKeeper (허용된 CIDR 블록에서)
- **포트 9021**: Control Center (허용된 CIDR 블록에서)
- **포트 22**: SSH (허용된 CIDR 블록에서)

### 배포되는 서비스

| 서비스 | 포트 | URL |
|---------|------|-----|
| Kafka (직접 연결) | 9092 | `<EC2_DNS>:9092` |
| Kafka (NLB 경유) | 9094 | `<NLB_ENDPOINT>:9094` |
| Control Center | 9021 | `http://<EC2_DNS>:9021` |
| Schema Registry | 8081 | `http://<EC2_DNS>:8081` |
| Kafka Connect | 8083 | `http://<EC2_DNS>:8083` |
| ksqlDB Server | 8088 | `http://<EC2_DNS>:8088` |
| REST Proxy | 8082 | `http://<EC2_DNS>:8082` |

### 유용한 명령

```bash
# 모든 출력값 보기
terraform output

# 연결 정보 보기
terraform output connection_info

# NLB 엔드포인트 보기
terraform output nlb_endpoint

# Kafka 부트스트랩 서버 보기
terraform output kafka_bootstrap_servers_nlb

# 인스턴스에 SSH 접속
ssh -i your-key.pem ubuntu@$(terraform output -raw instance_public_dns)

# 인스턴스에서 Kafka 상태 확인
ssh -i your-key.pem ubuntu@<EC2_DNS> 'sudo /opt/confluent/status.sh'

# 프로듀서 로그 보기
ssh -i your-key.pem ubuntu@<EC2_DNS> 'sudo journalctl -u confluent-producer -f'
```

### 정리

모든 리소스를 삭제하려면 다음을 실행합니다.

```bash
terraform destroy
```

### 문제 해결

#### NLB 헬스 체크 실패

Kafka가 9092 포트에서 리슨하고 있는지 확인합니다.

```bash
ssh -i your-key.pem ubuntu@<EC2_DNS>
docker exec broker kafka-broker-api-versions --bootstrap-server localhost:29092
```

#### SSL 연결 문제

1. NLB 인증서가 클라이언트 머신에 제대로 복사되었는지 확인합니다
2. NLB 리스너가 활성 상태인지 확인합니다: `aws elbv2 describe-listeners --load-balancer-arn <ARN>`
3. 대상 그룹 상태를 확인합니다: `aws elbv2 describe-target-health --target-group-arn <ARN>`

#### NLB로 연결할 수 없음

1. 보안 그룹이 9092 포트의 트래픽을 허용하는지 확인합니다
2. NLB 대상 그룹에 정상(healthy) 대상이 있는지 확인합니다
3. 먼저 EC2:9092로 직접 연결을 테스트합니다
4. Kafka 로그를 확인합니다: `docker logs broker`

### 아키텍처 한계와 테스트 결과

#### ⚠️ **중요: 이 아키텍처에는 근본적인 한계가 있습니다**

이 프로젝트는 **Kafka와 NLB SSL 종료를 테스트**하려고 만들었지만, 테스트에서 대부분의 Kafka 클라이언트와 올바르게 동작하지 못하게 하는 **치명적인 아키텍처 결함**이 드러났습니다.

#### 테스트 목표

다음이 가능한지 테스트하는 것이 목표였습니다.
1. AWS Network Load Balancer(NLB)로 SSL/TLS 종료를 처리
2. Kafka 브로커는 TLS 없이 유지 (SASL_PLAINTEXT만)
3. 외부 클라이언트가 NLB를 거쳐 SASL_SSL로 안전하게 연결

#### 실패하는 이유

**문제**: Kafka의 advertised listener 메커니즘은 이 SSL 종료 방식과 호환되지 않습니다.

**실패 흐름**:
```
1. Client → NLB:9094 (SASL_SSL connection)           ✓ Success
2. NLB → Kafka:9092 (SSL terminated, forwards plain) ✓ Success
3. Kafka returns metadata: "I'm at EC2:9092"         ✓ Success
4. Client → EC2:9092 (attempts SASL_SSL connection)  ❌ FAILURE
   - Kafka:9092 only speaks SASL_PLAINTEXT
   - Client expects SASL_SSL
   - SSL handshake fails: "connecting to a PLAINTEXT broker listener?"
```

**근본 원인**:
- Kafka는 자신의 리스너를 `EC2_DNS:9092`로 advertise합니다
- 클라이언트가 NLB를 통해 메타데이터를 가져오면, EC2:9092에 직접 연결하도록 리디렉션됩니다
- 클라이언트는 (처음에 SSL로 연결했으므로) EC2:9092에 SASL_SSL로 연결하려고 합니다
- 하지만 Kafka:9092는 SASL_PLAINTEXT만 지원합니다
- 결과: 프로토콜 불일치와 연결 실패

#### 테스트 결과

**EC2 직접 연결 (SASL_PLAINTEXT)**: ✅ **완벽하게 동작**
```bash
bootstrap.servers: ec2-xxx.amazonaws.com:9092
security.protocol: SASL_PLAINTEXT
# 연결에 성공하고 produce/consume 함
```

**NLB 연결 (SASL_SSL)**: ❌ **실패**
```bash
bootstrap.servers: nlb-xxx.elb.amazonaws.com:9094
security.protocol: SASL_SSL
# 초기 연결은 성공하지만, 메타데이터를 가져오면 EC2:9092로 리디렉션됨
# EC2:9092에 다시 연결하려 할 때 SSL 핸드셰이크가 실패함
# 오류: "SSL handshake failed: connecting to a PLAINTEXT broker listener?"
```

#### 이 아키텍처가 동작하지 않는 이유

Kafka의 설계는 다음을 요구합니다.
1. advertised listener의 프로토콜이 클라이언트가 연결에 쓰는 프로토콜과 일치해야 합니다
2. 클라이언트는 초기 연결 뒤 advertised listener 주소로 리디렉션됩니다
3. 이후의 모든 연결은 같은 보안 프로토콜을 써야 합니다

NLB SSL 종료를 쓰면:
- NLB가 SSL을 종료하고 Kafka로 PLAINTEXT를 전달 ✓
- Kafka가 PLAINTEXT 리스너(EC2:9092)를 advertise ✓
- 클라이언트가 NLB를 거쳐 SASL_SSL로 연결 ✓
- 클라이언트가 SASL_SSL인 채로 EC2:9092로 리디렉션됨 ❌ (프로토콜 불일치!)

#### Kafka에서 SSL을 쓰는 올바른 아키텍처

##### 옵션 1: 종단 간 암호화 (권장)
```
Client (SASL_SSL) → Kafka (SASL_SSL on 9092)
```
- Kafka가 SSL을 직접 처리
- 로드 밸런서 SSL 종료 없음
- 참고: terraform-confluent-aws (우리의 다른 프로젝트)

##### 옵션 2: NLB TCP 패스스루
```
Client (SASL_SSL) → NLB:9094 (TCP passthrough) → Kafka:9092 (SASL_SSL)
```
- NLB를 TCP 모드로 사용 (TLS 모드가 아님)
- SSL/TLS 암호화는 여전히 Kafka가 수행
- NLB는 암호화된 트래픽을 전달만 함

##### 옵션 3: 외부 네트워크에서 SSL 없음 (권장하지 않음)
```
Client (SASL_PLAINTEXT) → Kafka (SASL_PLAINTEXT on 9092)
```
- SSL 없이 직접 연결
- 신뢰할 수 있는 네트워크나 테스트 용도로만

#### 이 프로젝트가 보여 주는 것

✅ **성공적으로 보여 주는 것**:
- TLS 종료를 하는 AWS NLB를 구성하는 방법
- NLB용 ACM 인증서를 구성하는 방법
- NLB DNS와 일치하는 인증서의 자동 생성
- AWS에서 Confluent Platform을 위한 Terraform 인프라

❌ **동작하지 않는 것**:
- NLB를 거쳐 SSL로 연결하는 외부 Kafka 클라이언트
- SSL/TLS 암호화가 필요한 프로덕션 사용 사례
- SASL_SSL을 기대하는 ClickHouse ClickPipes나 다른 Kafka 클라이언트

#### 결론

**이 아키텍처는 중요한 한계를 드러내는 개념 증명(proof-of-concept)입니다**: NLB SSL 종료는 Kafka의 advertised listener 메커니즘과 **호환되지 않습니다**.

SSL이 필요한 프로덕션 Kafka 배포에서는:
- Kafka가 SSL을 직접 처리하는 종단 간 암호화를 사용합니다
- 또는 NLB를 TCP 패스스루 모드(TLS 종료 모드가 아님)로 사용합니다
- 동작하는 SSL 구현은 우리의 `terraform-confluent-aws` 프로젝트를 참고하세요

이 프로젝트는 여전히 다음 용도로 쓸모가 있습니다.
- Kafka 네트워킹과 SSL에 대한 학습 연습
- AWS에서 Confluent Platform을 위한 인프라 템플릿
- 무엇이 동작하지 않고 왜 그런지에 대한 기록

### 중요 참고 사항

- ⚠️ **이 아키텍처는 외부 Kafka 클라이언트에서 동작하지 않습니다** - 위의 "아키텍처 한계"를 참고하세요
- ⚠️ **Kafka 브로커에서 TLS가 비활성화되어 있습니다** - SSL 종료는 NLB만 제공합니다
- ⚠️ **Kafka advertised listener가 EC2 DNS를 사용합니다** - 클라이언트가 EC2:9092(PLAINTEXT)로 리디렉션됩니다
- ⚠️ **프로토콜 불일치** - 클라이언트는 SASL_SSL을 기대하지만 Kafka는 SASL_PLAINTEXT만 사용합니다
- ✅ **EC2 직접 연결은 동작합니다** - SASL_PLAINTEXT로 EC2:9092에 직접 연결하세요
- ℹ️ **동작하는 SSL 구성이 필요하면** - 대신 terraform-confluent-aws 프로젝트를 참고하세요
- ℹ️ **인증서 자동 생성** - 배포 중 NLB DNS와 자동으로 일치시킵니다
- ℹ️ 자체 서명 인증서를 사용합니다 - 프로덕션에는 적합하지 않습니다

### 비용 추정

대략적인 AWS 비용 (us-east-1):
- EC2 r5.xlarge: ~$0.25/시간
- NLB: ~$0.0225/시간 + 데이터 처리 요금
- EBS gp3 100GB: ~$8/월
- 데이터 전송: 사용량에 따라 다름

**예상 월 비용**: ~$190-220 (24/7로 실행할 경우)

### terraform-confluent-aws와의 차이

1. **TLS 구성**: Kafka에 TLS 없음 (terraform-confluent-aws는 9092에서 SASL_SSL)
2. **NLB 추가**: NLB 계층에서 SSL 종료
3. **포트 변경**: NLB가 9094에서 리슨 (terraform-confluent-aws는 9092/9093에 직접 접속)
4. **인증서 관리**: NLB 인증서 (terraform-confluent-aws는 Kafka 브로커 인증서)
5. **아키텍처**: 로드 밸런서에서 SSL 종료 (terraform-confluent-aws는 종단 간 암호화)

### SSL 인증서 구성

이 프로젝트는 테스트용으로 **자체 서명 인증서**를 사용합니다. 프로덕션에서 사용하려면:

#### 자체 서명 인증서 사용 (테스트 전용)

[SSL_CERTIFICATE_GUIDE.md](SSL_CERTIFICATE_GUIDE.md)에서 다음을 참고하세요.
- Python, Go, Java, Node.js 구성 예시
- 테스트용으로 인증서 검증을 끄는 방법
- 인증서 문제 해결

#### 유효한 CA 서명 인증서 사용 (프로덕션)

[CUSTOM_DOMAIN_SETUP.md](CUSTOM_DOMAIN_SETUP.md)에서 다음을 참고하세요.
- 사용자 지정 도메인 설정 (예: `kafka.yourcompany.com`)
- Let's Encrypt나 ACM에서 유효한 인증서 발급
- Route 53 DNS 구성
- 인증서 검증 문제 없음!

**프로덕션 권장**: 유효한 인증서와 함께 사용자 지정 도메인을 사용하세요.

### 참고 자료

- [AWS Network Load Balancer - TLS 종료](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/create-tls-listener.html)
- [Confluent Platform 문서](https://docs.confluent.io/)
- [Kafka 보안 문서](https://kafka.apache.org/documentation/#security)
- [Kafka advertised listener](https://cwiki.apache.org/confluence/display/KAFKA/KIP-103+-+Separation+of+Internal+and+External+traffic)

### 라이선스

[MIT](../../../LICENSE) — 저장소의 나머지 부분과 같습니다.
