terraform {
  required_version = ">= 1.4"

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
  region = var.aws_region

  default_tags {
    tags = {
      purpose = "aurora-analytics-t4g-test"
      owner   = var.owner
      ttl     = var.ttl
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# AL2023 arm64 AMI from the public SSM parameter (latest at apply time)
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  name = "aurora-analytics-lab"

  engine_major   = split(".", var.aurora_engine_version)[0]
  is_serverless  = var.aurora_instance_class == "db.serverless"
  cluster_params = merge({ "aurora_analytics.enabled" = "true" }, var.extra_cluster_parameters)

  # pg_clickhouse 0.11.0 multi-arch (amd64 + arm64) image index digests, read from the
  # GHCR manifest API on 2026-10-09 for the tags 17-0.11.0 and 18-0.11.0.
  pg_clickhouse_image = {
    "17" = "ghcr.io/clickhouse/pg_clickhouse@sha256:620d833aeba3d2723db4684cc77fdd4d48b0ac6a88ea2b78eb8afab079a7a0b8"
    "18" = "ghcr.io/clickhouse/pg_clickhouse@sha256:ce7a2b4bc7ee899fc1b87c82c87435acc8ede0903b138c66a580ccd197f88b29"
  }
}

# The front end's PostgreSQL major must equal the Aurora major (one lab, one version).
# A variable validation cannot read another variable before Terraform 1.9, hence a precondition.
resource "terraform_data" "version_match" {
  lifecycle {
    precondition {
      condition     = var.pg_major == local.engine_major
      error_message = "pg_major (${var.pg_major}) must equal the major of aurora_engine_version (${var.aurora_engine_version})."
    }
  }
}

resource "random_password" "pgfront" {
  length  = 24
  special = false # goes through a shell and docker -e; letters and digits only
}

# ---------------------------------------------------------------- Network

resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = local.name }
}

# One public subnet (first AZ) for both EC2s
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public" }
}

# Two private subnets (two AZs) for the DB subnet group
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.42.${10 + count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${local.name}-private-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name}-public" }
}

# No NAT gateway: the private subnets reach S3 through the gateway endpoint only
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# aurora_analytics reads S3 from the DB instance in a private subnet: it needs a gateway endpoint
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]

  tags = { Name = "${local.name}-s3" }
}

# ---------------------------------------------------------------- Security groups

# Generator / client EC2
resource "aws_security_group" "ec2" {
  name_prefix = "${local.name}-ec2-"
  description = "Generator EC2: SSH from allowed_cidr_blocks"
  vpc_id      = aws_vpc.this.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ec2_ssh" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.ec2.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "ec2_all" {
  security_group_id = aws_security_group.ec2.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# PostgreSQL front end (pg_clickhouse)
resource "aws_security_group" "pgfront" {
  name_prefix = "${local.name}-pgfront-"
  description = "PG front end: 5432 from the generator, SSH from allowed_cidr_blocks"
  vpc_id      = aws_vpc.this.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "pgfront_pg" {
  security_group_id            = aws_security_group.pgfront.id
  description                  = "PostgreSQL from the generator"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.ec2.id
}

resource "aws_vpc_security_group_ingress_rule" "pgfront_ssh" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.pgfront.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

# Egress to ClickHouse Cloud (TLS 9440) and package/image downloads
resource "aws_vpc_security_group_egress_rule" "pgfront_all" {
  security_group_id = aws_security_group.pgfront.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Aurora
resource "aws_security_group" "aurora" {
  name_prefix = "${local.name}-aurora-"
  description = "Aurora: 5432 from the generator only"
  vpc_id      = aws_vpc.this.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "aurora_pg" {
  security_group_id            = aws_security_group.aurora.id
  description                  = "PostgreSQL from the generator"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.ec2.id
}

# aurora_analytics reads S3 from the instance (via the gateway endpoint), so it needs egress
resource "aws_vpc_security_group_egress_rule" "aurora_all" {
  security_group_id = aws_security_group.aurora.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------- S3

resource "aws_s3_bucket" "data" {
  bucket_prefix = "aurora-analytics-lab-"
  force_destroy = true # destroy.sh makes the user type the bucket name first
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------- IAM

# Aurora reads Parquet with aurora_analytics (feature name AuroraAnalytics, trust rds.amazonaws.com,
# minimum s3:GetObject + s3:ListBucket for a directory location; AWS docs read 2026-10-09)
resource "aws_iam_role" "aurora_s3" {
  name_prefix = "${local.name}-aurora-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "aurora_s3" {
  name = "read-bucket"
  role = aws_iam_role.aurora_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.data.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.data.arn
      }
    ]
  })
}

resource "aws_rds_cluster_role_association" "aurora_analytics" {
  count = var.create_aurora ? 1 : 0

  db_cluster_identifier = aws_rds_cluster.this[0].id
  feature_name          = "AuroraAnalytics"
  role_arn              = aws_iam_role.aurora_s3.arn

  depends_on = [aws_iam_role_policy.aurora_s3]
}

# Role ClickHouse Cloud assumes to read the same bucket (optional: needs the service's role ARN)
resource "aws_iam_role" "chc_s3" {
  count = var.chc_iam_role_arn != "" ? 1 : 0

  name_prefix = "${local.name}-chc-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.chc_iam_role_arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "chc_s3" {
  count = var.chc_iam_role_arn != "" ? 1 : 0

  name = "read-bucket"
  role = aws_iam_role.chc_s3[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.data.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.data.arn
      }
    ]
  })
}

