# ClickHouse S3 Integration with Direct Bucket Policy Access

> **⚠️ WARNING: Limited ClickHouse Cloud Support**
> This approach **does not work reliably with ClickHouse Cloud** due to cross-account limitations.
> **For ClickHouse Cloud, use [terraform-chc-secures3-aws](../terraform-chc-secures3-aws/) instead.**
> This configuration is useful for learning, OSS ClickHouse, or same-account scenarios.

This Terraform configuration sets up S3 access using **direct S3 bucket policy** instead of IAM role assumption. This method provides a simpler approach where an IAM role is granted direct access to the S3 bucket through bucket policies.

## ⚠️ Important Limitation: Cross-Account Access

**This direct bucket policy approach has a significant limitation with ClickHouse Cloud:**

ClickHouse Cloud services run in **ClickHouse's AWS account** (different from your account), which creates a **cross-account access scenario**. For cross-account S3 access to work:

1. **S3 Bucket Policy** (your account) - ✅ This Terraform handles this
2. **IAM Role Policy** (ClickHouse's account) - ❌ ClickHouse must configure this

**Result**: The direct bucket policy method **may not work** with ClickHouse Cloud because:
- You can set the S3 bucket policy (done by this Terraform)
- But ClickHouse's IAM role also needs permissions to access your bucket
- You cannot modify ClickHouse's IAM role policy

### Recommended Approach

For **ClickHouse Cloud**, use the **AssumeRole method** ([terraform-chc-secures3-aws](../terraform-chc-secures3-aws/)) instead:
- Works reliably with cross-account scenarios
- You create an IAM role in your account that ClickHouse can assume
- Full control over permissions
- Proven to work with ClickHouse Cloud

### When Direct Bucket Policy Works

This approach works well for:
- **Same-account scenarios** (ClickHouse running in your own AWS account)
- **OSS ClickHouse** self-hosted on EC2 with instance roles
- **Testing and learning** about S3 bucket policies

## Key Differences from AssumeRole Method

### Direct Bucket Policy Access (This Project)
- ✅ **Simpler SQL**: No `extra_credentials()` needed in queries
- ✅ **Fewer AWS Resources**: No additional IAM role creation needed
- ✅ **Easier Setup**: Less configuration required
- ⚠️ **Limited Cross-Account**: May not work with ClickHouse Cloud
- ✅ **Good for OSS**: Works well with self-hosted ClickHouse

### AssumeRole Method (terraform-chc-secures3-aws) - **Recommended for ClickHouse Cloud**
- ✅ **Cross-Account Compatible**: Proven to work with ClickHouse Cloud
- ✅ **Full Control**: You control the IAM role permissions
- ✅ **Additional Security**: External ID option available
- ⚠️ **More Complex SQL**: Requires `extra_credentials(role_arn = '...')` in queries
- ⚠️ **More Resources**: Creates an additional IAM role

## Architecture

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

## Features

- **Direct Access**: ClickHouse IAM role directly accesses S3 via bucket policy
- **Simplified SQL Queries**: No extra_credentials() required
- **Read & Write Permissions**: Full support for SELECT, INSERT, and export operations
- **S3 Table Engine Support**: Create tables backed by S3 storage in various formats
- **Production-Ready**: Includes encryption, versioning, and public access blocking
- **Multiple Format Support**: Parquet, CSV, JSON, and other ClickHouse-supported formats

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- ClickHouse Cloud service (free or paid tier)

## AWS Credentials Setup

Set your AWS credentials as environment variables:

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # If using temporary credentials
export AWS_REGION="ap-northeast-2"  # Optional: Set default region
```

## Quick Start

### Step 1: Get Your ClickHouse IAM Role ARN

1. Log into [ClickHouse Cloud Console](https://clickhouse.cloud/)
2. Select your service
3. Navigate to: **Settings** → **Network security information**
4. Copy the **Service role ID (IAM)** value
   - Format: `arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx`

### Step 2: Configure Terraform

Copy the example configuration:

```bash
cd terraform-chc-secures3-aws-direct-attach
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

### Step 3: Deploy

```bash
# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply
```

The deployment takes about 1-2 minutes.

### Step 4: Get Connection Information

After deployment, view the connection details:

```bash
# View complete connection information
terraform output connection_info

# View SQL examples
terraform output clickhouse_sql_examples
```

## Usage Examples

### Example 1: Create S3-Backed Table (Parquet Format)

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

### Example 2: Direct S3 Query Without Table

Query S3 files directly:

```sql
SELECT *
FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/*.parquet'
)
LIMIT 100;
```

### Example 3: Export Query Results to S3

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

### Example 4: CSV Format

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

### Example 5: JSON Lines Format

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

## Comparison: Direct Access vs AssumeRole

### SQL Syntax Comparison

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

## Supported File Formats

ClickHouse S3 integration supports many formats:

- **Parquet** - Recommended for best compression and performance
- **CSV**, **CSVWithNames** - Simple text format with optional headers
- **JSONEachRow** - One JSON object per line
- **TSV**, **TSVWithNames** - Tab-separated values
- **Native** - ClickHouse native format (best for ClickHouse-to-ClickHouse)
- **Avro**, **ORC** - Other columnar formats

## Configuration

### Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `aws_region` | AWS region for deployment | null (uses env var) | No |
| `bucket_name` | S3 bucket name (globally unique) | - | **Yes** |
| `clickhouse_iam_role_arns` | ClickHouse Cloud IAM role ARN(s) | - | **Yes** |
| `environment` | Environment tag | "dev" | No |
| `enable_versioning` | Enable S3 versioning | true | No |
| `create_sample_folders` | Create sample folders | true | No |

### S3 Bucket Policy Permissions

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

## S3 Bucket Structure

The Terraform configuration optionally creates the following folder structure:

```
your-bucket-name/
├── data/           # For data files
├── logs/           # For log files
└── exports/        # For exported query results
```

You can organize your files however you prefer.

## Best Practices

### 1. Use the Same AWS Region

Place your S3 bucket in the same AWS region as your ClickHouse Cloud service to:
- Minimize data transfer costs
- Reduce latency
- Improve performance

### 2. Use Parquet Format

For best performance and storage efficiency:
- Use Parquet for large datasets
- Enable compression (Parquet has built-in compression)
- Consider partitioning large datasets

### 3. Use Wildcards for Partitioned Data

```sql
-- Query all partitions
SELECT * FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/bucket/data/year=*/month=*/day=*/*.parquet'
)
WHERE toDate(timestamp) >= today() - 7;
```

### 4. Enable S3 Versioning

Keep versioning enabled to:
- Protect against accidental deletions
- Maintain data history
- Enable data recovery

### 5. Monitor Costs

Watch for:
- S3 storage costs (varies by storage class)
- Data transfer costs (especially cross-region)
- S3 request costs (PUT, GET operations)

## Troubleshooting

### Error: "Access Denied" (HTTP 403)

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

### Error: "NoSuchBucket"

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

### Error: "InvalidParameter"

**Cause:** Malformed S3 URL

**Solution:** Use the exact format from terraform outputs:
```bash
terraform output clickhouse_sql_examples
```

## Monitoring and Logging

### CloudWatch Metrics

Monitor these S3 metrics:
- `NumberOfObjects` - Total objects in bucket
- `BucketSizeBytes` - Total storage used
- `AllRequests` - Total API requests

### S3 Access Logging (Optional)

Enable S3 access logging for audit trails:

```hcl
# Add to main.tf
resource "aws_s3_bucket_logging" "clickhouse_data_logging" {
  bucket = aws_s3_bucket.clickhouse_data.id

  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "s3-access-logs/"
}
```

## Cost Optimization

### Estimated Costs

For a bucket with 100 GB of data:

- **S3 Storage (Standard)**: ~$2.30/month
- **S3 Requests**: ~$0.50/month (varies by usage)
- **Data Transfer (same region)**: $0 (free)
- **Data Transfer (cross-region)**: $0.02/GB

**Total**: ~$3-5/month for moderate usage

### Cost Saving Tips

1. **Use S3 Lifecycle Policies**: Move old data to cheaper storage classes
2. **Use S3 Intelligent-Tiering**: Automatically optimize storage costs
3. **Compress Data**: Use Parquet with compression
4. **Minimize Requests**: Batch operations when possible
5. **Keep Data in Same Region**: Avoid cross-region transfer fees

## Advanced Configuration

### Multiple ClickHouse Services

To grant access to multiple ClickHouse Cloud services:

```hcl
# In terraform.tfvars
clickhouse_iam_role_arns = [
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-service1",
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-service2"
]
```

## Cleanup

To destroy all resources:

```bash
# Review what will be deleted
terraform plan -destroy

# Delete all resources
terraform destroy
```

**Warning**: This will delete the S3 bucket and all its contents. Make sure to backup any important data first.

## Outputs Reference

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

## When to Use Direct Access vs AssumeRole

### Use Direct Bucket Policy Access (This Project) When:
- You want simpler SQL queries without extra_credentials()
- You have a single or few ClickHouse services accessing the bucket
- You prefer minimal AWS resource creation
- Security requirements allow direct access

### Use AssumeRole Method When:
- You need additional security layers (External ID)
- You want to centralize access control through IAM roles
- You need more granular audit trails
- You want to follow the principle of least privilege more strictly

## Related Documentation

- [ClickHouse S3 Table Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/s3)
- [ClickHouse Cloud Secure S3](https://clickhouse.com/docs/cloud/data-sources/secure-s3)
- [AWS S3 Bucket Policies](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html)
- [S3 Best Practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/best-practices.html)

## Support

For issues or questions:

- ClickHouse Documentation: https://clickhouse.com/docs
- ClickHouse Community Slack: https://clickhouse.com/slack
- AWS Support: https://console.aws.amazon.com/support/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/

## License

This configuration is provided as-is for educational and development purposes.
