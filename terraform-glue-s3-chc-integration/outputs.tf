output "s3_bucket_name" {
  description = "Name of the S3 bucket for Iceberg data"
  value       = aws_s3_bucket.iceberg_data.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.iceberg_data.arn
}

output "s3_bucket_region" {
  description = "Region of the S3 bucket"
  value       = data.aws_region.current.name
}

output "glue_database_name" {
  description = "Name of the Glue database"
  value       = aws_glue_catalog_database.iceberg_db.name
}

output "glue_catalog_id" {
  description = "AWS Glue Catalog ID (AWS Account ID)"
  value       = data.aws_caller_identity.current.account_id
}

output "clickhouse_role_arn" {
  description = "IAM Role ARN for ClickHouse Cloud to assume (for S3 table function)"
  value       = local.clickhouse_role_arn
}

output "clickhouse_role_name" {
  description = "IAM Role name for ClickHouse Cloud"
  value       = local.clickhouse_role_name
}

output "using_existing_role" {
  description = "Whether using an existing IAM Role (true) or created new one (false)"
  value       = var.existing_clickhouse_role_name != null
}

output "clickhouse_external_id" {
  description = "External ID for role assumption"
  value       = var.clickhouse_external_id
  sensitive   = true
}

output "manual_iam_user_instructions" {
  description = "Instructions for manually creating IAM User for Glue Catalog integration"
  value       = "IAM User creation blocked by AWS SCP. See IAM_USER_LIMITATION.md for manual setup instructions."
}

output "aws_region" {
  description = "AWS region where resources are deployed"
  value       = data.aws_region.current.name
}

output "glue_crawler_names" {
  description = "Names of the Glue crawlers"
  value = var.enable_glue_crawler ? {
    iceberg = aws_glue_crawler.iceberg_crawler[0].name
    csv     = aws_glue_crawler.csv_crawler[0].name
    parquet = aws_glue_crawler.parquet_crawler[0].name
  } : null
}

# ClickHouse Cloud integration instructions
output "clickhouse_integration_info" {
  description = "Instructions for ClickHouse Cloud Iceberg integration"
  value = <<-EOT

  ========================================
  ClickHouse Cloud Glue Catalog Integration
  ========================================

  AWS Glue Catalog Credentials (DataLakeCatalog):
  -----------------------------------------------
  ⚠️  IAM User creation blocked by AWS SCP
  See IAM_USER_LIMITATION.md for manual setup instructions
  AWS Region:        ${data.aws_region.current.name}

  Glue Catalog Information:
  -------------------------
  Database Name:     ${aws_glue_catalog_database.iceberg_db.name}
  S3 Bucket:         s3://${aws_s3_bucket.iceberg_data.bucket}/iceberg/
  Iceberg Tables:    sales_orders

  Next Steps:
  -----------
  1. Upload Iceberg data: python3 scripts/create-iceberg-table.py
  2. Run Glue crawler: aws glue start-crawler --name chc-glue-integration-iceberg-crawler
  3. Wait for crawler to complete (~2 minutes)
  4. Create database in ClickHouse Cloud using DataLakeCatalog

  ClickHouse SQL (DataLakeCatalog - Database Level):
  --------------------------------------------------
  -- Step 1: Create database from Glue Catalog
  CREATE DATABASE glue_db
  ENGINE = DataLakeCatalog
  SETTINGS
      catalog_type = 'glue',
      region = '${data.aws_region.current.name}',
      glue_database = '${aws_glue_catalog_database.iceberg_db.name}',
      aws_access_key_id = '<manually_created_access_key_id>',
      aws_secret_access_key = '<manually_created_secret_access_key>';

  -- Step 2: List tables in the catalog
  SHOW TABLES FROM glue_db;

  -- Step 3: Query Iceberg tables (use backticks for table names)
  SELECT * FROM glue_db.`sales_orders` LIMIT 10;

  SELECT
      category,
      SUM(price * quantity) as revenue
  FROM glue_db.`sales_orders`
  GROUP BY category;

  Alternative - Direct S3 Path (IcebergS3):
  -----------------------------------------
  -- Query Iceberg table directly from S3 using manually created IAM User
  CREATE TABLE sales_orders
  ENGINE = IcebergS3(
      's3://${aws_s3_bucket.iceberg_data.bucket}/iceberg/sales_orders/',
      'AWS',
      '<manually_created_access_key_id>',
      '<manually_created_secret_access_key>'
  );

  SELECT * FROM sales_orders;

  ========================================
  EOT
}
