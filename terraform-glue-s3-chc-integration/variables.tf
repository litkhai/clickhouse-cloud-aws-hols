# AWS Region
variable "aws_region" {
  description = "AWS region to deploy resources (must match ClickHouse Cloud region)"
  type        = string
  default     = "ap-northeast-2"
}

# Resource Configuration
variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "chc-glue-integration"
}

variable "glue_database_name" {
  description = "Name of the AWS Glue database"
  type        = string
  default     = "clickhouse_iceberg_db"
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
