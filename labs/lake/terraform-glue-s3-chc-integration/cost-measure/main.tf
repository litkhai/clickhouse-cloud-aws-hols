# Cost measurement for Glue federation (#71): what ClickHouse DataLakeCatalog asks of the Glue Data
# Catalog and of S3. A bucket, an Athena workgroup that writes Iceberg tables and registers them in
# Glue (no crawler), one Glue database, and the role ClickHouse Cloud assumes (aws_role_arn, v26.2+).
# Run by measure.sh; destroy right after. Nothing here has a schedule.

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

# The ClickHouse Cloud service's IAM role (console: service Settings -> Network security information).
variable "chc_iam_role_arn" {
  type = string
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name = "glue-cost-${random_id.suffix.hex}"
  db   = "glue_cost_${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "data" {
  bucket        = local.name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_glue_catalog_database" "this" {
  name = local.db
}

resource "aws_athena_workgroup" "this" {
  name          = local.name
  force_destroy = true
  configuration {
    enforce_workgroup_configuration = true
    result_configuration {
      output_location = "s3://${aws_s3_bucket.data.bucket}/athena-results/"
    }
  }
}

resource "aws_iam_role" "chc" {
  name = "${local.name}-chc"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.chc_iam_role_arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "chc" {
  name = "read-catalog-and-bucket"
  role = aws_iam_role.chc.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["glue:GetCatalog", "glue:GetCatalogs", "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartitions"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.data.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.data.arn
      }
    ]
  })
}

output "bucket" {
  value = aws_s3_bucket.data.bucket
}
output "glue_database" {
  value = aws_glue_catalog_database.this.name
}
output "workgroup" {
  value = aws_athena_workgroup.this.name
}
output "chc_role_arn" {
  value = aws_iam_role.chc.arn
}
