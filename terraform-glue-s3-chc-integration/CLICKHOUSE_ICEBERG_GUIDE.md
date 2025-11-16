# ClickHouse Cloud Glue Catalog Integration Guide

This guide demonstrates **database-level integration** between **ClickHouse Cloud** and **AWS Glue Catalog** using the `DataLakeCatalog` engine to query Apache Iceberg tables.

## Overview

This infrastructure creates:
- ✅ AWS S3 bucket with Iceberg-formatted data
- ✅ AWS Glue Data Catalog for metadata management
- ✅ AWS Glue Crawlers for automatic table discovery
- ✅ Sample Iceberg table: `sales_orders`

### Key Concept: Database-Level Integration

Instead of creating individual table engines for each Iceberg table, ClickHouse's `DataLakeCatalog` engine allows you to **mount an entire Glue database** as a ClickHouse database. This provides:

- **Automatic table discovery**: All tables in the Glue catalog are immediately available
- **Schema synchronization**: Schema changes in Glue are reflected in ClickHouse
- **Simplified management**: No need to create individual table definitions
- **Unified access**: Single authentication for all tables in the catalog

## Quick Setup

### 1. Deploy Infrastructure

```bash
# Configure AWS credentials
export AWS_REGION="ap-northeast-2"  # Match your ClickHouse Cloud region

# Deploy
cd terraform-glue-s3-chc-integration
terraform init
terraform apply
```

### 2. Create Iceberg Table & Register in Glue

```bash
# Create proper Iceberg table with metadata
python3 ./scripts/create-iceberg-table.py

# Register Iceberg table in Glue Catalog
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# Wait 2-3 minutes, then verify
aws glue get-tables --database-name clickhouse_iceberg_db --region ap-northeast-2
```

### 3. Create IAM User for Access Keys

⚠️ **Note**: Due to AWS SCP restrictions in this account, IAM User creation must be done manually. See [IAM_USER_LIMITATION.md](IAM_USER_LIMITATION.md) for detailed instructions.

```bash
# Create IAM User
aws iam create-user --user-name chc-glue-integration-glue-user

# Attach policy (use policy from IAM_USER_LIMITATION.md)
aws iam put-user-policy \
  --user-name chc-glue-integration-glue-user \
  --policy-name chc-glue-integration-glue-catalog-policy \
  --policy-document file://glue-catalog-policy.json

# Create access keys
aws iam create-access-key --user-name chc-glue-integration-glue-user
```

**Save the output**:
- `AccessKeyId`
- `SecretAccessKey`

## ClickHouse Cloud Configuration

### Method 1: DataLakeCatalog (Recommended - Database Level)

This is the **primary integration method** that allows you to access all tables in the Glue catalog through a single database.

```sql
-- Step 1: Create database from Glue Catalog
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
    region = 'ap-northeast-2',
    glue_database = 'clickhouse_iceberg_db',
    aws_access_key_id = '<YOUR_ACCESS_KEY_ID>',
    aws_secret_access_key = '<YOUR_SECRET_ACCESS_KEY>';

-- Step 2: List all tables in the catalog
SHOW TABLES FROM glue_db;

-- Expected output:
-- ┌─name──────────┐
-- │ sales_orders  │
-- └───────────────┘

-- Step 3: Query Iceberg tables (use backticks for table names)
SELECT * FROM glue_db.`sales_orders` LIMIT 10;

-- Step 4: Run analytics queries
SELECT
    category,
    COUNT(*) as order_count,
    SUM(price * quantity) as total_revenue
FROM glue_db.`sales_orders`
GROUP BY category
ORDER BY total_revenue DESC;
```

**Key Points**:
- Use **backticks** for table names: `` `sales_orders` ``
- All tables in the Glue database are automatically available
- No need to create individual table definitions
- Schema changes in Glue are automatically reflected

### Method 2: IcebergS3 (Alternative - Table Level)

If you need direct S3 access without Glue Catalog:

