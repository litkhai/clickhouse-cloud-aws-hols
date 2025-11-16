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
  description = "IAM Role ARN for ClickHouse Cloud to assume"
  value       = aws_iam_role.clickhouse_role.arn
}

output "clickhouse_role_name" {
  description = "IAM Role name for ClickHouse Cloud"
  value       = aws_iam_role.clickhouse_role.name
}

output "clickhouse_external_id" {
  description = "External ID for role assumption"
  value       = var.clickhouse_external_id
  sensitive   = true
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
  ClickHouse Cloud Iceberg Integration
  ========================================

  AWS IAM Role for ClickHouse Cloud:
  -----------------------------------
  Role ARN:          ${aws_iam_role.clickhouse_role.arn}
  External ID:       (use: terraform output -raw clickhouse_external_id)
  AWS Region:        ${data.aws_region.current.name}

  Glue Catalog Information:
  -------------------------
  Catalog ID:        ${data.aws_caller_identity.current.account_id}
  Database Name:     ${aws_glue_catalog_database.iceberg_db.name}
  S3 Bucket:         s3://${aws_s3_bucket.iceberg_data.bucket}/

  Sample Data Locations:
  ----------------------
  CSV files:     s3://${aws_s3_bucket.iceberg_data.bucket}/csv/
  Parquet files: s3://${aws_s3_bucket.iceberg_data.bucket}/parquet/
  Avro files:    s3://${aws_s3_bucket.iceberg_data.bucket}/avro/
  Iceberg data:  s3://${aws_s3_bucket.iceberg_data.bucket}/iceberg/

  Next Steps:
  -----------
  1. Upload sample data: ./scripts/upload-sample-data.sh
  2. Run Glue crawlers to populate catalog
  3. In ClickHouse Cloud, configure IAM Role integration:
     - Go to Settings > Integrations > AWS
     - Add IAM Role ARN: ${aws_iam_role.clickhouse_role.arn}
     - Add External ID from: terraform output -raw clickhouse_external_id

  ClickHouse SQL Example (Using IAM Role):
  ----------------------------------------
  -- Create S3 table function with IAM role
  SELECT * FROM s3(
    's3://${aws_s3_bucket.iceberg_data.bucket}/csv/*.csv',
    'CSV'
  ) LIMIT 10;

  -- Create Iceberg table with Glue Catalog
  CREATE TABLE sales_iceberg
  ENGINE = IcebergS3(
    's3://${aws_s3_bucket.iceberg_data.bucket}/iceberg/sales_data/',
    'AWS'
  );

  -- Query the table
  SELECT category, COUNT(*) as cnt, SUM(price * quantity) as revenue
  FROM sales_iceberg
  GROUP BY category;

  ========================================
  EOT
}
