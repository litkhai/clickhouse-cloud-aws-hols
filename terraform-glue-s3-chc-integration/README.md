# Terraform AWS Glue S3 ClickHouse Cloud Integration

Terraform configuration to set up AWS infrastructure for **ClickHouse Cloud Glue Catalog Integration** with:
- AWS S3 bucket with Apache Iceberg formatted data
- AWS Glue Data Catalog for metadata management
- **DataLakeCatalog** engine for database-level integration
- Sample Iceberg table: `sales_orders`
- Automated Glue Crawlers for table discovery

## Overview

This project enables **ClickHouse Cloud to query entire AWS Glue Catalog databases** using the **DataLakeCatalog engine**. This provides:

### Key Feature: Database-Level Integration

Instead of creating individual table definitions, mount an entire Glue database as a ClickHouse database:

```sql
-- One command to access all tables in Glue Catalog
CREATE DATABASE glue_db ENGINE = DataLakeCatalog SETTINGS ...;

-- All tables automatically available
SHOW TABLES FROM glue_db;
SELECT * FROM glue_db.`sales_orders`;
```

### Benefits

- ✅ **Automatic table discovery**: All Glue tables immediately available in ClickHouse
- ✅ **Schema synchronization**: Changes in Glue reflected automatically
- ✅ **Simplified management**: No individual table definitions needed
- ✅ **Unified authentication**: Single credential for all catalog tables
- ✅ **Production-ready**: ACID guarantees from Apache Iceberg

## Prerequisites

1. **Terraform** (>= 1.0)
2. **AWS CLI** (configured with credentials)
3. **Python 3** (for Iceberg table generation)
4. **ClickHouse Cloud account** (in the same AWS region)
5. **AWS Account** with permissions to create:
   - S3 buckets
   - AWS Glue databases and crawlers
   - IAM roles and policies

## Quick Start

### 1. Configure AWS Credentials

```bash
# Using environment variables
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="ap-northeast-2"  # Must match ClickHouse Cloud region

# Or use AWS CLI
aws configure
```

### 2. Configure Terraform Variables (Optional)

This project automatically uses existing IAM Roles if available, avoiding the need to create new ones.

```bash
# Copy example configuration
cp terraform.tfvars.example terraform.tfvars

# Edit to use existing role (recommended)
existing_clickhouse_role_name = "clickhouse-role"  # or any existing role
```

**Smart Role Detection**:
- If `existing_clickhouse_role_name` is set: Terraform will use that role and add required S3 + Glue permissions
- If `null` (default): Terraform will try to create a new role (may fail due to AWS SCP restrictions)

### 3. Deploy Infrastructure

```bash
# Initialize Terraform
terraform init

# Review execution plan
terraform plan

# Deploy resources
terraform apply
```

**What gets created**:
- ✅ S3 bucket with encryption and versioning
- ✅ Glue Database and Crawlers
- ✅ IAM policies attached to existing or new role
- ✅ Required permissions for S3 and Glue access

### 4. Create Iceberg Table & Register in Glue

```bash
# Create proper Iceberg table with metadata
python3 ./scripts/create-iceberg-table.py

# Register table in Glue Catalog
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# Wait 2-3 minutes, then verify
aws glue get-tables --database-name clickhouse_iceberg_db --region ap-northeast-2
```

### 5. Create IAM User for Access Keys

⚠️ **Note**: ClickHouse DataLakeCatalog currently only supports access keys (not IAM Role). Due to AWS SCP restrictions, IAM User creation must be done manually. See [IAM_USER_LIMITATION.md](IAM_USER_LIMITATION.md) for detailed instructions.

```bash
# Create IAM User
aws iam create-user --user-name chc-glue-integration-glue-user

# Attach policy from IAM_USER_LIMITATION.md
aws iam put-user-policy \
  --user-name chc-glue-integration-glue-user \
  --policy-name chc-glue-integration-glue-catalog-policy \
  --policy-document file://glue-catalog-policy.json

# Create access keys
aws iam create-access-key --user-name chc-glue-integration-glue-user
```

**Save the output**: AccessKeyId and SecretAccessKey

### 6. Configure ClickHouse Cloud

```sql
-- Mount entire Glue database as ClickHouse database
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
    region = 'ap-northeast-2',
    glue_database = 'clickhouse_iceberg_db',
    aws_access_key_id = '<YOUR_ACCESS_KEY_ID>',
    aws_secret_access_key = '<YOUR_SECRET_ACCESS_KEY>';

-- List all tables (automatically discovered from Glue)
SHOW TABLES FROM glue_db;

-- Query Iceberg table (use backticks)
SELECT * FROM glue_db.`sales_orders` LIMIT 10;

-- Run analytics
SELECT
    category,
    COUNT(*) as order_count,
    SUM(price * quantity) as revenue
FROM glue_db.`sales_orders`
GROUP BY category
ORDER BY revenue DESC;
```

## Integration Methods

### Method 1: DataLakeCatalog (Recommended - Database Level) ✅

