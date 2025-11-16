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

### 1. Configure Your AWS Credentials

Create a `terraform.tfvars` file:

```hcl
aws_access_key_id     = "AKIA..."
aws_secret_access_key = "your-secret-key"
aws_region            = "ap-northeast-2"  # Must match your ClickHouse Cloud region
```

### 2. Run Setup (One Command)

```bash
./quick-setup.sh
```

This will:
- Deploy all AWS infrastructure
- Create and upload sample Iceberg table (`sales_orders`)
- Run Glue Crawler to register the table
- Display ClickHouse connection SQL

### 3. Use in ClickHouse Cloud

Copy the SQL output and run in your ClickHouse Cloud console:

```sql
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
    region = 'ap-northeast-2',
    glue_database = 'clickhouse_iceberg_db',
    aws_access_key_id = 'AKIA...',
    aws_secret_access_key = 'your-secret-key';

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
# 1. Initialize Terraform
terraform init

# 2. Deploy infrastructure
terraform apply

# 3. Create Iceberg table
python3 ./scripts/create-iceberg-table.py

# 4. Run Glue Crawler
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# 5. Wait ~2 minutes, then check tables
aws glue get-tables --database-name clickhouse_iceberg_db --region ap-northeast-2

# 6. Get connection info
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

Edit [variables.tf](variables.tf) or create `terraform.tfvars`:

```hcl
# Required
aws_access_key_id     = "AKIA..."           # Your AWS access key (long-term)
aws_secret_access_key = "your-secret-key"   # Your AWS secret key
aws_region            = "ap-northeast-2"    # AWS region

# Optional
project_name          = "chc-glue-integration"     # Resource name prefix
glue_database_name    = "clickhouse_iceberg_db"    # Glue database name
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
terraform destroy

# Clean up local state
rm -rf .terraform terraform.tfstate*
```

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