```sql
-- Create individual table pointing to S3 location
CREATE TABLE sales_orders
ENGINE = IcebergS3(
    's3://chc-iceberg-data-123456789012/iceberg/sales_orders/',
    'AWS',
    '<YOUR_ACCESS_KEY_ID>',
    '<YOUR_SECRET_ACCESS_KEY>'
);

SELECT * FROM sales_orders LIMIT 10;
```

**Use this method when**:
- You need to query specific Iceberg tables without Glue
- You want fine-grained control over table definitions
- You're testing or prototyping

## Data Schema

### sales_orders Table

| Column       | Type   | Description              |
|-------------|--------|--------------------------|
| id          | Int64  | Order ID                 |
| user_id     | String | User identifier          |
| product_id  | String | Product identifier       |
| category    | String | Product category         |
| quantity    | Int64  | Quantity ordered         |
| price       | Double | Price per unit           |
| order_date  | Date   | Order date (partition)   |
| description | String | Product description      |

**Partition**: By `order_date`
**Sample Data**: 10 records across categories (Electronics, Books, Clothing, Food, Sports)

## Example Queries

### Basic Analytics

```sql
-- Count orders by category
SELECT
    category,
    COUNT(*) as order_count
FROM glue_db.`sales_orders`
GROUP BY category;

-- Revenue by date
SELECT
    order_date,
    SUM(price * quantity) as daily_revenue
FROM glue_db.`sales_orders`
GROUP BY order_date
ORDER BY order_date;

-- Top products by revenue
SELECT
    product_id,
    category,
    SUM(quantity) as total_quantity,
    SUM(price * quantity) as total_revenue
FROM glue_db.`sales_orders`
GROUP BY product_id, category
ORDER BY total_revenue DESC
LIMIT 5;
```

### Advanced Queries

```sql
-- Average order value by category
SELECT
    category,
    AVG(price * quantity) as avg_order_value,
    COUNT(*) as order_count,
    SUM(price * quantity) as total_revenue
FROM glue_db.`sales_orders`
GROUP BY category
ORDER BY avg_order_value DESC;

-- Partition pruning with date filter
SELECT
    category,
    SUM(price * quantity) as revenue
FROM glue_db.`sales_orders`
WHERE order_date = '2024-01-01'  -- Only scans partition for this date
GROUP BY category;
```

### Working with Multiple Tables

```sql
-- List all tables in catalog
SHOW TABLES FROM glue_db;

-- Describe table schema
DESCRIBE glue_db.`sales_orders`;

-- Query multiple tables (when available)
SELECT 'sales_orders' as source, COUNT(*) as cnt FROM glue_db.`sales_orders`
UNION ALL
SELECT 'other_table' as source, COUNT(*) as cnt FROM glue_db.`other_table`;
```

## Verifying Glue Catalog

### Check Database and Tables

```bash
# List Glue databases
aws glue get-databases --region ap-northeast-2

# List tables in database
aws glue get-tables \
    --database-name clickhouse_iceberg_db \
    --region ap-northeast-2

# Get specific table details
aws glue get-table \
    --database-name clickhouse_iceberg_db \
    --name sales_orders \
    --region ap-northeast-2
```

### Check Crawler Status

```bash
# Check crawler status
aws glue get-crawler \
    --name chc-glue-integration-iceberg-crawler \
    --region ap-northeast-2 \
    --query 'Crawler.{Name:Name,State:State,LastCrawl:LastCrawl.Status}'

# Start crawler manually
aws glue start-crawler \
    --name chc-glue-integration-iceberg-crawler \
    --region ap-northeast-2
```

### Verify Iceberg Files in S3

```bash
# Check Iceberg table structure
aws s3 ls s3://chc-iceberg-data-123456789012/iceberg/sales_orders/ --recursive

# Expected structure:
# metadata/v1.metadata.json
# metadata/version-hint.text
# data/data-001.parquet
```

## Troubleshooting

### Table Not Visible in ClickHouse

**Problem**: `SHOW TABLES FROM glue_db` returns empty or missing tables.

