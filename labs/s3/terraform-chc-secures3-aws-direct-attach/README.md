# ClickHouse S3 Integration with Direct Bucket Policy Access

> **Last run: 2025-12-05 — not verified** — date of the last commit made while running the lab (there is no separate run log). AWS provider `~> 5.0`.
> **That run failed on ClickHouse Cloud** (cross-account access, HTTP 403) — see the warning below.
> No code changes since — only documentation and licence edits.
>
> Not checked — adjust before `apply` (recorded 2026-10-04 from reading the code; nothing was run):
> - Never verified anywhere. The same-account and OSS cases under *When Direct Bucket Policy Works* were never run.
> - Missing on ClickHouse Cloud: per the limitation below, ClickHouse's own role (in ClickHouse's account) would also need a permission for your bucket, which you cannot add; the 403 was not traced further. Use [terraform-chc-secures3-aws](../terraform-chc-secures3-aws/) there.
> - Missing for an OSS or same-account check: a ClickHouse server running under an IAM role in your account, with that role's ARN in `clickhouse_iam_role_arns`. The lab creates only the bucket and its settings, the bucket policy and optional sample folders.
> - AWS provider: `~> 5.0` resolves to 5.100.0, the last 5.x release; never run on 6.x (6.67.0 is the newest, Terraform Registry API read 2026-10-04).
> - Potential issue ([#21](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/21)): the scripts come from the AssumeRole lab. `test-s3-integration.sh` reads `terraform output -raw iam_role_arn`, which this lab does not define (`outputs.tf` has `clickhouse_iam_role_arns`), and exits when it is empty; `deploy.sh` and `destroy.sh` read it too and fall back to `N/A` / empty. Their texts mention an IAM role and policy and `extra_credentials()` SQL that this lab does not use.
> - A re-run should show: a `SELECT` from the bucket succeeds under a role listed in `clickhouse_iam_role_arns` and returns 403 under a role that is not.
>
> AWS and ClickHouse Cloud behaviour may have drifted since.
>
> **마지막 실행: 2025-12-05 — 검증되지 않음** — 실습을 실행하며 남긴 마지막 커밋 날짜 (별도 실행 기록은 없음). AWS provider `~> 5.0`.
> **이 실행은 ClickHouse Cloud에서 실패했습니다** (교차 계정 접근, HTTP 403) — 아래 경고 참고.
> 그 뒤 코드 변경 없음 — 문서와 라이선스 수정만 있었음.
>
> 확인 안 된 것 — `apply` 전에 맞출 것 (2026-10-04 코드를 읽고 기록, 실행 안 함):
> - 어디서도 검증된 적 없음. 아래 *직접 버킷 정책 방식이 동작하는 경우*의 같은 계정·OSS 경우도 실행한 적 없음.
> - ClickHouse Cloud에서 빠진 것: 아래 제약 설명대로라면 ClickHouse 계정에 있는 ClickHouse 쪽 IAM 역할에도 이 버킷 권한이 있어야 하는데, 사용자는 그것을 추가할 수 없음. 403의 원인을 더 추적하지는 않았음. ClickHouse Cloud에서는 [terraform-chc-secures3-aws](../terraform-chc-secures3-aws/)를 쓸 것.
> - OSS·같은 계정 확인에 빠진 것: 내 계정의 IAM 역할로 실행되는 ClickHouse 서버와, 그 역할 ARN을 넣은 `clickhouse_iam_role_arns`. 이 실습은 버킷과 그 설정, 버킷 정책, 선택적 샘플 폴더만 만듦.
> - AWS provider: `~> 5.0`은 마지막 5.x인 5.100.0으로 잡힘. 6.x에서는 실행한 적 없음 (최신 6.67.0, 2026-10-04 Terraform Registry API로 확인).
> - 잠재 문제 ([#21](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/21)): 스크립트가 AssumeRole 실습에서 온 것임. `test-s3-integration.sh`는 이 실습에 없는 출력값 `iam_role_arn`을 `terraform output -raw iam_role_arn`으로 읽고(`outputs.tf`에는 `clickhouse_iam_role_arns`만 있음), 값이 비면 종료함. `deploy.sh`, `destroy.sh`도 같은 값을 읽고 `N/A`·빈 값으로 넘어감. 스크립트 문구의 IAM 역할·정책, `extra_credentials()` SQL은 이 실습에서 쓰지 않음.
> - 재실행에서 보여야 할 것: `clickhouse_iam_role_arns`에 있는 역할로는 버킷 `SELECT`가 성공하고, 없는 역할로는 403이 남.
>
> 그동안 AWS·ClickHouse Cloud 동작이 달라졌을 수 있습니다.

[English](#english) | [한국어](#한국어)

## English

> **⚠️ WARNING: Limited ClickHouse Cloud Support**
> This approach **does not work reliably with ClickHouse Cloud** due to cross-account limitations.
> **For ClickHouse Cloud, use [terraform-chc-secures3-aws](../terraform-chc-secures3-aws/) instead.**
> This configuration is useful for learning, OSS ClickHouse, or same-account scenarios.

This Terraform configuration sets up S3 access using **direct S3 bucket policy** instead of IAM role assumption. This method provides a simpler approach where an IAM role is granted direct access to the S3 bucket through bucket policies.

### ⚠️ Important Limitation: Cross-Account Access

**This direct bucket policy approach has a significant limitation with ClickHouse Cloud:**

ClickHouse Cloud services run in **ClickHouse's AWS account** (different from your account), which creates a **cross-account access scenario**. For cross-account S3 access to work:

1. **S3 Bucket Policy** (your account) - ✅ This Terraform handles this
2. **IAM Role Policy** (ClickHouse's account) - ❌ ClickHouse must configure this

**Result**: The direct bucket policy method **may not work** with ClickHouse Cloud because:
- You can set the S3 bucket policy (done by this Terraform)
- But ClickHouse's IAM role also needs permissions to access your bucket
- You cannot modify ClickHouse's IAM role policy

#### Recommended Approach

For **ClickHouse Cloud**, use the **AssumeRole method** ([terraform-chc-secures3-aws](../terraform-chc-secures3-aws/)) instead:
- Works reliably with cross-account scenarios
- You create an IAM role in your account that ClickHouse can assume
- Full control over permissions
- Proven to work with ClickHouse Cloud

#### When Direct Bucket Policy Works

This approach is expected to work for the cases below — none of them has been run (see the banner):
- **Same-account scenarios** (ClickHouse running in your own AWS account)
- **OSS ClickHouse** self-hosted on EC2 with instance roles
- **Testing and learning** about S3 bucket policies

### Key Differences from AssumeRole Method

#### Direct Bucket Policy Access (This Project)
- ✅ **Simpler SQL**: No `extra_credentials()` needed in queries
- ✅ **Fewer AWS Resources**: No additional IAM role creation needed
- ✅ **Easier Setup**: Less configuration required
- ⚠️ **Limited Cross-Account**: May not work with ClickHouse Cloud
- ❔ **OSS (not run)**: expected to work with self-hosted ClickHouse

#### AssumeRole Method (terraform-chc-secures3-aws) - **Recommended for ClickHouse Cloud**
- ✅ **Cross-Account Compatible**: Proven to work with ClickHouse Cloud
- ✅ **Full Control**: You control the IAM role permissions
- ✅ **Additional Security**: External ID option available
- ⚠️ **More Complex SQL**: Requires `extra_credentials(role_arn = '...')` in queries
- ⚠️ **More Resources**: Creates an additional IAM role

### Architecture

```
┌─────────────────────────┐
│  ClickHouse Cloud      │
│  Service               │
│  (with IAM Role)       │
└───────────┬─────────────┘
            │ Direct Access
            │ (via Bucket Policy)
            ▼
┌─────────────────────────┐
│  S3 Bucket             │
│  - Bucket Policy       │
│  - Encrypted           │
│  - Versioned           │
│  - Private             │
└─────────────────────────┘
```

### Features

- **Direct Access**: ClickHouse IAM role directly accesses S3 via bucket policy
- **Simplified SQL Queries**: No extra_credentials() required
- **Read & Write Permissions**: Full support for SELECT, INSERT, and export operations
- **S3 Table Engine Support**: Create tables backed by S3 storage in various formats
- **Bucket hardening**: encryption (AES256), versioning and public ACL blocking
- **Multiple Format Support**: Parquet, CSV, JSON, and other ClickHouse-supported formats

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

#### Step 1: Get Your ClickHouse IAM Role ARN

1. Log into [ClickHouse Cloud Console](https://clickhouse.cloud/)
2. Select your service
3. Navigate to: **Settings** → **Network security information**
4. Copy the **Service role ID (IAM)** value
   - Format: `arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx`

#### Step 2: Configure Terraform

Copy the example configuration:

```bash
cd labs/s3/terraform-chc-secures3-aws-direct-attach  # from the repository root
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# REQUIRED: Set a globally unique bucket name
bucket_name = "my-company-clickhouse-data-2024"

# REQUIRED: Paste your ClickHouse Cloud IAM role ARN
clickhouse_iam_role_arns = [
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx"
]

# Optional: Customize other settings
aws_region = "ap-northeast-2"  # Same region as ClickHouse Cloud recommended
environment = "production"
```

#### Step 3: Deploy

```bash
# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply
```

The deployment takes about 1-2 minutes.

Instead of Steps 2–3 you can run `./deploy.sh`: it creates `terraform.tfvars` from the example if it is missing, asks for a bucket name and the ClickHouse IAM role ARN (saved to `.env`), runs `terraform init`, `validate` and `plan`, and applies the plan after you type `yes`. Its confirmation text lists an IAM role and policy that `main.tf` does not create, and the `deployment-info.txt` it writes uses `extra_credentials()` SQL; both are left over from the AssumeRole lab.

#### Step 4: Get Connection Information

After deployment, view the connection details:

```bash
# View complete connection information
terraform output connection_info

# View SQL examples
terraform output clickhouse_sql_examples
```

`./test-s3-integration.sh` checks that the bucket exists, uploads a small CSV to `test/data.csv` with the AWS CLI and writes SQL files (`test_s3_queries.sql`, `example_*.sql`) for you to run in ClickHouse; it does not connect to ClickHouse itself. As written it also needs a Terraform output `iam_role_arn`, which `outputs.tf` does not define, and exits when that output is empty; its SQL uses `extra_credentials()` from the AssumeRole lab.

### Usage Examples

#### Example 1: Create S3-Backed Table (Parquet Format)

**Notice: No `extra_credentials()` needed!**

```sql
CREATE TABLE logs_s3
(
    timestamp DateTime,
    level String,
    message String
)
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/logs/app_logs.parquet',
    'Parquet'
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

Query S3 files directly:

```sql
SELECT *
FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/*.parquet'
)
LIMIT 100;
```

#### Example 3: Export Query Results to S3

```sql
INSERT INTO FUNCTION s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/exports/daily_summary.parquet',
    'Parquet',
    'date Date, total_events UInt64, unique_users UInt64'
)
SELECT
    toDate(timestamp) AS date,
    count() AS total_events,
    uniq(user_id) AS unique_users
FROM events
GROUP BY date;
```

#### Example 4: CSV Format

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
    'CSVWithNames'
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
    'JSONEachRow'
);
```

### Comparison: Direct Access vs AssumeRole

#### SQL Syntax Comparison

**Direct Access (This Project):**
```sql
CREATE TABLE my_table (...)
ENGINE = S3(
    'https://s3.region.amazonaws.com/bucket/path',
    'Parquet'
);
```

**AssumeRole Method:**
```sql
CREATE TABLE my_table (...)
ENGINE = S3(
    'https://s3.region.amazonaws.com/bucket/path',
    'Parquet',
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
| `environment` | Environment tag | "dev" | No |
| `enable_versioning` | Enable S3 versioning | true | No |
| `create_sample_folders` | Create sample folders | true | No |

#### S3 Bucket Policy Permissions

The bucket policy grants the following permissions to ClickHouse IAM role ARNs:

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
    'https://s3.ap-northeast-2.amazonaws.com/bucket/data/year=*/month=*/day=*/*.parquet'
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

#### Error: "Access Denied" (HTTP 403)

**Most Common Cause: Cross-Account Access Limitation**

If you're using **ClickHouse Cloud**, the 403 error is likely due to cross-account access:

```
Failed to check existence of key: ACCESS_DENIED. HTTP response code: 403
```

**Why this happens:**
- ClickHouse Cloud runs in ClickHouse's AWS account (e.g., <clickhouse-cloud-aws-account-id>)
- Your S3 bucket is in your AWS account (e.g., 123456789012)
- For cross-account access to work, **both sides** need configuration:
  - ✅ S3 bucket policy (you can set this - done by Terraform)
  - ❌ ClickHouse IAM role policy (ClickHouse controls this - you cannot set)

**Solution:**
Use the **AssumeRole method** ([terraform-chc-secures3-aws](../terraform-chc-secures3-aws/)) which is designed for cross-account scenarios.

**Other Possible Causes:**
1. Incorrect ClickHouse IAM role ARN in terraform.tfvars
2. S3 bucket policy not properly applied
3. Region mismatch

**Verification Steps:**
```bash
# 1. Verify your ClickHouse IAM role ARN
terraform output clickhouse_iam_role_arns

# 2. Check the S3 bucket policy is applied
aws s3api get-bucket-policy --bucket your-bucket-name --query Policy --output text | python3 -m json.tool

# 3. Verify bucket region matches
aws s3api get-bucket-location --bucket your-bucket-name

# 4. Check AWS account IDs
aws sts get-caller-identity  # Your account
# Compare with ClickHouse role ARN account ID
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

**Cause:** Malformed S3 URL

**Solution:** Use the exact format from terraform outputs:
```bash
terraform output clickhouse_sql_examples
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

The snippet assumes a separate log bucket, `aws_s3_bucket.log_bucket`, that you create yourself; `main.tf` does not define it.

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

`./destroy.sh` does the same with prompts: it lists the bucket's objects, offers a local backup (`aws s3 sync`), empties the bucket including old object versions (`main.tf` does not set `force_destroy`), applies a destroy plan after you type `yes`, and offers to delete the local Terraform files.

### Outputs Reference

After deployment, these outputs are available:

```bash
# Essential outputs
terraform output bucket_name                    # S3 bucket name
terraform output clickhouse_iam_role_arns      # ClickHouse IAM role ARNs
terraform output s3_url_prefix                 # Base S3 URL

# Detailed information
terraform output connection_info                # Complete setup information
terraform output clickhouse_sql_examples       # Ready-to-use SQL examples
terraform output setup_checklist              # Step-by-step setup guide
```

### When to Use Direct Access vs AssumeRole

#### Use Direct Bucket Policy Access (This Project) When:
- You want simpler SQL queries without extra_credentials()
- You have a single or few ClickHouse services accessing the bucket
- You prefer minimal AWS resource creation
- Security requirements allow direct access

#### Use AssumeRole Method When:
- You need additional security layers (External ID)
- You want to centralize access control through IAM roles
- You need more granular audit trails
- You want to follow the principle of least privilege more strictly

### Related Documentation

- [ClickHouse S3 Table Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/s3)
- [ClickHouse Cloud Secure S3](https://clickhouse.com/docs/cloud/data-sources/secure-s3)
- [AWS S3 Bucket Policies](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html)
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

---

## 한국어

> **⚠️ 경고: ClickHouse Cloud 지원 제한**
> 이 방식은 교차 계정 제약 때문에 **ClickHouse Cloud에서 안정적으로 동작하지 않습니다**.
> **ClickHouse Cloud에서는 대신 [terraform-chc-secures3-aws](../terraform-chc-secures3-aws/)를 사용하세요.**
> 이 구성은 학습용, OSS ClickHouse, 또는 같은 계정 시나리오에 유용합니다.

이 Terraform 구성은 IAM 역할 위임 대신 **S3 버킷 정책 직접 부여** 방식으로 S3 접근을 설정합니다. IAM 역할에 버킷 정책을 통해 S3 버킷 직접 접근 권한을 주는, 더 단순한 방식입니다.

### ⚠️ 중요한 제약: 교차 계정 접근

**이 직접 버킷 정책 방식은 ClickHouse Cloud에서 중대한 제약이 있습니다.**

ClickHouse Cloud 서비스는 (내 계정과 다른) **ClickHouse의 AWS 계정**에서 실행되므로 **교차 계정 접근 시나리오**가 됩니다. 교차 계정 S3 접근이 동작하려면 다음이 필요합니다.

1. **S3 버킷 정책** (내 계정) - ✅ 이 Terraform이 처리합니다
2. **IAM 역할 정책** (ClickHouse 계정) - ❌ ClickHouse가 설정해야 합니다

**결과**: 다음 이유로 직접 버킷 정책 방식은 ClickHouse Cloud에서 **동작하지 않을 수 있습니다**.
- S3 버킷 정책은 설정할 수 있습니다 (이 Terraform이 설정함)
- 하지만 ClickHouse의 IAM 역할에도 내 버킷에 접근할 권한이 필요합니다
- ClickHouse의 IAM 역할 정책은 수정할 수 없습니다

#### 권장 방식

**ClickHouse Cloud**에서는 대신 **AssumeRole 방식**([terraform-chc-secures3-aws](../terraform-chc-secures3-aws/))을 사용하세요.
- 교차 계정 시나리오에서 안정적으로 동작합니다
- ClickHouse가 위임받을(assume) 수 있는 IAM 역할을 내 계정에 만듭니다
- 권한을 완전히 통제할 수 있습니다
- ClickHouse Cloud에서 동작이 입증되었습니다

#### 직접 버킷 정책 방식이 동작하는 경우

아래 경우에는 이 방식이 동작할 것으로 예상됩니다. 다만 어느 것도 실행한 적은 없습니다(배너 참고).
- **같은 계정 시나리오** (ClickHouse가 내 AWS 계정에서 실행되는 경우)
- 인스턴스 역할을 쓰는 EC2에 직접 호스팅한 **OSS ClickHouse**
- S3 버킷 정책에 대한 **테스트와 학습**

### AssumeRole 방식과의 주요 차이

#### 직접 버킷 정책 접근 (이 프로젝트)
- ✅ **더 단순한 SQL**: 쿼리에 `extra_credentials()`가 필요 없습니다
- ✅ **더 적은 AWS 리소스**: 추가 IAM 역할을 만들 필요가 없습니다
- ✅ **더 쉬운 설정**: 필요한 구성이 적습니다
- ⚠️ **제한적인 교차 계정**: ClickHouse Cloud에서 동작하지 않을 수 있습니다
- ❔ **OSS (실행 안 함)**: 직접 호스팅한 ClickHouse에서 동작할 것으로 예상됩니다

#### AssumeRole 방식 (terraform-chc-secures3-aws) - **ClickHouse Cloud에 권장**
- ✅ **교차 계정 호환**: ClickHouse Cloud에서 동작이 입증되었습니다
- ✅ **완전한 통제**: IAM 역할 권한을 직접 통제합니다
- ✅ **추가 보안**: External ID 옵션을 쓸 수 있습니다
- ⚠️ **더 복잡한 SQL**: 쿼리에 `extra_credentials(role_arn = '...')`가 필요합니다
- ⚠️ **더 많은 리소스**: 추가 IAM 역할을 하나 만듭니다

### 아키텍처

```
┌─────────────────────────┐
│  ClickHouse Cloud      │
│  Service               │
│  (with IAM Role)       │
└───────────┬─────────────┘
            │ Direct Access
            │ (via Bucket Policy)
            ▼
┌─────────────────────────┐
│  S3 Bucket             │
│  - Bucket Policy       │
│  - Encrypted           │
│  - Versioned           │
│  - Private             │
└─────────────────────────┘
```

### 기능

- **직접 접근**: ClickHouse IAM 역할이 버킷 정책을 통해 S3에 직접 접근합니다
- **단순해진 SQL 쿼리**: extra_credentials()가 필요 없습니다
- **읽기·쓰기 권한**: SELECT, INSERT, 내보내기 작업을 모두 지원합니다
- **S3 테이블 엔진 지원**: 다양한 포맷의 S3 스토리지를 기반으로 하는 테이블을 만듭니다
- **버킷 보호 설정**: 암호화(AES256), 버전 관리, 퍼블릭 ACL 차단을 포함합니다
- **여러 포맷 지원**: Parquet, CSV, JSON 및 ClickHouse가 지원하는 그 밖의 포맷

### 사전 준비

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- 적절한 권한이 있는 AWS 계정
- 자격 증명이 설정된 AWS CLI
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

#### 1단계: ClickHouse IAM 역할 ARN 확인

1. [ClickHouse Cloud 콘솔](https://clickhouse.cloud/)에 로그인합니다
2. 서비스를 선택합니다
3. **Settings** → **Network security information**으로 이동합니다
4. **Service role ID (IAM)** 값을 복사합니다
   - 형식: `arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx`

#### 2단계: Terraform 구성

예시 구성을 복사합니다.

```bash
cd labs/s3/terraform-chc-secures3-aws-direct-attach  # 저장소 루트에서
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars`를 편집합니다.

```hcl
# 필수: 전역에서 고유한 버킷 이름을 지정합니다
bucket_name = "my-company-clickhouse-data-2024"

# 필수: ClickHouse Cloud IAM 역할 ARN을 붙여 넣습니다
clickhouse_iam_role_arns = [
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx"
]

# 선택: 그 밖의 설정을 조정합니다
aws_region = "ap-northeast-2"  # ClickHouse Cloud와 같은 리전을 권장
environment = "production"
```

#### 3단계: 배포

```bash
# Terraform 초기화
terraform init

# 배포 계획 검토
terraform plan

# 인프라 배포
terraform apply
```

배포에는 1-2분 정도 걸립니다.

2–3단계 대신 `./deploy.sh`를 실행해도 됩니다. 이 스크립트는 `terraform.tfvars`가 없으면 예시에서 만들고, 버킷 이름과 ClickHouse IAM 역할 ARN을 물어본 뒤(ARN은 `.env`에 저장), `terraform init`, `validate`, `plan`을 실행하고 `yes`를 입력하면 그 계획을 적용합니다. 확인 문구에는 `main.tf`가 만들지 않는 IAM 역할과 정책이 나오고, 스크립트가 쓰는 `deployment-info.txt`에는 `extra_credentials()` SQL이 들어 있습니다. 둘 다 AssumeRole 실습에서 남은 것입니다.

#### 4단계: 연결 정보 확인

배포가 끝나면 연결 정보를 확인합니다.

```bash
# 전체 연결 정보 보기
terraform output connection_info

# SQL 예시 보기
terraform output clickhouse_sql_examples
```

`./test-s3-integration.sh`는 버킷이 있는지 확인하고, AWS CLI로 작은 CSV를 `test/data.csv`에 올리고, ClickHouse에서 실행할 SQL 파일(`test_s3_queries.sql`, `example_*.sql`)을 씁니다. ClickHouse에 직접 연결하지는 않습니다. 지금 코드로는 `outputs.tf`에 정의되지 않은 Terraform 출력값 `iam_role_arn`도 필요하며, 이 출력값이 비어 있으면 종료합니다. 스크립트가 쓰는 SQL은 AssumeRole 실습의 `extra_credentials()`를 사용합니다.

### 사용 예시

#### 예시 1: S3 기반 테이블 만들기 (Parquet 포맷)

**참고: `extra_credentials()`가 필요 없습니다!**

```sql
CREATE TABLE logs_s3
(
    timestamp DateTime,
    level String,
    message String
)
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/logs/app_logs.parquet',
    'Parquet'
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

S3 파일을 직접 쿼리합니다.

```sql
SELECT *
FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/*.parquet'
)
LIMIT 100;
```

#### 예시 3: 쿼리 결과를 S3로 내보내기

```sql
INSERT INTO FUNCTION s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/exports/daily_summary.parquet',
    'Parquet',
    'date Date, total_events UInt64, unique_users UInt64'
)
SELECT
    toDate(timestamp) AS date,
    count() AS total_events,
    uniq(user_id) AS unique_users
FROM events
GROUP BY date;
```

#### 예시 4: CSV 포맷

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
    'CSVWithNames'
);
```

#### 예시 5: JSON Lines 포맷

```sql
CREATE TABLE user_activity_json
(
    user_id String,
    action String,
    timestamp DateTime
)
ENGINE = S3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/activity_*.json',
    'JSONEachRow'
);
```

### 비교: 직접 접근 vs AssumeRole

#### SQL 문법 비교

**직접 접근 (이 프로젝트):**
```sql
CREATE TABLE my_table (...)
ENGINE = S3(
    'https://s3.region.amazonaws.com/bucket/path',
    'Parquet'
);
```

**AssumeRole 방식:**
```sql
CREATE TABLE my_table (...)
ENGINE = S3(
    'https://s3.region.amazonaws.com/bucket/path',
    'Parquet',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
);
```

### 지원 파일 포맷

ClickHouse S3 통합은 여러 포맷을 지원합니다.

- **Parquet** - 가장 좋은 압축과 성능을 위해 권장합니다
- **CSV**, **CSVWithNames** - 헤더를 선택적으로 포함하는 단순 텍스트 포맷
- **JSONEachRow** - 한 줄에 JSON 객체 하나
- **TSV**, **TSVWithNames** - 탭으로 구분한 값
- **Native** - ClickHouse 네이티브 포맷 (ClickHouse 간 전송에 가장 적합)
- **Avro**, **ORC** - 그 밖의 컬럼형 포맷

### 구성

#### 변수

| 변수 | 설명 | 기본값 | 필수 |
|----------|-------------|---------|----------|
| `aws_region` | 배포할 AWS 리전 | null (환경 변수 사용) | 아니요 |
| `bucket_name` | S3 버킷 이름 (전역에서 고유) | - | **예** |
| `clickhouse_iam_role_arns` | ClickHouse Cloud IAM 역할 ARN (하나 이상) | - | **예** |
| `environment` | 환경 태그 | "dev" | 아니요 |
| `enable_versioning` | S3 버전 관리 사용 | true | 아니요 |
| `create_sample_folders` | 샘플 폴더 생성 | true | 아니요 |

#### S3 버킷 정책 권한

버킷 정책은 ClickHouse IAM 역할 ARN에 다음 권한을 부여합니다.

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

### S3 버킷 구조

Terraform 구성은 선택적으로 다음 폴더 구조를 만듭니다.

```
your-bucket-name/
├── data/           # 데이터 파일용
├── logs/           # 로그 파일용
└── exports/        # 내보낸 쿼리 결과용
```

파일은 원하는 대로 정리해도 됩니다.

### 모범 사례

#### 1. 같은 AWS 리전 사용

다음을 위해 S3 버킷을 ClickHouse Cloud 서비스와 같은 AWS 리전에 두세요.
- 데이터 전송 비용 최소화
- 지연 시간 감소
- 성능 향상

#### 2. Parquet 포맷 사용

가장 좋은 성능과 저장 효율을 얻으려면 다음과 같이 합니다.
- 큰 데이터셋에는 Parquet을 사용합니다
- 압축을 켭니다 (Parquet에는 압축이 내장되어 있습니다)
- 큰 데이터셋은 파티셔닝을 고려합니다

#### 3. 파티션된 데이터에는 와일드카드 사용

```sql
-- 모든 파티션 조회
SELECT * FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/bucket/data/year=*/month=*/day=*/*.parquet'
)
WHERE toDate(timestamp) >= today() - 7;
```

#### 4. S3 버전 관리 사용

다음을 위해 버전 관리를 켜 둡니다.
- 실수로 인한 삭제 방지
- 데이터 이력 유지
- 데이터 복구 가능

#### 5. 비용 모니터링

다음 항목을 지켜봅니다.
- S3 스토리지 비용 (스토리지 클래스에 따라 다름)
- 데이터 전송 비용 (특히 리전 간)
- S3 요청 비용 (PUT, GET 작업)

### 문제 해결

#### 오류: "Access Denied" (HTTP 403)

**가장 흔한 원인: 교차 계정 접근 제약**

**ClickHouse Cloud**를 쓰고 있다면 403 오류는 교차 계정 접근 때문일 가능성이 큽니다.

```
Failed to check existence of key: ACCESS_DENIED. HTTP response code: 403
```

**발생 이유:**
- ClickHouse Cloud는 ClickHouse의 AWS 계정에서 실행됩니다 (예: <clickhouse-cloud-aws-account-id>)
- S3 버킷은 내 AWS 계정에 있습니다 (예: 123456789012)
- 교차 계정 접근이 동작하려면 **양쪽 모두** 설정이 필요합니다
  - ✅ S3 버킷 정책 (직접 설정 가능 - Terraform이 설정함)
  - ❌ ClickHouse IAM 역할 정책 (ClickHouse가 관리 - 직접 설정 불가)

**해결 방법:**
교차 계정 시나리오를 위해 설계된 **AssumeRole 방식**([terraform-chc-secures3-aws](../terraform-chc-secures3-aws/))을 사용하세요.

**그 밖의 가능한 원인:**
1. terraform.tfvars의 ClickHouse IAM 역할 ARN이 잘못됨
2. S3 버킷 정책이 제대로 적용되지 않음
3. 리전 불일치

**확인 단계:**
```bash
# 1. ClickHouse IAM 역할 ARN 확인
terraform output clickhouse_iam_role_arns

# 2. S3 버킷 정책이 적용되었는지 확인
aws s3api get-bucket-policy --bucket your-bucket-name --query Policy --output text | python3 -m json.tool

# 3. 버킷 리전이 맞는지 확인
aws s3api get-bucket-location --bucket your-bucket-name

# 4. AWS 계정 ID 확인
aws sts get-caller-identity  # 내 계정
# ClickHouse 역할 ARN의 계정 ID와 비교
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

**원인:** 형식이 잘못된 S3 URL

**해결 방법:** terraform 출력값의 형식을 그대로 사용합니다.
```bash
terraform output clickhouse_sql_examples
```

### 모니터링과 로깅

#### CloudWatch 메트릭

다음 S3 메트릭을 모니터링합니다.
- `NumberOfObjects` - 버킷의 전체 객체 수
- `BucketSizeBytes` - 사용 중인 전체 스토리지
- `AllRequests` - 전체 API 요청 수

#### S3 액세스 로깅 (선택)

감사 기록을 남기려면 S3 액세스 로깅을 켭니다.

```hcl
# main.tf에 추가
resource "aws_s3_bucket_logging" "clickhouse_data_logging" {
  bucket = aws_s3_bucket.clickhouse_data.id

  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "s3-access-logs/"
}
```

이 코드는 직접 만든 별도 로그 버킷 `aws_s3_bucket.log_bucket`을 전제로 합니다. `main.tf`에는 이 리소스가 정의되어 있지 않습니다.

### 비용 최적화

#### 예상 비용

데이터가 100 GB인 버킷 기준:

- **S3 스토리지 (Standard)**: ~$2.30/월
- **S3 요청**: ~$0.50/월 (사용량에 따라 다름)
- **데이터 전송 (같은 리전)**: $0 (무료)
- **데이터 전송 (리전 간)**: $0.02/GB

**합계**: 보통 수준의 사용량에서 ~$3-5/월

실습을 작성할 때의 추정치이며 측정한 값이 아닙니다. 사용하는 리전의 현재 AWS 요금을 확인하세요.

#### 비용 절감 팁

1. **S3 수명 주기 정책 사용**: 오래된 데이터를 더 저렴한 스토리지 클래스로 옮깁니다
2. **S3 Intelligent-Tiering 사용**: 스토리지 비용을 자동으로 최적화합니다
3. **데이터 압축**: 압축을 적용한 Parquet을 사용합니다
4. **요청 최소화**: 가능하면 작업을 묶어서 처리합니다
5. **데이터를 같은 리전에 유지**: 리전 간 전송 요금을 피합니다

### 고급 구성

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

`./destroy.sh`는 같은 작업을 확인 질문과 함께 합니다. 버킷의 객체를 보여 주고, 로컬 백업(`aws s3 sync`)을 제안하고, 이전 객체 버전까지 포함해 버킷을 비운 다음(`main.tf`는 `force_destroy`를 설정하지 않음), `yes`를 입력하면 삭제 계획을 적용하고, 로컬 Terraform 파일 삭제를 제안합니다.

### 출력값 (`outputs`) 참조

배포가 끝나면 다음 출력값을 쓸 수 있습니다.

```bash
# 핵심 출력값
terraform output bucket_name                    # S3 버킷 이름
terraform output clickhouse_iam_role_arns      # ClickHouse IAM 역할 ARN
terraform output s3_url_prefix                 # 기본 S3 URL

# 상세 정보
terraform output connection_info                # 전체 설정 정보
terraform output clickhouse_sql_examples       # 바로 쓸 수 있는 SQL 예시
terraform output setup_checklist              # 단계별 설정 가이드
```

### 직접 접근과 AssumeRole 중 언제 무엇을 쓸지

#### 직접 버킷 정책 접근(이 프로젝트)을 쓰는 경우
- extra_credentials() 없이 더 단순한 SQL 쿼리를 쓰고 싶을 때
- 버킷에 접근하는 ClickHouse 서비스가 하나이거나 몇 개뿐일 때
- AWS 리소스 생성을 최소화하고 싶을 때
- 보안 요구 사항이 직접 접근을 허용할 때

#### AssumeRole 방식을 쓰는 경우
- 추가 보안 계층(External ID)이 필요할 때
- IAM 역할로 접근 제어를 중앙화하고 싶을 때
- 더 세밀한 감사 기록이 필요할 때
- 최소 권한 원칙을 더 엄격하게 따르고 싶을 때

### 관련 문서

- [ClickHouse S3 테이블 엔진](https://clickhouse.com/docs/en/engines/table-engines/integrations/s3)
- [ClickHouse Cloud Secure S3](https://clickhouse.com/docs/cloud/data-sources/secure-s3)
- [AWS S3 버킷 정책](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html)
- [S3 모범 사례](https://docs.aws.amazon.com/AmazonS3/latest/userguide/best-practices.html)

### 지원

문제나 질문이 있으면 다음을 참고하세요.

- ClickHouse 문서: https://clickhouse.com/docs
- ClickHouse 커뮤니티 Slack: https://clickhouse.com/slack
- AWS Support: https://console.aws.amazon.com/support/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/

### 라이선스

[MIT](../../../LICENSE) — 저장소의 나머지 부분과 같습니다. 이전 문구는 아무 권리도 부여하지 않았습니다.
그래도 여전히 교육용 자료입니다. 비용이 드는 실제 클라우드 리소스를 만들며, 어떤 보증도 하지 않습니다.
이 자료가 호출하는 provider와 서비스에는 각자의 약관이 있습니다.
