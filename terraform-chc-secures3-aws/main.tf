terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  # Region priority:
  # 1. var.aws_region (from terraform.tfvars)
  # 2. AWS_REGION or AWS_DEFAULT_REGION environment variable (automatically detected)
  # 3. Defaults to ap-northeast-2 (Seoul) if nothing is set
  region = var.aws_region != null ? var.aws_region : null

  # Authentication uses environment variables:
  # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
}

# Validation: Check that external_id is provided when require_external_id is true
locals {
  validate_external_id = (
    var.require_external_id && var.external_id == "" ?
    tobool("ERROR: external_id must be provided when require_external_id is true") :
    true
  )
}

# S3 Bucket for ClickHouse data
resource "aws_s3_bucket" "clickhouse_data" {
  bucket = var.bucket_name

  tags = {
    Name        = var.bucket_name
    Environment = var.environment
    Purpose     = "ClickHouse S3 Table Engine"
  }
}

# Enable versioning for data protection
resource "aws_s3_bucket_versioning" "clickhouse_data_versioning" {
  bucket = aws_s3_bucket.clickhouse_data.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# Server-side encryption configuration
resource "aws_s3_bucket_server_side_encryption_configuration" "clickhouse_data_encryption" {
  bucket = aws_s3_bucket.clickhouse_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "clickhouse_data_public_access" {
  bucket = aws_s3_bucket.clickhouse_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM Role for ClickHouse Cloud to assume
resource "aws_iam_role" "clickhouse_s3_role" {
  name        = var.iam_role_name
  description = "IAM Role for ClickHouse Cloud to access S3 buckets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.clickhouse_iam_role_arns
        }
        Action = "sts:AssumeRole"
        Condition = var.require_external_id ? {
          StringEquals = {
            "sts:ExternalId" = var.external_id
          }
        } : {}
      }
    ]
  })

  tags = {
    Name        = var.iam_role_name
    Environment = var.environment
    Purpose     = "ClickHouse Cloud S3 Access"
  }
}

# IAM Policy for S3 access (Read and Write permissions)
resource "aws_iam_role_policy" "clickhouse_s3_policy" {
  name = "${var.iam_role_name}-s3-policy"
  role = aws_iam_role.clickhouse_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.clickhouse_data.arn
      },
      {
        Effect = "Allow"
        Action = [
          # Read permissions
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListMultipartUploadParts",
          # Write permissions for INSERT operations
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = "${aws_s3_bucket.clickhouse_data.arn}/*"
      }
    ]
  })
}

# Optional: Create sample data folders
resource "aws_s3_object" "sample_folders" {
  for_each = var.create_sample_folders ? toset(["data/", "logs/", "exports/"]) : []

  bucket       = aws_s3_bucket.clickhouse_data.id
  key          = each.value
  content      = ""
  content_type = "application/x-directory"
}
