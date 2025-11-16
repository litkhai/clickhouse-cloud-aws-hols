# Credential Solutions for ClickHouse Glue Catalog

## Problem Summary

ClickHouse DataLakeCatalog requires **long-term AWS access keys** (Access Key ID + Secret Access Key) but:

1. ❌ **IAM User creation is blocked** by AWS SCP in this account
2. ❌ **Session tokens are not supported** by ClickHouse DataLakeCatalog
3. ✅ **You have SSO temporary credentials** (ASIA prefix with session token)

## Solution Options

### Option 1: Use Existing Long-Term Credentials (Recommended)

If you or your team has existing long-term IAM User credentials:

```bash
# Extract your current credentials (if long-term)
./scripts/get-current-credentials.sh
```

Then use the output in ClickHouse Cloud.

**Check if your credentials are long-term**:
- Access Key ID starts with `AKIA` → Long-term ✅
- Access Key ID starts with `ASIA` → Temporary ❌ (won't work)

### Option 2: Request IAM User from Administrator

Ask your AWS administrator to create an IAM User with this policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::chc-iceberg-data-123456789012",
        "arn:aws:s3:::chc-iceberg-data-123456789012/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase",
        "glue:GetDatabases",
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetPartition",
        "glue:GetPartitions",
        "glue:BatchGetPartition"
      ],
      "Resource": [
        "arn:aws:glue:ap-northeast-2:123456789012:catalog",
        "arn:aws:glue:ap-northeast-2:123456789012:database/clickhouse_iceberg_db",
        "arn:aws:glue:ap-northeast-2:123456789012:table/clickhouse_iceberg_db/*"
      ]
    }
  ]
}
```

**Automated script for administrator**:
```bash
./scripts/create-iam-user-for-admin.sh
```

### Option 3: Use Alternative ClickHouse Engines

If you cannot get long-term credentials, consider these alternatives:

#### A. IcebergS3 Engine (Direct S3 Access)

This still requires credentials, but you can test with existing Role:

```sql
-- This might work if the role allows S3 access
CREATE TABLE sales_orders
ENGINE = IcebergS3(
    's3://chc-iceberg-data-123456789012/iceberg/sales_orders/',
    'AWS'
);
```

**Note**: This uses the IAM Role attached to ClickHouse Cloud, not access keys.

#### B. S3 Table Function

Query data directly without Glue Catalog:

```sql
-- Query Parquet files directly
SELECT * FROM s3(
    's3://chc-iceberg-data-123456789012/parquet/*.parquet',
    'Parquet'
) LIMIT 10;
```

### Option 4: Wait for ClickHouse to Support Session Tokens

ClickHouse documentation states:

> "Currently, the Glue catalog only supports access and secret keys, but we will support additional authentication approaches in the future."

Future support may include:
- Session tokens (temporary credentials)
- IAM Role assumption
- Cross-account access

## Current Workaround

Since you have temporary credentials (ASIA prefix), here's what you can do:

### 1. Extract Current Credentials

```bash
./scripts/get-current-credentials.sh
```

This will show:
```
Access Key ID:     ASIA57AEO7VF... (temporary)
Secret Access Key: 7zB4VRpqtFXQ...
Session Token:     IQoJb3JpZ2luX2VjEMj... (not supported by ClickHouse)
```

### 2. Try Without Session Token (Will Likely Fail)

```sql
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
    region = 'ap-northeast-2',
    glue_database = 'clickhouse_iceberg_db',
    aws_access_key_id = 'ASIA57AEO7VF...',
    aws_secret_access_key = '7zB4VRpqtFXQ...';
    -- Session token cannot be included ❌
```

**Expected Result**: `AccessDenied` error because temporary credentials require session token.

### 3. Request Long-Term Credentials

Contact your AWS administrator:

> "Hi, I need long-term AWS credentials (IAM User with access keys starting with AKIA) to use ClickHouse DataLakeCatalog with AWS Glue. The service doesn't support temporary credentials/session tokens yet. Can you create an IAM User with S3 and Glue read permissions?"

Share this document: `CREDENTIAL_SOLUTIONS.md`

## Testing Your Setup

### Check Credential Type

```bash
# Check if you have long-term or temporary credentials
aws configure get aws_access_key_id

# If it starts with:
# - AKIA → Long-term (will work) ✅
# - ASIA → Temporary (won't work without session token) ❌
```

### Test S3 Access

```bash
# Test if you can access the bucket
aws s3 ls s3://chc-iceberg-data-123456789012/iceberg/

# If you see files, your credentials have S3 access
```

### Test Glue Access

```bash
# Test if you can access Glue
aws glue get-database --name clickhouse_iceberg_db --region ap-northeast-2

# If successful, your credentials have Glue access
```

## Summary Table

| Solution | Requires Admin | Works Now | Effort |
|----------|---------------|-----------|---------|
| Existing long-term credentials | No | ✅ Yes | Low |
| Request IAM User | Yes | ✅ Yes | Medium |
| Alternative engines | No | ⚠️ Limited | Low |
| Wait for session token support | No | ❌ No | N/A |

## Recommended Next Steps

1. **Check your credential type**: Run `./scripts/get-current-credentials.sh`
2. **If temporary (ASIA)**: Request long-term IAM User from admin
3. **If long-term (AKIA)**: Use them directly in ClickHouse
4. **Share this document** with your AWS administrator

## Support

- [ClickHouse Glue Catalog Documentation](https://clickhouse.com/docs/use-cases/data-lake/glue-catalog)
- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [Project Documentation](./README.md)
