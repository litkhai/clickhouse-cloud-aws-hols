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
  region = var.aws_region != null ? var.aws_region : null
}

# Get current AWS account info
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# S3 Bucket for Iceberg data
resource "aws_s3_bucket" "iceberg_data" {
  bucket = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-bucket"
    }
  )
}

# Enable versioning for data protection
resource "aws_s3_bucket_versioning" "iceberg_data" {
  bucket = aws_s3_bucket.iceberg_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "iceberg_data" {
  bucket = aws_s3_bucket.iceberg_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "iceberg_data" {
  bucket = aws_s3_bucket.iceberg_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Create folder structure in S3
resource "aws_s3_object" "avro_folder" {
  bucket       = aws_s3_bucket.iceberg_data.id
  key          = "avro/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "csv_folder" {
  bucket       = aws_s3_bucket.iceberg_data.id
  key          = "csv/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "parquet_folder" {
  bucket       = aws_s3_bucket.iceberg_data.id
  key          = "parquet/"
  content_type = "application/x-directory"
}

resource "aws_s3_object" "iceberg_folder" {
  bucket       = aws_s3_bucket.iceberg_data.id
  key          = "iceberg/"
  content_type = "application/x-directory"
}

# IAM role for Glue Crawler
resource "aws_iam_role" "glue_crawler_role" {
  name = "${var.project_name}-glue-crawler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# Attach AWS managed Glue service policy
resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Custom policy for S3 access
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
        Resource = [
          "${aws_s3_bucket.iceberg_data.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.iceberg_data.arn
        ]
      }
    ]
  })
}

# AWS Glue Database
resource "aws_glue_catalog_database" "iceberg_db" {
  name        = var.glue_database_name
  description = "Glue database for ClickHouse Iceberg integration"

  tags = var.tags
}

# AWS Glue Crawler for Iceberg tables
resource "aws_glue_crawler" "iceberg_crawler" {
  count = var.enable_glue_crawler ? 1 : 0

  name          = "${var.project_name}-iceberg-crawler"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.iceberg_db.name

  schedule = var.crawler_schedule

  iceberg_target {
    paths = [
      "s3://${aws_s3_bucket.iceberg_data.bucket}/iceberg/"
    ]
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
    CrawlerOutput = {
      Partitions = {
        AddOrUpdateBehavior = "InheritFromTable"
      }
    }
  })

  tags = var.tags
}

# AWS Glue Crawler for CSV data
resource "aws_glue_crawler" "csv_crawler" {
  count = var.enable_glue_crawler ? 1 : 0

  name          = "${var.project_name}-csv-crawler"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.iceberg_db.name

  schedule = var.crawler_schedule

  s3_target {
    path = "s3://${aws_s3_bucket.iceberg_data.bucket}/csv/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = var.tags
}

# AWS Glue Crawler for Parquet data
resource "aws_glue_crawler" "parquet_crawler" {
  count = var.enable_glue_crawler ? 1 : 0

  name          = "${var.project_name}-parquet-crawler"
  role          = aws_iam_role.glue_crawler_role.arn
  database_name = aws_glue_catalog_database.iceberg_db.name

  schedule = var.crawler_schedule

  s3_target {
    path = "s3://${aws_s3_bucket.iceberg_data.bucket}/parquet/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = var.tags
}

# IAM Role for ClickHouse Cloud integration
resource "aws_iam_role" "clickhouse_role" {
  name = "${var.project_name}-clickhouse-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.clickhouse_external_id
          }
        }
      }
    ]
  })

  tags = var.tags
}

# IAM policy for ClickHouse to access S3 and Glue
resource "aws_iam_role_policy" "clickhouse_policy" {
  name = "${var.project_name}-clickhouse-policy"
  role = aws_iam_role.clickhouse_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.iceberg_data.arn,
          "${aws_s3_bucket.iceberg_data.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchGetPartition"
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.iceberg_db.name}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.iceberg_db.name}/*"
        ]
      }
    ]
  })
}
