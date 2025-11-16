# IAM User Creation Limitation

## Problem

This AWS account has a Service Control Policy (SCP) or permissions boundary that prevents IAM User creation:

```
AccessDenied: User is not authorized to perform: iam:CreateUser with an explicit deny
```

## Why This Matters

ClickHouse Cloud's **DataLakeCatalog engine for Glue** currently **only supports access keys** (AWS Access Key ID + Secret Access Key) for authentication. It does not yet support IAM Role assumption.

> From ClickHouse docs: "Currently, the Glue catalog only supports access and secret keys, but we will support additional authentication approaches in the future."

## Workaround: Manual IAM User Creation

Since Terraform cannot create IAM Users in this account, you need to manually create an IAM User with the required permissions.

### Option 1: Automated Script (Recommended)

We provide a script that automates the entire process. **Ask your AWS administrator** to run:

```bash
cd terraform-glue-s3-chc-integration
./scripts/create-iam-user-for-admin.sh
```

This script will:
1. ✅ Create IAM User: `chc-glue-integration-glue-user`
2. ✅ Attach required S3 and Glue permissions
3. ✅ Generate access keys
4. ✅ Display credentials and ClickHouse SQL commands

**Output example**:
```
AWS Access Key ID:     AKIAIOSFODNN7EXAMPLE
AWS Secret Access Key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

### Option 2: Manual Steps

If you prefer manual creation, follow these steps:

#### Step 1: Create IAM User

Use the AWS Console or ask an administrator with `iam:CreateUser` permission:

```bash
aws iam create-user --user-name chc-glue-integration-glue-user
```

#### Step 2: Attach Policy to IAM User

Create and attach the following policy:

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

Save this as `glue-catalog-policy.json` and attach:

```bash
aws iam put-user-policy \
  --user-name chc-glue-integration-glue-user \
  --policy-name chc-glue-integration-glue-catalog-policy \
  --policy-document file://glue-catalog-policy.json
```

#### Step 3: Create Access Keys

```bash
aws iam create-access-key --user-name chc-glue-integration-glue-user
```

Save the output:
- AccessKeyId
- SecretAccessKey

## Using the Credentials in ClickHouse Cloud

```sql
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
    region = 'ap-northeast-2',
    glue_database = 'clickhouse_iceberg_db',
    aws_access_key_id = '<AccessKeyId_from_step_3>',
    aws_secret_access_key = '<SecretAccessKey_from_step_3>';

SHOW TABLES FROM glue_db;

SELECT * FROM glue_db.`sales_orders` LIMIT 10;
```

## Alternative: Request SCP Exception

If you need automated IAM User creation, request an exception to the SCP from your AWS Organization administrator.

## Future: IAM Role Support

Once ClickHouse adds IAM Role support for Glue Catalog, this Terraform configuration includes an IAM Role that can be used:

- Role ARN: `arn:aws:iam::123456789012:role/chc-glue-integration-clickhouse-role`
- External ID: (get with `terraform output -raw clickhouse_external_id`)

Monitor ClickHouse release notes for IAM Role support in DataLakeCatalog.
