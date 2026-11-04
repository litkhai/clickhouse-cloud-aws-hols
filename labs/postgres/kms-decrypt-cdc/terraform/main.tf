terraform {
  required_version = ">= 1.4"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { purpose = "kms-decrypt-cdc-lab", owner = var.owner, ttl = var.ttl }
  }
}

data "aws_availability_zones" "available" { state = "available" }

locals {
  name = "kms-decrypt-cdc-lab"
  # ClickPipes egress for services in AWS ap-northeast-2 created on or after 2025-11-14
  # (docs integrations/clickpipes/static-ips, read 2026-11-04). Older services use the us-east-2 list.
  clickpipes_cidrs = [for ip in var.clickpipes_ips : "${ip}/32"]
}

# ---------------------------------------------------------------- KMS (the application's master key)

resource "aws_kms_key" "app" {
  description             = "${local.name}: wraps the application's AES-256 data keys"
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "app" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.app.key_id
}

# A principal for the ClickHouse Cloud UDF: Cloud UDFs have no cloud identity and no secret store,
# so the UDF gets a static access key that may only call kms:Decrypt on this key.
resource "aws_iam_user" "udf" {
  count = var.create_udf_user ? 1 : 0
  name  = "${local.name}-udf"
}

resource "aws_iam_user_policy" "udf" {
  count = var.create_udf_user ? 1 : 0
  name  = "kms-decrypt-only"
  user  = aws_iam_user.udf[0].name
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["kms:Decrypt"], Resource = aws_kms_key.app.arn }]
  })
}

resource "aws_iam_access_key" "udf" {
  count = var.create_udf_user ? 1 : 0
  user  = aws_iam_user.udf[0].name
}

# Fallback when the account forbids IAM users (an SCP denied iam:CreateUser in the lab account, 2026-11-04):
# a role with the same kms:Decrypt-only policy, assumed by the operator; its STS credentials (1 hour,
# role chaining) go into the UDF's config.json, so the UDF must be re-published before they expire.
data "aws_caller_identity" "me" {}
data "aws_iam_session_context" "me" { arn = data.aws_caller_identity.me.arn }

resource "aws_iam_role" "udf" {
  count = var.create_udf_user ? 0 : 1
  name  = "${local.name}-udf"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { AWS = data.aws_iam_session_context.me.issuer_arn } }]
  })
}

resource "aws_iam_role_policy" "udf" {
  count = var.create_udf_user ? 0 : 1
  name  = "kms-decrypt-only"
  role  = aws_iam_role.udf[0].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["kms:Decrypt"], Resource = aws_kms_key.app.arn }]
  })
}

# ---------------------------------------------------------------- Network (public subnets: ClickPipes reaches Aurora over the internet)

resource "aws_vpc" "this" {
  cidr_block           = "10.43.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.43.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = local.name }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "aurora" {
  name        = "${local.name}-aurora"
  description = "PostgreSQL from ClickPipes egress IPs and the operator"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "ClickPipes (ap-northeast-2)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = local.clickpipes_cidrs
  }
  ingress {
    description = "operator"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------- Aurora PostgreSQL 16 with logical replication

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_rds_cluster_parameter_group" "this" {
  name   = local.name
  family = "aurora-postgresql16"
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "random_password" "master" {
  length  = 24
  special = false
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = local.name
  engine                          = "aurora-postgresql"
  engine_version                  = var.aurora_engine_version
  database_name                   = "app"
  master_username                 = "labadmin"
  master_password                 = random_password.master.result
  db_subnet_group_name            = aws_db_subnet_group.this.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  storage_encrypted               = true # storage encryption (AWS-managed key) — transparent to CDC
  skip_final_snapshot             = true
  apply_immediately               = true
}

resource "aws_rds_cluster_instance" "writer" {
  identifier          = "${local.name}-writer"
  cluster_identifier  = aws_rds_cluster.this.id
  engine              = aws_rds_cluster.this.engine
  engine_version      = aws_rds_cluster.this.engine_version
  instance_class      = var.aurora_instance_class
  publicly_accessible = true
}
