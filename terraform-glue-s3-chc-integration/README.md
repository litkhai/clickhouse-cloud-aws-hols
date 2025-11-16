# Terraform AWS Glue S3 ClickHouse Cloud Integration

Terraform configuration to set up AWS infrastructure for **ClickHouse Cloud Iceberg Table Engine** integration with:
- AWS S3 bucket with Apache Iceberg formatted data
- AWS Glue Data Catalog as Iceberg catalog
- Sample Iceberg table: `sales_orders`
- IAM Role for ClickHouse Cloud access
- Automated Glue Crawlers for catalog updates

## Overview

This project enables **ClickHouse Cloud to query Apache Iceberg tables** using:
- **IcebergS3 Engine**: Query Iceberg tables directly from S3
- **IcebergGlueCatalog Engine**: Use AWS Glue as Iceberg catalog
- **AWS Glue Data Catalog**: Centralized metadata management
- **IAM Role**: Secure access without long-lived credentials

### Key Use Case

Test and develop with ClickHouse Cloud's **Iceberg Table Engine** to query data lake tables managed by Apache Iceberg format.

## Prerequisites

1. **Terraform** (>= 1.0)
2. **AWS CLI** (configured with credentials)
3. **Python 3** (for sample data generation)
4. **ClickHouse Cloud account** (in the same AWS region)
5. **AWS Account** with permissions to create:
   - S3 buckets
   - AWS Glue databases and crawlers
   - IAM users and policies

## Features

- ✅ **S3 Bucket**: Encrypted, versioned bucket for data storage
- ✅ **AWS Glue Catalog**: Database and crawlers for Iceberg tables
- ✅ **Automated Crawlers**: Schedule-based catalog updates
- ✅ **IAM Integration**: Dedicated user with minimal permissions
- ✅ **Sample Data**: Pre-generated CSV, Parquet, Avro, and Iceberg files
- ✅ **ClickHouse Ready**: Output includes connection details and SQL examples

## Quick Start

### 1. Configure AWS Credentials

```bash
# Using environment variables
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="us-east-1"  # Must match ClickHouse Cloud region

# Or use AWS CLI
aws configure
```

### 2. Create Configuration File

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# AWS Configuration
aws_region = "us-east-1"  # Must match ClickHouse Cloud region

# Project Configuration
project_name         = "chc-glue-integration"
glue_database_name   = "clickhouse_iceberg_db"
enable_glue_crawler  = true
```

### 3. Deploy Infrastructure

```bash
# Initialize Terraform
terraform init

# Review execution plan
terraform plan

# Deploy resources
terraform apply
```

### 4. Upload Sample Data & Run Crawlers

```bash
# One command: creates sample data, uploads to S3, and runs crawlers automatically
./scripts/upload-sample-data.sh
```

This script will:
- ✅ Generate sample CSV data files locally (no Python dependencies needed)
- ✅ Upload files to S3 (CSV, Parquet, Iceberg)
- ✅ Start all Glue crawlers automatically
- ✅ Wait for crawlers to complete (2-5 minutes)
- ✅ Verify and display created tables in Glue Catalog

**Created Tables:**
- `sales_data_csv` - Transaction data with 10 sample records
- `users_csv` - User demographics (5 users)
- `parquet` - Product catalog data

### 5. Get ClickHouse Integration Info

```bash
# View all integration details
terraform output clickhouse_integration_info

# Get AWS credentials for ClickHouse
terraform output clickhouse_access_key_id
terraform output -raw clickhouse_secret_access_key
```

## ClickHouse Cloud Iceberg Integration

📖 **For detailed Iceberg integration guide, see [CLICKHOUSE_ICEBERG_GUIDE.md](./CLICKHOUSE_ICEBERG_GUIDE.md)**

### Quick Test: Iceberg Table Engine

After deployment, test the Iceberg table engine:

#### Method 1: Direct S3 Path (IcebergS3)

```sql
-- Create Iceberg table pointing to S3 location
CREATE TABLE sales_orders
ENGINE = IcebergS3(
    's3://chc-iceberg-data-ACCOUNT_ID/iceberg/sales_orders/',
    'AWS'
)
SETTINGS cloud_mode=1;

-- Query the table
SELECT * FROM sales_orders LIMIT 10;

-- Aggregate query
SELECT
    category,
    COUNT(*) as order_count,
    SUM(price * quantity) as total_revenue
