# labs/serving/direct-vs-cache — the AWS side: a load client, one Valkey node, two DynamoDB tables.
# The ClickHouse Cloud service already exists and is not managed here.
#
# No inbound rule anywhere: the client is reached through SSM (send-command), and only the client's
# security group may reach Valkey on 6379.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      lab   = "direct-vs-cache"
      owner = var.owner
      ttl   = var.ttl
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name = "cachelab-${random_id.suffix.hex}"
}

# ---------------------------------------------------------------- network (default VPC)

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "az" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = [var.az]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_route_tables" "default" {
  vpc_id = data.aws_vpc.default.id
}

# DynamoDB traffic stays in the VPC (gateway endpoints have no hourly charge).
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.default.ids
}

resource "aws_security_group" "client" {
  name        = "${local.name}-client"
  description = "cachelab load client: no inbound, all outbound"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "valkey" {
  name        = "${local.name}-valkey"
  description = "cachelab Valkey: 6379 from the load client only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.client.id]
  }
}

# ---------------------------------------------------------------- artifacts bucket

resource "aws_s3_bucket" "artifacts" {
  bucket        = local.name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------- DynamoDB

resource "aws_dynamodb_table" "kv" {
  name         = "${local.name}-kv"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }
}

resource "aws_dynamodb_table" "aside" {
  name         = "${local.name}-aside"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  # Background deletion of expired items lags; cachebench checks `exp` on every read.
  ttl {
    attribute_name = "exp"
    enabled        = true
  }
}

# ---------------------------------------------------------------- ElastiCache for Valkey

resource "aws_elasticache_subnet_group" "valkey" {
  name       = local.name
  subnet_ids = data.aws_subnets.az.ids
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id        = local.name
  description                 = "cachelab single Valkey node"
  engine                      = "valkey"
  engine_version              = var.valkey_engine_version
  node_type                   = var.valkey_node_type
  parameter_group_name        = var.valkey_parameter_group
  num_cache_clusters          = 1
  automatic_failover_enabled  = false
  preferred_cache_cluster_azs = [var.az]
  subnet_group_name           = aws_elasticache_subnet_group.valkey.name
  security_group_ids          = [aws_security_group.valkey.id]
  port                        = 6379
  transit_encryption_enabled  = true
  at_rest_encryption_enabled  = true
  apply_immediately           = true
}

# ---------------------------------------------------------------- load client

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_iam_role" "client" {
  name = "${local.name}-client"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.client.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "client" {
  name = "${local.name}-client"
  role = aws_iam_role.client.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:BatchWriteItem", "dynamodb:DescribeTable"]
        Resource = [aws_dynamodb_table.kv.arn, aws_dynamodb_table.aside.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "client" {
  name = "${local.name}-client"
  role = aws_iam_role.client.name
}

resource "aws_instance" "client" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.client_instance_type
  subnet_id                   = data.aws_subnets.az.ids[0]
  vpc_security_group_ids      = [aws_security_group.client.id]
  iam_instance_profile        = aws_iam_instance_profile.client.name
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  # Enough file descriptors for 512 keep-alive connections per system.
  user_data = <<-EOT
    #!/bin/bash
    mkdir -p /opt/cachebench/results
    echo '* soft nofile 65536' >> /etc/security/limits.conf
    echo '* hard nofile 65536' >> /etc/security/limits.conf
  EOT

  tags = { Name = "${local.name}-client" }
}
