# Terraform MinIO on AWS

> **Last verified: 2025-11-16** — date of the last commit made while running the lab (there is no separate run log). AWS provider `~> 5.0`.
> Changed since without a full re-run:
> - 2026-08-10 — `allowed_cidr_blocks` is required and rejects `0.0.0.0/0` (checked with `terraform plan` on 1.15.8, not applied)
>
> AWS provider: `~> 5.0` resolves to 5.100.0, the last 5.x release; never run on 6.x (6.67.0 is the newest, Terraform Registry API read 2026-10-04).
> Provider, AMI and Confluent/MinIO versions may have drifted since; expect to adjust before `apply`.
>
> **마지막 검증: 2025-11-16** — 실습을 실행하며 남긴 마지막 커밋 날짜 (별도 실행 기록은 없음). AWS provider `~> 5.0`.
> 그 뒤 전체 재실행 없이 바뀐 것:
> - 2026-08-10 — `allowed_cidr_blocks` 필수화, `0.0.0.0/0` 거부 (terraform 1.15.8에서 `plan`까지만 확인, apply 안 함)
>
> AWS provider: `~> 5.0`은 마지막 5.x인 5.100.0으로 잡힘. 6.x에서는 실행한 적 없음 (최신 6.67.0, 2026-10-04 Terraform Registry API로 확인).
> 그동안 provider·AMI·Confluent/MinIO 버전이 달라졌을 수 있으니 `apply` 전에 조정이 필요할 수 있습니다.