**Use this for**: Production use, multiple tables, automatic discovery

```sql
-- Step 1: Create database from Glue Catalog
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
    region = 'ap-northeast-2',
    glue_database = 'clickhouse_iceberg_db',
    aws_access_key_id = '<YOUR_KEY>',
    aws_secret_access_key = '<YOUR_SECRET>';

-- Step 2: All tables automatically available
SHOW TABLES FROM glue_db;

-- Step 3: Query any table (use backticks)
SELECT * FROM glue_db.`sales_orders` LIMIT 10;
SELECT * FROM glue_db.`other_table` LIMIT 10;
```

**Benefits**:
- ✅ Automatic table discovery
- ✅ Schema synchronization
- ✅ Single authentication
- ✅ Simplified management

### Method 2: IcebergS3 (Alternative - Table Level)

**Use this for**: Single table access, testing, or when Glue is not needed

```sql
CREATE TABLE sales_orders
ENGINE = IcebergS3(
    's3://chc-iceberg-data-123456789012/iceberg/sales_orders/',
    'AWS',
    '<YOUR_ACCESS_KEY_ID>',
    '<YOUR_SECRET_ACCESS_KEY>'
);

SELECT * FROM sales_orders LIMIT 10;
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   ClickHouse Cloud                       │
│  ┌──────────────────────────────────────────────────┐  │
│  │         CREATE DATABASE glue_db                  │  │
│  │         ENGINE = DataLakeCatalog                 │  │
│  │                                                  │  │
│  │  glue_db.sales_orders  (auto-discovered)        │  │
│  │  glue_db.other_table   (auto-discovered)        │  │
│  └────────────────┬─────────────────────────────────┘  │
└───────────────────┼─────────────────────────────────────┘
                    │
                    │ AWS Access Keys
                    │
        ┌───────────▼────────────────┐
        │      AWS Account           │
        │  ┌──────────────────────┐  │
        │  │   AWS Glue Catalog   │  │
        │  │  Database:           │  │
        │  │  clickhouse_iceberg_db  │
        │  │                      │  │
        │  │  Tables:             │  │
        │  │  - sales_orders      │  │
        │  │  - (auto-discovered) │  │
        │  │                      │  │
        │  │  Glue Crawlers       │  │
        │  │  (Auto-update)       │  │
        │  └──────────┬───────────┘  │
        │             │              │
        │  ┌──────────▼───────────┐  │
        │  │    S3 Bucket         │  │
        │  │  /iceberg/           │  │
        │  │    /sales_orders/    │  │
        │  │      /metadata/      │  │
        │  │        v1.metadata.json │
        │  │        version-hint.text│
        │  │      /data/          │  │
        │  │        data-001.parquet │
        │  └──────────────────────┘  │
        └────────────────────────────┘
```

## Sample Data

### sales_orders Table

The project creates a sample Iceberg table with:

- **10 records** across 5 categories (Electronics, Books, Clothing, Food, Sports)
- **Partitioned by** `order_date` for efficient queries
- **Schema**:
  - id (Int64)
  - user_id (String)
  - product_id (String)
  - category (String)
  - quantity (Int64)
  - price (Double)
  - order_date (Date)
  - description (String)

## Example Queries

### Basic Queries

```sql
-- Count by category
SELECT category, COUNT(*) as cnt
FROM glue_db.`sales_orders`
GROUP BY category;

-- Revenue by date
SELECT order_date, SUM(price * quantity) as revenue
FROM glue_db.`sales_orders`
GROUP BY order_date
ORDER BY order_date;
```

### Advanced Queries

```sql
-- Top products with partition pruning
SELECT product_id, category, SUM(price * quantity) as revenue
FROM glue_db.`sales_orders`
WHERE order_date = '2024-01-01'  -- Only scans one partition
GROUP BY product_id, category
ORDER BY revenue DESC
LIMIT 5;

-- Average order value
SELECT
    category,
    AVG(price * quantity) as avg_order_value,
    COUNT(*) as order_count
FROM glue_db.`sales_orders`
GROUP BY category;
```

### Working with Multiple Tables

```sql
-- List all tables in catalog
SHOW TABLES FROM glue_db;

-- Describe schema
DESCRIBE glue_db.`sales_orders`;

-- Query multiple tables
SELECT 'sales' as source, COUNT(*) FROM glue_db.`sales_orders`
UNION ALL
SELECT 'other' as source, COUNT(*) FROM glue_db.`other_table`;
```

## Configuration Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region (must match ClickHouse Cloud) | From environment |
| `project_name` | Project name for resource naming | `chc-glue-integration` |
| `s3_bucket_prefix` | S3 bucket name prefix | `chc-iceberg-data` |
| `glue_database_name` | Glue database name | `clickhouse_iceberg_db` |
| `enable_glue_crawler` | Enable automatic crawlers | `true` |
| `crawler_schedule` | Crawler schedule (cron) | None (manual trigger) |
| `tags` | Common tags for resources | See variables.tf |

## Outputs

