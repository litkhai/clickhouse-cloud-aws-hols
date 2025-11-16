variable "aws_region" {
  description = "AWS region to deploy resources. Must match ClickHouse Cloud region. If not set, uses AWS_REGION or AWS_DEFAULT_REGION environment variable"
  type        = string
  default     = null
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "chc-glue-integration"
}

variable "s3_bucket_prefix" {
  description = "Prefix for S3 bucket name (will be suffixed with account ID for uniqueness)"
  type        = string
  default     = "chc-iceberg-data"
}

variable "glue_database_name" {
  description = "Name of the AWS Glue database"
  type        = string
  default     = "clickhouse_iceberg_db"
}

variable "clickhouse_cloud_region" {
  description = "ClickHouse Cloud region (should match aws_region)"
  type        = string
  default     = null
}

variable "clickhouse_external_id" {
  description = "External ID for ClickHouse Cloud to assume the IAM role (provide a random string for security)"
  type        = string
  default     = "clickhouse-external-id-12345"
}

variable "enable_glue_crawler" {
  description = "Enable automatic Glue crawler for catalog updates"
  type        = bool
  default     = true
}

variable "crawler_schedule" {
  description = "Cron expression for Glue crawler schedule (default: every 5 minutes)"
  type        = string
  default     = "cron(0/5 * * * ? *)"
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default = {
    Project     = "ClickHouse-Glue-Integration"
    ManagedBy   = "Terraform"
    Environment = "Demo"
  }
}