[English](#english) | [한국어](#한국어)

## English

Terraform scripts to deploy a single-node MinIO server on AWS EC2.

### Prerequisites

1. Terraform installed (>= 1.0)
2. AWS account and credentials configured
3. AWS EC2 Key Pair created

### Features

- **Ubuntu 22.04 LTS**: Uses Ubuntu Server following MinIO's official documentation
- **Configurable Instance Type**: Default `c5.xlarge`, customizable
- **EBS Volume Size**: Default `250GB`, customizable
- **AWS Authentication**: Uses standard AWS environment variables
- **Security Group**: Automatically configures MinIO API (9000), Console (9001), and SSH (22) ports
- **Elastic IP**: Optional stable public IP allocation
- **Automated Installation**: MinIO automatically installed and configured via user-data script
- **Automated Deployment Scripts**: Quick deployment and cleanup with shell scripts

### Quick Start (Automated)

The easiest way to deploy is using the provided deployment script:

```bash
# 1. Configure AWS credentials
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="us-east-1"  # Optional

# Or use AWS CLI
aws configure

# 2. Run deployment script
./deploy.sh
```

The script will:
- Check prerequisites (Terraform, AWS credentials)
- Create terraform.tfvars if needed
- Initialize Terraform
- Show execution plan
- Deploy all resources
- Display MinIO access information

#### Cleanup

To destroy all resources:

```bash
./destroy.sh
```

### Manual Deployment Instructions

#### 1. Configure AWS Credentials and Region

Set up AWS credentials and region using environment variables:

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # Optional, for temporary credentials
export AWS_REGION="us-west-2"  # Optional, defaults to us-east-1 if not set

# Or use AWS CLI configuration (recommended)
aws configure
```

The AWS region will be determined in this order:
1. `aws_region` variable in terraform.tfvars (if set)
2. `AWS_REGION` or `AWS_DEFAULT_REGION` environment variable
3. Falls back to `us-east-1` if none of the above are set

#### 2. Create terraform.tfvars File

```bash
cp terraform.tfvars.example terraform.tfvars
```

#### 3. Edit terraform.tfvars File

```hcl
# AWS Configuration
# Optional: Region can be set via AWS_REGION environment variable
# aws_region = "us-west-2"

# EC2 Configuration
instance_name   = "minio-server"
instance_type   = "c5.xlarge"      # Change to desired instance type
ebs_volume_size = 250               # Change to desired EBS size (GB)
key_pair_name   = "YOUR_KEY_PAIR_NAME"

# Network Configuration
allowed_cidr_blocks = ["203.0.113.4/32"]  # required — your own address (curl -s ifconfig.me)
use_elastic_ip      = false  # Set to true for production to get stable IP

# MinIO Configuration
minio_root_user     = "admin"
minio_root_password = "minioadmin"  # Must be at least 8 characters
minio_data_dir      = "/mnt/data"
```

#### 4. Initialize Terraform

```bash
terraform init
```

#### 5. Review Execution Plan

```bash
terraform plan
```

#### 6. Deploy

```bash
terraform apply
```

After deployment completes, the following information will be displayed:
- MinIO Console URL
- MinIO API Endpoint
- SSH connection command
- Public/Private IP addresses

#### 7. Access MinIO

Access the MinIO web console using the `minio_console_url` from the output:
- URL: `http://<PUBLIC_IP>:9001`
- Username: Value set in `minio_root_user` in terraform.tfvars
- Password: Value set in `minio_root_password` in terraform.tfvars

### Configurable Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region for deployment | Uses `AWS_REGION` env var, or `us-east-1` |
| `instance_name` | EC2 instance name tag | `minio-server` |
| `instance_type` | EC2 instance type | `c5.xlarge` |
| `ebs_volume_size` | EBS volume size in GB | `250` |
| `key_pair_name` | EC2 key pair name | - (required) |
| `allowed_cidr_blocks` | Who may reach MinIO and SSH. `0.0.0.0/0` is rejected | - (required) |
| `minio_root_user` | MinIO root username (min 3 chars) | `admin` |
| `minio_root_password` | MinIO root password (min 8 chars) | `minioadmin` |
| `minio_data_dir` | MinIO data directory path | `/mnt/data` |
| `use_elastic_ip` | Enable Elastic IP allocation | `false` |

### Recommended Instance Types

Recommended instance types based on MinIO usage:

- **Development/Testing**: `t3.medium`, `t3.large`
- **Small Production**: `c5.xlarge` (default), `c5.2xlarge`
- **Medium Production**: `c5.4xlarge`, `c5.9xlarge`
- **Large Production**: `c5.12xlarge`, `c5.18xlarge` or memory-optimized `r5` series

### Deployment Scripts

#### deploy.sh

Automated deployment script that handles the entire deployment process:

**Features:**
- Validates prerequisites (Terraform, AWS credentials)
- Creates terraform.tfvars from template if needed
- Runs terraform init, plan, and apply
- Shows deployment information after completion
- Provides MinIO access URLs and credentials

**Usage:**
```bash
./deploy.sh
```

**What it checks:**
- Terraform installation
- AWS CLI installation (optional)
- AWS credentials (environment variables or AWS CLI config)
- AWS region configuration
- Existing terraform.tfvars file
- EC2 key pair configuration

#### destroy.sh

Automated cleanup script to remove all deployed resources:

**Features:**
- Shows current deployment information
- Confirms destruction with double-check
- Removes all AWS resources (EC2, Security Group, Elastic IP)
- Optional cleanup of local Terraform files

**Usage:**
```bash
./destroy.sh
```

**Safety features:**
- Requires explicit "yes" confirmation
- Requires typing "destroy" as second confirmation
- Shows what will be destroyed before proceeding

### View Outputs

```bash
# View all outputs
terraform output

# View specific output
terraform output minio_console_url

# View sensitive information (passwords, etc.)
terraform output -json minio_credentials
```

### SSH Access

```bash
# SSH to Ubuntu instance (default user is 'ubuntu')
ssh -i /path/to/your-key.pem ubuntu@<PUBLIC_IP>

# Check MinIO status
sudo systemctl status minio

# View MinIO logs
sudo journalctl -u minio -f

# Check installation logs
sudo cat /var/log/minio-setup.log
```

### Destroy Resources

```bash
terraform destroy
```

### Security Recommendations

1. **terraform.tfvars Security**:
   - Add `terraform.tfvars` to `.gitignore`
   - Use AWS environment variables instead of hardcoding credentials

2. **Network Security**:
   - Restrict `allowed_cidr_blocks` to your IP address
   - Use VPN or Bastion host for production environments

3. **MinIO Credentials**:
   - Username must be at least 3 characters
   - Password must be at least 8 characters (MinIO requirement)
   - Use strong passwords for production
   - Rotate passwords regularly

4. **HTTPS Configuration**:
   - Apply SSL/TLS certificates for production environments
   - Consider using Let's Encrypt or AWS Certificate Manager

### Troubleshooting

#### Check Installation Logs

The installation script creates detailed logs that can help diagnose issues:

```bash
# View the complete installation log
sudo cat /var/log/minio-setup.log

# Check if installation completed successfully
sudo cat /var/log/minio-installation-complete

# View cloud-init output logs
sudo cat /var/log/cloud-init-output.log

# View real-time MinIO service logs
sudo journalctl -u minio -f
```

#### MinIO Service Not Starting

```bash
# SSH into the instance (Ubuntu default user)
ssh -i /path/to/your-key.pem ubuntu@<PUBLIC_IP>

# Check MinIO service status
sudo systemctl status minio

# Check recent MinIO logs
sudo journalctl -u minio -n 50

# Verify MinIO configuration
sudo cat /etc/default/minio

# Check if MinIO binary is present
ls -la /usr/local/bin/minio

# Test MinIO binary
sudo -u minio-user /usr/local/bin/minio --version
```

#### Installation Script Features

The enhanced user-data script includes:
- **Ubuntu 22.04 LTS**: Uses Ubuntu Server with apt package manager
- **Comprehensive Logging**: All output is logged to `/var/log/minio-setup.log`
- **Step-by-Step Progress**: Shows progress through 10 installation steps
- **Error Handling**: Exits immediately on errors with detailed error messages
- **Package Verification**: Verifies all required commands are available
- **Health Checks**: Waits up to 60 seconds for MinIO to become healthy
- **Installation Summary**: Creates detailed completion report in `/var/log/minio-installation-complete`

#### Verify Firewall Configuration

Check that required ports (9000, 9001, 22) are open in the Security Group settings

#### Manual MinIO Restart

If MinIO needs to be restarted:

```bash
sudo systemctl restart minio
sudo systemctl status minio
```

### AWS Authentication Methods

This configuration supports multiple AWS authentication methods:

1. **Environment Variables** (Recommended):
```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_SESSION_TOKEN="your-session-token"  # Optional, for temporary credentials
export AWS_REGION="us-west-2"  # Optional, defaults to us-east-1
```

2. **AWS CLI Configuration**:
```bash
aws configure
```

3. **IAM Role** (for EC2/ECS deployments):
   - No explicit credentials needed
   - Automatically uses attached IAM role

4. **AWS SSO**:
```bash
aws sso login
```

The Terraform AWS provider will automatically detect and use credentials from these sources.

### License

[MIT](../../../LICENSE) — same as the rest of the repository.

---

## 한국어

Terraform 스크립트로 AWS EC2에 단일 노드 MinIO 서버를 배포합니다.

### 사전 준비

1. Terraform 설치 (>= 1.0)
2. AWS 계정과 자격 증명 설정
3. AWS EC2 Key Pair 생성

### 기능

- **Ubuntu 22.04 LTS**: MinIO 공식 문서를 따라 Ubuntu Server를 사용합니다
- **인스턴스 유형 설정 가능**: 기본값 `c5.xlarge`, 변경할 수 있습니다
- **EBS 볼륨 크기**: 기본값 `250GB`, 변경할 수 있습니다
- **AWS 인증**: 표준 AWS 환경 변수를 사용합니다
- **보안 그룹**: MinIO API (9000), Console (9001), SSH (22) 포트를 자동으로 설정합니다
- **Elastic IP**: 고정 공인 IP를 선택적으로 할당합니다
- **자동 설치**: user-data 스크립트로 MinIO를 자동으로 설치하고 설정합니다
- **자동 배포 스크립트**: 셸 스크립트로 빠르게 배포하고 정리합니다

### 빠른 시작 (자동)

가장 쉬운 배포 방법은 제공된 배포 스크립트를 사용하는 것입니다.

```bash
# 1. AWS 자격 증명 설정
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="us-east-1"  # 선택

# 또는 AWS CLI 사용
aws configure

# 2. 배포 스크립트 실행
./deploy.sh
```

스크립트가 하는 일:
- 사전 준비 확인 (Terraform, AWS 자격 증명)
- 필요하면 terraform.tfvars 생성
- Terraform 초기화
- 실행 계획 표시
- 모든 리소스 배포
- MinIO 접속 정보 표시

#### 정리

모든 리소스를 삭제하려면 다음을 실행합니다.

```bash
./destroy.sh
```

### 수동 배포 안내

#### 1. AWS 자격 증명과 리전 설정

환경 변수로 AWS 자격 증명과 리전을 설정합니다.

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # 선택, 임시 자격 증명용
export AWS_REGION="us-west-2"  # 선택, 설정하지 않으면 기본값은 us-east-1

# 또는 AWS CLI 설정 사용 (권장)
aws configure
```

AWS 리전은 다음 순서로 정해집니다.
1. terraform.tfvars의 `aws_region` 변수 (설정한 경우)
2. `AWS_REGION` 또는 `AWS_DEFAULT_REGION` 환경 변수
3. 위 어느 것도 설정하지 않으면 `us-east-1`

#### 2. terraform.tfvars 파일 만들기

```bash
cp terraform.tfvars.example terraform.tfvars
```

#### 3. terraform.tfvars 파일 편집

```hcl
# AWS 설정
# 선택: 리전은 AWS_REGION 환경 변수로 설정할 수 있음
# aws_region = "us-west-2"

# EC2 설정
instance_name   = "minio-server"
instance_type   = "c5.xlarge"      # 원하는 인스턴스 유형으로 변경
ebs_volume_size = 250               # 원하는 EBS 크기로 변경 (GB)
key_pair_name   = "YOUR_KEY_PAIR_NAME"

# 네트워크 설정
allowed_cidr_blocks = ["203.0.113.4/32"]  # 필수 — 본인 주소 (curl -s ifconfig.me)
use_elastic_ip      = false  # 프로덕션에서는 고정 IP를 받도록 true로 설정

# MinIO 설정
minio_root_user     = "admin"
minio_root_password = "minioadmin"  # 최소 8자 이상이어야 함
minio_data_dir      = "/mnt/data"
```

#### 4. Terraform 초기화

```bash
terraform init
```

#### 5. 실행 계획 검토

```bash
terraform plan
```

#### 6. 배포

```bash
terraform apply
```

배포가 끝나면 다음 정보가 표시됩니다.
- MinIO Console URL
- MinIO API 엔드포인트
- SSH 접속 명령
- 공인/사설 IP 주소

#### 7. MinIO 접속

출력값의 `minio_console_url`로 MinIO 웹 콘솔에 접속합니다.
- URL: `http://<PUBLIC_IP>:9001`
- 사용자 이름: terraform.tfvars의 `minio_root_user`에 설정한 값
- 비밀번호: terraform.tfvars의 `minio_root_password`에 설정한 값

### 설정 가능한 변수

| 변수 | 설명 | 기본값 |
|----------|-------------|---------|
| `aws_region` | 배포할 AWS 리전 | `AWS_REGION` 환경 변수, 없으면 `us-east-1` |
| `instance_name` | EC2 인스턴스 이름 태그 | `minio-server` |
| `instance_type` | EC2 인스턴스 유형 | `c5.xlarge` |
| `ebs_volume_size` | EBS 볼륨 크기 (GB) | `250` |
| `key_pair_name` | EC2 key pair 이름 | - (필수) |
| `allowed_cidr_blocks` | MinIO와 SSH에 접근할 수 있는 대상. `0.0.0.0/0`은 거부됨 | - (필수) |
| `minio_root_user` | MinIO root 사용자 이름 (최소 3자) | `admin` |
| `minio_root_password` | MinIO root 비밀번호 (최소 8자) | `minioadmin` |
| `minio_data_dir` | MinIO 데이터 디렉터리 경로 | `/mnt/data` |
| `use_elastic_ip` | Elastic IP 할당 사용 | `false` |

### 권장 인스턴스 유형

MinIO 용도에 따른 권장 인스턴스 유형입니다.

- **개발/테스트**: `t3.medium`, `t3.large`
- **소규모 프로덕션**: `c5.xlarge` (기본값), `c5.2xlarge`
- **중규모 프로덕션**: `c5.4xlarge`, `c5.9xlarge`
- **대규모 프로덕션**: `c5.12xlarge`, `c5.18xlarge` 또는 메모리 최적화 `r5` 시리즈

### 배포 스크립트

#### deploy.sh

전체 배포 과정을 처리하는 자동 배포 스크립트입니다.

**기능:**
- 사전 준비 검증 (Terraform, AWS 자격 증명)
- 필요하면 템플릿에서 terraform.tfvars 생성
- terraform init, plan, apply 실행
- 완료 후 배포 정보 표시
- MinIO 접속 URL과 자격 증명 제공

**사용법:**
```bash
./deploy.sh
```

**확인하는 항목:**
- Terraform 설치
- AWS CLI 설치 (선택)
- AWS 자격 증명 (환경 변수 또는 AWS CLI 설정)
- AWS 리전 설정
- 기존 terraform.tfvars 파일
- EC2 key pair 설정

#### destroy.sh

배포한 모든 리소스를 제거하는 자동 정리 스크립트입니다.

**기능:**
- 현재 배포 정보 표시
- 두 번 확인한 뒤 삭제
- 모든 AWS 리소스 제거 (EC2, 보안 그룹, Elastic IP)
- 로컬 Terraform 파일 정리 (선택)

**사용법:**
```bash
./destroy.sh
```

**안전 장치:**
- "yes"를 명시적으로 입력해야 합니다
- 두 번째 확인으로 "destroy"를 입력해야 합니다
- 진행하기 전에 삭제될 항목을 보여 줍니다

### 출력값 (`outputs`) 보기

```bash
# 모든 출력값 보기
terraform output

# 특정 출력값 보기
terraform output minio_console_url

# 민감한 정보 보기 (비밀번호 등)
terraform output -json minio_credentials
```

### SSH 접속

```bash
# Ubuntu 인스턴스에 SSH 접속 (기본 사용자는 'ubuntu')
ssh -i /path/to/your-key.pem ubuntu@<PUBLIC_IP>

# MinIO 상태 확인
sudo systemctl status minio

# MinIO 로그 보기
sudo journalctl -u minio -f

# 설치 로그 확인
sudo cat /var/log/minio-setup.log
```

### 리소스 삭제

```bash
terraform destroy
```

### 보안 권장 사항

1. **terraform.tfvars 보안**:
   - `terraform.tfvars`를 `.gitignore`에 추가합니다
   - 자격 증명을 하드코딩하지 말고 AWS 환경 변수를 사용합니다

2. **네트워크 보안**:
   - `allowed_cidr_blocks`를 본인 IP 주소로 제한합니다
   - 프로덕션 환경에서는 VPN이나 Bastion 호스트를 사용합니다

3. **MinIO 자격 증명**:
   - 사용자 이름은 최소 3자 이상이어야 합니다
   - 비밀번호는 최소 8자 이상이어야 합니다 (MinIO 요구 사항)
   - 프로덕션에서는 강력한 비밀번호를 사용합니다
   - 비밀번호를 정기적으로 교체합니다

4. **HTTPS 설정**:
   - 프로덕션 환경에서는 SSL/TLS 인증서를 적용합니다
   - Let's Encrypt나 AWS Certificate Manager 사용을 고려합니다

### 문제 해결

#### 설치 로그 확인

설치 스크립트는 문제 진단에 도움이 되는 자세한 로그를 남깁니다.

```bash
# 전체 설치 로그 보기
sudo cat /var/log/minio-setup.log

# 설치가 성공적으로 끝났는지 확인
sudo cat /var/log/minio-installation-complete

# cloud-init 출력 로그 보기
sudo cat /var/log/cloud-init-output.log

# MinIO 서비스 로그 실시간 보기
sudo journalctl -u minio -f
```

#### MinIO 서비스가 시작되지 않을 때

```bash
# 인스턴스에 SSH 접속 (Ubuntu 기본 사용자)
ssh -i /path/to/your-key.pem ubuntu@<PUBLIC_IP>

# MinIO 서비스 상태 확인
sudo systemctl status minio

# 최근 MinIO 로그 확인
sudo journalctl -u minio -n 50

# MinIO 설정 확인
sudo cat /etc/default/minio

# MinIO 바이너리가 있는지 확인
ls -la /usr/local/bin/minio

# MinIO 바이너리 테스트
sudo -u minio-user /usr/local/bin/minio --version
```

#### 설치 스크립트 기능

개선된 user-data 스크립트에는 다음이 포함됩니다.
- **Ubuntu 22.04 LTS**: apt 패키지 관리자와 함께 Ubuntu Server를 사용합니다
- **상세 로깅**: 모든 출력을 `/var/log/minio-setup.log`에 기록합니다
- **단계별 진행 상황**: 10개 설치 단계의 진행 상황을 보여 줍니다
- **오류 처리**: 오류가 나면 자세한 오류 메시지와 함께 즉시 종료합니다
- **패키지 검증**: 필요한 명령이 모두 있는지 확인합니다
- **헬스 체크**: MinIO가 정상 상태가 될 때까지 최대 60초 기다립니다
- **설치 요약**: `/var/log/minio-installation-complete`에 자세한 완료 보고서를 만듭니다

#### 방화벽 설정 확인

보안 그룹 설정에서 필요한 포트(9000, 9001, 22)가 열려 있는지 확인합니다.

#### MinIO 수동 재시작

MinIO를 재시작해야 하면 다음을 실행합니다.

```bash
sudo systemctl restart minio
sudo systemctl status minio
```

### AWS 인증 방법

이 구성은 여러 AWS 인증 방법을 지원합니다.

1. **환경 변수** (권장):
```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_SESSION_TOKEN="your-session-token"  # 선택, 임시 자격 증명용
export AWS_REGION="us-west-2"  # 선택, 기본값은 us-east-1
```

2. **AWS CLI 설정**:
```bash
aws configure
```

3. **IAM 역할** (EC2/ECS 배포용):
   - 명시적인 자격 증명이 필요 없습니다
   - 연결된 IAM 역할을 자동으로 사용합니다

4. **AWS SSO**:
```bash
aws sso login
```

Terraform AWS provider가 이 소스들에서 자격 증명을 자동으로 찾아 사용합니다.

### 라이선스

[MIT](../../../LICENSE) — 저장소의 나머지 부분과 같은 라이선스입니다.
