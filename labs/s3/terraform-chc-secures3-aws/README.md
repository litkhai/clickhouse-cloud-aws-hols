# ClickHouse Cloud Secure S3 Integration with Terraform

> **Last verified: 2025-11-30** — date of the last commit made while running the lab (there is no separate run log). AWS provider `~> 5.0`.
> No code changes since — only documentation and licence edits.
> AWS provider: `~> 5.0` resolves to 5.100.0, the last 5.x release; never run on 6.x (6.67.0 is the newest, Terraform Registry API read 2026-10-04).
> Provider and AWS/ClickHouse Cloud behaviour may have drifted since; expect to adjust before `apply`.
>
> **마지막 검증: 2025-11-30** — 실습을 실행하며 남긴 마지막 커밋 날짜 (별도 실행 기록은 없음). AWS provider `~> 5.0`.
> 그 뒤 코드 변경 없음 — 문서와 라이선스 수정만 있었음.
> AWS provider: `~> 5.0`은 마지막 5.x인 5.100.0으로 잡힘. 6.x에서는 실행한 적 없음 (최신 6.67.0, 2026-10-04 Terraform Registry API로 확인).
> 그동안 provider와 AWS·ClickHouse Cloud 동작이 달라졌을 수 있으니 `apply` 전에 조정이 필요할 수 있습니다.

[English](#english) | [한국어](#한국어)

## English

This Terraform configuration sets up secure S3 access for ClickHouse Cloud using IAM role-based authentication. It allows ClickHouse Cloud to read from and write to an S3 bucket using the S3 table engine without managing access keys.

### Features

- **Secure IAM Role-Based Authentication**: No access keys needed - uses AWS IAM role assumption
- **Read & Write Permissions**: Full support for SELECT, INSERT, and export operations
- **S3 Table Engine Support**: Create tables backed by S3 storage in various formats (Parquet, CSV, JSON)
- **Bucket hardening**: Includes encryption, versioning, and public access blocking
- **Easy Integration**: Pre-configured for ClickHouse Cloud service roles
- **Multiple Format Support**: Parquet, CSV, JSON, and other ClickHouse-supported formats

### Architecture

```
┌─────────────────────────┐
│  ClickHouse Cloud      │
│  Service               │
│  (with IAM Role)       │
└───────────┬─────────────┘
            │ AssumeRole
            │
            ▼
┌─────────────────────────┐
│  IAM Role              │
│  ClickHouseS3Access    │
│  (Created by Terraform) │
└───────────┬─────────────┘
            │ S3 Permissions
            │ (Get, Put, Delete)
            ▼
┌─────────────────────────┐
│  S3 Bucket             │
│  - Encrypted           │
│  - Versioned           │
│  - Private             │
└─────────────────────────┘
```

### Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- ClickHouse Cloud service (free or paid tier)

### AWS Credentials Setup

Set your AWS credentials as environment variables:

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # If using temporary credentials
export AWS_REGION="ap-northeast-2"  # Optional: Set default region
```

### Quick Start

#### Option A: Automated Deployment (Recommended)

The easiest way to deploy is using the automated deployment script:

```bash
cd labs/s3/terraform-chc-secures3-aws  # from the repository root
./deploy.sh
```

The script will:
1. ✅ Check AWS credentials automatically
2. ✅ Auto-detect AWS region
3. ✅ Prompt for S3 bucket name (with random hash generation)
4. ✅ Load saved ClickHouse IAM role ARN from `.env` (if exists)
5. ✅ Prompt for ClickHouse Cloud IAM role ARN (with reuse option)
6. ✅ Validate and save configuration
7. ✅ Deploy the infrastructure
8. ✅ Display connection information

**Interactive Deployment Process:**

When you run `./deploy.sh`, the script will:

1. **S3 Bucket Configuration:**
   - Prompt for bucket name prefix (default: `clickhouse-s3`)
   - Automatically append 8-character random hash
   - Example: `my-project` → `my-project-a1b2c3d4`

2. **ClickHouse IAM Role:**
   - Check for saved ARN in `.env` file
   - If found, ask to reuse or enter new one
   - If not found, prompt for new ARN
   - Automatically save to `.env` for future use

**First Time Setup:**

Get your ClickHouse Cloud IAM role ARN:
1. Log into [ClickHouse Cloud Console](https://clickhouse.cloud/)
2. Select your service
3. Navigate to: **Settings** → **Network security information**
4. Copy the **Service role ID (IAM)** value
   - Format: `arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx`

Then run:

```bash
./deploy.sh
```

**Subsequent Deployments:**

The script will remember your ClickHouse IAM role ARN from `.env`:

```bash
./deploy.sh
# ✅ Found saved ClickHouse IAM role ARN in .env
# Use saved ClickHouse IAM role ARN from .env? (y/n): y
```

#### Option B: Manual Deployment

If you prefer manual configuration:

##### 1. Copy the example configuration:

```bash
cd labs/s3/terraform-chc-secures3-aws  # from the repository root
cp terraform.tfvars.example terraform.tfvars
```

##### 2. Edit `terraform.tfvars`:

```hcl
# REQUIRED: Set a globally unique bucket name
bucket_name = "my-company-clickhouse-data-2024"

# REQUIRED: Paste your ClickHouse Cloud IAM role ARN
clickhouse_iam_role_arns = [
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx"
]

# Optional: Customize other settings
aws_region = "ap-northeast-2"  # Same region as ClickHouse Cloud recommended
iam_role_name = "ClickHouseS3Access"
environment = "production"
```

##### 3. Deploy:

```bash
# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply
```

The deployment takes about 1-2 minutes.

#### Get Connection Information

After deployment, view the connection details:

```bash
# View complete connection information
terraform output connection_info

# Get the IAM role ARN (needed for ClickHouse queries)
terraform output iam_role_arn

# View SQL examples
terraform output clickhouse_sql_examples
```

### Usage Examples

#### Example 1: Create S3-Backed Table (Parquet Format)

The most efficient format for ClickHouse is Parquet:

```sql
CREATE TABLE logs_s3
(
    timestamp DateTime,
    level String,
    message String
)
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/logs/app_logs.parquet',
    'Parquet',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
);