FROM sales_orders
GROUP BY category
ORDER BY total_revenue DESC;
```

#### Method 2: AWS Glue Catalog (IcebergGlueCatalog)

```sql
-- Get your Catalog ID
-- terraform output glue_catalog_id

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

### Alternative: Query CSV/Parquet from S3

If you just want to test S3 access (not Iceberg):

```sql
-- Query CSV files from S3
SELECT * FROM s3(
    's3://chc-iceberg-data-ACCOUNT_ID/csv/*.csv',
    'CSV'
)
LIMIT 10;

-- Query Parquet files from S3
SELECT * FROM s3(
    's3://chc-iceberg-data-ACCOUNT_ID/parquet/*.parquet',
    'Parquet'
)
LIMIT 10;

-- Create table from S3 Parquet
CREATE TABLE products_local
ENGINE = MergeTree()
ORDER BY product_id
AS SELECT * FROM s3(
    's3://your-bucket-name/parquet/products/*.parquet',
    'AWS',
    'AKIAXXXXX',
    'xxxxx',
    'Parquet'
);
```

### Using S3 Table Function with Glue Catalog

```sql
-- Query using Glue Catalog schema
SELECT * FROM s3Cluster(
    'default',
    's3://your-bucket-name/csv/users/*.csv',
    'AWS',
    'AKIAXXXXX',
    'xxxxx'
)
SETTINGS schema_inference_use_cache_for_s3 = 1;
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   ClickHouse Cloud                       │
│  ┌──────────────────────────────────────────────────┐  │
│  │  IcebergGlueCatalog / S3 Table Engine            │  │
│  └────────────────┬─────────────────────────────────┘  │
└───────────────────┼─────────────────────────────────────┘
                    │
                    │ IAM Credentials
                    │
        ┌───────────▼────────────────┐
        │      AWS Account           │
        │  ┌──────────────────────┐  │
        │  │   AWS Glue Catalog   │  │
        │  │  ┌────────────────┐  │  │
        │  │  │  Database      │  │  │
        │  │  │  - sales_data  │  │  │
        │  │  │  - users       │  │  │
        │  │  │  - products    │  │  │
        │  │  └────────────────┘  │  │
        │  │                      │  │
        │  │  Glue Crawlers       │  │
        │  │  (Auto-update)       │  │
        │  └──────────┬───────────┘  │
        │             │              │
        │  ┌──────────▼───────────┐  │
        │  │    S3 Bucket         │  │
        │  │  /csv/               │  │
        │  │  /parquet/           │  │
        │  │  /avro/              │  │
        │  │  /iceberg/           │  │
        │  │    /sales_data/      │  │
        │  │      /metadata/      │  │
        │  │      /data/          │  │
        │  └──────────────────────┘  │
        └────────────────────────────┘
```

## Sample Data

The project includes sample data generation for:

### Sales Data (1,000 records)
- Transaction data with user, product, and pricing information
- Available in CSV, Parquet, and Iceberg formats

### Users Table (100 records)
- User demographics and account information
- Available in CSV format

### Products Table (50 records)
- Product catalog with pricing and inventory
- Available in Parquet format

## Configuration Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region (must match ClickHouse Cloud) | From environment |
| `project_name` | Project name for resource naming | `chc-glue-integration` |
| `s3_bucket_prefix` | S3 bucket name prefix | `chc-iceberg-data` |
| `glue_database_name` | Glue database name | `clickhouse_iceberg_db` |
| `enable_glue_crawler` | Enable automatic crawlers | `true` |
| `crawler_schedule` | Crawler schedule (cron) | `cron(0/5 * * * ? *)` |
| `tags` | Common tags for resources | See variables.tf |

## Outputs

After deployment, Terraform provides:

- `s3_bucket_name`: S3 bucket for data storage
- `glue_database_name`: Glue database name
- `glue_catalog_id`: AWS account ID (Glue Catalog ID)
- `clickhouse_access_key_id`: IAM access key for ClickHouse
- `clickhouse_secret_access_key`: IAM secret key (sensitive)
- `clickhouse_integration_info`: Complete integration guide

## AWS Glue Crawler Configuration

The crawlers are configured to:
- **Schedule**: Run every 5 minutes (configurable)
- **Schema Changes**: Update database on changes
- **New Data**: Crawl only new folders
- **Partitions**: Inherit from table configuration

