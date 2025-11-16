# ClickHouse Cloud Iceberg Integration Guide

This guide focuses on using **ClickHouse Cloud's Iceberg Table Engine** with AWS Glue Catalog for querying Apache Iceberg tables.

## Overview

This infrastructure creates:
- ✅ AWS S3 bucket with Iceberg-formatted data
- ✅ AWS Glue Data Catalog as Iceberg catalog
- ✅ IAM Role for ClickHouse Cloud to access resources
- ✅ Sample Iceberg table: `sales_orders`

## Quick Setup

### 1. Deploy Infrastructure

```bash
# Configure AWS credentials
export AWS_REGION="ap-northeast-2"  # Match your ClickHouse Cloud region

# Deploy
terraform init
terraform apply
```

### 2. Create Iceberg Table & Upload Data

```bash
# Option A: Create proper Iceberg table (Recommended)
python3 ./scripts/create-iceberg-table.py

# Option B: Create all sample data including Iceberg
./scripts/upload-sample-data.sh
```

### 3. Run Glue Crawler

```bash
# Register Iceberg table in Glue Catalog
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# Wait 2-3 minutes, then verify
aws glue get-tables --database-name clickhouse_iceberg_db --region ap-northeast-2
```

## ClickHouse Cloud Configuration

### Step 1: Configure IAM Role in ClickHouse Cloud

1. Go to ClickHouse Cloud Console
2. Navigate to **Settings > Integrations > AWS**
3. Add new IAM Role integration:

```bash
# Get Role ARN
terraform output clickhouse_role_arn

# Get External ID
terraform output -raw clickhouse_external_id
```

4. Configure in ClickHouse:
   - **Role ARN**: `arn:aws:iam::ACCOUNT_ID:role/chc-glue-integration-clickhouse-role`
   - **External ID**: (from terraform output)
   - **Region**: `ap-northeast-2` (your region)

### Step 2: Test Iceberg Table Engine

#### Method 1: Direct S3 Path (IcebergS3)

```sql
-- Create table pointing to Iceberg location
CREATE TABLE sales_orders_iceberg
ENGINE = IcebergS3(
    's3://chc-iceberg-data-ACCOUNT_ID/iceberg/sales_orders/',
    'AWS'
)
SETTINGS cloud_mode=1;

-- Query the table
SELECT * FROM sales_orders_iceberg LIMIT 10;

-- Aggregate query
SELECT
    category,
    COUNT(*) as order_count,
    SUM(price * quantity) as total_revenue
FROM sales_orders_iceberg
GROUP BY category
ORDER BY total_revenue DESC;
```

#### Method 2: AWS Glue Catalog (IcebergGlueCatalog)

```sql
-- Get Glue Catalog ID
terraform output glue_catalog_id

-- Create table using Glue Catalog
CREATE TABLE sales_orders_glue
ENGINE = IcebergGlueCatalog(
    'catalog_id=123456789012',  -- Your AWS Account ID
    'database=clickhouse_iceberg_db',
    'table=sales_orders',
    'region=ap-northeast-2'
)
SETTINGS cloud_mode=1;

-- Query the table
SELECT * FROM sales_orders_glue;
```

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
| order_date  | Date   | Order date               |
| description | String | Product description      |

**Sample Data**: 10 records across categories (Electronics, Books, Clothing, Food, Sports)

## Example Queries

### Basic Queries

```sql
-- Count orders by category
SELECT
    category,
    COUNT(*) as cnt
FROM sales_orders_iceberg
GROUP BY category;

-- Revenue by date
SELECT
    order_date,
    SUM(price * quantity) as daily_revenue
FROM sales_orders_iceberg
GROUP BY order_date
ORDER BY order_date;
```

### Advanced Queries

```sql
-- Top products by revenue
SELECT
    product_id,
    category,
    SUM(quantity) as total_quantity,
    SUM(price * quantity) as total_revenue
FROM sales_orders_iceberg
GROUP BY product_id, category
ORDER BY total_revenue DESC
LIMIT 5;

-- Average order value by category
SELECT
    category,
    AVG(price * quantity) as avg_order_value,
    COUNT(*) as order_count
FROM sales_orders_iceberg
GROUP BY category
ORDER BY avg_order_value DESC;
```

### Joining with S3 Data

```sql
-- Join Iceberg table with CSV from S3
SELECT
    o.category,
    u.country,
    COUNT(*) as orders,
    SUM(o.price * o.quantity) as revenue
FROM sales_orders_iceberg o
JOIN s3('s3://chc-iceberg-data-ACCOUNT_ID/csv/users.csv', 'CSV') u
    ON o.user_id = u.user_id
GROUP BY o.category, u.country
ORDER BY revenue DESC;
```

