output "bucket_name" {
  description = "Name of the created S3 bucket"
  value       = aws_s3_bucket.clickhouse_data.id
}

output "bucket_arn" {
  description = "ARN of the created S3 bucket"
  value       = aws_s3_bucket.clickhouse_data.arn
}

output "bucket_region" {
  description = "AWS region where the S3 bucket is created"
  value       = aws_s3_bucket.clickhouse_data.region
}

output "bucket_domain_name" {
  description = "S3 bucket domain name"
  value       = aws_s3_bucket.clickhouse_data.bucket_domain_name
}

output "clickhouse_iam_role_arns" {
  description = "ClickHouse IAM role ARNs with direct S3 access (configured via bucket policy)"
  value       = var.clickhouse_iam_role_arns
}

output "s3_url_prefix" {
  description = "S3 URL prefix for ClickHouse queries"
  value       = "https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}"
}

output "connection_info" {
  description = "Complete connection information for ClickHouse"
  value       = <<-EOT
    ================================================================================
    ClickHouse S3 Configuration (Direct Bucket Policy Access)
    ================================================================================

    ⚠️  WARNING: Cross-Account Limitation
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    This configuration may NOT work with ClickHouse Cloud due to cross-account
    access limitations. For ClickHouse Cloud, use terraform-chc-secures3-aws.
    This setup works for: OSS ClickHouse, same-account scenarios, or learning.
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    S3 Bucket Information:
      Bucket Name:       ${aws_s3_bucket.clickhouse_data.id}
      Bucket ARN:        ${aws_s3_bucket.clickhouse_data.arn}
      Region:            ${aws_s3_bucket.clickhouse_data.region}
      S3 URL:            https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}

    Access Method:
      Type:              Direct S3 Bucket Policy (No AssumeRole)
      Allowed ARNs:      ${join("\n                     ", var.clickhouse_iam_role_arns)}

    ClickHouse S3 Table Engine Example (No extra_credentials needed):
      -- Create table with S3 engine (direct access)
      CREATE TABLE s3_table
      (
          id UInt64,
          name String,
          timestamp DateTime
      )
      ENGINE = S3(
          'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/table_data.parquet',
          'Parquet'
      );

      -- Insert data to S3
      INSERT INTO s3_table VALUES (1, 'example', now());

      -- Query data from S3
      SELECT * FROM s3_table;

    ClickHouse S3 Function Example (No extra_credentials needed):
      -- Query Parquet file directly
      SELECT * FROM s3(
          'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/*.parquet'
      );

      -- Insert data to S3 using s3() function
      INSERT INTO FUNCTION s3(
          'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/output.parquet',
          'Parquet',
          'id UInt64, name String, timestamp DateTime'
      )
      SELECT 1 AS id, 'test' AS name, now() AS timestamp;

    ================================================================================
  EOT
}

output "clickhouse_sql_examples" {
  description = "ClickHouse SQL examples for testing S3 integration (Direct Access - No extra_credentials needed)"
  value       = <<-EOT
    -- Example 1: Create S3-backed table (Parquet format) - Direct Access
    CREATE TABLE logs_s3
    (
        timestamp DateTime,
        level String,
        message String
    )
    ENGINE = S3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/logs/app_logs.parquet',
        'Parquet'
    );

    -- Example 2: Create S3-backed table (CSV format) - Direct Access
    CREATE TABLE events_s3
    (
        event_id UInt64,
        user_id String,
        event_type String,
        created_at DateTime
    )
    ENGINE = S3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/events.csv',
        'CSV'
    );

    -- Example 3: Create S3-backed table (JSON format with wildcard) - Direct Access
    CREATE TABLE user_activity_s3
    (
        user_id String,
        action String,
        timestamp DateTime
    )
    ENGINE = S3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/user_activity_*.json',
        'JSONEachRow'
    );

    -- Example 4: Direct query without creating table - Direct Access
    SELECT * FROM s3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/*.parquet'
    ) LIMIT 10;

    -- Example 5: Insert data to S3
    INSERT INTO logs_s3 VALUES
        (now(), 'INFO', 'Application started'),
        (now(), 'DEBUG', 'Processing request'),
        (now(), 'ERROR', 'Connection timeout');

    -- Example 6: Export query results to S3 - Direct Access
    INSERT INTO FUNCTION s3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/exports/query_result.parquet',
        'Parquet',
        'user_id String, total_events UInt64'
    )
    SELECT user_id, count() AS total_events
    FROM user_activity_s3
    GROUP BY user_id;
  EOT
}

output "setup_checklist" {
  description = "Setup checklist for ClickHouse Cloud integration"
  value       = <<-EOT
    ================================================================================
    Setup Checklist (Direct S3 Bucket Policy Access)
    ================================================================================

    AWS Setup (Completed by Terraform):
      ✓ S3 bucket created: ${aws_s3_bucket.clickhouse_data.id}
      ✓ S3 bucket policy created with direct ARN access
      ✓ S3 permissions configured (read + write)
      ✓ Bucket encryption enabled
      ✓ Public access settings configured

    ClickHouse Cloud Setup (Manual Steps):
      1. Log into ClickHouse Cloud Console
      2. Select your service
      3. Navigate to: Settings → Network security information
      4. Copy the "Service role ID (IAM)" value
      5. Verify it matches one of the ARNs in your terraform.tfvars:
         ${join("\n         ", var.clickhouse_iam_role_arns)}

    Testing Steps:
      1. Connect to your ClickHouse Cloud instance
      2. Copy SQL examples from the 'clickhouse_sql_examples' output
      3. Execute the SQL to create S3-backed tables (NO extra_credentials needed!)
      4. Insert test data
      5. Query the data to verify
      6. Check S3 bucket for created files

    Key Differences from AssumeRole Method:
      • No IAM role creation - uses direct S3 bucket policy
      • No extra_credentials() needed in SQL queries
      • Simpler SQL syntax
      • Direct access from ClickHouse IAM role to S3 bucket

    Troubleshooting:
      - If you get "Access Denied" errors:
        • Verify ClickHouse IAM role ARN is correct
        • Check S3 bucket policy in AWS Console
        • Ensure S3 bucket is in the same region as ClickHouse Cloud
      - If you get "Bucket not found" errors:
        • Verify S3 URL format
        • Check bucket name spelling
        • Ensure bucket region matches

    ================================================================================
  EOT
}
