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

output "iam_role_name" {
  description = "Name of the IAM role for ClickHouse Cloud"
  value       = aws_iam_role.clickhouse_s3_role.name
}

output "iam_role_arn" {
  description = "ARN of the IAM role for ClickHouse Cloud (use this in your ClickHouse queries)"
  value       = aws_iam_role.clickhouse_s3_role.arn
}

output "s3_url_prefix" {
  description = "S3 URL prefix for ClickHouse queries"
  value       = "https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}"
}

output "connection_info" {
  description = "Complete connection information for ClickHouse"
  value       = <<-EOT
    ================================================================================
    ClickHouse Cloud Secure S3 Configuration
    ================================================================================

    S3 Bucket Information:
      Bucket Name:       ${aws_s3_bucket.clickhouse_data.id}
      Bucket ARN:        ${aws_s3_bucket.clickhouse_data.arn}
      Region:            ${aws_s3_bucket.clickhouse_data.region}
      S3 URL:            https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}

    IAM Role for ClickHouse:
      Role Name:         ${aws_iam_role.clickhouse_s3_role.name}
      Role ARN:          ${aws_iam_role.clickhouse_s3_role.arn}

    ClickHouse S3 Table Engine Example:
      -- Create table with S3 engine
      CREATE TABLE s3_table
      (
          id UInt64,
          name String,
          timestamp DateTime
      )
      ENGINE = S3(
          'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/table_data.parquet',
          'Parquet',
          extra_credentials(role_arn = '${aws_iam_role.clickhouse_s3_role.arn}')
      );

      -- Insert data to S3
      INSERT INTO s3_table VALUES (1, 'example', now());

      -- Query data from S3
      SELECT * FROM s3_table;

    ClickHouse S3 Function Example:
      -- Query Parquet file directly
      SELECT * FROM s3(
          'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/*.parquet',
          extra_credentials(role_arn = '${aws_iam_role.clickhouse_s3_role.arn}')
      );

      -- Insert data to S3 using s3() function
      INSERT INTO FUNCTION s3(
          'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/output.parquet',
          'Parquet',
          'id UInt64, name String, timestamp DateTime',
          extra_credentials(role_arn = '${aws_iam_role.clickhouse_s3_role.arn}')
      )
      SELECT 1 AS id, 'test' AS name, now() AS timestamp;

    ================================================================================
  EOT
}

output "clickhouse_sql_examples" {
  description = "ClickHouse SQL examples for testing S3 integration"
  value       = <<-EOT
    -- Example 1: Create S3-backed table (Parquet format)
    CREATE TABLE logs_s3
    (
        timestamp DateTime,
        level String,
        message String
    )
    ENGINE = S3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/logs/app_logs.parquet',
        'Parquet',
        extra_credentials(role_arn = '${aws_iam_role.clickhouse_s3_role.arn}')
    );

    -- Example 2: Create S3-backed table (CSV format)
    CREATE TABLE events_s3
    (
        event_id UInt64,
        user_id String,
        event_type String,
        created_at DateTime
    )
    ENGINE = S3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/events.csv',
        'CSV',
        extra_credentials(role_arn = '${aws_iam_role.clickhouse_s3_role.arn}')
    );

    -- Example 3: Create S3-backed table (JSON format with wildcard)
    CREATE TABLE user_activity_s3
    (
        user_id String,
        action String,
        timestamp DateTime
    )
    ENGINE = S3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/user_activity_*.json',
        'JSONEachRow',
        extra_credentials(role_arn = '${aws_iam_role.clickhouse_s3_role.arn}')
    );

    -- Example 4: Direct query without creating table
    SELECT * FROM s3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/data/*.parquet',
        extra_credentials(role_arn = '${aws_iam_role.clickhouse_s3_role.arn}')
    ) LIMIT 10;

    -- Example 5: Insert data to S3
    INSERT INTO logs_s3 VALUES
        (now(), 'INFO', 'Application started'),
        (now(), 'DEBUG', 'Processing request'),
        (now(), 'ERROR', 'Connection timeout');

    -- Example 6: Export query results to S3
    INSERT INTO FUNCTION s3(
        'https://s3.${aws_s3_bucket.clickhouse_data.region}.amazonaws.com/${aws_s3_bucket.clickhouse_data.id}/exports/query_result.parquet',
        'Parquet',
        'user_id String, total_events UInt64',
        extra_credentials(role_arn = '${aws_iam_role.clickhouse_s3_role.arn}')
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
    Setup Checklist
    ================================================================================

    AWS Setup (Completed by Terraform):
      ✓ S3 bucket created: ${aws_s3_bucket.clickhouse_data.id}
      ✓ IAM role created: ${aws_iam_role.clickhouse_s3_role.name}
      ✓ S3 permissions configured (read + write)
      ✓ Bucket encryption enabled
      ✓ Public access blocked

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
      3. Execute the SQL to create S3-backed tables
      4. Insert test data
      5. Query the data to verify
      6. Check S3 bucket for created files

    Troubleshooting:
      - If you get "Access Denied" errors:
        • Verify ClickHouse IAM role ARN is correct
        • Check IAM role trust policy
        • Ensure S3 bucket is in the same region as ClickHouse Cloud
      - If you get "Bucket not found" errors:
        • Verify S3 URL format
        • Check bucket name spelling
        • Ensure bucket region matches

    ================================================================================
  EOT
}