To modify the crawler schedule:

```hcl
crawler_schedule = "cron(0 */2 * * ? *)"  # Every 2 hours
```

## Security Best Practices

1. **IAM Permissions**: The created IAM user has minimal permissions:
   - Read-only access to S3 bucket
   - Read-only access to Glue Catalog
   - No write or delete permissions

2. **S3 Security**:
   - Server-side encryption enabled (AES256)
   - Versioning enabled for data protection
   - Public access blocked

3. **Credentials Management**:
   - Secret access key is marked as sensitive
   - Use `terraform output -raw clickhouse_secret_access_key` to retrieve
   - Rotate credentials regularly

4. **Network Access**:
   - ClickHouse Cloud must be in the same AWS region
   - Consider using VPC endpoints for production

## Troubleshooting

### Crawler Not Finding Tables

```bash
# Check crawler status
aws glue get-crawler --name <crawler-name>

# View crawler logs
aws logs tail /aws-glue/crawlers --follow
```

### Permission Issues

```bash
# Test IAM user permissions
aws s3 ls s3://bucket-name --profile clickhouse-user

# Verify Glue access
aws glue get-databases --profile clickhouse-user
```

### ClickHouse Connection Issues

1. Verify AWS region matches between ClickHouse Cloud and resources
2. Check IAM credentials are correct
3. Ensure S3 bucket and Glue Catalog are accessible
4. Check ClickHouse Cloud logs for detailed error messages

### Data Not Appearing in Catalog

```bash
# Manually trigger crawler
aws glue start-crawler --name <crawler-name>

# Check crawler run history
aws glue get-crawler-metrics --crawler-name-list <crawler-name>
```

## Cost Estimation

Approximate monthly costs for typical usage:

- **S3 Storage**: ~$0.023/GB (Standard)
- **Glue Crawler**: ~$0.44/hour (only when running)
- **Glue Catalog**: First 1M objects free, $1/100k after
- **Data Transfer**: Varies by usage

Example: 10GB data with hourly crawlers ≈ $6-10/month

## Cleanup

To destroy all resources:

```bash
# Remove all resources
terraform destroy

# Clean up local files (optional)
rm -rf .terraform terraform.tfstate* sample-data/
```

**Warning**: This will permanently delete:
- S3 bucket and all data
- Glue database and catalog entries
- IAM user and credentials

## Advanced Usage

### Custom Iceberg Table

```sql
-- Create Iceberg table with custom configuration
CREATE TABLE custom_iceberg
ENGINE = IcebergGlueCatalog(
    'catalog_id=123456789012',
    'database=clickhouse_iceberg_db',
    'table=my_custom_table',
    'aws_access_key_id=AKIAXXXXX',
    'aws_secret_access_key=xxxxx',
    'region=us-east-1'
)
SETTINGS iceberg_engine_ignore_schema_evolution = 1;
```

### Querying Partitioned Data

```sql
-- Iceberg supports partition pruning
SELECT * FROM sales_data
WHERE toDate(timestamp) = '2024-01-15'
  AND category = 'Electronics';
```

### Materialized Views with S3 Data

```sql
-- Create materialized view from S3 source
CREATE MATERIALIZED VIEW mv_sales_summary
ENGINE = SummingMergeTree()
ORDER BY (category, date)
AS SELECT
    category,
    toDate(timestamp) as date,
    sum(quantity) as total_quantity,
    sum(price * quantity) as total_revenue
FROM s3(
    's3://bucket-name/iceberg/sales_data/',
    'AWS',
    'AKIAXXXXX',
    'xxxxx'
)
GROUP BY category, date;
```

## Contributing

Suggestions and improvements are welcome! Please:
1. Test changes thoroughly
2. Update documentation
3. Follow Terraform best practices

## License

MIT License

## Support

For issues related to:
- **Terraform/AWS**: Check AWS documentation
- **ClickHouse Cloud**: Contact ClickHouse support
- **This project**: Open an issue in the repository

## References

- [ClickHouse Iceberg Documentation](https://clickhouse.com/docs/en/engines/table-engines/integrations/iceberg)
- [AWS Glue Documentation](https://docs.aws.amazon.com/glue/)
- [Apache Iceberg](https://iceberg.apache.org/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