-- Insert data
INSERT INTO logs_s3 VALUES
    (now(), 'INFO', 'Application started'),
    (now(), 'DEBUG', 'Processing request'),
    (now(), 'ERROR', 'Connection timeout');

-- Query data
SELECT * FROM logs_s3;
```

#### Example 2: Direct S3 Query Without Table

Query S3 files directly without creating a table:

```sql
SELECT *
FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/*.parquet',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
)
LIMIT 100;
```

#### Example 3: Export Query Results to S3

Export aggregated results to S3:

```sql
INSERT INTO FUNCTION s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/exports/daily_summary.parquet',
    'Parquet',
    'date Date, total_events UInt64, unique_users UInt64',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
)
SELECT
    toDate(timestamp) AS date,
    count() AS total_events,
    uniq(user_id) AS unique_users
FROM events
GROUP BY date;
```

#### Example 4: CSV Format with Headers

```sql
CREATE TABLE events_csv
(
    event_id UInt64,
    user_id String,
    event_type String,
    created_at DateTime
)
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/events.csv',
    'CSVWithNames',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
);
```

#### Example 5: JSON Lines Format

```sql
CREATE TABLE user_activity_json
(
    user_id String,
    action String,
    timestamp DateTime
)
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/activity_*.json',
    'JSONEachRow',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
);
```

### Supported File Formats

ClickHouse S3 integration supports many formats:

- **Parquet** - Recommended for best compression and performance
- **CSV**, **CSVWithNames** - Simple text format with optional headers
- **JSONEachRow** - One JSON object per line
- **TSV**, **TSVWithNames** - Tab-separated values
- **Native** - ClickHouse native format (best for ClickHouse-to-ClickHouse)
- **Avro**, **ORC** - Other columnar formats

### Configuration

#### Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `aws_region` | AWS region for deployment | null (uses env var) | No |
| `bucket_name` | S3 bucket name (globally unique) | - | **Yes** |
| `clickhouse_iam_role_arns` | ClickHouse Cloud IAM role ARN(s) | - | **Yes** |
| `iam_role_name` | Name for IAM role | "ClickHouseS3Access" | No |
| `environment` | Environment tag | "dev" | No |
| `enable_versioning` | Enable S3 versioning | true | No |
| `create_sample_folders` | Create sample folders | true | No |
| `require_external_id` | Use external ID for security | false | No |
| `external_id` | External ID shared secret | "" | No (if enabled) |

#### IAM Permissions

The Terraform configuration creates an IAM role with the following permissions:

**Bucket-level permissions:**
- `s3:GetBucketLocation`
- `s3:ListBucket`

**Object-level permissions (read):**
- `s3:GetObject`
- `s3:GetObjectVersion`
- `s3:ListMultipartUploadParts`

**Object-level permissions (write):**
- `s3:PutObject`
- `s3:DeleteObject`
- `s3:AbortMultipartUpload`

### Testing

Run the included test script to verify your setup:

```bash
# Make the script executable
chmod +x test-s3-integration.sh

# Run the test
./test-s3-integration.sh
```

The test script will:
1. Create a test table with S3 engine
2. Insert sample data
3. Query the data back
4. Verify files were created in S3
5. Clean up test resources

### S3 Bucket Structure

The Terraform configuration optionally creates the following folder structure:

```
your-bucket-name/
├── data/           # For data files
├── logs/           # For log files
└── exports/        # For exported query results
```

You can organize your files however you prefer.

### Best Practices

#### 1. Use the Same AWS Region

Place your S3 bucket in the same AWS region as your ClickHouse Cloud service to:
- Minimize data transfer costs
- Reduce latency
- Improve performance

#### 2. Use Parquet Format

For best performance and storage efficiency:
- Use Parquet for large datasets
- Enable compression (Parquet has built-in compression)
- Consider partitioning large datasets

#### 3. Use Wildcards for Partitioned Data

```sql
-- Query all partitions
SELECT * FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/bucket/data/year=*/month=*/day=*/*.parquet',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
)
WHERE toDate(timestamp) >= today() - 7;
```

#### 4. Enable S3 Versioning

Keep versioning enabled to:
- Protect against accidental deletions
- Maintain data history
- Enable data recovery

#### 5. Monitor Costs

Watch for:
- S3 storage costs (varies by storage class)
- Data transfer costs (especially cross-region)
- S3 request costs (PUT, GET operations)

### Troubleshooting

#### Error: "Access Denied"

**Causes:**
1. Incorrect ClickHouse IAM role ARN
2. IAM role trust policy issue
3. Missing S3 permissions

**Solutions:**
```bash
# 1. Verify your ClickHouse IAM role ARN
terraform output connection_info

# 2. Check the IAM role in AWS Console
aws iam get-role --role-name ClickHouseS3Access

# 3. Check the IAM role policy
aws iam get-role-policy --role-name ClickHouseS3Access --policy-name ClickHouseS3Access-s3-policy

# 4. Verify the assume role policy
aws iam get-role --role-name ClickHouseS3Access --query 'Role.AssumeRolePolicyDocument'
```

#### Error: "NoSuchBucket"

**Causes:**
1. Bucket name typo
2. Wrong region
3. Bucket not created

**Solutions:**
```bash
# Verify bucket exists
aws s3 ls s3://your-bucket-name

# Check bucket region
aws s3api get-bucket-location --bucket your-bucket-name
```

#### Error: "InvalidParameter"

**Cause:** Malformed S3 URL or role ARN

**Solution:** Use the exact format from terraform outputs:
```bash
terraform output clickhouse_sql_examples
```

#### Testing IAM Role Assumption

Test if ClickHouse can assume the role:

```bash
# Get the role ARN
ROLE_ARN=$(terraform output -raw iam_role_arn)

# Try to assume the role (this should fail from your local machine)
aws sts assume-role --role-arn $ROLE_ARN --role-session-name test
# Expected: Error because only ClickHouse can assume this role
```

### Monitoring and Logging

#### CloudWatch Metrics

Monitor these S3 metrics:
- `NumberOfObjects` - Total objects in bucket
- `BucketSizeBytes` - Total storage used
- `AllRequests` - Total API requests

#### S3 Access Logging (Optional)

Enable S3 access logging for audit trails:

```hcl
# Add to main.tf
resource "aws_s3_bucket_logging" "clickhouse_data_logging" {
  bucket = aws_s3_bucket.clickhouse_data.id

  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "s3-access-logs/"
}
```

### Cost Optimization

#### Estimated Costs

For a bucket with 100 GB of data:

- **S3 Storage (Standard)**: ~$2.30/month
- **S3 Requests**: ~$0.50/month (varies by usage)
- **Data Transfer (same region)**: $0 (free)
- **Data Transfer (cross-region)**: $0.02/GB

**Total**: ~$3-5/month for moderate usage

These are estimates from when the lab was written, not measured; check current AWS pricing for your region.

#### Cost Saving Tips

1. **Use S3 Lifecycle Policies**: Move old data to cheaper storage classes
2. **Use S3 Intelligent-Tiering**: Automatically optimize storage costs
3. **Compress Data**: Use Parquet with compression
4. **Minimize Requests**: Batch operations when possible
5. **Keep Data in Same Region**: Avoid cross-region transfer fees

### Advanced Configuration

#### Using External ID for Additional Security

For enhanced security, use an external ID:

```hcl
# In terraform.tfvars
require_external_id = true
external_id = "your-shared-secret-12345"
```

Then in ClickHouse queries:

```sql
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/bucket/file.parquet',
    'Parquet',
    extra_credentials(
        role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access',
        external_id = 'your-shared-secret-12345'
    )
);
```

#### Multiple ClickHouse Services

To grant access to multiple ClickHouse Cloud services:

```hcl
# In terraform.tfvars
clickhouse_iam_role_arns = [
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-service1",
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-service2"
]
```

### Cleanup

To destroy all resources:

```bash
# Review what will be deleted
terraform plan -destroy

# Delete all resources
terraform destroy
```

**Warning**: This will delete the S3 bucket and all its contents. Make sure to backup any important data first.

### Outputs Reference

After deployment, these outputs are available:

```bash
# Essential outputs
terraform output bucket_name              # S3 bucket name
terraform output iam_role_arn            # IAM role ARN for ClickHouse
terraform output s3_url_prefix           # Base S3 URL

# Detailed information
terraform output connection_info          # Complete setup information
terraform output clickhouse_sql_examples  # Ready-to-use SQL examples
terraform output setup_checklist         # Step-by-step setup guide
```

### Related Documentation

- [ClickHouse S3 Table Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/s3)
- [ClickHouse Cloud Secure S3](https://clickhouse.com/docs/cloud/data-sources/secure-s3)
- [AWS IAM Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
- [S3 Best Practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/best-practices.html)

### Support

For issues or questions:

- ClickHouse Documentation: https://clickhouse.com/docs
- ClickHouse Community Slack: https://clickhouse.com/slack
- AWS Support: https://console.aws.amazon.com/support/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/

### License

[MIT](../../../LICENSE), like the rest of the repository — the earlier wording granted nothing.
It is still educational material: it provisions real cloud resources that cost money, and
carries no warranty. The providers and services it calls have their own terms.

### From the notes site (migrated, not verified)

> Moved on 2026-10-06 from the author's notes site; not re-run here. English is an LLM-assisted translation.

The official ClickHouse documentation page "Accessing S3 data securely" only covers secure *access*. For the *write* operations this lab uses, the role also needs `s3:PutObject`, `s3:DeleteObject` and `s3:AbortMultipartUpload`. Besides Terraform, the notes site describes two other ways to create the IAM role.

#### Create the IAM role with CloudFormation

Use the template from the official ClickHouse documentation to create the resources automatically:

[CloudFormation quick-create](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/quickcreate?templateURL=https://s3.us-east-2.amazonaws.com/clickhouse-public-resources.clickhouse.cloud/cf-templates/secure-s3.yaml&stackName=ClickHouseSecureS3)

| Parameter | Description |
| --- | --- |
| RoleName | Name of the IAM role to create (for example ClickHouseAccessRole-001) |
| ClickHouse Instance Roles | ClickHouse service IAM role ARN (comma-separated) |
| Bucket Names | S3 bucket names to allow (names only, not ARNs) |
| Bucket Access | Read or Read/Write |
| Role Session Name | Session name for extra security (optional) |

#### Create the IAM role by hand in the AWS Console (without Terraform)

**1. Create the IAM role.** Go to AWS Console → IAM → Roles → Create role, choose "Custom trust policy" and enter the trust policy below. Replace `Principal.AWS` with the Service role ID (IAM) copied from the ClickHouse Cloud Console.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowClickHouseAssumeRole",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::123456789012:role/CH-S3-your-service-Role"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**2. Create the permission policy.** On the role's Permissions tab choose "Add permissions" → "Create inline policy", open the JSON tab and enter the policy below. Replace `YOUR_BUCKET_NAME` with the real bucket name; for several buckets, make `Resource` an array or add statements.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BucketLevelPermissions",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME"
    },
    {
      "Sid": "ObjectLevelReadPermissions",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
    },
    {
      "Sid": "ObjectLevelWritePermissions",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
    }
  ]
}
```

**3. Copy the role ARN** (for example `arn:aws:iam::111111111111:role/ClickHouseAccessRole`) and use it as `extra_credentials` in the ClickHouse query.

---

## 한국어

이 Terraform 구성은 IAM 역할 기반 인증으로 ClickHouse Cloud의 안전한 S3 접근을 설정합니다. ClickHouse Cloud가 액세스 키를 관리하지 않고도 S3 테이블 엔진으로 S3 버킷을 읽고 쓸 수 있게 합니다.

### 기능

- **안전한 IAM 역할 기반 인증**: 액세스 키가 필요 없습니다 - AWS IAM 역할 위임을 사용합니다
- **읽기·쓰기 권한**: SELECT, INSERT, 내보내기 작업을 모두 지원합니다
- **S3 테이블 엔진 지원**: 여러 형식(Parquet, CSV, JSON)의 S3 스토리지를 기반으로 하는 테이블을 만듭니다
- **버킷 보호 설정**: 암호화, 버전 관리, 퍼블릭 액세스 차단을 포함합니다
- **쉬운 통합**: ClickHouse Cloud 서비스 역할에 맞게 미리 구성되어 있습니다
- **여러 형식 지원**: Parquet, CSV, JSON 및 ClickHouse가 지원하는 그 밖의 형식

### 아키텍처

```
┌─────────────────────────┐
│  ClickHouse Cloud      │
│  Service               │
│  (with IAM Role)       │
└───────────┬─────────────┘
            │ AssumeRole
            │
            ▼
┌─────────────────────────┐
│  IAM Role              │
│  ClickHouseS3Access    │
│  (Created by Terraform) │
└───────────┬─────────────┘
            │ S3 Permissions
            │ (Get, Put, Delete)
            ▼
┌─────────────────────────┐
│  S3 Bucket             │
│  - Encrypted           │
│  - Versioned           │
│  - Private             │
└─────────────────────────┘
```

### 사전 준비

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- 적절한 권한이 있는 AWS 계정
- 자격 증명이 구성된 AWS CLI
- ClickHouse Cloud 서비스 (무료 또는 유료 티어)

### AWS 자격 증명 설정

AWS 자격 증명을 환경 변수로 설정합니다.

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # 임시 자격 증명을 쓰는 경우
export AWS_REGION="ap-northeast-2"  # 선택: 기본 리전 설정
```

### 빠른 시작

#### 옵션 A: 자동 배포 (권장)

가장 쉬운 배포 방법은 자동 배포 스크립트를 쓰는 것입니다.

```bash
cd labs/s3/terraform-chc-secures3-aws  # 저장소 루트에서
./deploy.sh
```

스크립트가 하는 일은 다음과 같습니다.
1. ✅ AWS 자격 증명을 자동으로 확인
2. ✅ AWS 리전을 자동으로 감지
3. ✅ S3 버킷 이름 입력 요청 (랜덤 해시 생성 포함)
4. ✅ `.env`에 저장된 ClickHouse IAM 역할 ARN 불러오기 (있는 경우)
5. ✅ ClickHouse Cloud IAM 역할 ARN 입력 요청 (재사용 옵션 포함)
6. ✅ 구성을 검증하고 저장
7. ✅ 인프라 배포
8. ✅ 연결 정보 표시

**대화형 배포 과정:**

`./deploy.sh`를 실행하면 스크립트가 다음을 합니다.

1. **S3 버킷 구성:**
   - 버킷 이름 접두사 입력 요청 (기본값: `clickhouse-s3`)
   - 8자리 랜덤 해시를 자동으로 덧붙임
   - 예: `my-project` → `my-project-a1b2c3d4`

2. **ClickHouse IAM 역할:**
   - `.env` 파일에 저장된 ARN이 있는지 확인
   - 있으면 재사용할지, 새로 입력할지 물음
   - 없으면 새 ARN 입력 요청
   - 다음에 쓸 수 있도록 `.env`에 자동 저장

**처음 설정할 때:**

ClickHouse Cloud IAM 역할 ARN을 확인합니다.
1. [ClickHouse Cloud 콘솔](https://clickhouse.cloud/)에 로그인합니다
2. 서비스를 선택합니다
3. **Settings** → **Network security information**으로 이동합니다
4. **Service role ID (IAM)** 값을 복사합니다
   - 형식: `arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx`

그다음 실행합니다.

```bash
./deploy.sh
```

**이후 배포:**

스크립트가 `.env`에 저장된 ClickHouse IAM 역할 ARN을 기억합니다.

```bash
./deploy.sh
# ✅ Found saved ClickHouse IAM role ARN in .env
# Use saved ClickHouse IAM role ARN from .env? (y/n): y
```

#### 옵션 B: 수동 배포

직접 구성하려면 다음 순서를 따릅니다.

##### 1. 예시 구성 복사:

```bash
cd labs/s3/terraform-chc-secures3-aws  # 저장소 루트에서
cp terraform.tfvars.example terraform.tfvars
```

##### 2. `terraform.tfvars` 편집:

```hcl
# 필수: 전역에서 고유한 버킷 이름 설정
bucket_name = "my-company-clickhouse-data-2024"

# 필수: ClickHouse Cloud IAM 역할 ARN 붙여넣기
clickhouse_iam_role_arns = [
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx"
]

# 선택: 그 밖의 설정 변경
aws_region = "ap-northeast-2"  # ClickHouse Cloud와 같은 리전 권장
iam_role_name = "ClickHouseS3Access"
environment = "production"
```

##### 3. 배포:

```bash
# Terraform 초기화
terraform init

# 배포 계획 검토
terraform plan

# 인프라 배포
terraform apply
```

배포에는 약 1-2분이 걸립니다.

#### 연결 정보 확인

배포가 끝나면 연결 정보를 확인합니다.

```bash
# 전체 연결 정보 보기
terraform output connection_info

# IAM 역할 ARN 확인 (ClickHouse 쿼리에 필요)
terraform output iam_role_arn

# SQL 예시 보기
terraform output clickhouse_sql_examples
```

### 사용 예시

#### 예시 1: S3 기반 테이블 만들기 (Parquet 형식)

ClickHouse에 가장 효율적인 형식은 Parquet입니다.

```sql
CREATE TABLE logs_s3
(
    timestamp DateTime,
    level String,
    message String
)
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/logs/app_logs.parquet',
    'Parquet',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
);

-- 데이터 삽입
INSERT INTO logs_s3 VALUES
    (now(), 'INFO', 'Application started'),
    (now(), 'DEBUG', 'Processing request'),
    (now(), 'ERROR', 'Connection timeout');

-- 데이터 조회
SELECT * FROM logs_s3;
```

#### 예시 2: 테이블 없이 S3 직접 쿼리

테이블을 만들지 않고 S3 파일을 직접 쿼리합니다.

```sql
SELECT *
FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/*.parquet',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
)
LIMIT 100;
```

#### 예시 3: 쿼리 결과를 S3로 내보내기

집계 결과를 S3로 내보냅니다.

```sql
INSERT INTO FUNCTION s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/exports/daily_summary.parquet',
    'Parquet',
    'date Date, total_events UInt64, unique_users UInt64',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
)
SELECT
    toDate(timestamp) AS date,
    count() AS total_events,
    uniq(user_id) AS unique_users
FROM events
GROUP BY date;
```

#### 예시 4: 헤더가 있는 CSV 형식

```sql
CREATE TABLE events_csv
(
    event_id UInt64,
    user_id String,
    event_type String,
    created_at DateTime
)
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/events.csv',
    'CSVWithNames',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
);
```

#### 예시 5: JSON Lines 형식

```sql
CREATE TABLE user_activity_json
(
    user_id String,
    action String,
    timestamp DateTime
)
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/activity_*.json',
    'JSONEachRow',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
);
```

### 지원하는 파일 형식

ClickHouse S3 통합은 많은 형식을 지원합니다.

- **Parquet** - 압축률과 성능이 가장 좋아 권장합니다
- **CSV**, **CSVWithNames** - 헤더를 선택적으로 넣을 수 있는 단순한 텍스트 형식
- **JSONEachRow** - 한 줄에 JSON 객체 하나
- **TSV**, **TSVWithNames** - 탭으로 구분한 값
- **Native** - ClickHouse 네이티브 형식 (ClickHouse에서 ClickHouse로 옮길 때 가장 좋음)
- **Avro**, **ORC** - 그 밖의 컬럼 형식

### 구성

#### 변수

| 변수 | 설명 | 기본값 | 필수 |
|----------|-------------|---------|----------|
| `aws_region` | 배포할 AWS 리전 | null (환경 변수 사용) | 아니요 |
| `bucket_name` | S3 버킷 이름 (전역에서 고유) | - | **예** |
| `clickhouse_iam_role_arns` | ClickHouse Cloud IAM 역할 ARN (하나 이상) | - | **예** |
| `iam_role_name` | IAM 역할 이름 | "ClickHouseS3Access" | 아니요 |
| `environment` | 환경 태그 | "dev" | 아니요 |
| `enable_versioning` | S3 버전 관리 활성화 | true | 아니요 |
| `create_sample_folders` | 샘플 폴더 생성 | true | 아니요 |
| `require_external_id` | 보안을 위해 external ID 사용 | false | 아니요 |
| `external_id` | external ID 공유 비밀 값 | "" | 아니요 (활성화한 경우) |

#### IAM 권한

이 Terraform 구성은 다음 권한을 가진 IAM 역할을 만듭니다.

**버킷 수준 권한:**
- `s3:GetBucketLocation`
- `s3:ListBucket`

**객체 수준 권한 (읽기):**
- `s3:GetObject`
- `s3:GetObjectVersion`
- `s3:ListMultipartUploadParts`

**객체 수준 권한 (쓰기):**
- `s3:PutObject`
- `s3:DeleteObject`
- `s3:AbortMultipartUpload`

### 테스트

포함된 테스트 스크립트를 실행해 설정을 검증합니다.

```bash
# 스크립트에 실행 권한 부여
chmod +x test-s3-integration.sh

# 테스트 실행
./test-s3-integration.sh
```

테스트 스크립트가 하는 일은 다음과 같습니다.
1. S3 엔진으로 테스트 테이블 생성
2. 샘플 데이터 삽입
3. 데이터를 다시 조회
4. S3에 파일이 생성되었는지 확인
5. 테스트 리소스 정리

### S3 버킷 구조

이 Terraform 구성은 선택적으로 다음 폴더 구조를 만듭니다.

```
your-bucket-name/
├── data/           # 데이터 파일용
├── logs/           # 로그 파일용
└── exports/        # 내보낸 쿼리 결과용
```

파일은 원하는 방식으로 정리해도 됩니다.

### 모범 사례

#### 1. 같은 AWS 리전 사용

S3 버킷을 ClickHouse Cloud 서비스와 같은 AWS 리전에 두면 다음과 같은 이점이 있습니다.
- 데이터 전송 비용 최소화
- 지연 시간 감소
- 성능 향상

#### 2. Parquet 형식 사용

성능과 스토리지 효율을 가장 좋게 하려면 다음을 따릅니다.
- 큰 데이터셋에는 Parquet 사용
- 압축 활성화 (Parquet에는 압축이 내장되어 있음)
- 큰 데이터셋은 파티셔닝 고려

#### 3. 파티션된 데이터에는 와일드카드 사용

```sql
-- 모든 파티션 조회
SELECT * FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/bucket/data/year=*/month=*/day=*/*.parquet',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
)
WHERE toDate(timestamp) >= today() - 7;
```

#### 4. S3 버전 관리 활성화

버전 관리를 켜 두면 다음을 할 수 있습니다.
- 실수로 인한 삭제 방지
- 데이터 이력 유지
- 데이터 복구 가능

#### 5. 비용 모니터링

다음 항목을 지켜봅니다.
- S3 스토리지 비용 (스토리지 클래스에 따라 다름)
- 데이터 전송 비용 (특히 리전 간)
- S3 요청 비용 (PUT, GET 작업)

### 문제 해결

#### 오류: "Access Denied"

**원인:**
1. 잘못된 ClickHouse IAM 역할 ARN
2. IAM 역할 신뢰 정책 문제
3. S3 권한 누락

**해결 방법:**
```bash
# 1. ClickHouse IAM 역할 ARN 확인
terraform output connection_info

# 2. AWS 콘솔에서 IAM 역할 확인
aws iam get-role --role-name ClickHouseS3Access

# 3. IAM 역할 정책 확인
aws iam get-role-policy --role-name ClickHouseS3Access --policy-name ClickHouseS3Access-s3-policy

# 4. 역할 위임(assume role) 정책 확인
aws iam get-role --role-name ClickHouseS3Access --query 'Role.AssumeRolePolicyDocument'
```

#### 오류: "NoSuchBucket"

**원인:**
1. 버킷 이름 오타
2. 잘못된 리전
3. 버킷이 생성되지 않음

**해결 방법:**
```bash
# 버킷이 있는지 확인
aws s3 ls s3://your-bucket-name

# 버킷 리전 확인
aws s3api get-bucket-location --bucket your-bucket-name
```

#### 오류: "InvalidParameter"

**원인:** S3 URL 또는 역할 ARN의 형식이 잘못됨

**해결 방법:** terraform 출력값 (`outputs`)에 나온 형식을 그대로 사용합니다.
```bash
terraform output clickhouse_sql_examples
```

#### IAM 역할 위임 테스트

ClickHouse가 역할을 위임받을 수 있는지 테스트합니다.

```bash
# 역할 ARN 가져오기
ROLE_ARN=$(terraform output -raw iam_role_arn)

# 역할 위임 시도 (로컬 머신에서는 실패해야 함)
aws sts assume-role --role-arn $ROLE_ARN --role-session-name test
# 예상 결과: ClickHouse만 이 역할을 위임받을 수 있으므로 오류
```

### 모니터링과 로깅

#### CloudWatch 지표

다음 S3 지표를 모니터링합니다.
- `NumberOfObjects` - 버킷의 전체 객체 수
- `BucketSizeBytes` - 사용 중인 전체 스토리지
- `AllRequests` - 전체 API 요청 수

#### S3 액세스 로깅 (선택)

감사 추적이 필요하면 S3 액세스 로깅을 켭니다.

```hcl
# main.tf에 추가
resource "aws_s3_bucket_logging" "clickhouse_data_logging" {
  bucket = aws_s3_bucket.clickhouse_data.id

  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "s3-access-logs/"
}
```

### 비용 최적화

#### 예상 비용

데이터가 100 GB인 버킷 기준:

- **S3 스토리지 (Standard)**: ~$2.30/월
- **S3 요청**: ~$0.50/월 (사용량에 따라 다름)
- **데이터 전송 (같은 리전)**: $0 (무료)
- **데이터 전송 (리전 간)**: $0.02/GB

**합계**: 보통 수준으로 사용하면 ~$3-5/월

실습을 작성할 때의 추정치이며 측정한 값이 아닙니다. 사용하는 리전의 현재 AWS 요금을 확인하세요.

#### 비용 절감 팁

1. **S3 수명 주기 정책 사용**: 오래된 데이터를 더 저렴한 스토리지 클래스로 옮깁니다
2. **S3 Intelligent-Tiering 사용**: 스토리지 비용을 자동으로 최적화합니다
3. **데이터 압축**: 압축을 적용한 Parquet를 사용합니다
4. **요청 최소화**: 가능하면 작업을 일괄 처리합니다
5. **데이터를 같은 리전에 유지**: 리전 간 전송 요금을 피합니다

### 고급 구성

#### 추가 보안을 위한 external ID 사용

보안을 강화하려면 external ID를 사용합니다.

```hcl
# terraform.tfvars에서
require_external_id = true
external_id = "your-shared-secret-12345"
```

그다음 ClickHouse 쿼리에서 다음과 같이 씁니다.

```sql
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/bucket/file.parquet',
    'Parquet',
    extra_credentials(
        role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access',
        external_id = 'your-shared-secret-12345'
    )
);
```

#### 여러 ClickHouse 서비스

여러 ClickHouse Cloud 서비스에 접근 권한을 주려면 다음과 같이 합니다.

```hcl
# terraform.tfvars에서
clickhouse_iam_role_arns = [
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-service1",
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-service2"
]
```

### 정리

모든 리소스를 삭제하려면 다음을 실행합니다.

```bash
# 삭제될 항목 검토
terraform plan -destroy

# 모든 리소스 삭제
terraform destroy
```

**경고**: S3 버킷과 그 안의 모든 내용이 삭제됩니다. 중요한 데이터는 먼저 백업하세요.

### 출력값 참조

배포가 끝나면 다음 출력값을 쓸 수 있습니다.

```bash
# 핵심 출력값
terraform output bucket_name              # S3 버킷 이름
terraform output iam_role_arn            # ClickHouse용 IAM 역할 ARN
terraform output s3_url_prefix           # 기본 S3 URL

# 상세 정보
terraform output connection_info          # 전체 설정 정보
terraform output clickhouse_sql_examples  # 바로 쓸 수 있는 SQL 예시
terraform output setup_checklist         # 단계별 설정 가이드
```

### 관련 문서

- [ClickHouse S3 테이블 엔진](https://clickhouse.com/docs/en/engines/table-engines/integrations/s3)
- [ClickHouse Cloud Secure S3](https://clickhouse.com/docs/cloud/data-sources/secure-s3)
- [AWS IAM 역할](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
- [S3 모범 사례](https://docs.aws.amazon.com/AmazonS3/latest/userguide/best-practices.html)

### 지원

문제가 있거나 질문이 있으면 다음을 참고하세요.

- ClickHouse 문서: https://clickhouse.com/docs
- ClickHouse 커뮤니티 Slack: https://clickhouse.com/slack
- AWS 지원: https://console.aws.amazon.com/support/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/

### 라이선스

저장소의 나머지 부분과 같이 [MIT](../../../LICENSE)입니다 — 예전 문구는 아무 권리도 부여하지 않았습니다.
여전히 교육용 자료입니다. 비용이 드는 실제 클라우드 리소스를 프로비저닝하며, 어떤 보증도
제공하지 않습니다. 이 자료가 호출하는 provider와 서비스에는 각자의 약관이 있습니다.

### 노트 사이트에서 옮긴 내용 (이관본, 미검증)

> 2026-10-06 작성자의 노트 사이트에서 옮겼습니다. 여기서 다시 실행하지 않았습니다. 영어본은 LLM 도움으로 번역한 것입니다.

ClickHouse 공식 문서 "Accessing S3 data securely"는 S3에 안전하게 "접근"하는 방법만 다룹니다. 이 실습처럼 "쓰기" 작업을 하려면 `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`가 추가로 필요합니다. 노트 사이트에는 Terraform 외에 IAM Role을 만드는 방법이 두 가지 더 있습니다.

#### CloudFormation으로 IAM Role 생성

ClickHouse 공식 문서에서 제공하는 템플릿으로 필요한 리소스를 자동 생성합니다.

[CloudFormation 빠른 생성](https://us-west-2.console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/quickcreate?templateURL=https://s3.us-east-2.amazonaws.com/clickhouse-public-resources.clickhouse.cloud/cf-templates/secure-s3.yaml&stackName=ClickHouseSecureS3)

| 파라미터 | 설명 |
| --- | --- |
| RoleName | 생성할 IAM Role 이름 (예: ClickHouseAccessRole-001) |
| ClickHouse Instance Roles | ClickHouse 서비스 IAM Role ARN (쉼표로 구분) |
| Bucket Names | 접근을 허용할 S3 버킷 이름 (ARN이 아닌 이름만) |
| Bucket Access | Read 또는 Read/Write |
| Role Session Name | 추가 보안을 위한 세션 이름 (선택) |

#### AWS Console에서 직접 IAM Role 생성 (Terraform 없이)

**1. IAM Role 생성**

AWS Console → IAM → Roles → Create role로 이동합니다. "Custom trust policy"를 선택하고 아래 Trust Policy를 입력합니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowClickHouseAssumeRole",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::123456789012:role/CH-S3-your-service-Role"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

`Principal.AWS` 값을 ClickHouse Cloud Console에서 복사한 Service role ID (IAM)로 교체합니다.

**2. Permission Policy 생성**

Role 생성 후 Permissions 탭에서 "Add permissions" → "Create inline policy"를 선택하고 JSON 탭에서 아래 내용을 입력합니다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BucketLevelPermissions",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME"
    },
    {
      "Sid": "ObjectLevelReadPermissions",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
    },
    {
      "Sid": "ObjectLevelWritePermissions",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
    }
  ]
}
```

`YOUR_BUCKET_NAME`을 실제 S3 버킷 이름으로 교체합니다. 여러 버킷에 접근해야 하면 Resource를 배열로 지정하거나 Statement를 추가합니다.

**3. Role ARN 복사**

생성된 Role의 ARN (예: `arn:aws:iam::111111111111:role/ClickHouseAccessRole`)을 복사해서 ClickHouse 쿼리의 `extra_credentials`에서 사용합니다.