**Solutions**:
1. Verify Glue Catalog has the table:
   ```bash
   aws glue get-table --database-name clickhouse_iceberg_db --name sales_orders --region ap-northeast-2
   ```

2. Check IAM User permissions:
   - Must have `glue:GetTable`, `glue:GetTables`, `glue:GetDatabase`
   - Must have `s3:GetObject`, `s3:ListBucket` on the S3 bucket

3. Recreate the DataLakeCatalog database:
   ```sql
   DROP DATABASE IF EXISTS glue_db;

   CREATE DATABASE glue_db
   ENGINE = DataLakeCatalog
   SETTINGS
       catalog_type = 'glue',
       region = 'ap-northeast-2',
       glue_database = 'clickhouse_iceberg_db',
       aws_access_key_id = '<YOUR_KEY>',
       aws_secret_access_key = '<YOUR_SECRET>';
   ```

### Access Denied Errors

**Problem**: `AccessDenied` when querying tables.

**Solutions**:
1. Verify IAM User policy includes S3 permissions:
   ```json
   {
     "Effect": "Allow",
     "Action": ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"],
     "Resource": [
       "arn:aws:s3:::chc-iceberg-data-123456789012",
       "arn:aws:s3:::chc-iceberg-data-123456789012/*"
     ]
   }
   ```

2. Test S3 access manually:
   ```bash
   aws s3 ls s3://chc-iceberg-data-123456789012/iceberg/ \
       --profile <your-profile>
   ```

### Invalid Iceberg Metadata

**Problem**: Error reading Iceberg metadata.

**Solutions**:
1. Recreate Iceberg table:
   ```bash
   python3 scripts/create-iceberg-table.py
   ```

2. Restart Glue Crawler:
   ```bash
   aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2
   ```

3. Verify metadata files exist:
   ```bash
   aws s3 ls s3://chc-iceberg-data-123456789012/iceberg/sales_orders/metadata/
   ```

### Wrong Table Names

**Problem**: Table name format issues.

**Remember**:
- Always use **backticks** for table names: `` FROM glue_db.`sales_orders` ``
- Table names are case-sensitive in Glue Catalog
- Use `SHOW TABLES FROM glue_db` to get exact names

## Performance Tips

### 1. Partition Pruning

The `sales_orders` table is partitioned by `order_date`. Queries with date filters will only scan relevant partitions:

```sql
-- Efficient: Only scans one partition
SELECT * FROM glue_db.`sales_orders`
WHERE order_date = '2024-01-01';

-- Efficient: Scans date range partitions
SELECT * FROM glue_db.`sales_orders`
WHERE order_date BETWEEN '2024-01-01' AND '2024-01-31';
```

### 2. Column Projection

Only select columns you need:

```sql
-- Efficient: Reads only 2 columns
SELECT category, SUM(price * quantity) as revenue
FROM glue_db.`sales_orders`
GROUP BY category;

-- Inefficient: Reads all columns
SELECT * FROM glue_db.`sales_orders`;
```

### 3. Predicate Pushdown

ClickHouse pushes filters to Iceberg for efficient scanning:

```sql
-- Filter is pushed to Iceberg scanner
SELECT * FROM glue_db.`sales_orders`
WHERE category = 'Electronics' AND quantity > 2;
```

## Iceberg Features Supported

### In ClickHouse DataLakeCatalog

- ✅ **Column projection** (reading specific columns)
- ✅ **Predicate pushdown** (filter optimization)
- ✅ **Partition pruning** (skip irrelevant partitions)
- ✅ **Schema evolution** (add/remove columns)
- ✅ **Automatic table discovery** (via Glue Catalog)
- ✅ **Schema synchronization** (Glue changes reflected)

### Limitations

- ❌ **Write operations** (read-only access)
- ❌ **Time travel** (not yet supported in DataLakeCatalog)
- ⚠️ **Authentication**: Only access keys (IAM Role support coming)

## Comparison: Integration Methods

