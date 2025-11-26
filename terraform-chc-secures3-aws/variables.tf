variable "aws_region" {
  description = "AWS region to deploy resources. If not set, uses AWS_REGION or AWS_DEFAULT_REGION environment variable, or defaults to ap-northeast-2"
  type        = string
  default     = null
}

variable "bucket_name" {
  description = "Name of the S3 bucket for ClickHouse data (must be globally unique)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.bucket_name)) && length(var.bucket_name) >= 3 && length(var.bucket_name) <= 63
    error_message = "Bucket name must be between 3 and 63 characters, start and end with a lowercase letter or number, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "iam_role_name" {
  description = "Name of the IAM role for ClickHouse Cloud to assume"
  type        = string
  default     = "ClickHouseS3Access"

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=,.@_-]+$", var.iam_role_name)) && length(var.iam_role_name) <= 64
    error_message = "IAM role name must be 64 characters or less and contain only alphanumeric characters plus +=,.@_-"
  }
}

variable "clickhouse_iam_role_arns" {
  description = "List of ClickHouse Cloud IAM role ARNs that can assume this role (found in ClickHouse Cloud Console -> Settings -> Network security information -> Service role ID)"
  type        = list(string)

  validation {
    condition     = length(var.clickhouse_iam_role_arns) > 0
    error_message = "At least one ClickHouse IAM role ARN must be provided."
  }

  validation {
    condition     = alltrue([for arn in var.clickhouse_iam_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/.+", arn))])
    error_message = "All ClickHouse IAM role ARNs must be valid IAM role ARNs in the format: arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME"
  }
}

variable "environment" {
  description = "Environment tag (e.g., dev, staging, production)"
  type        = string
  default     = "dev"
}

variable "enable_versioning" {
  description = "Enable S3 bucket versioning for data protection"
  type        = bool
  default     = true
}

variable "require_external_id" {
  description = "Require external ID for additional security when assuming the role"
  type        = bool
  default     = false
}

variable "external_id" {
  description = "External ID for additional security (shared secret between ClickHouse and AWS)"
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.require_external_id == false || (var.require_external_id == true && length(var.external_id) > 0)
    error_message = "External ID must be provided when require_external_id is true."
  }
}

variable "create_sample_folders" {
  description = "Create sample folder structure in S3 bucket (data/, logs/, exports/)"
  type        = bool
  default     = true
}
