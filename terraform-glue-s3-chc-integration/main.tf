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
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
}

# Get current AWS account info
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ==================== S3 Bucket ====================

resource "aws_s3_bucket" "iceberg_data" {
  bucket = "${var.project_name}-${data.aws_caller_identity.current.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "iceberg_data" {
  bucket = aws_s3_bucket.iceberg_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "iceberg_data" {
  bucket = aws_s3_bucket.iceberg_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "iceberg_data" {
  bucket                  = aws_s3_bucket.iceberg_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Create folder structure for Iceberg data
resource "aws_s3_object" "iceberg_folder" {
  bucket       = aws_s3_bucket.iceberg_data.id
  key          = "iceberg/"
  content_type = "application/x-directory"
}

# ==================== IAM Role for Glue Crawler ====================

resource "aws_iam_role" "glue_crawler_role" {
  name = "${var.project_name}-glue-crawler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_policy" {
  name = "${var.project_name}-glue-s3-policy"
  role = aws_iam_role.glue_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = ["${aws_s3_bucket.iceberg_data.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [aws_s3_bucket.iceberg_data.arn]
      }
    ]
  })
}

# ==================== AWS Glue Database ====================

resource "aws_glue_catalog_database" "iceberg_db" {
  name        = var.glue_database_name
  description = "Glue database for ClickHouse Iceberg integration"
  tags        = var.tags
}

# ==================== AWS Glue Crawler ====================

resource "aws_glue_crawler" "iceberg_crawler" {
  name          = "${var.project_name}-iceberg-crawler"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.iceberg_db.name

  iceberg_target {
    paths                   = ["s3://${aws_s3_bucket.iceberg_data.bucket}/iceberg/"]
    maximum_traversal_depth = 3
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "LOG"
  }

  configuration = jsonencode({
    Version = 1.0
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })

  tags = var.tags
}