## Verifying Glue Catalog

### Check Tables

```bash
# List all tables
aws glue get-tables \
    --database-name clickhouse_iceberg_db \
    --region ap-northeast-2 \
    --query 'TableList[].{Name:Name,Type:Parameters.table_type}'

# Get specific table details
aws glue get-table \
    --database-name clickhouse_iceberg_db \
    --name sales_orders \
    --region ap-northeast-2
```

### Check Table Schema

```bash
# View table schema
aws glue get-table \
    --database-name clickhouse_iceberg_db \
    --name sales_orders \
    --region ap-northeast-2 \
    --query 'Table.StorageDescriptor.Columns'
```

## Troubleshooting

### Table Not Found in Glue Catalog

```bash
# Check if Iceberg files exist in S3
aws s3 ls s3://chc-iceberg-data-ACCOUNT_ID/iceberg/sales_orders/ --recursive

# Check crawler status
aws glue get-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# Manually start crawler
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2
```

### ClickHouse Cannot Access Table

1. **Verify IAM Role permissions**:
   ```bash
   aws sts assume-role \
       --role-arn $(terraform output -raw clickhouse_role_arn) \
       --role-session-name test \
       --external-id $(terraform output -raw clickhouse_external_id)
   ```

2. **Check S3 access**:
   ```sql
   -- Test S3 access first
   SELECT * FROM s3('s3://chc-iceberg-data-ACCOUNT_ID/csv/users.csv', 'CSV') LIMIT 1;
   ```

3. **Verify table exists in Glue**:
   ```bash
   aws glue get-table \
       --database-name clickhouse_iceberg_db \
       --name sales_orders \
       --region ap-northeast-2
   ```

### Invalid Iceberg Metadata

If the Iceberg table has invalid metadata:

```bash
# Recreate with Python script
cd terraform-glue-s3-chc-integration
python3 scripts/create-iceberg-table.py

# Restart crawler
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2
```

## Performance Tips

### 1. Use Projection Pushdown

```sql
-- ClickHouse will push category filter to Iceberg
SELECT * FROM sales_orders_iceberg
WHERE category = 'Electronics';
```

### 2. Select Specific Columns

```sql
-- Only read required columns from Iceberg
SELECT category, SUM(price * quantity) as revenue
FROM sales_orders_iceberg
GROUP BY category;
```

### 3. Partition Pruning

The `sales_orders` table is partitioned by `order_date`:

```sql
-- This query will only scan relevant partitions
SELECT * FROM sales_orders_iceberg
WHERE order_date = '2024-01-01';
```

## Iceberg Table Features

### Supported in ClickHouse

- ✅ Column projection (reading specific columns)
- ✅ Predicate pushdown (filter pushdown)
- ✅ Partition pruning
- ✅ Schema evolution
- ✅ Time travel (reading historical snapshots)

### Example: Time Travel

```sql
-- Read table as of specific timestamp
-- (requires snapshot metadata in Iceberg table)
SELECT * FROM sales_orders_iceberg
WHERE snapshot_id = 123456789;
```

## Comparison: S3 vs Iceberg Table Engine

| Feature | S3 Table Function | Iceberg Table Engine |
|---------|------------------|----------------------|
| Format Support | CSV, Parquet, JSON, etc. | Iceberg only |
| Schema Discovery | Automatic | Via Glue Catalog |
| Partition Pruning | Limited | Full support |
| Column Pruning | Yes | Yes |
| Time Travel | No | Yes |
| ACID | No | Yes |
| Use Case | Ad-hoc queries | Production data lakes |

## Additional Resources

- [ClickHouse Iceberg Documentation](https://clickhouse.com/docs/en/engines/table-engines/integrations/iceberg)
- [Apache Iceberg Specification](https://iceberg.apache.org/spec/)
- [AWS Glue Data Catalog](https://docs.aws.amazon.com/glue/latest/dg/catalog-and-crawler.html)

## Get Configuration Details

```bash
# View all integration info
terraform output clickhouse_integration_info

# Get specific values
terraform output clickhouse_role_arn
terraform output glue_database_name
terraform output s3_bucket_name
```

## Next Steps

1. ✅ Create more Iceberg tables with your own data
2. ✅ Set up incremental updates to Iceberg tables
3. ✅ Configure Glue Crawlers to run on schedule
4. ✅ Build ClickHouse materialized views on top of Iceberg tables

---

**Note**: This setup is for **development and testing**. For production use:
- Use stricter IAM policies
- Enable S3 bucket logging
- Configure VPC endpoints
- Set up monitoring and alerting