# Instance profile shared by both EC2s
resource "aws_iam_role" "ec2" {
  name_prefix = "${local.name}-ec2-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ec2" {
  name = "lab"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "BucketObjects"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
          Resource = "${aws_s3_bucket.data.arn}/*"
        },
        {
          Sid      = "BucketList"
          Effect   = "Allow"
          Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
          Resource = aws_s3_bucket.data.arn
        },
        {
          Sid      = "Metrics"
          Effect   = "Allow"
          Action   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]
          Resource = "*"
        },
        {
          Sid      = "RdsDescribe"
          Effect   = "Allow"
          Action   = ["rds:Describe*"]
          Resource = "*"
        },
        {
          Sid      = "Pricing"
          Effect   = "Allow"
          Action   = ["pricing:GetProducts"]
          Resource = "*"
        }
      ],
      var.create_aurora ? [
        {
          Sid      = "RebootInstance"
          Effect   = "Allow"
          Action   = ["rds:RebootDBInstance"]
          Resource = aws_rds_cluster_instance.this[0].arn
        },
        {
          Sid      = "AuroraMasterSecret"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = aws_rds_cluster.this[0].master_user_secret[0].secret_arn
        }
      ] : []
    )
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "${local.name}-ec2-"
  role        = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------- Aurora

resource "aws_db_subnet_group" "this" {
  name_prefix = "${local.name}-"
  description = "Private subnets for the aurora_analytics lab"
  subnet_ids  = aws_subnet.private[*].id
}

resource "aws_rds_cluster_parameter_group" "this" {
  name_prefix = "${local.name}-"
  family      = "aurora-postgresql${local.engine_major}"
  description = "aurora_analytics lab: aurora_analytics.enabled plus extra_cluster_parameters"

  dynamic "parameter" {
    for_each = local.cluster_params

    content {
      name         = parameter.key
      value        = parameter.value
      apply_method = parameter.key == "aurora_analytics.enabled" ? "immediate" : "pending-reboot"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_rds_cluster" "this" {
  count = var.create_aurora ? 1 : 0

  cluster_identifier = local.name
  engine             = "aurora-postgresql"
  engine_version     = var.aurora_engine_version

  master_username             = "postgres"
  manage_master_user_password = true
  database_name               = "postgres"

  storage_type      = var.aurora_storage_type == "" ? null : var.aurora_storage_type
  storage_encrypted = true

  db_subnet_group_name            = aws_db_subnet_group.this.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  dynamic "serverlessv2_scaling_configuration" {
    for_each = local.is_serverless ? [1] : []

    content {
      min_capacity = var.serverless_min_acu
      max_capacity = var.serverless_max_acu
    }
  }

  depends_on = [terraform_data.version_match]
}

resource "aws_rds_cluster_instance" "this" {
  count = var.create_aurora ? 1 : 0

  identifier         = "${local.name}-1"
  cluster_identifier = aws_rds_cluster.this[0].id
  engine             = aws_rds_cluster.this[0].engine
  engine_version     = aws_rds_cluster.this[0].engine_version
  instance_class     = var.aurora_instance_class

  db_subnet_group_name = aws_db_subnet_group.this.name

  publicly_accessible          = false
  performance_insights_enabled = false
  monitoring_interval          = 0
  apply_immediately            = true
}

# ---------------------------------------------------------------- Generator EC2

resource "aws_instance" "generator" {
  count = var.create_generator ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.generator_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  key_name                    = var.key_name != "" ? var.key_name : null
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.generator_disk_gb
  }

  metadata_options {
    http_tokens = "required"
  }

  # The script reads PG_MAJOR from the environment; the first line is the shebang cloud-init needs.
  user_data = join("\n", [
    "#!/bin/bash",
    "export PG_MAJOR=${var.pg_major}",
    file("${path.module}/user-data/generator.sh"),
  ])
  # A user-data or AMI change must not replace the generator in the middle of a run: it holds R's
  # DuckDB database and the run's out/ (lost once on 2026-10-09, when a user-data edit replaced it).
  user_data_replace_on_change = false
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  tags = { Name = "${local.name}-generator" }
}

# ---------------------------------------------------------------- PG front EC2 (pg_clickhouse)

resource "aws_instance" "pgfront" {
  count = var.create_pgfront ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.pgfront_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.pgfront.id]
  key_name                    = var.key_name != "" ? var.key_name : null
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true # egress to ClickHouse Cloud over the internet

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
  }

  metadata_options {
    http_tokens = "required"
  }

  # The password is in user data (visible with ec2:DescribeInstanceAttribute) and in state: lab only.
  user_data = join("\n", [
    "#!/bin/bash",
    "export PG_MAJOR=${var.pg_major}",
    "export PG_IMAGE=${local.pg_clickhouse_image[var.pg_major]}",
    "export POSTGRES_PASSWORD=${random_password.pgfront.result}",
    file("${path.module}/user-data/pgfront.sh"),
  ])
  user_data_replace_on_change = true

  tags = { Name = "${local.name}-pgfront" }

  depends_on = [terraform_data.version_match]
}
