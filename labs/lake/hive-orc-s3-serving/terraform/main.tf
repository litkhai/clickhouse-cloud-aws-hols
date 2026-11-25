# Hive-catalog ORC tables on S3, served by ClickHouse Cloud, with EMR running the same work.
# One bucket (data, Spark scripts, EMR logs), the Glue database Spark writes Hive tables into
# (Glue as the Hive metastore), the role ClickHouse Cloud assumes to read the bucket and the
# catalog, and the two EMR roles. The EMR cluster itself is created by 02-emr.sh, not here.
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
  default_tags {
    tags = { lab = "hive-orc-s3-serving" }
  }
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

# The ClickHouse Cloud service's IAM role (console: service Settings -> Network security information).
variable "chc_iam_role_arn" {
  type = string
}

variable "glue_database" {
  type    = string
  default = "game_lake"
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name = "hive-orc-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "lake" {
  bucket        = local.name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_glue_catalog_database" "lake" {
  name         = var.glue_database
  location_uri = "s3://${aws_s3_bucket.lake.bucket}/warehouse/${var.glue_database}.db"
}

# --- ClickHouse Cloud: read the bucket (s3() / S3 engine) and the catalog (DataLakeCatalog probe)
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
  name = "read-lake"
  role = aws_iam_role.chc.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.lake.arn}/warehouse/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.lake.arn
      },
      {
        Effect   = "Allow"
        Action   = ["glue:GetCatalog", "glue:GetCatalogs", "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartitions"]
        Resource = "*"
      }
    ]
  })
}

# --- EMR: service role and instance profile (AWS managed policies for EMR)
resource "aws_iam_role" "emr_service" {
  name = "${local.name}-emr-service"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "elasticmapreduce.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "emr_service" {
  role       = aws_iam_role.emr_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceRole"
}

resource "aws_iam_role" "emr_ec2" {
  name = "${local.name}-emr-ec2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "emr_ec2" {
  role       = aws_iam_role.emr_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role"
}

resource "aws_iam_instance_profile" "emr_ec2" {
  name = "${local.name}-emr-ec2"
  role = aws_iam_role.emr_ec2.name
}

output "bucket" {
  value = aws_s3_bucket.lake.bucket
}

output "glue_database" {
  value = aws_glue_catalog_database.lake.name
}

output "chc_role_arn" {
  value = aws_iam_role.chc.arn
}

output "emr_service_role" {
  value = aws_iam_role.emr_service.name
}

output "emr_instance_profile" {
  value = aws_iam_instance_profile.emr_ec2.name
}
