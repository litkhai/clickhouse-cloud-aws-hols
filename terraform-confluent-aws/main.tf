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

# Security Group for Confluent Platform
resource "aws_security_group" "confluent_sg" {
  name        = "${var.instance_name}-sg"
  description = "Security group for Confluent Platform server"
  vpc_id      = data.aws_vpc.default.id

  # ZooKeeper
  ingress {
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "ZooKeeper"
  }

  # Kafka Broker
  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Kafka Broker"
  }

  # Schema Registry
  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Schema Registry"
  }

  # Kafka Connect
  ingress {
    from_port   = 8083
    to_port     = 8083
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Kafka Connect"
  }

  # Control Center
  ingress {
    from_port   = 9021
    to_port     = 9021
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Confluent Control Center Web UI"
  }

  # ksqlDB Server
  ingress {
    from_port   = 8088
    to_port     = 8088
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "ksqlDB Server"
  }

  # REST Proxy
  ingress {
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "REST Proxy"
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

# EC2 Instance for Confluent Platform
resource "aws_instance" "confluent" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_pair_name

  vpc_security_group_ids = [aws_security_group.confluent_sg.id]

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
    topic_name        = var.sample_topic_name
    data_interval     = var.data_producer_interval
    confluent_version = var.confluent_version
    sasl_username     = var.kafka_sasl_username
    sasl_password     = var.kafka_sasl_password
  })

  tags = {
    Name = var.instance_name
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# Elastic IP for stable public IP
resource "aws_eip" "confluent_eip" {
  count    = var.use_elastic_ip ? 1 : 0
  instance = aws_instance.confluent.id
  domain   = "vpc"

  tags = {
    Name = "${var.instance_name}-eip"
  }
}