| Feature | DataLakeCatalog | IcebergS3 | IcebergGlueCatalog |
|---------|----------------|-----------|-------------------|
| **Level** | Database | Table | Table |
| **Automatic Discovery** | ✅ Yes | ❌ No | ❌ No |
| **Schema Sync** | ✅ Yes | ❌ No | ✅ Yes |
| **Setup Complexity** | 🟢 Simple | 🔴 Manual | 🟡 Medium |
| **Use Case** | Multiple tables | Single table | Single table |
| **Recommended** | ✅ Yes | For testing | For specific needs |

## Adding More Tables

### Option 1: Via Glue Crawler (Automatic)

1. Add new Iceberg table to S3:
   ```bash
   # Upload your Iceberg table to:
   # s3://chc-iceberg-data-123456789012/iceberg/<table_name>/
   ```

2. Run Glue Crawler:
   ```bash
   aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2
   ```

3. Table automatically appears in ClickHouse:
   ```sql
   SHOW TABLES FROM glue_db;  -- New table will appear
   SELECT * FROM glue_db.`new_table` LIMIT 10;
   ```

### Option 2: Manual Glue Registration

```bash
# Create table definition in Glue
aws glue create-table \
    --database-name clickhouse_iceberg_db \
    --table-input '{...}'  # Iceberg table definition
```

Then refresh ClickHouse:
```sql
SHOW TABLES FROM glue_db;  -- Table appears immediately
```

## Production Considerations

### Security

1. **Use IAM Roles when supported** (coming soon)
2. **Rotate access keys regularly**:
   ```bash
   aws iam create-access-key --user-name chc-glue-integration-glue-user
   aws iam delete-access-key --user-name chc-glue-integration-glue-user --access-key-id <OLD_KEY>
   ```

3. **Apply least privilege** IAM policies
4. **Enable S3 bucket logging**
5. **Use VPC endpoints** for S3 and Glue

### Monitoring

1. **Monitor Glue Crawler runs**:
   ```bash
   aws glue get-crawler-metrics --region ap-northeast-2
   ```

2. **Track S3 access costs**:
   - Enable S3 access logging
   - Use AWS Cost Explorer

3. **ClickHouse query performance**:
   ```sql
   SELECT query, query_duration_ms
   FROM system.query_log
   WHERE query LIKE '%glue_db%'
   ORDER BY event_time DESC
   LIMIT 10;
   ```

### Automation

1. **Schedule Glue Crawlers** for regular table discovery
2. **Set up Glue Triggers** for event-driven crawling
3. **Automate IAM key rotation** with AWS Secrets Manager

## Additional Resources

- [ClickHouse DataLakeCatalog Documentation](https://clickhouse.com/docs/use-cases/data-lake/glue-catalog)
- [Apache Iceberg Specification](https://iceberg.apache.org/spec/)
- [AWS Glue Data Catalog](https://docs.aws.amazon.com/glue/latest/dg/catalog-and-crawler.html)
- [ClickHouse Iceberg Table Engine](https://clickhouse.com/docs/en/engines/table-engines/integrations/iceberg)

## Get Configuration Details

```bash
# View all integration info
terraform output clickhouse_integration_info

# Get specific values
terraform output glue_database_name     # clickhouse_iceberg_db
terraform output s3_bucket_name         # chc-iceberg-data-123456789012
terraform output aws_region             # ap-northeast-2
```

## Next Steps

1. ✅ Add more Iceberg tables to the Glue Catalog
2. ✅ Set up incremental updates to Iceberg tables
3. ✅ Configure Glue Crawlers to run on schedule
4. ✅ Build ClickHouse materialized views on top of catalog tables
5. ✅ Integrate with your data pipeline (Spark, Flink, etc.)

---

**Note**: This setup is for **development and testing**. For production use:
- Use AWS Secrets Manager for credentials
- Implement proper IAM policies with least privilege
- Enable S3 bucket logging and encryption
- Configure VPC endpoints for private access
- Set up monitoring and alerting
- Test disaster recovery procedures
