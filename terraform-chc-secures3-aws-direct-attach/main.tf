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

# Note: External ID is not applicable for direct S3 bucket policy access

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

# Block public access (but allow specific ClickHouse IAM role ARNs)
resource "aws_s3_bucket_public_access_block" "clickhouse_data_public_access" {
  bucket = aws_s3_bucket.clickhouse_data.id

  block_public_acls       = true
  block_public_policy     = false # Allow bucket policy with specific ARNs
  ignore_public_acls      = true
  restrict_public_buckets = false # Allow bucket policy with specific ARNs
}

# S3 Bucket Policy for direct ClickHouse ARN access
resource "aws_s3_bucket_policy" "clickhouse_access" {
  bucket = aws_s3_bucket.clickhouse_data.id

  # Ensure public access block is configured first
  depends_on = [aws_s3_bucket_public_access_block.clickhouse_data_public_access]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ClickHouseDirectBucketAccess"
        Effect = "Allow"
        Principal = {
          AWS = var.clickhouse_iam_role_arns
        }
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.clickhouse_data.arn
      },
      {
        Sid    = "ClickHouseDirectObjectAccess"
        Effect = "Allow"
        Principal = {
          AWS = var.clickhouse_iam_role_arns
        }
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
