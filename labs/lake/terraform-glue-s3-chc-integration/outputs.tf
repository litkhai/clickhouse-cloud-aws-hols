# ==================== ClickHouse Cloud Connection Info ====================

output "clickhouse_connection_info" {
  description = "Complete ClickHouse Cloud DataLakeCatalog connection information"
  sensitive   = true
  value       = <<-EOT

========================================
ClickHouse Cloud - Glue Catalog Integration
========================================

Infrastructure Created:
-----------------------
✓ S3 Bucket:      s3://${aws_s3_bucket.iceberg_data.bucket}/
✓ Glue Database:  ${aws_glue_catalog_database.iceberg_db.name}
✓ Glue Crawler:   ${aws_glue_crawler.iceberg_crawler.name}
✓ AWS Region:     ${data.aws_region.current.name}

ClickHouse DataLakeCatalog SQL:
-------------------------------
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
 -- glue_database = '${aws_glue_catalog_database.iceberg_db.name}', -- Not supported in ClickHouse 25.8
    region = '${data.aws_region.current.name}',
    aws_access_key_id = '$AWS_ACCESS_KEY_ID',
    aws_secret_access_key = '$AWS_SECRET_ACCESS_KEY';

-- List all tables from the default Glue database
SHOW TABLES FROM glue_db;

-- Query Iceberg table
SELECT * FROM glue_db.`sales_orders` LIMIT 10;

Note:
- Replace $AWS_ACCESS_KEY_ID and $AWS_SECRET_ACCESS_KEY with your actual credentials
- glue_database parameter is not supported in ClickHouse 25.8
- DataLakeCatalog will use the default Glue database in the specified region
========================================
EOT
}

# Individual outputs for programmatic access
output "s3_bucket_name" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.iceberg_data.bucket
}

output "glue_database_name" {
  description = "Glue database name"
  value       = aws_glue_catalog_database.iceberg_db.name
}

output "glue_crawler_name" {
  description = "Glue crawler name"
  value       = aws_glue_crawler.iceberg_crawler.name
}

output "aws_region" {
  description = "AWS region"
  value       = data.aws_region.current.name
}
