terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
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

  # Kafka Broker (SASL_SSL with TLS)
  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Kafka Broker (SASL_SSL with TLS)"
  }

  # Kafka Broker (SASL_PLAINTEXT)
  ingress {
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Kafka Broker (SASL_PLAINTEXT)"
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

  user_data = base64gzip(templatefile("${path.module}/user-data.sh", {
    topic_name        = var.sample_topic_name
    data_interval     = var.data_producer_interval
    confluent_version = var.confluent_version
    sasl_username     = var.kafka_sasl_username
    sasl_password     = var.kafka_sasl_password
  }))

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

# Get default subnets for NLB
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Network Load Balancer (create first to get DNS)
resource "aws_lb" "kafka_nlb" {
  name               = "${var.instance_name}-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = data.aws_subnets.default.ids

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.instance_name}-nlb"
  }
}

# Self-signed certificate for NLB SSL (using initial placeholder cert)
resource "aws_acm_certificate" "nlb_cert" {
  private_key      = file("${path.module}/certs/nlb-private-key.pem")
  certificate_body = file("${path.module}/certs/nlb-certificate.pem")

  tags = {
    Name = "${var.instance_name}-nlb-cert"
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      private_key,
      certificate_body,
    ]
  }
}

# Generate certificate with actual NLB DNS and update ACM
resource "null_resource" "update_nlb_cert" {
  depends_on = [aws_lb.kafka_nlb, aws_acm_certificate.nlb_cert]

  triggers = {
    nlb_dns = aws_lb.kafka_nlb.dns_name
    always_run = timestamp()
  }

  provisioner "local-exec" {
    when = create
    command = <<-EOT
      echo "Generating certificate with NLB DNS: ${aws_lb.kafka_nlb.dns_name}"
      cd ${path.module}/certs

      # Generate new certificate with actual NLB DNS
      openssl genrsa -out nlb-private-key-new.pem 2048
      openssl req -new -x509 \
        -key nlb-private-key-new.pem \
        -out nlb-certificate-new.pem \
        -days 365 \
        -subj "/C=US/ST=State/L=City/O=Confluent/CN=kafka-nlb" \
        -addext "subjectAltName=DNS:${aws_lb.kafka_nlb.dns_name}"

      # Replace old certificates
      mv nlb-private-key-new.pem nlb-private-key.pem
      mv nlb-certificate-new.pem nlb-certificate.pem

      echo "✓ Certificate generated for: ${aws_lb.kafka_nlb.dns_name}"
      echo "✓ To update ACM, run: terraform apply -replace='aws_acm_certificate.nlb_cert'"
    EOT
  }
}

# Update Kafka advertised listener with NLB DNS
resource "null_resource" "update_kafka_advertised_listener" {
  depends_on = [aws_lb.kafka_nlb, aws_instance.confluent]

  triggers = {
    nlb_dns = aws_lb.kafka_nlb.dns_name
    instance_id = aws_instance.confluent.id
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = var.ssh_private_key != null ? file(var.ssh_private_key) : null
      host        = aws_instance.confluent.public_ip
      timeout     = "5m"
    }

    inline = [
      "echo 'Waiting for docker-compose to be ready...'",
      "timeout 300 bash -c 'until [ -f /opt/confluent/docker-compose.yml ]; do sleep 5; done' || true",
      "echo 'Updating Kafka advertised listener with NLB DNS: ${aws_lb.kafka_nlb.dns_name}'",
      "sudo sed -i 's/NLB_DNS_PLACEHOLDER/${aws_lb.kafka_nlb.dns_name}/g' /opt/confluent/docker-compose.yml",
      "echo 'Restarting Kafka broker...'",
      "cd /opt/confluent && sudo docker-compose restart broker",
      "echo 'Waiting for Kafka to be ready...'",
      "sleep 30",
      "echo '✓ Kafka advertised listener updated to: ${aws_lb.kafka_nlb.dns_name}:9094'"
    ]
  }
}

# NLB Target Group for Kafka (port 9092)
resource "aws_lb_target_group" "kafka" {
  name     = "${var.instance_name}-kafka-tg"
  port     = 9092
  protocol = "TCP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    enabled             = true
    interval            = 30
    port                = 9092
    protocol            = "TCP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.instance_name}-kafka-tg"
  }
}

# Register EC2 instance with target group
resource "aws_lb_target_group_attachment" "kafka" {
  target_group_arn = aws_lb_target_group.kafka.arn
  target_id        = aws_instance.confluent.id
  port             = 9092
}

# NLB Listener with SSL/TLS termination
resource "aws_lb_listener" "kafka_ssl" {
  load_balancer_arn = aws_lb.kafka_nlb.arn
  port              = 9094
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.nlb_cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kafka.arn
  }
}