After deployment, Terraform provides:

```bash
# View all integration info
terraform output clickhouse_integration_info

# Get specific values
terraform output s3_bucket_name         # chc-iceberg-data-123456789012
terraform output glue_database_name     # clickhouse_iceberg_db
terraform output aws_region             # ap-northeast-2
```

## Verifying Setup

### Check Glue Catalog

```bash
# List tables in Glue
aws glue get-tables \
    --database-name clickhouse_iceberg_db \
    --region ap-northeast-2

# Check crawler status
aws glue get-crawler \
    --name chc-glue-integration-iceberg-crawler \
    --region ap-northeast-2
```

### Verify S3 Files

```bash
# Check Iceberg structure
aws s3 ls s3://chc-iceberg-data-123456789012/iceberg/sales_orders/ --recursive

# Expected structure:
# metadata/v1.metadata.json
# metadata/version-hint.text
# data/data-001.parquet
```

## Troubleshooting

### Table Not Visible in ClickHouse

1. Verify table exists in Glue:
   ```bash
   aws glue get-table --database-name clickhouse_iceberg_db --name sales_orders --region ap-northeast-2
   ```

2. Check IAM permissions (see IAM_USER_LIMITATION.md)

3. Recreate DataLakeCatalog database in ClickHouse

### Access Denied Errors

1. Verify IAM User has S3 and Glue permissions
2. Test credentials manually:
   ```bash
   aws s3 ls s3://chc-iceberg-data-123456789012/ --profile <your-profile>
   ```

### Glue Crawler Issues

```bash
# Start crawler manually
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# Check crawler logs
aws glue get-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2
```

## Adding More Tables

### Automatic (Recommended)

1. Add Iceberg table to S3:
   ```bash
   # Upload to: s3://bucket/iceberg/new_table/
   ```

2. Run Glue Crawler:
   ```bash
   aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2
   ```

3. Table automatically appears in ClickHouse:
   ```sql
   SHOW TABLES FROM glue_db;  -- new_table appears
   SELECT * FROM glue_db.`new_table`;
   ```

## Security Best Practices

1. **IAM Permissions**: Minimal permissions (read-only S3 and Glue)
2. **S3 Security**: Encryption enabled, versioning on, public access blocked
3. **Credentials**: Store in AWS Secrets Manager for production
4. **Network**: Use VPC endpoints for private access
5. **Monitoring**: Enable CloudTrail and S3 access logging

## Performance Tips

### 1. Partition Pruning

```sql
-- Efficient: Only scans relevant partitions
SELECT * FROM glue_db.`sales_orders`
WHERE order_date = '2024-01-01';
```

### 2. Column Projection

```sql
-- Efficient: Reads only needed columns
SELECT category, SUM(price * quantity)
FROM glue_db.`sales_orders`
GROUP BY category;
```

### 3. Predicate Pushdown

```sql
-- Filters pushed to Iceberg
SELECT * FROM glue_db.`sales_orders`
WHERE category = 'Electronics' AND quantity > 2;
```

## Comparison: Integration Methods

| Feature | DataLakeCatalog | IcebergS3 |
|---------|----------------|-----------|
| **Level** | Database | Table |
| **Discovery** | Automatic | Manual |
| **Schema Sync** | Yes | No |
| **Setup** | Simple | Per-table |
| **Use Case** | Production | Testing |
| **Recommended** | ✅ Yes | For specific needs |

## Cost Estimation

Approximate monthly costs:

- **S3 Storage**: ~$0.023/GB
- **Glue Crawler**: ~$0.44/hour (only when running)
- **Glue Catalog**: First 1M objects free
- **Data Transfer**: Varies

Example: 10GB + hourly crawlers ≈ $6-10/month

## Cleanup

```bash
# Remove all resources
terraform destroy

# Clean up local files
rm -rf .terraform terraform.tfstate*
```

**Warning**: Permanently deletes S3 bucket, Glue database, and IAM resources.

## Documentation

- 📖 **[CLICKHOUSE_ICEBERG_GUIDE.md](./CLICKHOUSE_ICEBERG_GUIDE.md)** - Complete integration guide
- 📖 **[IAM_USER_LIMITATION.md](./IAM_USER_LIMITATION.md)** - IAM User manual setup
- 📖 **[DEPLOYMENT_FIXES.md](./DEPLOYMENT_FIXES.md)** - Deployment troubleshooting history

## Additional Resources

- [ClickHouse DataLakeCatalog Documentation](https://clickhouse.com/docs/use-cases/data-lake/glue-catalog)
- [Apache Iceberg Specification](https://iceberg.apache.org/spec/)
- [AWS Glue Data Catalog](https://docs.aws.amazon.com/glue/latest/dg/catalog-and-crawler.html)
- [ClickHouse Iceberg Table Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/iceberg)

## Support

For issues related to:
- **Terraform/AWS**: Check AWS documentation
- **ClickHouse Cloud**: Contact ClickHouse support
- **This project**: Open an issue in the repository

## License

MIT License
