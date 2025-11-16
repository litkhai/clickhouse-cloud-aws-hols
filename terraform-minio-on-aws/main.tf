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

# Get latest Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Get default VPC
data "aws_vpc" "default" {
  default = true
}

# Security Group for MinIO
resource "aws_security_group" "minio_sg" {
  name        = "${var.instance_name}-sg"
  description = "Security group for MinIO server"
  vpc_id      = data.aws_vpc.default.id

  # MinIO Console (Web UI)
  ingress {
    from_port   = 9001
    to_port     = 9001
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "MinIO Console"
  }

  # MinIO API
  ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "MinIO API"
  }

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "SSH"
  }

  # Outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# EC2 Instance for MinIO
resource "aws_instance" "minio" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_pair_name

  vpc_security_group_ids = [aws_security_group.minio_sg.id]

  root_block_device {
    volume_size           = var.ebs_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true

    tags = {
      Name = "${var.instance_name}-root-volume"
    }
  }

  user_data = templatefile("${path.module}/user-data.sh", {
    minio_root_user     = var.minio_root_user
    minio_root_password = var.minio_root_password
    data_dir            = var.minio_data_dir
  })

  tags = {
    Name = var.instance_name
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# Elastic IP for stable public IP
resource "aws_eip" "minio_eip" {
  count    = var.use_elastic_ip ? 1 : 0
  instance = aws_instance.minio.id
  domain   = "vpc"

  tags = {
    Name = "${var.instance_name}-eip"
  }
}
