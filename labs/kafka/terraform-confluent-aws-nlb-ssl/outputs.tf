output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.confluent.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip
}

output "instance_public_dns" {
  description = "Public DNS hostname of the EC2 instance"
  value       = aws_instance.confluent.public_dns
}

output "instance_private_ip" {
  description = "Private IP address of the EC2 instance"
  value       = aws_instance.confluent.private_ip
}

output "control_center_url" {
  description = "URL for Confluent Control Center"
  value       = "http://${aws_instance.confluent.public_dns}:9021"
}

output "schema_registry_url" {
  description = "URL for Schema Registry"
  value       = "http://${aws_instance.confluent.public_dns}:8081"
}

output "kafka_connect_url" {
  description = "URL for Kafka Connect"
  value       = "http://${aws_instance.confluent.public_dns}:8083"
}

output "ksqldb_url" {
  description = "URL for ksqlDB Server"
  value       = "http://${aws_instance.confluent.public_dns}:8088"
}

output "rest_proxy_url" {
  description = "URL for REST Proxy"
  value       = "http://${aws_instance.confluent.public_dns}:8082"
}

output "kafka_bootstrap_servers_direct" {
  description = "Kafka bootstrap servers (direct to EC2, SASL_PLAINTEXT, no TLS)"
  value       = "${aws_instance.confluent.public_dns}:9092"
}

output "kafka_bootstrap_servers_nlb" {
  description = "Kafka bootstrap servers via NLB (SSL terminated at NLB, port 9094)"
  value       = "${aws_lb.kafka_nlb.dns_name}:9094"
}

output "nlb_endpoint" {
  description = "Network Load Balancer DNS endpoint"
  value       = aws_lb.kafka_nlb.dns_name
}

output "nlb_ssl_port" {
  description = "NLB SSL listener port"
  value       = "9094"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = var.key_pair_name != null ? "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns}" : "SSH key pair not configured"
}

output "sample_topic_name" {
  description = "Name of the sample topic created"
  value       = var.sample_topic_name
}

output "kafka_sasl_username" {
  description = "Kafka SASL username (API Key)"
  value       = var.kafka_sasl_username
}

output "kafka_sasl_password" {
  description = "Kafka SASL password (API Secret)"
  value       = var.kafka_sasl_password
  sensitive   = true
}

output "connection_info" {
  description = "Complete connection information"
  sensitive   = true
  value       = <<-EOT
    ================================================================================
    Confluent Platform with NLB SSL Termination Architecture
    ================================================================================

    Architecture:
      - Kafka Broker: SASL_PLAINTEXT (NO TLS) on port 9092
      - NLB: SSL/TLS termination, listening on port 9094
      - External clients connect via NLB with SSL

    Kafka Bootstrap Servers:
      Direct to EC2:     ${aws_instance.confluent.public_dns}:9092 [SASL_PLAINTEXT]
      Via NLB (SSL):     ${aws_lb.kafka_nlb.dns_name}:9094 [RECOMMENDED]

    Network Load Balancer:
      NLB Endpoint:      ${aws_lb.kafka_nlb.dns_name}
      NLB SSL Port:      9094

    Public DNS Hostname:    ${aws_instance.confluent.public_dns}
    Public IP Address:      ${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip}

    Authentication:
      SASL Mechanism:    PLAIN
      Username:          ${var.kafka_sasl_username}
      Password:          ${var.kafka_sasl_password}

    SSL Certificate:
      NLB Certificate:   terraform-confluent-aws-nlb-ssl/certs/nlb-certificate.pem
      Note: Self-signed certificate for NLB SSL termination

    Service URLs:
      Control Center:    http://${aws_instance.confluent.public_dns}:9021
      Schema Registry:   http://${aws_instance.confluent.public_dns}:8081
      Kafka Connect:     http://${aws_instance.confluent.public_dns}:8083
      ksqlDB Server:     http://${aws_instance.confluent.public_dns}:8088
      REST Proxy:        http://${aws_instance.confluent.public_dns}:8082

    ================================================================================
  EOT
}

output "useful_commands" {
  description = "Useful commands to manage Confluent Platform"
  value = var.key_pair_name != null ? join("\n", [
    "# Check status",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'sudo /opt/confluent/status.sh'",
    "",
    "# Stop Confluent Platform",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'sudo /opt/confluent/stop.sh'",
    "",
    "# Start Confluent Platform",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'sudo /opt/confluent/start.sh'",
    "",
    "# View data producer logs",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'sudo journalctl -u confluent-producer -f'"
  ]) : "SSH key pair not configured - SSH access not available"
}

output "test_connection" {
  description = "Instructions to test Kafka connection"
  value = var.key_pair_name != null ? join("\n", [
    "# Test direct connection to EC2 (SASL_PLAINTEXT)",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'python3 /opt/confluent/test_kafka_sasl.py'",
    "",
    "# Download the NLB SSL certificate for client testing",
    "# The certificate is in: terraform-confluent-aws-nlb-ssl/certs/nlb-certificate.pem",
    "",
    "# Test via NLB with SSL (from local machine):",
    "# 1. Copy nlb-certificate.pem to your test machine",
    "# 2. Use bootstrap server: ${aws_lb.kafka_nlb.dns_name}:9094",
    "# 3. Set security.protocol=SASL_SSL",
    "# 4. Set ssl.ca.location=nlb-certificate.pem",
    "",
    "# Download Python test script:",
    "scp -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns}:/opt/confluent/test_kafka_sasl.py ."
  ]) : "SSH key pair not configured - cannot retrieve test script"
}
