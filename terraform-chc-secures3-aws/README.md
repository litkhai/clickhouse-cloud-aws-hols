# ClickHouse Cloud Secure S3 Integration with Terraform

This Terraform configuration sets up secure S3 access for ClickHouse Cloud using IAM role-based authentication. It allows ClickHouse Cloud to read from and write to an S3 bucket using the S3 table engine without managing access keys.

## Features

- **Secure IAM Role-Based Authentication**: No access keys needed - uses AWS IAM role assumption
- **Read & Write Permissions**: Full support for SELECT, INSERT, and export operations
- **S3 Table Engine Support**: Create tables backed by S3 storage in various formats (Parquet, CSV, JSON)
- **Production-Ready**: Includes encryption, versioning, and public access blocking
- **Easy Integration**: Pre-configured for ClickHouse Cloud service roles
- **Multiple Format Support**: Parquet, CSV, JSON, and other ClickHouse-supported formats

## Architecture

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

### 1. Get ClickHouse Cloud IAM Role ARN

Before running Terraform, you need to get your ClickHouse Cloud service's IAM role ARN:

1. Log into [ClickHouse Cloud Console](https://clickhouse.cloud/)
2. Select your service
3. Navigate to: **Settings** → **Network security information**
4. Copy the **Service role ID (IAM)** value
   - Format: `arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx`

### 2. Configure Variables

Copy the example configuration:

```bash
cd terraform-chc-secures3-aws
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your configuration:

```hcl
# REQUIRED: Set a globally unique bucket name
bucket_name = "my-company-clickhouse-data-2024"

# REQUIRED: Paste your ClickHouse Cloud IAM role ARN from step 1
clickhouse_iam_role_arns = [
  "arn:aws:iam::123456789012:role/ClickHouseInstanceRole-xxxxx"
]

# Optional: Customize other settings
aws_region = "ap-northeast-2"  # Same region as ClickHouse Cloud recommended
iam_role_name = "ClickHouseS3Access"
environment = "production"
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

The deployment takes about 1-2 minutes.

### 4. Get Connection Information

After deployment, view the connection details:

```bash
# View complete connection information
terraform output connection_info

# Get the IAM role ARN (needed for ClickHouse queries)
terraform output iam_role_arn

# View SQL examples
terraform output clickhouse_sql_examples
```

## Usage Examples

### Example 1: Create S3-Backed Table (Parquet Format)

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

### Example 2: Direct S3 Query Without Table

Query S3 files directly without creating a table:

```sql
SELECT *
FROM s3(
    'https://s3.ap-northeast-2.amazonaws.com/your-bucket-name/data/*.parquet',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
)
LIMIT 100;
```

### Example 3: Export Query Results to S3

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

### Example 4: CSV Format with Headers

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
    'JSONEachRow',
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
| `iam_role_name` | Name for IAM role | "ClickHouseS3Access" | No |
| `environment` | Environment tag | "dev" | No |
| `enable_versioning` | Enable S3 versioning | true | No |
| `create_sample_folders` | Create sample folders | true | No |
| `require_external_id` | Use external ID for security | false | No |
| `external_id` | External ID shared secret | "" | No (if enabled) |

### IAM Permissions

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

## Testing

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
    'https://s3.ap-northeast-2.amazonaws.com/bucket/data/year=*/month=*/day=*/*.parquet',
    extra_credentials(role_arn = 'arn:aws:iam::123456789012:role/ClickHouseS3Access')
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

### Error: "Access Denied"

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

**Cause:** Malformed S3 URL or role ARN

**Solution:** Use the exact format from terraform outputs:
```bash
terraform output clickhouse_sql_examples
```

### Testing IAM Role Assumption

Test if ClickHouse can assume the role:

```bash
# Get the role ARN
ROLE_ARN=$(terraform output -raw iam_role_arn)

# Try to assume the role (this should fail from your local machine)
aws sts assume-role --role-arn $ROLE_ARN --role-session-name test
# Expected: Error because only ClickHouse can assume this role
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

### Using External ID for Additional Security

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
terraform output bucket_name              # S3 bucket name
terraform output iam_role_arn            # IAM role ARN for ClickHouse
terraform output s3_url_prefix           # Base S3 URL

# Detailed information
terraform output connection_info          # Complete setup information
terraform output clickhouse_sql_examples  # Ready-to-use SQL examples
terraform output setup_checklist         # Step-by-step setup guide
```

## Related Documentation

- [ClickHouse S3 Table Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/s3)
- [ClickHouse Cloud Secure S3](https://clickhouse.com/docs/cloud/data-sources/secure-s3)
- [AWS IAM Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
- [S3 Best Practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/best-practices.html)

## Support

For issues or questions:

- ClickHouse Documentation: https://clickhouse.com/docs
- ClickHouse Community Slack: https://clickhouse.com/slack
- AWS Support: https://console.aws.amazon.com/support/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/

## License

This configuration is provided as-is for educational and development purposes.
