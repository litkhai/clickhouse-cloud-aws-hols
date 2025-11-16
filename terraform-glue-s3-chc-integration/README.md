# ClickHouse Cloud + AWS Glue Catalog Integration

Simple Terraform setup to integrate ClickHouse Cloud with AWS Glue Catalog using Apache Iceberg tables.

## What This Does

1. Creates S3 bucket for Iceberg data storage
2. Sets up AWS Glue Database and Crawler
3. Generates sample Iceberg table data
4. Automatically runs crawler to register tables
5. Outputs ready-to-use ClickHouse SQL commands

## Prerequisites

- Terraform >= 1.0
- AWS CLI configured
- Python 3 with pip
- ClickHouse Cloud account (same AWS region)
- AWS credentials with permissions for:
  - S3 (create buckets, upload objects)
  - Glue (create databases, crawlers)
  - IAM (create/manage roles for Glue Crawler)

⚠️ **Note**: Some operations may fail if your AWS account has Service Control Policies (SCP) restrictions.

## Quick Start

### 1. Run Deployment Script

```bash
./deploy.sh
```

The script will:
1. **Prompt for AWS credentials** (stored only in environment variables, not in files)
   - AWS Access Key ID (must start with AKIA for long-term credentials)
   - AWS Secret Access Key
   - AWS Region (default: ap-northeast-2)

2. **Deploy all AWS infrastructure**
   - S3 bucket with encryption and versioning
   - AWS Glue Database and Crawler
   - IAM Role for Glue Crawler (if permissions allow)

3. **Create and upload sample Iceberg table** (`sales_orders`)

4. **Run Glue Crawler** to register the table

5. **Display ClickHouse connection SQL** with credentials embedded

### 2. Use in ClickHouse Cloud

Copy the SQL output from deploy.sh and run it in your ClickHouse Cloud console. The SQL will already have your credentials embedded:

```sql
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
    region = 'ap-northeast-2',
    glue_database = 'clickhouse_iceberg_db',
    aws_access_key_id = 'AKIA...',           -- Your actual credentials
    aws_secret_access_key = 'your-secret';    -- filled in by deploy.sh

-- List all tables
SHOW TABLES FROM glue_db;

-- Query the Iceberg table
SELECT * FROM glue_db.`sales_orders` LIMIT 10;

-- Run analytics
SELECT category, SUM(price * quantity) as revenue
FROM glue_db.`sales_orders`
GROUP BY category
ORDER BY revenue DESC;
```

## Manual Setup (Alternative)

If you prefer step-by-step control:

```bash
# 1. Set AWS credentials as environment variables
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="ap-northeast-2"

# 2. Initialize Terraform
terraform init

# 3. Deploy infrastructure
terraform apply

# 4. Create Iceberg table
python3 ./scripts/create-iceberg-table.py

# 5. Run Glue Crawler
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# 6. Wait ~2 minutes, then check tables
aws glue get-tables --database-name clickhouse_iceberg_db --region ap-northeast-2

# 7. Get connection info (credentials will show as $AWS_ACCESS_KEY_ID placeholders)
terraform output clickhouse_connection_info
```

## What Gets Created

| Resource | Name | Purpose |
|----------|------|---------|
| S3 Bucket | `chc-glue-integration-{account_id}` | Stores Iceberg data |
| Glue Database | `clickhouse_iceberg_db` | Metadata catalog |
| Glue Crawler | `chc-glue-integration-iceberg-crawler` | Auto-discovers tables |
| IAM Role | `chc-glue-integration-glue-crawler-role` | Crawler permissions |
| Sample Table | `sales_orders` | Demo Iceberg table with 10 rows |

## Configuration

AWS credentials are provided via environment variables (not stored in files):
- `AWS_ACCESS_KEY_ID` - Your AWS access key (must start with AKIA for long-term)
- `AWS_SECRET_ACCESS_KEY` - Your AWS secret access key
- `AWS_REGION` - AWS region (default: ap-northeast-2)

Optional settings in `terraform.tfvars`:

```hcl
aws_region         = "ap-northeast-2"           # AWS region
project_name       = "chc-glue-integration"     # Resource name prefix
glue_database_name = "clickhouse_iceberg_db"    # Glue database name
```

## Architecture

```
┌─────────────────────────────┐
│    ClickHouse Cloud         │
│  ┌───────────────────────┐  │
│  │ DataLakeCatalog DB    │  │
│  │ - Auto-discovers      │  │
│  │   all Glue tables     │  │
│  └───────────┬───────────┘  │
└──────────────┼──────────────┘
               │ AWS Credentials
               ▼
┌─────────────────────────────┐
│         AWS Account         │
│  ┌──────────────────────┐  │
│  │  Glue Catalog        │  │
│  │  - clickhouse_       │  │
│  │    iceberg_db        │  │
│  │  - sales_orders      │  │
│  │                      │  │
│  │  Glue Crawler        │  │
│  │  (Auto-updates)      │  │
│  └──────────┬───────────┘  │
│             │              │
│  ┌──────────▼───────────┐  │
│  │  S3 Bucket           │  │
│  │  /iceberg/           │  │
│  │    /sales_orders/    │  │
│  │      /metadata/      │  │
│  │      /data/          │  │
│  └──────────────────────┘  │
└─────────────────────────────┘
```

## Sample Data

The `sales_orders` table contains:
- 10 sample records
- Categories: Electronics, Books, Clothing, Food, Sports
- Partitioned by `order_date`
- Schema: id, user_id, product_id, category, quantity, price, order_date, description

## Troubleshooting

### Tables not visible in ClickHouse

```bash
# Check if table exists in Glue
aws glue get-table --database-name clickhouse_iceberg_db --name sales_orders --region ap-northeast-2

# Check crawler status
aws glue get-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# Manually trigger crawler
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2
```

### Access Denied errors

- Verify your AWS credentials have S3 and Glue read permissions
- Check that credentials start with `AKIA` (long-term, not temporary `ASIA`)
- Test manually:
  ```bash
  aws s3 ls s3://chc-glue-integration-{your-account-id}/
  aws glue get-database --name clickhouse_iceberg_db --region ap-northeast-2
  ```

### AWS SCP Restrictions

If you see permission denied errors for IAM operations:
- Your AWS account has organizational restrictions
- The setup will still work if you have S3 and Glue permissions
- IAM Role creation may fail (this is expected and safe to ignore)

## Cleanup

```bash
# Remove all resources
./destroy.sh
```

This will:
- Destroy all AWS resources (S3 bucket, Glue database, crawlers, IAM roles)
- Optionally clean up local Terraform state files

⚠️ **Warning**: This permanently deletes the S3 bucket, Glue database, and all data.

## Key Features

- ✅ **Database-level integration**: Mount entire Glue database in ClickHouse
- ✅ **Automatic table discovery**: All Glue tables immediately available
- ✅ **Schema synchronization**: Changes reflected automatically
- ✅ **Partition pruning**: Efficient queries on partitioned data
- ✅ **ACID guarantees**: Powered by Apache Iceberg

## Documentation

- [ClickHouse DataLakeCatalog Documentation](https://clickhouse.com/docs/use-cases/data-lake/glue-catalog)
- [Apache Iceberg Specification](https://iceberg.apache.org/spec/)
- [AWS Glue Data Catalog](https://docs.aws.amazon.com/glue/latest/dg/catalog-and-crawler.html)

## License

MIT License
